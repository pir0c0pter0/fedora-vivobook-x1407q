#!/usr/bin/env bash
# Run in the Yoga build container with /work mounted.
set -euo pipefail
cd "${1:-/work/public-live-20261118}"
stage=$PWD
root=$stage/rootfs
base=/work/downloads/Fedora-Workstation-Live-45-1.4.aarch64.iso
kernel=/work/kernel-out
version=$(cat "$kernel/include/config/kernel.release")
image=$stage/Yoga-14Q8Y11-Live-45-20261118.iso
[[ $version == 7.4.0-rc1-yoga-kalambo+ && ! -e $image && ! -e $image.partial ]]
echo "ad73a977709d417f5b7dda4147fc071396b9d8d2bdcca2df615aa3aab7673710  $base" | sha256sum -c -
rpm --root "$root" -q generic-release generic-logos generic-release-notes
for package in fedora-logos fedora-release-workstation; do
    ! rpm --root "$root" -q "$package" >/dev/null
done

# The RPM payload is shared with Fedora; remove the replaced kernel and unrelated device firmware.
mapfile -t obsolete < <(rpm --root "$root" -qa --qf '%{NAME}\n' |
    grep -E '^(kernel(-modules(-core|-extra)?|-uki-dtbloader)?|linux-firmware|amd-gpu-firmware|amd-ucode-firmware|intel-(gpu|audio|npu)-firmware|nvidia-gpu-firmware|iwl[a-z0-9-]*-firmware|bcm[0-9a-z-]+-firmware|brcmfmac-firmware|fedora-logos-httpd|anaconda-(core|tui|webui|install-env-deps|live))$')
if (("${#obsolete[@]}")); then
    rpm --root "$root" -e --nodeps --noscripts "${obsolete[@]}"
fi
rm -f "$root"/boot/{initramfs,vmlinuz}-0-rescue-* "$root"/boot/loader/entries/{*-0-rescue,*-7.2.11-300.fc45.aarch64}.conf
mkdir -p "$root/usr/lib/modules/$version" "$root/usr/share/yoga-live" "$root/boot"
rsync -a --exclude=build --exclude=source "/work/kernel-stage/lib/modules/$version/" "$root/usr/lib/modules/$version/"
tar -xf yoga-hardware.tar -C "$root"
mv "$root/boot/yoga/current/board.dtb" "$stage/board.dtb"
rmdir "$root"/boot/yoga/{current,}
install -m644 "$kernel/arch/arm64/boot/Image" "$root/boot/vmlinuz-$version"
install -m644 "$kernel/.config" "$root/boot/config-$version"
install -m644 "$kernel/System.map" "$root/boot/System.map-$version"
tar -xJf /work/mesa-build/mesa-x2-45-26.2.3-aarch64.tar.xz -C "$root"
repo=$stage/port/install
units=$root/etc/systemd/system
rules=$root/etc/udev/rules.d
sbin=$root/usr/local/sbin
device_dropin='sys-subsystem-net-yoga\x2dwifi\x2dready.device.d/timeout.conf'
install -m644 "$repo"/{audio/yoga-audio,camera/yoga-camera,mesa-x2-45/yoga-gpu,usb/yoga-usb}.service "$units/"
install -D -m644 "$repo/usb/$device_dropin" "$units/$device_dropin"
install -D -m644 "$repo/mesa-x2-45/90-yoga-mesa.conf" "$units/gdm.service.d/90-yoga-mesa.conf"
install -m644 "$repo"/{usb/90-yoga-usb,audio/72-yoga-audio}.rules "$rules/"
install -m755 "$repo/camera/yoga-camera-up" "$repo/mesa-x2-45/yoga-gpu-up" "$sbin/"
install -m755 "$repo/audio/yoga-audio.sh" "$sbin/yoga-audio"
install -D -m755 "$repo/mesa-x2-45/mesa-x2-45-env" "$root/usr/local/bin/mesa-x2-45-env"
install -D -m755 "$repo/mesa-x2-45/egl-offscreen-test.py" "$root/usr/local/libexec/yoga-egl-test.py"
install -D -m644 "$repo/camera/wireplumber.service.d/90-yoga-libcamera-cpu.conf" \
    "$root/etc/systemd/user/wireplumber.service.d/90-yoga-libcamera-cpu.conf"
install -d "$root/etc/environment.d" "$root/etc/systemd/system-preset" "$root/usr/share/alsa/ucm2/conf.d/glymur"
ln -sfn /run/yoga-gpu.env "$root/etc/environment.d/90-yoga-mesa.conf"
install -m644 "$repo"/audio/ucm/*.conf "$root/usr/share/alsa/ucm2/conf.d/glymur/"
cat > "$root/etc/systemd/system-preset/00-yoga-live.preset" <<'PRESET'
enable yoga-video.service
enable yoga-soccp.service
enable yoga-camera.service
enable yoga-audio.service
enable yoga-gpu.service
enable yoga-ec.service
enable yoga-rtc.service
disable sshd.service
PRESET
systemctl --root="$root" preset yoga-{video,soccp,camera,audio,gpu,ec,rtc}.service sshd.service
# The RAM live path is independent of Linux USB enumeration. The storage stays in the user's control.
if [[ -e $root/usr/share/applications/liveinst.desktop ]]; then
    mv "$root/usr/share/applications/liveinst.desktop" "$root/usr/share/yoga-live/liveinst.desktop.disabled"
fi
# This kernel uses uncompressed firmware. Derive the files solely from the Fedora RPM payload.
for f in "$root"/usr/lib/firmware/ath12k/WCN7850/hw2.0/{amss,board-2,m3}.bin.xz \
          "$root"/usr/lib/firmware/qcom/gen80100_{gmu.bin,sqe.fw,aqe.fw}.xz; do
    [[ -f $f && $f == *.xz ]] || continue
    xz -dc "$f" > "${f%.xz}"
done
while IFS= read -r -d '' f; do xz -dc "$f" > "${f%.xz}"; done \
    < <(find "$root/usr/lib/firmware/qca" -maxdepth 1 -type f -name 'hmt*.xz' -print0)
for f in qcom/gen80100_gmu.bin qcom/gen80100_sqe.fw qcom/gen80100_aqe.fw \
    ath12k/WCN7850/hw2.0/amss.bin ath12k/WCN7850/hw2.0/board-2.bin ath12k/WCN7850/hw2.0/m3.bin; do
    test -s "$root/usr/lib/firmware/$f"
done
xz -dc "$root/usr/lib/firmware/qcom/glymur/GLYMUR-CRD-tplg.bin.xz" \
    > "$root/usr/lib/firmware/qcom/glymur/GLYMUR-LENOVO-Yoga-Slim7x-tplg.bin"
test ! -e "$root/var/lib/yoga-fw"
install -m644 release-readme.txt "$root/usr/share/yoga-live/README.txt"
rpm --root "$root" -qa --qf '%{NAME} %{EVR} %{ARCH}\n' | sort > "$root/usr/share/yoga-live/packages.txt"
udevadm verify --root="$root" /etc/udev/rules.d/72-yoga-audio.rules /etc/udev/rules.d/90-yoga-usb.rules
systemd-analyze --root="$root" --man=no verify /etc/systemd/system/yoga-{video,usb,usb3,gpu,camera,audio}.service /usr/lib/systemd/system/gdm.service

binds=()
cleanup() {
    for ((i=${#binds[@]}-1; i>=0; i--)); do umount -R "${binds[i]}"; done
    binds=()
}
trap cleanup EXIT
for name in dev proc sys; do
    mount --rbind "/$name" "$root/$name"
    mount --make-rslave "$root/$name"
    binds+=("$root/$name")
done
chroot "$root" depmod "$version"
chroot "$root" dracut --force --no-hostonly --no-hostonly-cmdline --compress zstd \
    --add dmsquash-live --omit 'plymouth livenet network iscsi nvmf' \
    --add-drivers 'simpledrm squashfs loop overlay nvme phy-qcom-qmp-pcie i2c-qcom-geni i2c-hid-of' \
    --force-drivers 'tcsrcc-glymur pwrseq-qcom-wcn pci-pwrctrl-pwrseq' \
    --omit-drivers 'msm dispcc_glymur gpucc_glymur phy_qcom_edp phy_qcom_qmp_combo qcom_q6v5_pas ath12k ath12k_wifi7_pci' \
    "/boot/initramfs-$version.img" "$version" > dracut.log 2>&1
chroot "$root" lsinitrd -m "/boot/initramfs-$version.img" > initramfs-modules.txt
grep -qx dmsquash-live initramfs-modules.txt
mv "$root/boot/initramfs-$version.img" initrd
cleanup

: > "$root/etc/machine-id"
rm -f "$root"/etc/ssh/ssh_host_* "$root"/var/lib/{systemd/random-seed,NetworkManager/secret_key}
find "$root/etc/NetworkManager/system-connections" "$root/root" -name '*.nmconnection' -o -name authorized_keys |
    { ! grep -q .; }

mksquashfs "$root" yoga-live.img -noappend -comp xz -b 1M -Xbcj arm64 -Xdict-size 100% \
    -no-exports -no-progress -processors 20 -wildcards -e 'var/cache/*' 'var/log/*' > squashfs.log 2>&1
unsquashfs -s yoga-live.img
test "$(stat -c '%s' yoga-live.img)" -le 4294967295
printf 'yoga-live.img\n' | cpio -o -H newc --owner=0:0 > yoga-live.cpio
test "$(cpio -it < yoga-live.cpio)" = yoga-live.img
xorriso -abort_on FAILURE -indev "$base" -outdev "$image.partial" \
    -rm /LiveOS/squashfs.img -- \
    -map "$root/boot/vmlinuz-$version" /boot/aarch64/loader/linux \
    -map "$stage/initrd" /boot/aarch64/loader/initrd \
    -map "$stage/board.dtb" /boot/yoga-14q8y11.dtb \
    -map "$stage/yoga-live.cpio" /boot/aarch64/loader/yoga-live.cpio \
    -map "$stage/grub-live.cfg" /boot/grub2/grub.cfg \
    -map "$stage/release-readme.txt" /LEIA-ME-YOGA.txt \
    -volid YOGA45-LIVE -boot_image any replay > xorriso.log 2>&1
implantisomd5 --force "$image.partial"
checkisomd5 "$image.partial"
mv "$image.partial" "$image"
sha256sum "$(basename "$image")" > "$(basename "$image").sha256"
