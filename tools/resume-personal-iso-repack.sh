#!/usr/bin/env bash
set -euo pipefail

VERSION=7.2.0-x1407qa
REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
INPUT_ISO=${INPUT_ISO:-$REPO_ROOT/Fedora-Workstation-Live-44-1.7.aarch64.iso}
KERNEL_ARTIFACTS=${KERNEL_ARTIFACTS:-/var/lib/x1407qa-kernel-7.2/artifacts}
WORK_ROOT=${WORK_ROOT:-/var/lib/x1407qa-personal-iso}
OUTPUT_ISO=${OUTPUT_ISO:-$PWD/Fedora-44-X1407QA-Linux-7.2.iso}
REPO_ROOT=$(realpath -m "$REPO_ROOT")
INPUT_ISO=$(realpath -m "$INPUT_ISO")
KERNEL_ARTIFACTS=$(realpath -m "$KERNEL_ARTIFACTS")
WORK_ROOT=$(realpath -m "$WORK_ROOT")
OUTPUT_ISO=$(realpath -m "$OUTPUT_ISO")
OUTPUT_SHA256=$OUTPUT_ISO.sha256
ISO_TREE=$WORK_ROOT/iso
ROOTFS=$WORK_ROOT/rootfs
LIVE_IMAGE=$ISO_TREE/LiveOS/squashfs.img
INITRD_LIST=$WORK_ROOT/initrd-list.txt
INITRD_MODULES=$WORK_ROOT/initrd-modules.txt
OUTPUT_TMP=

cleanup() {
    if [[ -n $OUTPUT_TMP ]]; then
        rm -f -- "$OUTPUT_TMP"
    fi
}
trap cleanup EXIT

[[ $(basename "$WORK_ROOT") == x1407qa-* ]] || {
    echo "ERROR: work root must use an x1407qa-* directory: $WORK_ROOT" >&2
    exit 1
}
[[ -s $INPUT_ISO ]] || { echo "ERROR: input ISO missing: $INPUT_ISO" >&2; exit 1; }
[[ -d $ROOTFS/usr ]] || { echo 'ERROR: completed extracted root is missing' >&2; exit 1; }
file "$LIVE_IMAGE" | grep -q EROFS || { echo 'ERROR: resume only supports EROFS live images' >&2; exit 1; }
"$REPO_ROOT/tools/verify-live-root.sh" "$ROOTFS"
for path in dev proc sys run; do
    mountpoint -q "$ROOTFS/$path" && {
        echo "ERROR: stale mount in live root: $path" >&2
        exit 1
    }
done

lsinitrd "$ROOTFS/boot/initramfs-$VERSION.img" > "$INITRD_LIST"
lsinitrd -m "$ROOTFS/boot/initramfs-$VERSION.img" > "$INITRD_MODULES"
for module in dmsquash-live livenet pollcdrom; do
    grep -qxF "$module" "$INITRD_MODULES" || {
        echo "ERROR: initramfs missing dracut module $module" >&2
        exit 1
    }
done
grep -Eq '/pwrseq-qcom-wcn\.ko(\.|$)' "$INITRD_LIST" || {
    echo 'ERROR: initramfs missing X1407QA module pwrseq_qcom_wcn' >&2
    exit 1
}
for module in wcn_regulator_fix vivobook_hotkey_fix vivobook_kbd_fix vivobook_bl_fix; do
    grep -Eq "/$module\.ko(\.|$)" "$INITRD_LIST" || {
        echo "ERROR: initramfs missing X1407QA module $module" >&2
        exit 1
    }
done
for firmware in qcadsp8380.mbn qccdsp8380.mbn qcdxkmsucpurwa.mbn gen71500_sqe.fw gen71500_gmu.bin; do
    grep -qF "/$firmware" "$INITRD_LIST" || {
        echo "ERROR: initramfs missing X1407QA firmware $firmware" >&2
        exit 1
    }
done
if grep -Eq '^(iscsi|nvmf)$' "$INITRD_MODULES" || grep -Eq 'parse-iscsiroot|iscsi_tcp' "$INITRD_LIST"; then
    echo 'ERROR: initramfs unexpectedly contains iSCSI support' >&2
    exit 1
fi
module_trees=$(grep -oE 'usr/lib/modules/[0-9][^/ ]*' "$INITRD_LIST" | sort -u)
[[ $module_trees == "usr/lib/modules/$VERSION" ]] || {
    echo "ERROR: initramfs kernel module trees do not match $VERSION: $module_trees" >&2
    exit 1
}

echo '[5b/8] Making the live root installable'
"$REPO_ROOT/tools/make-rootfs-installable.sh" "$ROOTFS"

echo '[6/8] Creating RAM, fallback USB and diagnostic Linux 7.2 boot entries'
LOADER=$ISO_TREE/boot/aarch64/loader
install -m0644 "$KERNEL_ARTIFACTS/boot/vmlinuz-$VERSION" "$LOADER/linux"
install -m0644 "$ROOTFS/boot/initramfs-$VERSION.img" "$LOADER/initrd"
install -Dm0644 "$KERNEL_ARTIFACTS/boot/dtb/qcom/x1p42100-asus-zenbook-a14.dtb" \
    "$LOADER/x1p42100-asus-vivobook-x1407qa.dtb"
awk 'copy && $0 == "GRUB" { exit } copy { print } /^cat > .*grub\.cfg.*GRUB/ { copy=1 }' \
    "$REPO_ROOT/tools/build-personal-maximal-iso.sh" > "$ISO_TREE/boot/grub2/grub.cfg"
grep -qF 'rd.driver.pre=pwrseq_qcom_wcn rd.driver.pre=wcn_regulator_fix' \
    "$ISO_TREE/boot/grub2/grub.cfg" || { echo 'ERROR: failed to generate WCN boot order' >&2; exit 1; }

echo '[7/8] Repacking live filesystem and bootable ISO'
for module in wcn_regulator_fix vivobook_hotkey_fix vivobook_kbd_fix vivobook_bl_fix; do
    find "$ROOTFS/lib/modules/$VERSION" -type f -name "$module.ko*" -size +0c \
        -print -quit | grep -q . || {
            echo "ERROR: live root missing X1407QA module $module" >&2
            exit 1
        }
done
for path in \
    usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/qcadsp8380.mbn \
    usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/qccdsp8380.mbn \
    usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/qcdxkmsucpurwa.mbn \
    usr/lib/firmware/ath11k/WCN6855/hw2.1/board.bin; do
    [[ -s $ROOTFS/$path ]] || { echo "ERROR: live root missing $path" >&2; exit 1; }
done
[[ -L $ROOTFS/etc/systemd/system/multi-user.target.wants/x1407qa-adsp-after-live-ram.service ]] || {
    echo 'ERROR: live root ADSP-after-RAM service is not enabled' >&2
    exit 1
}
[[ -s $ROOTFS/usr/share/anaconda/post-scripts/90-x1407qa-bootloader.ks ]] || {
    echo 'ERROR: live root is missing the installer bootloader post-script' >&2
    exit 1
}
[[ ! -e $ROOTFS/opt/vivobook-fixes/repository ]] || {
    echo 'ERROR: live root unexpectedly contains the repository payload' >&2
    exit 1
}
rm -f "$LIVE_IMAGE.new"
mkfs.erofs -zlz4hc,12 -L Fedora-WS-44 "$LIVE_IMAGE.new" "$ROOTFS" >/dev/null
mv "$LIVE_IMAGE.new" "$LIVE_IMAGE"
OUTPUT_TMP=$(mktemp --tmpdir="$(dirname "$OUTPUT_ISO")" ".$(basename "$OUTPUT_ISO").partial.XXXXXX")
xorriso -indev "$INPUT_ISO" -outdev "$OUTPUT_TMP" -update_r "$ISO_TREE" / -boot_image any replay >/dev/null 2>&1
mv -f -- "$OUTPUT_TMP" "$OUTPUT_ISO"
chmod 0644 "$OUTPUT_ISO"
OUTPUT_TMP=

echo '[8/8] Verifying output and writing SHA256'
ISO_FILES=$WORK_ROOT/iso-files.txt
xorriso -indev "$OUTPUT_ISO" -find /boot/aarch64/loader -type f > "$ISO_FILES" 2>&1
grep -q '/boot/aarch64/loader/linux' "$ISO_FILES"
grep -q '/boot/aarch64/loader/initrd' "$ISO_FILES"
grep -q 'x1p42100-asus-vivobook-x1407qa.dtb' "$ISO_FILES"
grep -qF 'rd.live.ram rd.minmem=4096' "$ISO_TREE/boot/grub2/grub.cfg"
grep -qF 'fallback USB' "$ISO_TREE/boot/grub2/grub.cfg"
fallback_linux=$(awk '/menuentry .*fallback USB/ { found=1 } found && /^[[:space:]]*linux / { print; exit }' "$ISO_TREE/boot/grub2/grub.cfg")
[[ $fallback_linux != *rd.live.ram* && $fallback_linux == *modprobe.blacklist=qcom_q6v5_pas* ]] || {
    echo 'ERROR: USB fallback RAM/ADSP policy is invalid' >&2
    exit 1
}
(cd "$(dirname "$OUTPUT_ISO")" && sha256sum "$(basename "$OUTPUT_ISO")") > "$OUTPUT_SHA256"
echo "PASS: $OUTPUT_ISO"
cat "$OUTPUT_SHA256"
