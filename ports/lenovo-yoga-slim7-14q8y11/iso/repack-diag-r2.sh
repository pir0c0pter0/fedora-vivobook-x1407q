#!/usr/bin/env bash
# Run in yoga-iso-build after host grub2-script-check and copying the R2 inputs.
set -euo pipefail
cd /work
base=artifacts/Fedora-45-Yoga-14Q8Y11-Experimental-20261113.iso
output=artifacts/Fedora-45-Yoga-14Q8Y11-Diag-R2-20261113.iso
dtb=kernel-out/arch/arm64/boot/dts/qcom/kalambo-lenovo-yoga-slim7x-diag.dtb
[[ ! -e $output && ! -e $output.partial ]]
echo "9efffc4de3e904e5a1cdca91148786a067bcd0da44f3430c9c734512bddc201c  $base" | sha256sum -c -
echo "1312ce6f353e842e1b770c265c4db1fff245f478b3c0319b67c69168478e1dd2  $dtb" | sha256sum -c -
# The fixed ESP offset belongs to the hash-verified base above.
dd if="$base" of=diag-r2-esp.img bs=512 skip=16057948 count=61440 status=none
mcopy -o -i diag-r2-esp.img grub-diag-r2.cfg ::/EFI/BOOT/grub.cfg
mcopy -o -i diag-r2-esp.img "$dtb" ::/EFI/BOOT/kalambo-lenovo-yoga-slim7x-diag.dtb
xorriso -indev "$base" -outdev "$output.partial" \
  -boot_image any replay \
  -append_partition 2 0xef diag-r2-esp.img \
  -map grub-diag-r2.cfg /boot/grub2/grub.cfg \
  -map grub-diag-r2.cfg /EFI/BOOT/grub.cfg \
  -map "$dtb" /boot/kalambo-lenovo-yoga-slim7x-diag.dtb \
  -map LEIA-ME-DIAG-R2.txt /LEIA-ME-YOGA.txt
implantisomd5 --force "$output.partial"
checkisomd5 "$output.partial"
mv "$output.partial" "$output"
sha256sum "$output" >"$output.sha256"
xorriso -indev "$output" -report_el_torito plain -report_system_area plain
