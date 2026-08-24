#!/usr/bin/env bash
# Torna um live root extraído instalável: o Anaconda copia este rootfs para o
# disco e, sem entrada BLS válida para o kernel 7.2, o sistema instalado não
# boota (as entradas herdadas da imagem kiwi apontam para /root/var/lib/mock).
set -euo pipefail

VERSION=7.2.0-x1407qa
ROOTFS=${1:?usage: make-rootfs-installable.sh <extracted-live-root>}
ROOTFS=$(realpath -m "$ROOTFS")
DTB_REL=dtb-x1407qa/qcom/x1p42100-asus-zenbook-a14.dtb

[[ -d $ROOTFS/usr && -d $ROOTFS/boot ]] || { echo "ERROR: not an extracted live root: $ROOTFS" >&2; exit 1; }
[[ -s $ROOTFS/boot/vmlinuz-$VERSION ]] || { echo "ERROR: live root missing /boot/vmlinuz-$VERSION" >&2; exit 1; }
[[ -s $ROOTFS/boot/initramfs-$VERSION.img ]] || { echo "ERROR: live root missing /boot/initramfs-$VERSION.img" >&2; exit 1; }
[[ -s $ROOTFS/boot/dtb/qcom/x1p42100-asus-zenbook-a14.dtb ]] || { echo 'ERROR: live root missing the X1407QA devicetree' >&2; exit 1; }

# DTB numa localização estável, fora dos diretórios dtb-<kver> tocados por updates
install -Dm0644 "$ROOTFS/boot/dtb/qcom/x1p42100-asus-zenbook-a14.dtb" "$ROOTFS/boot/$DTB_REL"

# Kit de resgate embutido no live: diagnostica/repara o boot do sistema
# instalado sem depender de rede ou de um segundo pendrive
install -Dm0755 "$(dirname "$(realpath "$0")")/rescue-installed-boot.sh" \
    "$ROOTFS/usr/local/sbin/rescue-installed-boot"

# Entradas BLS da imagem kiwi apontam para caminhos do chroot de build; remover
# (grep sai 1 sem matches; tolerar para manter o helper idempotente com pipefail)
if [[ -d $ROOTFS/boot/loader/entries ]]; then
    { grep -lrZF /root/var/lib/mock "$ROOTFS/boot/loader/entries" 2>/dev/null || :; } | xargs -0 -r rm -f --
fi

# grubenv válido (1024 bytes: assinatura + padding '#'), sem saved_entry órfão
mkdir -p "$ROOTFS/boot/grub2"
{
    printf '# GRUB Environment Block\n'
    head -c 999 /dev/zero | tr '\0' '#'
} > "$ROOTFS/boot/grub2/grubenv"

# Post-script do Anaconda: roda chrooted no sistema instalado no fim da
# instalação, quando /etc/fstab já existe (pyanaconda/kickstart.py lê
# /usr/share/anaconda/post-scripts/*ks)
install -d "$ROOTFS/usr/share/anaconda/post-scripts"
cat > "$ROOTFS/usr/share/anaconda/post-scripts/90-x1407qa-bootloader.ks" <<'KSEOF'
%post --erroronfail
set -eu

VERSION=7.2.0-x1407qa

root_spec=$(awk '$1 !~ /^#/ && $2 == "/" { print $1; exit }' /etc/fstab)
[ -n "$root_spec" ] || { echo 'x1407qa: /etc/fstab has no / entry' >&2; exit 1; }
root_opts=$(awk '$1 !~ /^#/ && $2 == "/" { print $4; exit }' /etc/fstab)
subvol=$(printf '%s\n' "$root_opts" | tr ',' '\n' | grep -m1 '^subvol=') || subvol=

# ponytail: caminhos BLS relativos à partição que contém as entradas; cobre os
# dois layouts do Anaconda (partição /boot separada ou /boot dentro da raiz)
boot_prefix=/boot
if awk '$1 !~ /^#/ && $2 == "/boot" { found=1 } END { exit !found }' /etc/fstab; then
    boot_prefix=
fi

for f in "/boot/vmlinuz-$VERSION" "/boot/initramfs-$VERSION.img" \
    /boot/dtb-x1407qa/qcom/x1p42100-asus-zenbook-a14.dtb; do
    [ -s "$f" ] || { echo "x1407qa: missing boot artifact: $f" >&2; exit 1; }
done

opts="root=$root_spec ro"
[ -n "$subvol" ] && opts="$opts rootflags=$subvol"
opts="$opts rd.driver.pre=pwrseq_qcom_wcn rd.driver.pre=wcn_regulator_fix"
opts="$opts clk_ignore_unused mem_sleep_default=s2idle systemd.tpm2_wait=0"
opts="$opts rd.systemd.mask=dev-tpm0.device rd.systemd.mask=dev-tpmrm0.device"

grep -lrZF /root/var/lib/mock /boot/loader/entries 2>/dev/null | xargs -0 -r rm -f --

mkdir -p /boot/loader/entries
cat > "/boot/loader/entries/x1407qa-$VERSION.conf" <<ENTRY
title Fedora 44 X1407QA (Linux $VERSION)
version $VERSION
linux $boot_prefix/vmlinuz-$VERSION
initrd $boot_prefix/initramfs-$VERSION.img
devicetree $boot_prefix/dtb-x1407qa/qcom/x1p42100-asus-zenbook-a14.dtb
options $opts
grub_users \$grub_users
grub_arg --unrestricted
grub_class fedora
ENTRY

# Fallback: entrada direta em custom.cfg (mesmo método comprovado do GRUB do
# live), caso o blscfg não aplique a linha devicetree da entrada BLS
boot_uuid=$(findmnt -no UUID /boot 2>/dev/null || findmnt -no UUID / 2>/dev/null) || boot_uuid=
if [ -n "$boot_uuid" ]; then
    mkdir -p /boot/grub2
    cat > /boot/grub2/custom.cfg <<CFG
menuentry 'Fedora 44 X1407QA (Linux $VERSION, entrada direta)' --unrestricted {
    search --no-floppy --fs-uuid --set=root $boot_uuid
    devicetree $boot_prefix/dtb-x1407qa/qcom/x1p42100-asus-zenbook-a14.dtb
    linux $boot_prefix/vmlinuz-$VERSION $opts
    initrd $boot_prefix/initramfs-$VERSION.img
}
CFG
else
    echo 'x1407qa: WARN sem UUID de /boot; custom.cfg de fallback não gerado' >&2
fi

grub2-editenv /boot/grub2/grubenv create
if [ -e /boot/efi/EFI/fedora/grubenv ]; then
    grub2-editenv /boot/efi/EFI/fedora/grubenv create
fi
%end
KSEOF

ks=$ROOTFS/usr/share/anaconda/post-scripts/90-x1407qa-bootloader.ks
grep -qF 'devicetree $boot_prefix/dtb-x1407qa/qcom/x1p42100-asus-zenbook-a14.dtb' "$ks" || {
    echo 'ERROR: installer post-script is missing the devicetree entry line' >&2
    exit 1
}
grep -qF 'rd.driver.pre=pwrseq_qcom_wcn rd.driver.pre=wcn_regulator_fix' "$ks" || {
    echo 'ERROR: installer post-script is missing the WCN driver ordering' >&2
    exit 1
}
grep -qF 'search --no-floppy --fs-uuid --set=root' "$ks" || {
    echo 'ERROR: installer post-script is missing the custom.cfg direct-entry fallback' >&2
    exit 1
}
if [[ -d $ROOTFS/boot/loader/entries ]] && grep -qrF /root/var/lib/mock "$ROOTFS/boot/loader/entries"; then
    echo 'ERROR: live root still carries kiwi build BLS entries' >&2
    exit 1
fi
[[ $(stat -c %s "$ROOTFS/boot/grub2/grubenv") -eq 1024 ]] || {
    echo 'ERROR: live root grubenv is not a 1024-byte environment block' >&2
    exit 1
}
head -c 25 "$ROOTFS/boot/grub2/grubenv" | grep -qF '# GRUB Environment Block' || {
    echo 'ERROR: live root grubenv lacks the GRUB signature' >&2
    exit 1
}
[[ -s $ROOTFS/boot/$DTB_REL ]] || { echo 'ERROR: live root is missing the stable X1407QA devicetree copy' >&2; exit 1; }
[[ -x $ROOTFS/usr/local/sbin/rescue-installed-boot ]] || {
    echo 'ERROR: live root is missing the embedded rescue tool' >&2
    exit 1
}

echo "PASS: live root at $ROOTFS is installable"
