#!/usr/bin/env bash
set -euo pipefail

setup=setup-vivobook.sh
for token in \
    'mktemp --tmpdir="$target_dir"' \
    'dracut --force --kver "$kernel" "$candidate"' \
    'lsinitrd "$candidate"' \
    'qcom_q6v5_pas.ko' \
    'qcom_q6v5_adsp.ko' \
    'qcom_glink_smem.ko' \
    'wcn_regulator_fix.ko' \
    'vivobook_kbd_fix.ko' \
    'vivobook_bl_fix.ko' \
    'vivobook_hotkey_fix.ko' \
    'mv -Tf -- "$candidate" "$target"'; do
    grep -qF "$token" "$setup" || {
        echo "safe initramfs candidate contract missing: $token" >&2
        exit 1
    }
done

if grep -qE '^[[:space:]]*dracut --force[[:space:]]*$' "$setup"; then
    echo 'setup retains direct in-place dracut invocation' >&2
    exit 1
fi

test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT
export VIVOBOOK_SETUP_LIBRARY_ONLY=1
export INITRAMFS_BOOT_DIR="$test_root"
# shellcheck source=../setup-vivobook.sh
source "$setup"

kernel=7.2.0-x1407qa
target="$test_root/initramfs-${kernel}.img"
backup="${target}.vivobook-backup"
printf 'known-old-image\n' > "$target"

run_dracut_candidate() {
    local ignored_kernel=$1 candidate=$2
    truncate -s 2097152 "$candidate"
}
inspect_initramfs_candidate() {
    printf '%s\n' \
        qcom_q6v5_pas.ko qcom_q6v5_adsp.ko qcom_glink_smem.ko \
        qcadsp8380.mbn adsp_dtbs.elf qccdsp8380.mbn cdsp_dtbs.elf \
        wcn_regulator_fix.ko vivobook_kbd_fix.ko \
        vivobook_bl_fix.ko vivobook_hotkey_fix.ko
}
publish_initramfs_candidate "$kernel"
[[ $(<"$backup") == known-old-image ]] || {
    echo 'candidate promotion did not retain the prior image backup' >&2
    exit 1
}
[[ $(stat -c %s "$target") -eq 2097152 ]] || {
    echo 'validated candidate was not promoted' >&2
    exit 1
}

printf 'must-survive-validation-failure\n' > "$target"
inspect_initramfs_candidate() { printf '%s\n' qcom_q6v5_pas.ko; }
if publish_initramfs_candidate "$kernel"; then
    echo 'incomplete candidate was incorrectly promoted' >&2
    exit 1
fi
[[ $(<"$target") == must-survive-validation-failure ]] || {
    echo 'failed candidate changed the active target' >&2
    exit 1
}
if find "$test_root" -maxdepth 1 \
    \( -name '*.candidate.*' -o -name '*.listing.*' -o -name '*.new.*' \) \
    -print -quit | grep -q .; then
    echo 'candidate failure leaked temporary files' >&2
    exit 1
fi

echo 'PASS: initramfs publication is candidate-validated and atomic'
