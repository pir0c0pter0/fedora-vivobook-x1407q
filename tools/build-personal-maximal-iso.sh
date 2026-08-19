#!/usr/bin/env bash
set -euo pipefail

VERSION=7.2.0-x1407qa
REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
INPUT_ISO=${INPUT_ISO:-$REPO_ROOT/Fedora-Workstation-Live-44-1.7.aarch64.iso}
EXPECTED_INPUT_ISO_SHA256=${EXPECTED_INPUT_ISO_SHA256:-162ba3c552a2d241c7c63ec26777af0255ee1b5a135adc0be986ceed999933ef}
KERNEL_ARTIFACTS=${KERNEL_ARTIFACTS:-/var/lib/x1407qa-kernel-7.2/artifacts}
FIRMWARE_CATALOG=${FIRMWARE_CATALOG:-$REPO_ROOT/firmware-catalog}
WORK_ROOT=${WORK_ROOT:-/var/lib/x1407qa-personal-iso}
OUTPUT_ISO=${OUTPUT_ISO:-$PWD/Fedora-44-X1407QA-Linux-7.2.iso}
ISO_TREE=$WORK_ROOT/iso
SQUASH_TREE=$WORK_ROOT/squash
ROOTFS=$WORK_ROOT/rootfs
ROOTFS_IMAGE=$SQUASH_TREE/LiveOS/rootfs.img
LIVE_IMAGE=$ISO_TREE/LiveOS/squashfs.img
ROOTFS_TYPE=
MOUNTS=()

cleanup() {
    local mountpoint
    for ((i=${#MOUNTS[@]}-1; i>=0; i--)); do
        mountpoint=${MOUNTS[$i]}
        mountpoint -q "$mountpoint" && umount "$mountpoint" || true
    done
}
trap cleanup EXIT

need() { command -v "$1" >/dev/null || { echo "ERROR: missing command: $1" >&2; exit 1; }; }
for command in xorriso unsquashfs mksquashfs fsck.erofs mkfs.erofs e2fsck resize2fs rsync dracut lsinitrd sha256sum file; do need "$command"; done
[[ $(uname -m) == aarch64 ]] || { echo 'ERROR: ISO customization must run in the ARM64 builder' >&2; exit 1; }
[[ -f $INPUT_ISO ]] || { echo "ERROR: Fedora ISO missing: $INPUT_ISO" >&2; exit 1; }
echo "$EXPECTED_INPUT_ISO_SHA256  $INPUT_ISO" | sha256sum --check --status || {
    echo 'ERROR: Fedora input ISO checksum mismatch' >&2; exit 1;
}
"$REPO_ROOT/kernel/verify-linux-7.2-x1407qa.sh" "$KERNEL_ARTIFACTS" >/dev/null
[[ -s $KERNEL_ARTIFACTS/boot/vmlinuz-$VERSION ]] || { echo 'ERROR: verified Linux 7.2 artifacts missing' >&2; exit 1; }
[[ -s $KERNEL_ARTIFACTS/lib/modules/$VERSION/modules.dep ]] || { echo 'ERROR: Linux 7.2 modules missing' >&2; exit 1; }
[[ -s $KERNEL_ARTIFACTS/boot/dtb/qcom/x1p42100-asus-zenbook-a14.dtb ]] || { echo 'ERROR: Vivobook DTB missing' >&2; exit 1; }

rm -rf "$WORK_ROOT"
mkdir -p "$ISO_TREE" "$SQUASH_TREE" "$ROOTFS"
echo '[1/8] Extracting Fedora ISO'
xorriso -osirrox on -indev "$INPUT_ISO" -extract / "$ISO_TREE" >/dev/null 2>&1
chmod -R u+w "$ISO_TREE"

echo '[2/8] Opening live filesystem'
if file "$LIVE_IMAGE" | grep -q EROFS; then
    ROOTFS_TYPE=erofs
    (umask 000; fsck.erofs --no-preserve-perms --extract="$ROOTFS" "$LIVE_IMAGE" >/dev/null)
else
    ROOTFS_TYPE=squashfs
    unsquashfs -d "$SQUASH_TREE" "$LIVE_IMAGE" >/dev/null
    truncate -s +2G "$ROOTFS_IMAGE"
    e2fsck -fy "$ROOTFS_IMAGE" >/dev/null || true
    resize2fs "$ROOTFS_IMAGE" >/dev/null
    mount -o loop "$ROOTFS_IMAGE" "$ROOTFS"
    MOUNTS+=("$ROOTFS")
fi

echo '[3/8] Installing Linux 7.2 kernel and modules'
install -Dm0644 "$KERNEL_ARTIFACTS/boot/vmlinuz-$VERSION" "$ROOTFS/boot/vmlinuz-$VERSION"
install -Dm0644 "$KERNEL_ARTIFACTS/boot/config-$VERSION" "$ROOTFS/boot/config-$VERSION"
install -Dm0644 "$KERNEL_ARTIFACTS/boot/dtb/qcom/x1p42100-asus-zenbook-a14.dtb" \
    "$ROOTFS/boot/dtb/qcom/x1p42100-asus-zenbook-a14.dtb"
mkdir -p "$ROOTFS/lib/modules"
rsync -a "$KERNEL_ARTIFACTS/lib/modules/$VERSION/" "$ROOTFS/lib/modules/$VERSION/"

echo '[4/8] Bundling repository and PC firmware catalog'
mkdir -p "$ROOTFS/opt/vivobook-fixes"
rsync -a --exclude='.git/' --exclude='*.iso' "$REPO_ROOT/" "$ROOTFS/opt/vivobook-fixes/repository/"
if [[ -d $FIRMWARE_CATALOG ]]; then
    rsync -a "$FIRMWARE_CATALOG/" "$ROOTFS/opt/vivobook-fixes/firmware-catalog/"
fi
if [[ -f $REPO_ROOT/docs/superpowers/specs/2026-08-08-personal-maximal-iso-design.md ]]; then
    install -Dm0644 "$REPO_ROOT/docs/superpowers/specs/2026-08-08-personal-maximal-iso-design.md" \
        "$ROOTFS/opt/vivobook-fixes/ISO-DESIGN.md"
fi

echo '[5/8] Generating Linux 7.2 initramfs inside Fedora live root'
BASE_MOUNTS=${#MOUNTS[@]}
for path in dev proc sys run; do
    mount --rbind "/$path" "$ROOTFS/$path"
    mount --make-rslave "$ROOTFS/$path"
    MOUNTS+=("$ROOTFS/$path")
done
chroot "$ROOTFS" depmod "$VERSION"
chroot "$ROOTFS" dracut --force --no-hostonly --add 'dmsquash-live livenet pollcdrom' \
    --omit 'iscsi nvmf' \
    "/boot/initramfs-$VERSION.img" "$VERSION"
INITRD_LIST=$WORK_ROOT/initrd-list.txt
INITRD_MODULES=$WORK_ROOT/initrd-modules.txt
lsinitrd "$ROOTFS/boot/initramfs-$VERSION.img" > "$INITRD_LIST"
lsinitrd -m "$ROOTFS/boot/initramfs-$VERSION.img" > "$INITRD_MODULES"
for module in dmsquash-live livenet pollcdrom; do
    grep -qxF "$module" "$INITRD_MODULES" || {
        echo "ERROR: initramfs missing dracut module $module" >&2
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
for ((i=${#MOUNTS[@]}-1; i>=BASE_MOUNTS; i--)); do
    mountpoint -q "${MOUNTS[$i]}" && umount -R "${MOUNTS[$i]}" || true
done
MOUNTS=("${MOUNTS[@]:0:$BASE_MOUNTS}")

echo '[6/8] Creating normal and diagnostic Linux 7.2 boot entries'
LOADER=$ISO_TREE/boot/aarch64/loader
install -m0644 "$KERNEL_ARTIFACTS/boot/vmlinuz-$VERSION" "$LOADER/linux"
install -m0644 "$ROOTFS/boot/initramfs-$VERSION.img" "$LOADER/initrd"
install -Dm0644 "$KERNEL_ARTIFACTS/boot/dtb/qcom/x1p42100-asus-zenbook-a14.dtb" \
    "$LOADER/x1p42100-asus-vivobook-x1407qa.dtb"
cat > "$ISO_TREE/boot/grub2/grub.cfg" <<'GRUB'
set default="0"
set timeout=12
set timeout_style=menu
insmod gzio
insmod part_gpt
insmod ext2
terminal_input console
terminal_output console
search --file --set=root /boot/0x503d6c7e

menuentry "Fedora 44 X1407QA — Linux 7.2 (principal)" --class fedora --class gnu-linux {
    devicetree ($root)/boot/aarch64/loader/x1p42100-asus-vivobook-x1407qa.dtb
    linux ($root)/boot/aarch64/loader/linux quiet rhgb root=live:CDLABEL=Fedora-WS-Live-44 rd.live.image clk_ignore_unused pd_ignore_unused
    initrd ($root)/boot/aarch64/loader/initrd
}
menuentry "Fedora 44 X1407QA — Linux 7.2 (diagnóstico)" --class fedora --class gnu-linux {
    devicetree ($root)/boot/aarch64/loader/x1p42100-asus-vivobook-x1407qa.dtb
    linux ($root)/boot/aarch64/loader/linux root=live:CDLABEL=Fedora-WS-Live-44 rd.live.image rd.debug log_buf_len=1M clk_ignore_unused pd_ignore_unused
    initrd ($root)/boot/aarch64/loader/initrd
}
GRUB

echo '[7/8] Repacking live filesystem and bootable ISO'
if [[ $ROOTFS_TYPE == erofs ]]; then
    rm -f "$LIVE_IMAGE.new"
    mkfs.erofs -zlz4hc,12 -L Fedora-WS-44 "$LIVE_IMAGE.new" "$ROOTFS" >/dev/null
    mv "$LIVE_IMAGE.new" "$LIVE_IMAGE"
else
    umount "$ROOTFS"
    MOUNTS=()
    e2fsck -fy "$ROOTFS_IMAGE" >/dev/null || true
    resize2fs -M "$ROOTFS_IMAGE" >/dev/null
    rm -f "$LIVE_IMAGE"
    mksquashfs "$SQUASH_TREE" "$LIVE_IMAGE" -comp xz -b 1M -Xdict-size 100% -no-recovery -processors "$(nproc)" >/dev/null
fi
rm -f "$OUTPUT_ISO"
xorriso -indev "$INPUT_ISO" -outdev "$OUTPUT_ISO" -update_r "$ISO_TREE" / -boot_image any replay >/dev/null 2>&1

echo '[8/8] Verifying output and writing SHA256'
ISO_FILES=$WORK_ROOT/iso-files.txt
xorriso -indev "$OUTPUT_ISO" -find /boot/aarch64/loader -type f >"$ISO_FILES" 2>&1
grep -q '/boot/aarch64/loader/linux' "$ISO_FILES"
grep -q '/boot/aarch64/loader/initrd' "$ISO_FILES"
grep -q 'x1p42100-asus-vivobook-x1407qa.dtb' "$ISO_FILES"
sha256sum "$OUTPUT_ISO" > "$OUTPUT_ISO.sha256"
echo "PASS: $OUTPUT_ISO"
cat "$OUTPUT_ISO.sha256"
