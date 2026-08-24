#!/usr/bin/env bash
set -euo pipefail

VERSION=7.2.0-x1407qa
REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
INPUT_ISO=${INPUT_ISO:-$REPO_ROOT/Fedora-Workstation-Live-44-1.7.aarch64.iso}
EXPECTED_INPUT_ISO_SHA256=${EXPECTED_INPUT_ISO_SHA256:-162ba3c552a2d241c7c63ec26777af0255ee1b5a135adc0be986ceed999933ef}
KERNEL_ARTIFACTS=${KERNEL_ARTIFACTS:-/var/lib/x1407qa-kernel-7.2/artifacts}
FIRMWARE_SOURCE=${FIRMWARE_SOURCE:-$REPO_ROOT/firmware-source}
WORK_ROOT=${WORK_ROOT:-/var/lib/x1407qa-personal-iso}
OUTPUT_ISO=${OUTPUT_ISO:-$PWD/Fedora-44-X1407QA-Linux-7.2.iso}
REPO_ROOT=$(realpath -m "$REPO_ROOT")
INPUT_ISO=$(realpath -m "$INPUT_ISO")
KERNEL_ARTIFACTS=$(realpath -m "$KERNEL_ARTIFACTS")
FIRMWARE_SOURCE=$(realpath -m "$FIRMWARE_SOURCE")
WORK_ROOT=$(realpath -m "$WORK_ROOT")
OUTPUT_ISO=$(realpath -m "$OUTPUT_ISO")
OUTPUT_SHA256=$OUTPUT_ISO.sha256
FIRMWARE_MANIFEST=$REPO_ROOT/firmware/x1407qa-driverstore.sha256
case "$WORK_ROOT" in
    /|/var|/var/tmp|/work|"$REPO_ROOT"|"$REPO_ROOT"/*)
        echo "ERROR: unsafe work root: $WORK_ROOT" >&2
        exit 1
        ;;
esac
[[ $(basename "$WORK_ROOT") == x1407qa-* ]] || {
    echo "ERROR: work root must use an x1407qa-* directory: $WORK_ROOT" >&2
    exit 1
}
for protected_path in "$INPUT_ISO" "$KERNEL_ARTIFACTS" "$FIRMWARE_SOURCE" "$OUTPUT_ISO" "$OUTPUT_SHA256"; do
    case "$protected_path" in
        "$WORK_ROOT"|"$WORK_ROOT"/*)
            echo "ERROR: protected path is inside work root: $protected_path" >&2
            exit 1
            ;;
    esac
done
[[ $INPUT_ISO != "$OUTPUT_ISO" ]] || { echo 'ERROR: input and output ISO paths must differ' >&2; exit 1; }
[[ $INPUT_ISO != "$OUTPUT_SHA256" ]] || { echo 'ERROR: input ISO conflicts with output checksum path' >&2; exit 1; }
ISO_TREE=$WORK_ROOT/iso
SQUASH_TREE=$WORK_ROOT/squash
ROOTFS=$WORK_ROOT/rootfs
ROOTFS_IMAGE=$SQUASH_TREE/LiveOS/rootfs.img
LIVE_IMAGE=$ISO_TREE/LiveOS/squashfs.img
ROOTFS_TYPE=
MOUNTS=()

resolve_driver_store() {
    local candidate
    for candidate in \
        "$FIRMWARE_SOURCE" \
        "$FIRMWARE_SOURCE/DriverStore-Backup/FileRepository" \
        "$FIRMWARE_SOURCE/Windows/System32/DriverStore/FileRepository" \
        "$FIRMWARE_SOURCE/FileRepository"; do
        if [[ -d $candidate && $(basename "$candidate") == FileRepository ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    echo "ERROR: DriverStore FileRepository not found below $FIRMWARE_SOURCE" >&2
    return 1
}

install_x1407qa_firmware() {
    local adsp_source cdsp_source gpu_source qcom_dest wifi_dest wifi_bundle name
    adsp_source=$DRIVER_STORE/qcsubsys_ext_adsp8380.inf_arm64_dad10e5e4880caf9
    cdsp_source=$DRIVER_STORE/qcnspmcdm_ext_cdsp8380.inf_arm64_a2e536ad01025a78
    gpu_source=$DRIVER_STORE/qcdx8380.inf_arm64_e13ac55ddce2b10f
    qcom_dest=$ROOTFS/usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14
    wifi_dest=$ROOTFS/usr/lib/firmware/ath11k/WCN6855/hw2.1
    for name in \
        adsp_dtbs.elf adspr.jsn adsps.jsn adspua.jsn battmgr.jsn \
        qcadsp8380.mbn; do
        install -Dm0644 "$adsp_source/$name" "$qcom_dest/$name"
    done
    for name in cdsp_dtbs.elf cdspr.jsn qccdsp8380.mbn; do
        install -Dm0644 "$cdsp_source/$name" "$qcom_dest/$name"
    done
    for name in qcdxkmsuc8380.mbn qcdxkmsucpurwa.mbn qcvss8380.mbn; do
        install -Dm0644 "$gpu_source/$name" "$qcom_dest/$name"
    done
    wifi_bundle=$REPO_ROOT/firmware/ath11k/WCN6855/hw2.1
    echo "00756e19aee2b5e6725f5029b7e6abea748caca0f53af5a7662cd32086dde4bd  $wifi_bundle/amss.bin" |
        sha256sum --check --status || {
        echo 'ERROR: bundled amss.bin is not the validated wlanfw20.mbn variant' >&2
        return 1
    }
    for name in amss.bin board.bin m3.bin regdb.bin; do
        install -Dm0644 "$wifi_bundle/$name" "$wifi_dest/$name"
    done
}

cleanup() {
    local mountpoint
    for ((i=${#MOUNTS[@]}-1; i>=0; i--)); do
        mountpoint=${MOUNTS[$i]}
        mountpoint -q "$mountpoint" && umount "$mountpoint" || true
    done
    [[ -n ${OUTPUT_TMP:-} ]] && rm -f -- "$OUTPUT_TMP"
}
trap cleanup EXIT

need() { command -v "$1" >/dev/null || { echo "ERROR: missing command: $1" >&2; exit 1; }; }
for command in xorriso unsquashfs mksquashfs fsck.erofs mkfs.erofs e2fsck resize2fs rsync dracut lsinitrd sha256sum file mktemp; do need "$command"; done
if [[ $(uname -m) != aarch64 ]]; then
    BINFMT_QEMU_AARCH64=${BINFMT_QEMU_AARCH64:-/proc/sys/fs/binfmt_misc/qemu-aarch64}
    grep -qx enabled "$BINFMT_QEMU_AARCH64" 2>/dev/null || {
        echo 'ERROR: ARM64 host or qemu-aarch64 binfmt is required' >&2
        exit 1
    }
fi
[[ -f $INPUT_ISO ]] || { echo "ERROR: Fedora ISO missing: $INPUT_ISO" >&2; exit 1; }
echo "$EXPECTED_INPUT_ISO_SHA256  $INPUT_ISO" | sha256sum --check --status || {
    echo 'ERROR: Fedora input ISO checksum mismatch' >&2; exit 1;
}
"$REPO_ROOT/kernel/verify-linux-7.2-x1407qa.sh" "$KERNEL_ARTIFACTS" >/dev/null
[[ -s $KERNEL_ARTIFACTS/boot/vmlinuz-$VERSION ]] || { echo 'ERROR: verified Linux 7.2 artifacts missing' >&2; exit 1; }
[[ -s $KERNEL_ARTIFACTS/lib/modules/$VERSION/modules.dep ]] || { echo 'ERROR: Linux 7.2 modules missing' >&2; exit 1; }
[[ -s $KERNEL_ARTIFACTS/boot/dtb/qcom/x1p42100-asus-zenbook-a14.dtb ]] || { echo 'ERROR: Vivobook DTB missing' >&2; exit 1; }
DRIVER_STORE=$(resolve_driver_store)
[[ -s $FIRMWARE_MANIFEST ]] || { echo "ERROR: firmware manifest missing: $FIRMWARE_MANIFEST" >&2; exit 1; }
(cd "$DRIVER_STORE" && sha256sum --check "$FIRMWARE_MANIFEST")

rm -rf "$WORK_ROOT"
mkdir -p "$ISO_TREE" "$SQUASH_TREE" "$ROOTFS"
echo '[1/8] Extracting Fedora ISO'
xorriso -osirrox on -indev "$INPUT_ISO" -extract / "$ISO_TREE" >/dev/null 2>&1
chmod -R u+w "$ISO_TREE"

echo '[2/8] Opening live filesystem'
if file "$LIVE_IMAGE" | grep -q EROFS; then
    ROOTFS_TYPE=erofs
    fsck.erofs --extract="$ROOTFS" "$LIVE_IMAGE" >/dev/null
else
    ROOTFS_TYPE=squashfs
    unsquashfs -d "$SQUASH_TREE" "$LIVE_IMAGE" >/dev/null
    truncate -s +2G "$ROOTFS_IMAGE"
    e2fsck -fy "$ROOTFS_IMAGE" >/dev/null || true
    resize2fs "$ROOTFS_IMAGE" >/dev/null
    mount -o loop "$ROOTFS_IMAGE" "$ROOTFS"
    MOUNTS+=("$ROOTFS")
fi
mkdir -p "$ROOTFS/run/lock"
chroot "$ROOTFS" rpm --restore -a
"$REPO_ROOT/tools/verify-live-root.sh" "$ROOTFS"

echo '[3/8] Installing Linux 7.2 kernel and modules'
install -Dm0644 "$KERNEL_ARTIFACTS/boot/vmlinuz-$VERSION" "$ROOTFS/boot/vmlinuz-$VERSION"
install -Dm0644 "$KERNEL_ARTIFACTS/boot/config-$VERSION" "$ROOTFS/boot/config-$VERSION"
install -Dm0644 "$KERNEL_ARTIFACTS/boot/dtb/qcom/x1p42100-asus-zenbook-a14.dtb" \
    "$ROOTFS/boot/dtb/qcom/x1p42100-asus-zenbook-a14.dtb"
mkdir -p "$ROOTFS/lib/modules"
rsync -a "$KERNEL_ARTIFACTS/lib/modules/$VERSION/" "$ROOTFS/lib/modules/$VERSION/"

echo '[4/8] Installing X1407QA modules and selected firmware'
install_x1407qa_firmware
mkdir -p "$ROOTFS/usr/src"
for module_dir in \
    wcn-regulator-fix-1.0 \
    vivobook-hotkey-fix-1.0 \
    vivobook-kbd-fix-1.0 \
    vivobook-bl-fix-1.0; do
    rsync -a --exclude='*.o' --exclude='*.ko' --exclude='*.mod*' \
        --exclude='Module.symvers' --exclude='modules.order' \
        "$REPO_ROOT/modules/$module_dir/" "$ROOTFS/usr/src/$module_dir/"
done
mkdir -p "$ROOTFS/etc/modules-load.d" "$ROOTFS/etc/dracut.conf.d"
cat > "$ROOTFS/etc/modules-load.d/10-vivobook-hotkey.conf" <<'EOF'
vivobook_hotkey_fix
EOF
cat > "$ROOTFS/etc/modules-load.d/20-vivobook-kbd.conf" <<'EOF'
vivobook_kbd_fix
EOF
cat > "$ROOTFS/etc/modules-load.d/30-wcn-regulator.conf" <<'EOF'
pwrseq_qcom_wcn
wcn_regulator_fix
EOF
cat > "$ROOTFS/etc/modules-load.d/40-vivobook-backlight.conf" <<'EOF'
vivobook_bl_fix
EOF
mkdir -p "$ROOTFS/etc/systemd/system/multi-user.target.wants"
cat > "$ROOTFS/etc/systemd/system/x1407qa-adsp-after-live-ram.service" <<'EOF'
[Unit]
Description=Start X1407QA ADSP after the live image is safe in RAM
After=local-fs.target systemd-modules-load.service
ConditionKernelCommandLine=rd.live.ram
ConditionPathExists=/run/initramfs/squashed.img

[Service]
Type=oneshot
ExecStart=/usr/sbin/modprobe qcom_q6v5_pas

[Install]
WantedBy=multi-user.target
EOF
ln -s ../x1407qa-adsp-after-live-ram.service \
    "$ROOTFS/etc/systemd/system/multi-user.target.wants/x1407qa-adsp-after-live-ram.service"
cat > "$ROOTFS/etc/dracut.conf.d/90-x1407qa-hardware.conf" <<'EOF'
force_drivers+=" vivobook_hotkey_fix vivobook_kbd_fix pwrseq_qcom_wcn wcn_regulator_fix "
add_drivers+=" vivobook_bl_fix "
install_items+=" /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/qcadsp8380.mbn /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/adsp_dtbs.elf /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/adspr.jsn /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/adsps.jsn /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/adspua.jsn /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/battmgr.jsn /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/qccdsp8380.mbn /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/cdsp_dtbs.elf /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/cdspr.jsn /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/qcdxkmsucpurwa.mbn /usr/lib/firmware/qcom/gen71500_sqe.fw.xz /usr/lib/firmware/qcom/gen71500_gmu.bin.xz "
EOF

LIVEINST_SETUP=$ROOTFS/usr/libexec/liveinst-setup.sh
[[ -f $LIVEINST_SETUP ]] || { echo 'ERROR: Fedora live installer setup script missing' >&2; exit 1; }
grep -qF '/dev/mapper/live-osimg-min' "$LIVEINST_SETUP" || {
    echo 'ERROR: unrecognized Fedora live installer setup script' >&2
    exit 1
}
sed -i 's#\[ ! -b /dev/mapper/live-osimg-min \]; then#[ ! -b /dev/mapper/live-osimg-min ] \&\& [ ! -e /run/initramfs/livedev ]; then#' "$LIVEINST_SETUP"
grep -qF '[ ! -b /dev/mapper/live-osimg-min ] && [ ! -e /run/initramfs/livedev ]; then' "$LIVEINST_SETUP" || {
    echo 'ERROR: failed to enable installer launcher for EROFS live boot' >&2
    exit 1
}
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
for ((i=${#MOUNTS[@]}-1; i>=BASE_MOUNTS; i--)); do
    if mountpoint -q "${MOUNTS[$i]}"; then
        umount -R "${MOUNTS[$i]}"
    fi
done
MOUNTS=("${MOUNTS[@]:0:$BASE_MOUNTS}")

echo '[5b/8] Making the live root installable'
"$REPO_ROOT/tools/make-rootfs-installable.sh" "$ROOTFS"

echo '[6/8] Creating RAM, fallback USB and diagnostic Linux 7.2 boot entries'
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

menuentry "Fedora 44 X1407QA — Linux 7.2 (RAM, principal)" --class fedora --class gnu-linux {
    devicetree ($root)/boot/aarch64/loader/x1p42100-asus-vivobook-x1407qa.dtb
    linux ($root)/boot/aarch64/loader/linux quiet rhgb root=live:CDLABEL=Fedora-WS-Live-44 rd.live.image rd.live.ram rd.minmem=4096 clk_ignore_unused pd_ignore_unused systemd.tpm2_wait=0 modprobe.blacklist=qcom_q6v5_pas rd.driver.pre=pwrseq_qcom_wcn rd.driver.pre=wcn_regulator_fix rd.systemd.mask=dev-tpm0.device rd.systemd.mask=dev-tpmrm0.device
    initrd ($root)/boot/aarch64/loader/initrd
}
menuentry "Fedora 44 X1407QA — Linux 7.2 (fallback USB)" --class fedora --class gnu-linux {
    devicetree ($root)/boot/aarch64/loader/x1p42100-asus-vivobook-x1407qa.dtb
    linux ($root)/boot/aarch64/loader/linux quiet rhgb root=live:CDLABEL=Fedora-WS-Live-44 rd.live.image clk_ignore_unused pd_ignore_unused systemd.tpm2_wait=0 modprobe.blacklist=qcom_q6v5_pas rd.driver.pre=pwrseq_qcom_wcn rd.driver.pre=wcn_regulator_fix rd.systemd.mask=dev-tpm0.device rd.systemd.mask=dev-tpmrm0.device
    initrd ($root)/boot/aarch64/loader/initrd
}
menuentry "Fedora 44 X1407QA — Linux 7.2 (diagnóstico)" --class fedora --class gnu-linux {
    devicetree ($root)/boot/aarch64/loader/x1p42100-asus-vivobook-x1407qa.dtb
    linux ($root)/boot/aarch64/loader/linux root=live:CDLABEL=Fedora-WS-Live-44 rd.live.image rd.debug log_buf_len=1M clk_ignore_unused pd_ignore_unused systemd.tpm2_wait=0 modprobe.blacklist=qcom_q6v5_pas rd.driver.pre=pwrseq_qcom_wcn rd.driver.pre=wcn_regulator_fix rd.systemd.mask=dev-tpm0.device rd.systemd.mask=dev-tpmrm0.device
    initrd ($root)/boot/aarch64/loader/initrd
}
GRUB

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
OUTPUT_TMP=$(mktemp --tmpdir="$(dirname "$OUTPUT_ISO")" ".$(basename "$OUTPUT_ISO").partial.XXXXXX")
xorriso -indev "$INPUT_ISO" -outdev "$OUTPUT_TMP" -update_r "$ISO_TREE" / -boot_image any replay >/dev/null 2>&1
mv -f -- "$OUTPUT_TMP" "$OUTPUT_ISO"
chmod 0644 "$OUTPUT_ISO"
OUTPUT_TMP=

echo '[8/8] Verifying output and writing SHA256'
ISO_FILES=$WORK_ROOT/iso-files.txt
xorriso -indev "$OUTPUT_ISO" -find /boot/aarch64/loader -type f >"$ISO_FILES" 2>&1
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
