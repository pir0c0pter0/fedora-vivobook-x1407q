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
FIRMWARE_ROOT=/usr/lib/firmware
RESOLVED_REMOTEPROC_FIRMWARE=(
    /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/qcadsp8380.mbn
    /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/adsp_dtbs.elf
    /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/qccdsp8380.mbn
    /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/cdsp_dtbs.elf
    /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/adspr.jsn
    /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/adsps.jsn
    /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/adspua.jsn
    /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/battmgr.jsn
    /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/cdspr.jsn
)
RESOLVED_GPU_FIRMWARE=(
    /usr/lib/firmware/qcom/gen71500_sqe.fw.xz
    /usr/lib/firmware/qcom/gen71500_gmu.bin.xz
    /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/qcdxkmsucpurwa.mbn
)
RESOLVED_BLUETOOTH_FIRMWARE=(
    /usr/lib/firmware/qca/hpbtfw21.tlv.xz
    /usr/lib/firmware/qca/hpnv21.bin.xz
)

run_dracut_candidate() {
    local ignored_kernel=$1 candidate=$2
    truncate -s 2097152 "$candidate"
}
inspect_initramfs_candidate() {
    printf '%s\n' \
        qcom_q6v5_pas.ko qcom_q6v5_adsp.ko qcom_glink_smem.ko \
        "${RESOLVED_REMOTEPROC_FIRMWARE[@]#/}" \
        "${RESOLVED_GPU_FIRMWARE[@]#/}" \
        "${RESOLVED_BLUETOOTH_FIRMWARE[@]#/}" \
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

# A later successful publication must not replace the first known-good backup.
printf 'image-before-second-success\n' > "$target"
publish_initramfs_candidate "$kernel"
[[ $(<"$backup") == known-old-image ]] || {
    echo 'a rerun overwrote the original initramfs backup' >&2
    exit 1
}

# A durability failure must occur before promotion, leaving the target intact.
printf 'must-survive-sync-failure\n' > "$target"
sync_initramfs_path() {
    [[ $1 != "$test_root" ]]
}
if publish_initramfs_candidate "$kernel"; then
    echo 'candidate was promoted despite a directory sync failure' >&2
    exit 1
fi
[[ $(<"$target") == must-survive-sync-failure ]] || {
    echo 'sync failure changed the active target' >&2
    exit 1
}
sync_initramfs_path() { command sync -f "$1"; }

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

# A single missing resolved firmware path must reject the candidate just like a
# missing module.  No selected firmware is allowed to escape validation.
printf 'must-survive-firmware-validation-failure\n' > "$target"
inspect_initramfs_candidate() {
    printf '%s\n' \
        qcom_q6v5_pas.ko qcom_q6v5_adsp.ko qcom_glink_smem.ko \
        "${RESOLVED_REMOTEPROC_FIRMWARE[@]#/}" \
        "${RESOLVED_GPU_FIRMWARE[@]#/}" \
        /usr/lib/firmware/qca/hpbtfw21.tlv.xz \
        wcn_regulator_fix.ko vivobook_kbd_fix.ko \
        vivobook_bl_fix.ko vivobook_hotkey_fix.ko
}
if publish_initramfs_candidate "$kernel"; then
    echo 'candidate was promoted without every resolved Bluetooth firmware item' >&2
    exit 1
fi
[[ $(<"$target") == must-survive-firmware-validation-failure ]] || {
    echo 'missing firmware validation changed the active target' >&2
    exit 1
}
if find "$test_root" -maxdepth 1 \
    \( -name '*.candidate.*' -o -name '*.listing.*' -o -name '*.new.*' \) \
    -print -quit | grep -q .; then
    echo 'candidate failure leaked temporary files' >&2
    exit 1
fi

echo 'PASS: initramfs publication is candidate-validated and atomic'
