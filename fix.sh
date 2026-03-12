#!/bin/bash
mkdir -p /mnt/win /lib/firmware/qcom
W=$(lsblk -rno NAME,FSTYPE | grep ntfs | head -1 | awk '{print $1}')
mount -o ro /dev/$W /mnt/win
find /mnt/win/Windows/System32/DriverStore/FileRepository \( -iname "qc*.mbn" -o -iname "qc*.bin" \) -exec cp -v {} /lib/firmware/qcom/ \;
umount /mnt/win
echo "Pronto! Roda: reboot"
