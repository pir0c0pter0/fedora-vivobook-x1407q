#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
build_script=$root/kernel/build-linux-7.2-wifi-wcn6855-delay-diagnostic.sh
patch_file=$root/kernel/linux-7.2-wifi-wcn6855-delay.patch
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

[[ -x $build_script ]] || {
    echo 'Linux 7.2 WCN6855 delay diagnostic builder missing' >&2
    exit 1
}
[[ -f $patch_file && ! -L $patch_file ]] || {
    echo 'Linux 7.2 WCN6855 delay diagnostic patch missing or unsafe' >&2
    exit 1
}

source_root=$test_root/linux-7.2
target=$source_root/drivers/power/sequencing/pwrseq-qcom-wcn.c
mkdir -p "$(dirname "$target")"
printf '%s\n' 'VERSION = 7' 'PATCHLEVEL = 2' 'SUBLEVEL = 0' > "$source_root/Makefile"
cat > "$target" <<'EOF'
static int pwrseq_qcom_wcn_pwup_delay(struct pwrseq_device *pwrseq)
{
	struct pwrseq_qcom_wcn_ctx *ctx = pwrseq_device_get_drvdata(pwrseq);

	if (ctx->pdata->pwup_delay_ms)
		msleep(ctx->pdata->pwup_delay_ms);

	return 0;
}

static const struct pwrseq_qcom_wcn_pdata pwrseq_wcn6855_of_data = {
	.vregs = pwrseq_wcn6855_vregs,
	.num_vregs = ARRAY_SIZE(pwrseq_wcn6855_vregs),
	.pwup_delay_ms = 50,
	.gpio_enable_delay_ms = 5,
	.targets = pwrseq_qcom_wcn6855_targets,
};
EOF

patch --batch --forward --fuzz=0 --dry-run -d "$source_root" -p1 < "$patch_file" >/dev/null
patch --batch --forward --fuzz=0 -d "$source_root" -p1 < "$patch_file" >/dev/null

grep -qxF $'\t.pwup_delay_ms = 6000,' "$target" || {
    echo 'diagnostic patch did not set the WCN6855 stabilization delay to 6000 ms' >&2
    exit 1
}
grep -qxF $'\t.gpio_enable_delay_ms = 5,' "$target" || {
    echo 'diagnostic patch changed the WCN6855 GPIO enable delay' >&2
    exit 1
}
grep -qF 'X1407QA Wi-Fi diagnostic: WCN6855 stabilization delay 6000 ms' "$target" || {
    echo 'diagnostic patch did not add its runtime marker' >&2
    exit 1
}

changed_paths=$(sed -n 's|^diff --git a/[^ ]* b/||p' "$patch_file")
[[ $changed_paths == drivers/power/sequencing/pwrseq-qcom-wcn.c ]] || {
    echo "diagnostic patch changes paths outside WCN pwrseq: $changed_paths" >&2
    exit 1
}

if patch --batch --forward --fuzz=0 --dry-run -d "$source_root" -p1 \
    < "$patch_file" >/dev/null 2>&1; then
    echo 'diagnostic patch applies twice to the same source tree' >&2
    exit 1
fi

fake_repo=$test_root/fake-repo
fake_artifacts=$test_root/output/wcn-delay
fake_no_marker=$test_root/output/no-marker
mkdir -p "$fake_repo/kernel"
cp "$build_script" "$patch_file" "$fake_repo/kernel/"
cat > "$fake_repo/kernel/build-linux-7.2-x1407qa.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
artifact_root=${3:?}
module_root="$artifact_root/lib/modules/${X1407QA_KERNEL_VERSION}/kernel/drivers/power/sequencing"
mkdir -p "$artifact_root/boot" "$module_root"
printf 'kernel image\n' > "$artifact_root/boot/vmlinuz-${X1407QA_KERNEL_VERSION}"
if [[ ${X1407QA_TEST_OMIT_MARKER:-0} != 1 ]]; then
    printf '%s\n' 'X1407QA Wi-Fi diagnostic: WCN6855 stabilization delay 6000 ms' \
        > "$module_root/pwrseq-qcom-wcn.ko"
else
    printf 'module without marker\n' > "$module_root/pwrseq-qcom-wcn.ko"
fi
printf '%s\n' \
    "version=${X1407QA_KERNEL_VERSION-}" \
    "localversion=${X1407QA_LOCALVERSION-}" \
    "patch=${X1407QA_SOURCE_PATCH-}" \
    "reference=${X1407QA_REFERENCE_CONFIG-}" \
    "tarball=${1-}" \
    "work=${2-}" \
    "artifacts=${3-}"
EOF
chmod +x "$fake_repo/kernel/build-linux-7.2-x1407qa.sh"

wrapper_output=$(
    X1407QA_REFERENCE_CONFIG=/inputs/config-7.2.0-x1407qa \
        "$fake_repo/kernel/$(basename "$build_script")" \
        /inputs/linux-7.2.tar.xz /build/wcn-delay "$fake_artifacts"
)
grep -qxF 'version=7.2.0-x1407qa-wifi-wcn6855-delay-diag' <<< "$wrapper_output"
grep -qxF 'localversion=-x1407qa-wifi-wcn6855-delay-diag' <<< "$wrapper_output"
grep -qxF "patch=$fake_repo/kernel/$(basename "$patch_file")" <<< "$wrapper_output"
grep -qxF 'reference=/inputs/config-7.2.0-x1407qa' <<< "$wrapper_output"
grep -qxF 'work=/build/wcn-delay' <<< "$wrapper_output"
grep -qxF "artifacts=$fake_artifacts" <<< "$wrapper_output"

if X1407QA_TEST_OMIT_MARKER=1 \
    "$fake_repo/kernel/$(basename "$build_script")" \
    /inputs/linux-7.2.tar.xz /build/no-marker "$fake_no_marker" >/dev/null 2>&1; then
    echo 'diagnostic builder accepted a WCN pwrseq module without the delay marker' >&2
    exit 1
fi

echo 'PASS: Linux 7.2 diagnostic isolates the WCN6855 stabilization delay'
