#!/usr/bin/env bash
set -euo pipefail

WORK_ROOT=${WORK_ROOT:-/var/lib/x1407qa-personal-iso}
REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
INPUT_ISO=${INPUT_ISO:-$REPO_ROOT/Fedora-Workstation-Live-44-1.7.aarch64.iso}
OUTPUT_ISO=${OUTPUT_ISO:-$PWD/Fedora-44-X1407QA-Linux-7.2.iso}
LIVE_IMAGE=$WORK_ROOT/iso/LiveOS/squashfs.img
ROOTFS=$WORK_ROOT/rootfs

[[ -d $ROOTFS/usr ]] || { echo 'ERROR: completed extracted root is missing' >&2; exit 1; }
[[ -f $WORK_ROOT/iso/boot/aarch64/loader/linux-fedora-recovery ]] || { echo 'ERROR: recovery kernel is missing' >&2; exit 1; }
[[ -f $WORK_ROOT/iso/boot/aarch64/loader/x1p42100-asus-vivobook-x1407qa.dtb ]] || { echo 'ERROR: Vivobook DTB is missing' >&2; exit 1; }

echo '[7/8] Repacking EROFS'
rm -f "$LIVE_IMAGE.new"
mkfs.erofs -zlz4hc,12 -L Fedora-WS-44 "$LIVE_IMAGE.new" "$ROOTFS"
mv "$LIVE_IMAGE.new" "$LIVE_IMAGE"

echo '[7/8] Rebuilding bootable ISO'
rm -f "$OUTPUT_ISO"
xorriso -indev "$INPUT_ISO" -outdev "$OUTPUT_ISO" \
    -update_r "$WORK_ROOT/iso" / -boot_image any replay

echo '[8/8] Writing SHA256'
sha256sum "$OUTPUT_ISO" > "$OUTPUT_ISO.sha256"
cat "$OUTPUT_ISO.sha256"
