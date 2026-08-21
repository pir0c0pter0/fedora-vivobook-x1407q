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

[[ $post_init_line -lt $perst_line && $perst_line -lt $power_line && $power_line -lt $marker_line ]] || {
    echo 'diagnostic patch did not isolate PERST-before-WCN-power ordering' >&2
    exit 1
}

power_failure_block=$(awk '
    /ret = pci_pwrctrl_power_on_devices\(pci->dev\);/ { capture = 1 }
    capture { print }
    capture && /goto err_pwrctrl_destroy;/ { exit }
' "$target")
grep -qF 'qcom_pcie_perst_assert(pcie);' <<< "$power_failure_block" || {
    echo 'diagnostic power-on failure does not reassert PERST#' >&2
    exit 1
}
grep -qF 'goto err_pwrctrl_destroy;' <<< "$power_failure_block" || {
    echo 'diagnostic power-on failure does not bypass duplicate power-off' >&2
    exit 1
}
! grep -qF 'goto err_assert_reset;' <<< "$power_failure_block" || {
    echo 'diagnostic power-on failure still enters duplicate power-off cleanup' >&2
    exit 1
}

if "$apply_script" "$source_root" >/dev/null 2>&1; then
    echo 'diagnostic patch applicator accepted an already-patched tree' >&2
    exit 1
fi

wrong_root=$test_root/linux-7.1
mkdir -p "$(dirname "$wrong_root/drivers/pci/controller/dwc/pcie-qcom.c")"
printf '%s\n' 'VERSION = 7' 'PATCHLEVEL = 1' 'SUBLEVEL = 0' > "$wrong_root/Makefile"
cp "$target" "$wrong_root/drivers/pci/controller/dwc/pcie-qcom.c"
wrong_version_output=$test_root/wrong-version-output
if "$apply_script" "$wrong_root" >"$wrong_version_output" 2>&1; then
    echo 'diagnostic patch applicator accepted a non-7.2 source tree' >&2
    exit 1
fi
grep -qF 'requires pristine Linux 7.2.0 sources' "$wrong_version_output" || {
    echo 'non-7.2 source tree was rejected for the wrong reason' >&2
    exit 1
}

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

verify_fixture=$test_root/verify-fixture
verify_version=7.2.0-x1407qa-wifi-pwrctrl-diag
reference_config=$test_root/stable-reference.config
mkdir -p \
    "$verify_fixture/boot/dtb/qcom" \
    "$verify_fixture/lib/modules/$verify_version/kernel/drivers/net/usb" \
    "$test_root/bin"
printf 'ARM64 image\nLinux version %s test\n%s\n' \
    "$verify_version" \
    'X1407QA Wi-Fi diagnostic: PERST# deasserted before WCN power-on' \
    > "$verify_fixture/boot/vmlinuz-$verify_version"
: > "$verify_fixture/lib/modules/$verify_version/modules.dep"
printf 'module dependency\n' > "$verify_fixture/lib/modules/$verify_version/modules.dep"
printf 'diagnostic dtb\n' > "$verify_fixture/boot/dtb/qcom/x1p42100-asus-zenbook-a14.dtb"
printf 'RNDIS module\n' > \
    "$verify_fixture/lib/modules/$verify_version/kernel/drivers/net/usb/rndis_host.ko"
printf '%s\n' \
    'CONFIG_USB=y' \
    'CONFIG_USB_USBNET=m' \
    'CONFIG_USB_NET_CDCETHER=m' \
    'CONFIG_USB_NET_RNDIS_HOST=m' \
    'CONFIG_TYPEC=m' \
    'CONFIG_TYPEC_UCSI=m' \
    'CONFIG_UCSI_PMIC_GLINK=m' \
    > "$reference_config"
printf '%s\n' \
    'CONFIG_USB=y' \
    'CONFIG_USB_USBNET=m' \
    'CONFIG_USB_NET_CDCETHER=m' \
    'CONFIG_USB_NET_RNDIS_HOST=m' \
    'CONFIG_TYPEC=m' \
    'CONFIG_TYPEC_UCSI=m' \
    'CONFIG_UCSI_PMIC_GLINK=m' \
    'CONFIG_ISO9660_FS=y' \
    'CONFIG_JOLIET=y' \
    'CONFIG_EROFS_FS=y' \
    'CONFIG_EROFS_FS_ZIP=y' \
    'CONFIG_DM_SNAPSHOT=m' \
    'CONFIG_QCOM_Q6V5_PAS=m' \
    'CONFIG_QCOM_Q6V5_ADSP=m' \
    'CONFIG_QCOM_PMIC_GLINK=m' \
    'CONFIG_BATTERY_QCOM_BATTMGR=m' \
    > "$verify_fixture/boot/config-$verify_version"
(cd "$verify_fixture" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
cat > "$test_root/bin/file" <<'EOF'
#!/usr/bin/env bash
printf '%s: Linux kernel ARM64 boot executable Image\n' "$1"
EOF
chmod +x "$test_root/bin/file"
cat > "$test_root/bin/modinfo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ $1 == -F && $# == 3 ]]
field=$2
module=$3
case "$field" in
    name) sed -n 's/^name=//p' "$module" | grep -m1 . ;;
    vermagic) sed -n 's/^vermagic=//p' "$module" | grep -m1 . ;;
    *) exit 2 ;;
esac
EOF
chmod +x "$test_root/bin/modinfo"

printf 'name=rndis_host\nvermagic=%s SMP preempt mod_unload aarch64\n' \
    "$verify_version" > \
    "$verify_fixture/lib/modules/$verify_version/kernel/drivers/net/usb/rndis_host.ko"
(cd "$verify_fixture" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)

verify_test_repo=$test_root/verify-repo
mkdir -p "$verify_test_repo/kernel"
reference_hash=$(sha256sum "$reference_config" | awk '{print $1}')
sed "s/^readonly EXPECTED_REFERENCE_SHA256=.*/readonly EXPECTED_REFERENCE_SHA256=$reference_hash/" \
    "$root/kernel/verify-linux-usb-config-preservation.sh" > \
    "$verify_test_repo/kernel/verify-linux-usb-config-preservation.sh"
cp "$root/kernel/verify-linux-7.2-x1407qa.sh" \
    "$verify_test_repo/kernel/verify-linux-7.2-x1407qa.sh"
chmod +x "$verify_test_repo/kernel/"*.sh
verify_script=$verify_test_repo/kernel/verify-linux-7.2-x1407qa.sh

PATH="$test_root/bin:$PATH" \
    X1407QA_REFERENCE_CONFIG="$reference_config" \
    "$verify_script" "$verify_fixture" "$verify_version" >/dev/null

sed -i '/CONFIG_USB_NET_RNDIS_HOST=m/d' "$verify_fixture/boot/config-$verify_version"
(cd "$verify_fixture" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
if PATH="$test_root/bin:$PATH" \
    X1407QA_REFERENCE_CONFIG="$reference_config" \
    "$verify_script" "$verify_fixture" "$verify_version" >/dev/null 2>&1; then
    echo 'diagnostic verifier accepted a kernel without RNDIS tethering' >&2
    exit 1
fi
sed -i '/CONFIG_USB_NET_CDCETHER=m/a CONFIG_USB_NET_RNDIS_HOST=m' \
    "$verify_fixture/boot/config-$verify_version"

rm "$verify_fixture/lib/modules/$verify_version/kernel/drivers/net/usb/rndis_host.ko"
(cd "$verify_fixture" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
if PATH="$test_root/bin:$PATH" \
    X1407QA_REFERENCE_CONFIG="$reference_config" \
    "$verify_script" "$verify_fixture" "$verify_version" >/dev/null 2>&1; then
    echo 'diagnostic verifier accepted artifacts without rndis_host.ko' >&2
    exit 1
fi
printf 'name=rndis_host\nvermagic=%s SMP preempt mod_unload aarch64\n' \
    "$verify_version" > \
    "$verify_fixture/lib/modules/$verify_version/kernel/drivers/net/usb/rndis_host.ko"

printf 'not a kernel module\n' > \
    "$verify_fixture/lib/modules/$verify_version/kernel/drivers/net/usb/rndis_host.ko"
(cd "$verify_fixture" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
if PATH="$test_root/bin:$PATH" \
    X1407QA_REFERENCE_CONFIG="$reference_config" \
    "$verify_script" "$verify_fixture" "$verify_version" >/dev/null 2>&1; then
    echo 'diagnostic verifier accepted a corrupt RNDIS module' >&2
    exit 1
fi
printf 'name=rndis_host\nvermagic=%s SMP preempt mod_unload aarch64\n' \
    "$verify_version" > \
    "$verify_fixture/lib/modules/$verify_version/kernel/drivers/net/usb/rndis_host.ko"

(cd "$verify_fixture" && find . -type f ! -name SHA256SUMS \
    ! -name 'rndis_host.ko' -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
if PATH="$test_root/bin:$PATH" \
    X1407QA_REFERENCE_CONFIG="$reference_config" \
    "$verify_script" "$verify_fixture" "$verify_version" >/dev/null 2>&1; then
    echo 'diagnostic verifier accepted an RNDIS module absent from SHA256SUMS' >&2
    exit 1
fi

printf 'name=rndis_host\nvermagic=wrong-release SMP preempt mod_unload aarch64\n' > \
    "$verify_fixture/lib/modules/$verify_version/kernel/drivers/net/usb/rndis_host.ko"
(cd "$verify_fixture" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
if PATH="$test_root/bin:$PATH" \
    X1407QA_REFERENCE_CONFIG="$reference_config" \
    "$verify_script" "$verify_fixture" "$verify_version" >/dev/null 2>&1; then
    echo 'diagnostic verifier accepted an RNDIS module with wrong vermagic' >&2
    exit 1
fi
printf 'name=rndis_host\nvermagic=%s SMP preempt mod_unload aarch64\n' \
    "$verify_version" > \
    "$verify_fixture/lib/modules/$verify_version/kernel/drivers/net/usb/rndis_host.ko"

sed -i '/X1407QA Wi-Fi diagnostic:/d' "$verify_fixture/boot/vmlinuz-$verify_version"
(cd "$verify_fixture" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
if PATH="$test_root/bin:$PATH" \
    X1407QA_REFERENCE_CONFIG="$reference_config" \
    "$verify_script" "$verify_fixture" "$verify_version" >/dev/null 2>&1; then
    echo 'diagnostic verifier accepted an Image without the diagnostic marker' >&2
    exit 1
fi

echo 'PASS: Linux 7.2 Wi-Fi diagnostic build isolates PERST-before-power ordering'
