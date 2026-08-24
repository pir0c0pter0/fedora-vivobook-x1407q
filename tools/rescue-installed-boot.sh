#!/usr/bin/env bash
# X1407QA — diagnóstico e reparo do boot do sistema INSTALADO no disco interno.
# Rodar como root no live USB deste projeto:
#   rescue-installed-boot.sh            # só diagnóstico (montagens read-only)
#   rescue-installed-boot.sh --repair   # aplica reparos de boot no disco
#
# O que ele descobre: se o post-script do Anaconda rodou (logs em
# /var/log/anaconda), se a entrada BLS do 7.2 existe com devicetree, se o
# grubenv/ESP/NVRAM estão íntegros. O que ele repara: entrada BLS, entrada
# direta via custom.cfg (mesmo método comprovado do GRUB do live), grubenv e
# fallback \EFI\BOOT\BOOTAA64.EFI.
set -euo pipefail

VERSION=7.2.0-x1407qa
DTB_REL=dtb-x1407qa/qcom/x1p42100-asus-zenbook-a14.dtb
WORK=/run/x1407qa-rescue
MNT=$WORK/mnt
REPORT=$WORK/report
REPAIR=0
[[ ${1:-} == --repair ]] && REPAIR=1

[[ $EUID -eq 0 ]] || { echo 'ERROR: rode como root (sudo)' >&2; exit 1; }
# execução anterior interrompida pode ter deixado o disco montado sob $WORK:
# desmontar antes, e nunca atravessar mountpoint no rm
umount -R "$WORK/mnt" 2>/dev/null || :
umount "$WORK/probe" 2>/dev/null || :
rm -rf --one-file-system "$WORK"
mkdir -p "$MNT" "$REPORT"

say()  { printf '%s\n' "$*" | tee -a "$REPORT/summary.txt"; }
ok()   { say "PASS: $*"; }
bad()  { say "FAIL: $*"; }

# ---------------------------------------------------------------- live device
LIVE_DISK=
if livedev=$(readlink -f /run/initramfs/livedev 2>/dev/null); then
    LIVE_DISK=$(lsblk -rno PKNAME "$livedev" 2>/dev/null | head -1 || :)
    [[ -n $LIVE_DISK ]] && LIVE_DISK=/dev/$LIVE_DISK
fi
say "live device: ${livedev:-desconhecido} (disco: ${LIVE_DISK:-desconhecido})"

on_live_disk() { [[ -n $LIVE_DISK && $(lsblk -rno PKNAME "$1" 2>/dev/null | head -1 || :) == "${LIVE_DISK#/dev/}" ]]; }

# ------------------------------------------------------- localizar partições
lsblk -f  > "$REPORT/lsblk.txt"  2>&1 || :
blkid     > "$REPORT/blkid.txt"  2>&1 || :

ROOT_DEV='' ROOT_SUBVOL='' BOOT_DEV='' ESP_DEV=''
probe=$WORK/probe
mkdir -p "$probe"
while read -r dev fstype dtype; do
    [[ -n $fstype ]] || continue
    # só partições reais (e LUKS aberto); exclui loop/dm do próprio live, que
    # também têm /etc/fstab e /boot e apareceriam antes do NVMe no lsblk
    [[ $dtype == part || $dtype == crypt ]] || continue
    on_live_disk "$dev" && continue
    # GNOME Files automonta partições do disco interno em /run/media e isso
    # bloqueia trial mounts ro e a montagem rw do reparo; desmontar antes
    umount -A "$dev" 2>/dev/null || :
    case $fstype in
        vfat)
            if [[ -z $ESP_DEV ]] && mount -o ro "$dev" "$probe" 2>/dev/null; then
                [[ -d $probe/EFI ]] && ESP_DEV=$dev
                umount "$probe"
            fi ;;
        btrfs|ext4|xfs)
            if [[ -z $ROOT_DEV ]]; then
                for sub in root ''; do
                    opts=ro; [[ $fstype == btrfs && -n $sub ]] && opts=ro,subvol=$sub
                    mount -o "$opts" "$dev" "$probe" 2>/dev/null || continue
                    if [[ -f $probe/etc/fstab && -d $probe/boot ]]; then
                        ROOT_DEV=$dev
                        [[ $fstype == btrfs ]] && ROOT_SUBVOL=$sub
                        umount "$probe"; break
                    fi
                    umount "$probe"
                    [[ $fstype != btrfs ]] && break
                done
            fi ;;
    esac
done < <(lsblk -rpno NAME,FSTYPE,TYPE)

[[ -n $ROOT_DEV ]] || { bad 'raiz instalada não encontrada em nenhum disco interno'; exit 1; }
say "raiz instalada: $ROOT_DEV ${ROOT_SUBVOL:+(subvol=$ROOT_SUBVOL)}"

rw=ro; [[ $REPAIR -eq 1 ]] && rw=rw
mopts=$rw; [[ -n $ROOT_SUBVOL ]] && mopts=$rw,subvol=$ROOT_SUBVOL
mount -o "$mopts" "$ROOT_DEV" "$MNT"
cleanup() { umount -R "$MNT" 2>/dev/null || :; }
trap cleanup EXIT

# montar /boot e /boot/efi conforme o fstab instalado
resolve_spec() {
    case $1 in
        UUID=*|LABEL=*|PARTUUID=*|PARTLABEL=*) findfs "$1" 2>/dev/null || : ;;
        /dev/*) printf '%s' "$1" ;;
    esac
}
resolve_installed() { # spec da fstab → device, recusando o próprio USB live
    local d
    d=$(resolve_spec "$1")
    if [[ -n $d ]] && on_live_disk "$d"; then
        bad "fstab: $1 resolve para o próprio USB live ($d); ignorado" >&2
        d=''
    fi
    printf '%s' "$d"
}
BOOT_PREFIX=/boot
if spec=$(awk '$1 !~ /^#/ && $2 == "/boot" { print $1; exit }' "$MNT/etc/fstab") && [[ -n $spec ]]; then
    dev=$(resolve_installed "$spec")
    if [[ -n $dev ]]; then
        umount -A "$dev" 2>/dev/null || :
        if mount -o "$rw" "$dev" "$MNT/boot"; then
            BOOT_DEV=$dev BOOT_PREFIX=
        else
            bad "não consegui montar a partição /boot ($dev)"
        fi
    fi
fi
if spec=$(awk '$1 !~ /^#/ && $2 == "/boot/efi" { print $1; exit }' "$MNT/etc/fstab") && [[ -n $spec ]]; then
    dev=$(resolve_installed "$spec")
    if [[ -n $dev ]]; then
        umount -A "$dev" 2>/dev/null || :
        [[ -d $MNT/boot/efi ]] || mkdir -p "$MNT/boot/efi" 2>/dev/null || :
        if mount -o "$rw" "$dev" "$MNT/boot/efi"; then
            ESP_DEV=$dev
        else
            bad "não consegui montar a ESP ($dev)"
        fi
    fi
fi
say "boot: ${BOOT_DEV:-na própria raiz}  esp: ${ESP_DEV:-não encontrado}"

# ------------------------------------------------------------------ evidências
cp -f "$MNT/etc/fstab" "$REPORT/fstab" 2>/dev/null || :
cp -rf "$MNT/var/log/anaconda" "$REPORT/anaconda-logs" 2>/dev/null || :
mkdir -p "$REPORT/loader-entries"
cp -f "$MNT"/boot/loader/entries/*.conf "$REPORT/loader-entries/" 2>/dev/null || :
cp -f "$MNT/boot/grub2/grub.cfg" "$REPORT/grub.cfg" 2>/dev/null || :
cp -f "$MNT/boot/grub2/custom.cfg" "$REPORT/custom.cfg" 2>/dev/null || :
cp -f "$MNT/boot/efi/EFI/fedora/grub.cfg" "$REPORT/esp-grub.cfg" 2>/dev/null || :
efibootmgr -v > "$REPORT/efibootmgr.txt" 2>&1 || :
mokutil --sb-state > "$REPORT/secureboot.txt" 2>&1 || :
if [[ -d $MNT/var/log/journal ]]; then
    journalctl -D "$MNT/var/log/journal" --list-boots > "$REPORT/journal-boots.txt" 2>&1 || :
fi

# -------------------------------------------------------------------- checks
say '--- resumo do diagnóstico ---'
[[ -s $MNT/boot/vmlinuz-$VERSION ]]        && ok "vmlinuz-$VERSION presente"        || bad "vmlinuz-$VERSION AUSENTE"
[[ -s $MNT/boot/initramfs-$VERSION.img ]]  && ok "initramfs-$VERSION presente"      || bad "initramfs-$VERSION AUSENTE"
[[ -s $MNT/boot/$DTB_REL ]]                && ok 'DTB estável presente'             || bad "DTB AUSENTE em /boot/$DTB_REL"

entry=$MNT/boot/loader/entries/x1407qa-$VERSION.conf
if [[ -s $entry ]]; then
    ok 'entrada BLS x1407qa existe'
    grep -q '^devicetree ' "$entry" && ok 'entrada BLS tem linha devicetree' || bad 'entrada BLS SEM linha devicetree'
else
    bad 'entrada BLS x1407qa NÃO existe (post-script do Anaconda não rodou?)'
fi
if grep -qrF /root/var/lib/mock "$MNT/boot/loader/entries" 2>/dev/null; then
    bad 'entradas BLS kiwi (mock) ainda presentes'
else
    ok 'sem entradas BLS kiwi órfãs'
fi
say '--- entradas BLS presentes ---'
ls -1 "$MNT/boot/loader/entries" 2>/dev/null | tee -a "$REPORT/summary.txt" || say '(diretório loader/entries ausente)'

genv=$MNT/boot/grub2/grubenv
if [[ -f $genv && $(stat -c %s "$genv") -eq 1024 ]] && head -c 25 "$genv" | grep -qF '# GRUB Environment Block'; then
    ok 'grubenv válido (1024 bytes)'
else
    bad 'grubenv inválido ou ausente'
fi
grep -qF 'blscfg' "$MNT/boot/grub2/grub.cfg" 2>/dev/null && ok 'grub.cfg usa blscfg' || bad 'grub.cfg sem blscfg (ou ausente)'
grep -qF 'custom.cfg' "$MNT/boot/grub2/grub.cfg" 2>/dev/null && ok 'grub.cfg tem hook do custom.cfg' || bad 'grub.cfg SEM hook do custom.cfg'
[[ -s $MNT/boot/efi/EFI/fedora/grubaa64.efi ]] && ok 'ESP tem EFI/fedora/grubaa64.efi' || bad 'ESP sem grubaa64.efi'
[[ -s $MNT/boot/efi/EFI/BOOT/BOOTAA64.EFI ]]   && ok 'ESP tem fallback EFI/BOOT/BOOTAA64.EFI' || bad 'ESP SEM fallback BOOTAA64.EFI'
grep -qi fedora "$REPORT/efibootmgr.txt" && ok 'NVRAM tem entrada Fedora' || bad 'NVRAM sem entrada Fedora (firmware pode não achar o GRUB)'
grep -qi 'enabled' "$REPORT/secureboot.txt" && bad 'Secure Boot ATIVO — kernel não assinado não boota; desative no firmware' || ok 'Secure Boot inativo/indeterminado'

if ls "$REPORT"/anaconda-logs/ks-script-*.log >/dev/null 2>&1; then
    say '--- logs de ks-script do Anaconda (post-script do bootloader) ---'
    tail -n 40 "$REPORT"/anaconda-logs/ks-script-*.log | tee -a "$REPORT/summary.txt"
elif [[ -d $REPORT/anaconda-logs ]]; then
    say 'AVISO: sem ks-script-*.log — o post-script 90-x1407qa-bootloader pode não ter rodado'
    grep -in 'x1407qa\|post-script\|error\|traceback' "$REPORT"/anaconda-logs/*.log 2>/dev/null | tail -n 30 | tee -a "$REPORT/summary.txt" || :
else
    say 'AVISO: /var/log/anaconda não existe no disco — a instalação chegou ao fim?'
fi

# -------------------------------------------------------------------- repair
if [[ $REPAIR -eq 1 ]]; then
    say '--- aplicando reparos ---'
    root_spec=$(awk '$1 !~ /^#/ && $2 == "/" { print $1; exit }' "$MNT/etc/fstab")
    [[ -n $root_spec ]] || { bad 'fstab instalado sem entrada /'; exit 1; }
    root_opts=$(awk '$1 !~ /^#/ && $2 == "/" { print $4; exit }' "$MNT/etc/fstab")
    subvol=$(printf '%s\n' "$root_opts" | tr ',' '\n' | grep -m1 '^subvol=') || subvol=

    opts="root=$root_spec ro"
    [[ -n $subvol ]] && opts="$opts rootflags=$subvol"
    opts="$opts rd.driver.pre=pwrseq_qcom_wcn rd.driver.pre=wcn_regulator_fix"
    opts="$opts clk_ignore_unused mem_sleep_default=s2idle systemd.tpm2_wait=0"
    opts="$opts rd.systemd.mask=dev-tpm0.device rd.systemd.mask=dev-tpmrm0.device"

    if [[ ! -s $MNT/boot/$DTB_REL ]]; then
        src=$MNT/boot/dtb/qcom/x1p42100-asus-zenbook-a14.dtb
        [[ -s $src ]] || src=/boot/dtb/qcom/x1p42100-asus-zenbook-a14.dtb
        if [[ -s $src ]] && install -Dm0644 "$src" "$MNT/boot/$DTB_REL"; then
            say "reparado: DTB copiado de $src"
        else
            bad 'DTB não encontrado/copiável; entradas apontarão para arquivo ausente'
        fi
    fi

    { grep -lrZF /root/var/lib/mock "$MNT/boot/loader/entries" 2>/dev/null || :; } | xargs -0 -r rm -f --
    mkdir -p "$MNT/boot/loader/entries"
    cat > "$entry" <<ENTRY
title Fedora 44 X1407QA (Linux $VERSION)
version $VERSION
linux $BOOT_PREFIX/vmlinuz-$VERSION
initrd $BOOT_PREFIX/initramfs-$VERSION.img
devicetree $BOOT_PREFIX/$DTB_REL
options $opts
grub_users \$grub_users
grub_arg --unrestricted
grub_class fedora
ENTRY
    say "reparado: entrada BLS $entry"

    mkdir -p "$MNT/boot/grub2"
    boot_fs_dev=${BOOT_DEV:-$ROOT_DEV}
    boot_uuid=$(blkid -s UUID -o value "$boot_fs_dev" || :)
    if [[ -n $boot_uuid ]]; then
        cat > "$WORK/direct-entry.cfg" <<CFG
menuentry 'Fedora 44 X1407QA (Linux $VERSION, entrada direta)' --unrestricted {
    search --no-floppy --fs-uuid --set=root $boot_uuid
    devicetree $BOOT_PREFIX/$DTB_REL
    linux $BOOT_PREFIX/vmlinuz-$VERSION $opts
    initrd $BOOT_PREFIX/initramfs-$VERSION.img
}
CFG
        cp -f "$WORK/direct-entry.cfg" "$MNT/boot/grub2/custom.cfg"
        say 'reparado: /boot/grub2/custom.cfg (entrada direta, método do live)'
        # sem hook do 41_custom, custom.cfg nunca é lido: anexar direto no grub.cfg
        if [[ -f $MNT/boot/grub2/grub.cfg ]] \
            && ! grep -qF 'custom.cfg' "$MNT/boot/grub2/grub.cfg" \
            && ! grep -qF 'entrada direta' "$MNT/boot/grub2/grub.cfg"; then
            cat "$WORK/direct-entry.cfg" >> "$MNT/boot/grub2/grub.cfg"
            say 'reparado: entrada direta anexada ao grub.cfg (hook custom.cfg ausente)'
        fi
    else
        bad 'não consegui UUID do fs de boot; custom.cfg não gerado'
    fi

    if command -v grub2-editenv >/dev/null; then
        grub2-editenv "$MNT/boot/grub2/grubenv" create
        # a entrada com devicetree vira o default do menu; sem isso o GRUB pode
        # escolher a entrada gêmea do Anaconda, que boota sem DTB (tela preta)
        grub2-editenv "$MNT/boot/grub2/grubenv" set "saved_entry=x1407qa-$VERSION"
        if [[ -e $MNT/boot/efi/EFI/fedora/grubenv ]]; then
            grub2-editenv "$MNT/boot/efi/EFI/fedora/grubenv" create
            grub2-editenv "$MNT/boot/efi/EFI/fedora/grubenv" set "saved_entry=x1407qa-$VERSION"
        fi
        say "reparado: grubenv (default fixado em x1407qa-$VERSION)"
    else
        { printf '# GRUB Environment Block\n'; head -c 999 /dev/zero | tr '\0' '#'; } > "$MNT/boot/grub2/grubenv"
        say 'reparado: grubenv (sem grub2-editenv; default não fixado)'
    fi

    esp=$MNT/boot/efi
    if [[ -s $esp/EFI/fedora/shimaa64.efi && ! -s $esp/EFI/BOOT/BOOTAA64.EFI ]]; then
        mkdir -p "$esp/EFI/BOOT"
        cp -f "$esp/EFI/fedora/shimaa64.efi" "$esp/EFI/BOOT/BOOTAA64.EFI"
        cp -f "$esp/EFI/fedora/grubaa64.efi" "$esp/EFI/BOOT/grubaa64.efi"
        [[ -s $esp/EFI/fedora/mmaa64.efi ]] && cp -f "$esp/EFI/fedora/mmaa64.efi" "$esp/EFI/BOOT/mmaa64.efi"
        say 'reparado: fallback EFI/BOOT/BOOTAA64.EFI criado'
    fi

    if [[ -n $ESP_DEV ]] && ! grep -qi 'shimaa64.efi' "$REPORT/efibootmgr.txt"; then
        esp_disk=/dev/$(lsblk -rno PKNAME "$ESP_DEV" 2>/dev/null | head -1 || :)
        esp_part=$(lsblk -rno PARTN "$ESP_DEV" 2>/dev/null | head -1 || :)
        if [[ $esp_disk != /dev/ && -n $esp_part ]]; then
            efibootmgr -c -d "$esp_disk" -p "$esp_part" -L 'Fedora X1407QA' \
                -l '\EFI\fedora\shimaa64.efi' >>"$REPORT/efibootmgr.txt" 2>&1 \
                && say 'reparado: entrada NVRAM criada' \
                || say 'AVISO: efibootmgr falhou (fallback BOOTAA64.EFI cobre)'
        fi
    fi
    sync
fi

say '--- fim ---'
say "relatório completo em: $REPORT (copie com: cp -r $REPORT /algum/pendrive)"
if [[ $REPAIR -eq 0 ]]; then
    say 'nada foi alterado; rode com --repair para aplicar os reparos'
fi
