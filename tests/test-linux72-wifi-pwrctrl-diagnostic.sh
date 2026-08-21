#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
apply_script=$root/kernel/apply-linux-7.2-wifi-pwrctrl-diagnostic.sh
build_script=$root/kernel/build-linux-7.2-wifi-pwrctrl-diagnostic.sh
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

[[ -x $apply_script ]] || {
    echo 'Linux 7.2 Wi-Fi diagnostic patch applicator missing' >&2
    exit 1
}
[[ -x $build_script ]] || {
    echo 'Linux 7.2 Wi-Fi diagnostic builder missing' >&2
    exit 1
}

source_root=$test_root/linux-7.2
target=$source_root/drivers/pci/controller/dwc/pcie-qcom.c
mkdir -p "$(dirname "$target")"
printf '%s\n' 'VERSION = 7' 'PATCHLEVEL = 2' 'SUBLEVEL = 0' > "$source_root/Makefile"
cat > "$target" <<'EOF'
static int qcom_pcie_host_init(struct dw_pcie_rp *pp)
{
	struct dw_pcie *pci = to_dw_pcie_from_pp(pp);
	struct qcom_pcie *pcie = to_qcom_pcie(pci);
	int ret;

	qcom_pcie_perst_assert(pcie);

	ret = pcie->cfg->ops->init(pcie);
	if (ret)
		return ret;

	ret = qcom_pcie_phy_power_on(pcie);
	if (ret)
		goto err_deinit;

	if (!pci->suspended) {
		ret = pci_pwrctrl_create_devices(pci->dev);
		if (ret)
			goto err_disable_phy;
	}

	if (!pp->skip_pwrctrl_off) {
		ret = pci_pwrctrl_power_on_devices(pci->dev);
		if (ret)
			goto err_pwrctrl_destroy;
	}

	if (pcie->cfg->ops->post_init) {
		ret = pcie->cfg->ops->post_init(pcie);
		if (ret)
			goto err_pwrctrl_power_off;
	}

	qcom_pcie_clear_aspm_l0s(pcie->pci);
	dw_pcie_remove_capability(pcie->pci, PCI_CAP_ID_MSIX);
	dw_pcie_remove_ext_capability(pcie->pci, PCI_EXT_CAP_ID_DPC);

	qcom_pcie_configure_ports(pcie);

	qcom_pcie_perst_deassert(pcie);

	if (pcie->cfg->ops->config_sid) {
		ret = pcie->cfg->ops->config_sid(pcie);
		if (ret)
			goto err_assert_reset;
	}

	return 0;

err_assert_reset:
	qcom_pcie_perst_assert(pcie);
err_pwrctrl_power_off:
	if (!pp->skip_pwrctrl_off)
		pci_pwrctrl_power_off_devices(pci->dev);
err_pwrctrl_destroy:
	if (ret != -EPROBE_DEFER && !pci->suspended)
		pci_pwrctrl_destroy_devices(pci->dev);
err_disable_phy:
	qcom_pcie_phy_power_off(pcie);
err_deinit:
	pcie->cfg->ops->deinit(pcie);

	return ret;
}
EOF

"$apply_script" "$source_root"

perst_line=$(rg -n '^\s*qcom_pcie_perst_deassert\(pcie\);' "$target" | cut -d: -f1)
marker_line=$(rg -n 'X1407QA Wi-Fi diagnostic: PERST# deasserted before WCN power-on' "$target" | cut -d: -f1)
power_line=$(rg -n '^\s*ret = pci_pwrctrl_power_on_devices\(pci->dev\);' "$target" | cut -d: -f1)
post_init_line=$(rg -n '^\s*if \(pcie->cfg->ops->post_init\)' "$target" | cut -d: -f1)

[[ $post_init_line -lt $perst_line && $perst_line -lt $marker_line && $marker_line -lt $power_line ]] || {
    echo 'diagnostic patch did not isolate PERST-before-WCN-power ordering' >&2
    exit 1
}

if "$apply_script" "$source_root" >/dev/null 2>&1; then
    echo 'diagnostic patch applicator accepted an already-patched tree' >&2
    exit 1
fi

wrong_root=$test_root/linux-7.1
mkdir -p "$wrong_root"
printf '%s\n' 'VERSION = 7' 'PATCHLEVEL = 1' 'SUBLEVEL = 0' > "$wrong_root/Makefile"
if "$apply_script" "$wrong_root" >/dev/null 2>&1; then
    echo 'diagnostic patch applicator accepted a non-7.2 source tree' >&2
    exit 1
fi

fake_repo=$test_root/fake-repo
mkdir -p "$fake_repo/kernel"
cp "$build_script" "$fake_repo/kernel/"
cp "$root/kernel/linux-7.2-wifi-pwrctrl-order.patch" "$fake_repo/kernel/"
cat > "$fake_repo/kernel/build-linux-7.2-x1407qa.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' \
    "version=${X1407QA_KERNEL_VERSION-}" \
    "localversion=${X1407QA_LOCALVERSION-}" \
    "patch=${X1407QA_SOURCE_PATCH-}" \
    "tarball=${1-}" \
    "work=${2-}" \
    "artifacts=${3-}"
EOF
chmod +x "$fake_repo/kernel/build-linux-7.2-x1407qa.sh"

wrapper_output=$(
    "$fake_repo/kernel/build-linux-7.2-wifi-pwrctrl-diagnostic.sh" \
        /inputs/linux-7.2.tar.xz /build/diag /output/diag
)
grep -qxF 'version=7.2.0-x1407qa-wifi-pwrctrl-diag' <<< "$wrapper_output"
grep -qxF 'localversion=-x1407qa-wifi-pwrctrl-diag' <<< "$wrapper_output"
grep -qxF "patch=$fake_repo/kernel/linux-7.2-wifi-pwrctrl-order.patch" <<< "$wrapper_output"
grep -qxF 'work=/build/diag' <<< "$wrapper_output"
grep -qxF 'artifacts=/output/diag' <<< "$wrapper_output"

echo 'PASS: Linux 7.2 Wi-Fi diagnostic build isolates PERST-before-power ordering'
