#!/usr/bin/env bash
# Run inside the private yoga-iso-build container after the builds in README.md.
set -euo pipefail
cd /work
base=downloads/Fedora-Workstation-Live-45-1.4.aarch64.iso
output=artifacts/Fedora-45-Yoga-14Q8Y11-Experimental-20261113.iso
version=$(cat kernel-out/include/config/kernel.release)
[[ $version == *-yoga-kalambo+ ]]
[[ ! -e $output && ! -e $output.partial ]]
echo "ad73a977709d417f5b7dda4147fc071396b9d8d2bdcca2df615aa3aab7673710  $base" | sha256sum -c -
[[ $(git -C kernel rev-parse HEAD) == 6a876df4686788cd39128b62d7fcbff62f39278f ]]
[[ $(chroot rootfs noctalia --version) == 'noctalia v5.5.0' ]]
chroot rootfs niri validate -c /etc/skel/.config/niri/config.kdl
[[ $(find inputs/colors -name '*.icm' -type f | wc -l) == 7 ]]
(cd inputs && sha256sum -c SHA256SUMS)
mkdir -p artifacts rootfs/usr/share/yoga-port rootfs/usr/share/color/icc/lenovo
cp -a inputs/colors/. rootfs/usr/share/color/icc/lenovo/
cp -a inputs/firmware-candidates inputs/manifest.json rootfs/usr/share/yoga-port/
cp inputs/colors.sha256 rootfs/usr/share/yoga-port/
cp inputs/LEIA-ME.txt rootfs/usr/share/yoga-port/
cp kernel-out/.config rootfs/usr/share/yoga-port/kernel.config
rsync -a "kernel-stage/lib/modules/$version/" "rootfs/usr/lib/modules/$version/"
rm -f "rootfs/usr/lib/modules/$version/build" "rootfs/usr/lib/modules/$version/source"
install -m644 kernel-out/arch/arm64/boot/Image "rootfs/boot/vmlinuz-$version"
install -m644 kernel-out/.config "rootfs/boot/config-$version"
install -m644 kernel-out/System.map "rootfs/boot/System.map-$version"
chroot rootfs depmod "$version"
chroot rootfs dracut --force --no-hostonly --add 'dmsquash-live livenet pollcdrom' \
  --omit 'iscsi nvmf' --add-drivers 'simpledrm virtio_blk virtio_pci' \
  "/boot/initramfs-$version.img" "$version" >initramfs-build.log 2>&1
! grep -E 'FAILED:|Failed to find module' initramfs-build.log
chroot rootfs lsinitrd -m "/boot/initramfs-$version.img" >initramfs-modules.txt
grep -qx 'dmsquash-live' initramfs-modules.txt
grep -qx 'overlayfs' initramfs-modules.txt
install -m644 kernel-out/arch/arm64/boot/Image iso/boot/aarch64/loader/linux-yoga
install -m644 "rootfs/boot/initramfs-$version.img" iso/boot/aarch64/loader/initrd-yoga
chroot rootfs rpm -qa --qf '%{NAME} %{EVR} %{ARCH}\n' | sort >rootfs/usr/share/yoga-port/packages.txt
for p in run sys proc dev; do
  if mountpoint -q "rootfs/$p"; then umount -R "rootfs/$p"; fi
done
# Prevent including build caches or the builder's resolver in the live image.
rm -rf rootfs/var/cache/libdnf5
rm -f rootfs/etc/resolv.conf
ln -s /run/NetworkManager/resolv.conf rootfs/etc/resolv.conf
mkfs.erofs -zzstd,level=15 --file-contexts=rootfs/etc/selinux/targeted/contexts/files/file_contexts \
  iso/LiveOS/squashfs.img.new rootfs >erofs-build.log 2>&1
fsck.erofs iso/LiveOS/squashfs.img.new
mv iso/LiveOS/squashfs.img.new iso/LiveOS/squashfs.img
mkdir -p ram-root
[[ $(stat -c %s iso/LiveOS/squashfs.img) -le 4294967295 ]]
ln -f iso/LiveOS/squashfs.img ram-root/yoga-live.img
# shortcut: an uncompressed second initrd doubles ISO size; remove after USB works.
(cd ram-root && printf 'yoga-live.img\n' | cpio -o -H newc --owner=0:0) >iso/boot/aarch64/loader/live-root.cpio
cp inputs/LEIA-ME.txt iso/LEIA-ME-YOGA.txt
cp grub-yoga.cfg iso/boot/grub2/grub.cfg
xorriso -indev "$base" -outdev "$output.partial" -update_r iso / \
  -volid YOGA45-EXPERIMENTAL -boot_image any replay >iso-build.log 2>&1
implantisomd5 --force "$output.partial" >iso-md5.log
checkisomd5 "$output.partial" >>iso-md5.log
mv "$output.partial" "$output"
(cd artifacts && sha256sum "$(basename "$output")" >"$(basename "$output").sha256")
xorriso -indev "$output" -report_el_torito plain -report_system_area plain >iso-boot-report.txt 2>&1
printf 'ISO: %s\n' "$output"
