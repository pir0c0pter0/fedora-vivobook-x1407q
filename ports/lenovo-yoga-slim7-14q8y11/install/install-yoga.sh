#!/usr/bin/env bash
# shellcheck disable=SC2016  # '$' literal em aspas simples e intencional (texto para o GRUB / bash -c)
# install-yoga.sh - instala o Fedora live (em RAM) no NVMe interno do Lenovo Yoga Slim 7 14Q8Y11.
# Rodar como root NO NOTEBOOK, a partir do live, depois de um boot em que o NVMe aparece.
#
#   install-yoga.sh preflight                      nao toca no disco (so mascara suspend no live)
#   install-yoga.sh backup-info                    salva tabela + ESP do Windows em /root/yoga-backup
#   CONFIRM_SERIAL=<serial> install-yoga.sh partition --yes-erase-nvme0n1   UNICA fase que apaga o disco
#   install-yoga.sh copy | configure | verify | umount
#   DTB_SHA256=<sha256 do DTB com que o live subiu> install-yoga.sh bootloader
#   install-yoga.sh selftest                       gera fstab/grub.cfg/GPT em arquivos temporarios (sem root)
#
# Variaveis: DTB_DIR (/root), DTB_NAME (kalambo-gwn1.dtb), ESP_SRC (dir com BOOTAA64.EFI, grubaa64.efi,
# mmaa64.efi copiados do pendrive; padrao: binarios do proprio live), TARGET (/mnt/yoga, sempre sob /mnt/),
# DRY_RUN=1 (partition so imprime os comandos), FORCE_BACKUP=1 (sobrescreve o backup),
# DTB_SHA256 (obrigatorio em bootloader; conferido tambem em preflight/verify quando definido).
#
# ANTES de 'partition' (nao ha volta depois dele):
#  - o live tem de ter subido com o DTB de NVMe (gwn1) e o preflight tem de passar nesse boot;
#  - teste 'systemctl reboot' no live e confirme que a maquina volta ao firmware/menu do pendrive.
#    Reboot com efi=noruntime nunca foi testado e o acesso remoto depende dele;
#  - 'partition' apaga o Windows e a recuperacao da Lenovo: exige consentimento direto do usuario.
# Notas:
#  - as fases que exigem o live mascaram suspend/hibernacao no live (--runtime) e o sistema instalado
#    nasce com eles desabilitados (sleep.conf.d + mask): o resume do PCIe/NVMe nunca foi testado;
#  - na primeira instalacao o slot 'good' e a entrada 'recovery' sao copias de 'current' que nunca deram
#    boot: so viram rede de seguranca depois do primeiro boot bem-sucedido. Retorno real: F12 + pendrive;
#  - pcie_aspm=off e nvme_core.default_ps_max_latency_us=0 ficam em /boot/yoga/<slot>/args.cfg; para
#    relaxar depois, edite o args.cfg do slot (teste antes no slot 'try' com yoga-boot-once);
#  - shim/grub2/kernel ficam fora do dnf (excludepkgs): atualiza-los quebraria o boot autonomo;
#  - as chaves de host do sshd do sistema instalado sao novas (aviso de known_hosts no primeiro SSH) e
#    o relogio sobe errado ate o chrony sincronizar (rtc-pm8xxx falha no probe).
set -euo pipefail

readonly DISK=/dev/nvme0n1
readonly MODEL_MATCH=MZAMX512HDLV
readonly KVER=${KVER:-7.4.0-rc1-yoga-kalambo+}
readonly BASE=/run/rootfsbase
readonly T=${TARGET:-/mnt/yoga}
readonly BACKUP=/root/yoga-backup OLDESP_MNT=/run/yoga-oldesp TOP_MNT=/run/yoga-top
# TARGET=/ faria o rsync da fase copy cair sobre o proprio live.
[[ $T == /mnt/?* && $T != *..* ]] || { echo "ERRO: TARGET tem de ficar sob /mnt/ (recebido: $T)" >&2; exit 1; }
readonly DTB_DIR=${DTB_DIR:-/root}
readonly DTB_NAME=${DTB_NAME:-kalambo-gwn1.dtb}
readonly NEW_HOSTNAME=MJRnb USER_LOGIN=mariojr USER_GECOS="Mario Jr"
readonly BTRFS_OPTS=compress=zstd:1,noatime
# Limites em MiB: ESP 1 GiB, /boot 4 GiB (3 slots de kernel+initramfs generico), swap 8 GiB, resto btrfs.
readonly P_ESP_END=1025 P_BOOT_END=5121 P_SWAP_END=13313
# Modulos de video: sem painel no DT eles apagam a tela (so ha simpledrm sobre o framebuffer do firmware).
readonly VIDEO_BLACKLIST="qcom_q6v5_pas msm dispcc_glymur gpucc_glymur camcc_glymur videocc_glymur evacc_glymur av1ecc_glymur"
# Ordem obrigatoria: estes tres ANTES de phy-qcom-qmp-pcie, senao o PCIe liga/desliga e a tela apaga.
readonly PCIE_PRE="tcsrcc-glymur pwrseq-qcom-wcn pci-pwrctrl-pwrseq"
readonly INITRD_MODS="nvme nvme-core btrfs phy-qcom-qmp-pcie $PCIE_PRE simpledrm i2c-qcom-geni i2c-hid-of"
# Primeira instalacao: sem ASPM (o driver habilita ate L1.2) e sem APST no NVMe. Vai para args.cfg de cada
# slot (e e o padrao do grub.cfg quando o args.cfg falta); relaxar depois editando o args.cfg.
readonly NVME_SAFE_ARGS="pcie_aspm=off nvme_core.default_ps_max_latency_us=0"
readonly SLEEP_UNITS="sleep.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target"

log()  { printf '\n== %s\n' "$*"; }
warn() { printf 'AVISO: %s\n' "$*" >&2; }
die()  { printf 'ERRO: %s\n' "$*" >&2; exit 1; }
run()  { printf '+ %s\n' "$*"; [[ -n ${DRY_RUN:-} ]] || "$@"; }
part() { printf '%sp%s' "$DISK" "$1"; }
is_dtb() { [[ -s $1 && $(od -An -tx1 -N4 "$1" | tr -d ' \n') == d00dfeed ]]; }
sha_of() { sha256sum < "$1" | cut -d' ' -f1; }
# $1 = arquivo; $2 = required -> DTB_SHA256 obrigatorio. Um DTB sem NVMe (ex.: gw1a) tambem tem o magic
# certo e deixaria o SSD sem raiz: so o hash distingue.
check_dtb() {
    is_dtb "$1" || die "DTB ausente ou invalido: $1"
    if [[ -z ${DTB_SHA256:-} ]]; then
        [[ ${2:-} != required ]] || die "defina DTB_SHA256 (sha256 do DTB com que este live subiu e achou o NVMe)"
        warn "DTB_SHA256 nao definido: $1 conferido so pelo magic"; return 0
    fi
    [[ $(sha_of "$1") == "${DTB_SHA256,,}" ]] || die "sha256 de $1 = $(sha_of "$1"), esperado ${DTB_SHA256,,}"
}

need_root() { [[ $EUID -eq 0 ]] || die "rode como root"; }
need_tools() {
    local t miss=()
    for t in parted mkfs.btrfs mkfs.ext4 mkfs.vfat mkswap rsync dracut lsinitrd wipefs blkdiscard btrfs \
             useradd blkid lsblk findmnt partprobe udevadm chroot grub2-editenv grub2-script-check; do
        command -v "$t" >/dev/null || miss+=("$t")
    done
    ((${#miss[@]} == 0)) || die "ferramentas ausentes: ${miss[*]}"
}
need_live() {
    [[ $(findmnt -no FSTYPE /) == overlay ]] || die "/ nao e overlay: este nao e o live em RAM"
    mountpoint -q "$BASE" || die "$BASE nao esta montado"
    grep -qw rd.live.image /proc/cmdline || die "cmdline sem rd.live.image"
    [[ -d $BASE/lib/modules/$KVER ]] || die "base sem /lib/modules/$KVER"
    # O GNOME do live suspende sozinho na bateria; um suspend no meio da instalacao derruba o link do NVMe.
    # --runtime: so vale para este boot do live (em RAM).
    # shellcheck disable=SC2086  # uma palavra por unit
    [[ $EUID -ne 0 ]] || systemctl mask --runtime --quiet $SLEEP_UNITS || warn "nao foi possivel mascarar suspend no live"
}
disk_serial() { tr -d '[:space:]' < "/sys/block/${DISK##*/}/device/serial"; }
need_disk() {
    [[ -b $DISK ]] || die "$DISK nao existe (boot com o DTB de NVMe?)"
    local model; model=$(< "/sys/block/${DISK##*/}/device/model")
    [[ ${model^^} == *"$MODEL_MATCH"* ]] || die "modelo inesperado em $DISK: '$model' (esperado *$MODEL_MATCH*)"
}
# Pontos de montagem/swap em uso no disco, um por linha.
disk_mounts() {
    findmnt -rno TARGET,SOURCE | awk -v d="$DISK" 'index($2, d) == 1 { print $1 }'
    awk -v d="$DISK" 'index($1, d) == 1 { print "[SWAP] " $1 }' /proc/swaps
}

load_uuids() {
    ESP_UUID=$(blkid -s UUID -o value "$(part 1)"); BOOT_UUID=$(blkid -s UUID -o value "$(part 2)")
    SWAP_UUID=$(blkid -s UUID -o value "$(part 3)"); ROOT_UUID=$(blkid -s UUID -o value "$(part 4)")
    [[ -n $ESP_UUID && -n $BOOT_UUID && -n $SWAP_UUID && -n $ROOT_UUID ]] || die "UUIDs incompletos: rode partition"
}
# So monta o que esta fase 'partition' criou (confere os rotulos antes).
mount_target() {
    local n want
    for n in 1:YOGA-ESP 2:yoga-boot 3:yoga-swap 4:yoga-root; do
        want=${n#*:}
        [[ $(blkid -s LABEL -o value "$(part "${n%%:*}")") == "$want" ]] || die "$(part "${n%%:*}") sem rotulo $want: rode partition"
    done
    # Ja montado so e aceito se vier da particao esperada (nunca "qualquer coisa montada em $T").
    mnt() {
        mountpoint -q "$3" || { mkdir -p "$3"; mount -o "$1" "$2" "$3"; }
        [[ $(findmnt -no SOURCE "$3") == "$2"* ]] || die "$3 esta montado de $(findmnt -no SOURCE "$3"), esperado $2"
    }
    mnt "subvol=root,$BTRFS_OPTS"      "$(part 4)" "$T"
    mnt "subvol=home,$BTRFS_OPTS"      "$(part 4)" "$T/home"
    mnt "subvol=var_log,$BTRFS_OPTS"   "$(part 4)" "$T/var/log"
    mnt "subvol=snapshots,$BTRFS_OPTS" "$(part 4)" "$T/.snapshots"
    mnt defaults                       "$(part 2)" "$T/boot"
    mnt umask=0077                     "$(part 1)" "$T/boot/efi"
}
# Instancias novas de proc/sysfs/devtmpfs (sem rbind: 'umount -R' nao propaga para o live).
in_chroot() {
    mountpoint -q "$T/proc" || mount -t proc proc "$T/proc"
    mountpoint -q "$T/sys"  || mount -t sysfs sys "$T/sys"
    mountpoint -q "$T/dev"  || mount -t devtmpfs dev "$T/dev"
    mountpoint -q "$T/run"  || mount -t tmpfs tmpfs "$T/run"
    chroot "$T" "$@"
}
chroot_umount() {
    local m
    for m in run dev sys proc; do ! mountpoint -q "$T/$m" || umount -R "$T/$m"; done
}
phase_umount() {
    need_root
    local m
    for m in "$T" "$OLDESP_MNT" "$TOP_MNT"; do ! mountpoint -q "$m" || umount -R "$m"; done
    log "desmontado"
}

# ---------- geradores puros (testados em 'selftest') ----------
# "/" sem subvol=: o subvolume vem de rootflags= (entrada de recuperacao usa outro) e do set-default.
# nofail no que nao e essencial: falha de /boot ou ESP nao pode derrubar o sshd.
gen_fstab() {
    cat <<EOF
UUID=$ROOT_UUID /           btrfs $BTRFS_OPTS 0 0
UUID=$ROOT_UUID /home       btrfs subvol=home,$BTRFS_OPTS 0 0
UUID=$ROOT_UUID /var/log    btrfs subvol=var_log,$BTRFS_OPTS 0 0
UUID=$ROOT_UUID /.snapshots btrfs subvol=snapshots,$BTRFS_OPTS,nofail 0 0
UUID=$BOOT_UUID /boot       ext4  defaults,nofail 1 2
UUID=$ESP_UUID /boot/efi   vfat  umask=0077,shortname=winnt,nofail 0 2
UUID=$SWAP_UUID none        swap  defaults,nofail 0 0
EOF
}
# Parametros comprovados no live (W6) sem os de live e sem earlycon. NAO ha rd.driver.blacklist do PHY:
# a raiz esta no NVMe, entao o PHY carrega no initramfs, depois do pwrctrl (force_drivers + softdep).
# clk_ignore_unused/pd_ignore_unused/regulator_ignore_unused sao OBRIGATORIOS: o PHY e modulo e carrega
# depois dos late_initcall; sem eles o kernel desliga clocks/GDSC do pcie5, o PHY devolve -ENODATA e nao ha raiz.
# systemd.zram=0: a base tem zram-generator e o kernel nao tem ZRAM.
gen_cmdline() {
    printf '%s' "root=UUID=$ROOT_UUID ro rootflags=subvol=$1 acpi=off clk_ignore_unused pd_ignore_unused" \
        " regulator_ignore_unused efi=noruntime enforcing=0 modprobe.blacklist=${VIDEO_BLACKLIST// /,}" \
        " rd.driver.pre=simpledrm console=tty0 loglevel=7 systemd.zram=0 systemd.tpm2_wait=0 plymouth.enable=0 rd.plymouth=0"
}
gen_grub_cfg() {
    cat <<EOF
# Gerado por install-yoga.sh. Slots em /boot/yoga/<slot>/{vmlinuz,board.dtb,initramfs.img,args.cfg}.
# Teste remoto de UMA tentativa: copie para /boot/yoga/try/ e rode 'yoga-boot-once try'; o boot seguinte
# volta sozinho para a entrada padrao (next_entry e apagado antes de entregar o controle ao kernel).
set timeout=1
# fallback por indice (funciona em qualquer GRUB): 1 = 'good', a segunda entrada. Nao reordene o menu.
set default=current
set fallback=1
insmod all_video
insmod gzio
set gfxpayload=keep
terminal_output console
terminal_input console
search --no-floppy --fs-uuid --set=yoga_esp $ESP_UUID
search --no-floppy --fs-uuid --set=yoga_boot $BOOT_UUID
set yoga_env=(\$yoga_esp)/EFI/BOOT/grubenv
if [ -s \$yoga_env ]; then
    load_env -f \$yoga_env
fi
if [ -n "\$next_entry" ]; then
    set default="\$next_entry"
    set next_entry=
    save_env -f \$yoga_env next_entry
elif [ -n "\$saved_entry" ]; then
    set default="\$saved_entry"
fi

# yoga_boot <slot> <subvolume da raiz>
function yoga_boot {
    set yoga_slot_args="$NVME_SAFE_ARGS"
    if [ -f (\$yoga_boot)/yoga/\$1/args.cfg ]; then
        source (\$yoga_boot)/yoga/\$1/args.cfg
    fi
    echo "YOGA: slot=\$1 raiz=\$2 extra=[\$yoga_slot_args]"
    # Slot incompleto nao carrega nada (kernel sem DTB com acpi=off trava sem panico): cai no fallback.
    if [ ! -s (\$yoga_boot)/yoga/\$1/vmlinuz -o ! -s (\$yoga_boot)/yoga/\$1/board.dtb -o ! -s (\$yoga_boot)/yoga/\$1/initramfs.img ]; then
        echo "YOGA: slot \$1 incompleto"
        false
    else
        linux (\$yoga_boot)/yoga/\$1/vmlinuz $(gen_cmdline '$2') \$yoga_slot_args
        devicetree (\$yoga_boot)/yoga/\$1/board.dtb
        initrd (\$yoga_boot)/yoga/\$1/initramfs.img
    fi
}

menuentry 'Fedora Yoga - atual' --id current {
    yoga_boot current root
}
menuentry 'Fedora Yoga - conhecida boa (kernel/DTB/initramfs anteriores)' --id good {
    yoga_boot good root
}
menuentry 'Fedora Yoga - teste de uma tentativa (/boot/yoga/try)' --id try {
    yoga_boot try root
}
menuentry 'Recuperacao - kernel bom + raiz do snapshot pos-instalacao' --id recovery {
    yoga_boot good snapshots/root-recovery
}
EOF
}
# Para os outros diretorios de onde um grub pode ser carregado (EFI/Microsoft/Boot, EFI/fedora).
gen_grub_stub() {
    printf '%s\n' "search --no-floppy --fs-uuid --set=yoga_esp $ESP_UUID" 'configfile ($yoga_esp)/EFI/BOOT/grub.cfg'
}
# $1 = slot (current|try). Arquivo lido pelo grub.cfg; e aqui que se relaxa ASPM/APST depois.
gen_slot_args() {
    local a=$NVME_SAFE_ARGS
    [[ $1 != try ]] || a="panic=30 $a"     # panico no slot de teste reinicia e volta para a entrada padrao
    printf '%s\n' "# Parametros extras deste slot (substituem o padrao do grub.cfg)." "set yoga_slot_args=\"$a\""
}
# $1 = dispositivo ou arquivo de imagem (o selftest usa um arquivo esparso).
make_gpt() {
    run parted -s -a optimal "$1" mklabel gpt \
        mkpart ESP fat32 1MiB "${P_ESP_END}MiB" set 1 esp on \
        mkpart boot ext4 "${P_ESP_END}MiB" "${P_BOOT_END}MiB" \
        mkpart swap linux-swap "${P_BOOT_END}MiB" "${P_SWAP_END}MiB" \
        mkpart root btrfs "${P_SWAP_END}MiB" 100%
}

# ---------- fases ----------
phase_preflight() {
    need_root; need_tools; need_live; need_disk
    local m; m=$(disk_mounts | grep -v -e "^$T\$" -e "^$T/" || true)
    [[ -z $m ]] || die "$DISK em uso fora de $T: $m"
    check_dtb "$DTB_DIR/$DTB_NAME"
    [[ -s /root/.ssh/authorized_keys ]] || die "/root/.ssh/authorized_keys vazio: o sistema instalado ficaria sem acesso"
    compgen -G '/etc/NetworkManager/system-connections/*.nmconnection' >/dev/null || die "nenhum perfil NetworkManager para copiar"
    compgen -G '/usr/lib/firmware/ath12k/WCN7850/hw2.0/*.bin' >/dev/null || die "firmware ath12k descomprimido ausente no live"
    [[ $(uname -r) == "$KVER" ]] || warn "kernel em execucao $(uname -r) != $KVER"
    log "disco: $(< "/sys/block/${DISK##*/}/device/model") serial=$(disk_serial)"
    parted -s "$DISK" unit MiB print || true
    lsblk -o NAME,SIZE,FSTYPE,LABEL,PARTLABEL,MOUNTPOINTS "$DISK"
    log "SMART"; smartctl -H -A "$DISK" || nvme smart-log "$DISK" || warn "sem leitura SMART"
    log "preflight OK. Antes de apagar: teste 'systemctl reboot' neste live (ver --help)."
    echo "Para apagar: CONFIRM_SERIAL=$(disk_serial) $0 partition --yes-erase-nvme0n1"
}

phase_backup_info() {
    need_root; need_disk
    [[ ! -e $BACKUP/parted.txt || -n ${FORCE_BACKUP:-} ]] || die "$BACKUP ja existe (FORCE_BACKUP=1 para sobrescrever)"
    mkdir -p "$BACKUP/esp"
    parted -sm "$DISK" unit s print > "$BACKUP/parted.txt"
    ! command -v sfdisk >/dev/null || sfdisk -d "$DISK" > "$BACKUP/sfdisk.dump"
    lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID,PARTTYPE,PARTUUID,PARTLABEL "$DISK" > "$BACKUP/lsblk.txt"
    dd if="$DISK" of="$BACKUP/gpt-primeiro-1MiB.bin" bs=1M count=1 status=none
    { smartctl -a "$DISK" || true; } > "$BACKUP/smart.txt" 2>&1
    disk_serial > "$BACKUP/serial.txt"
    local esp mp=$OLDESP_MNT
    esp=$(lsblk -nrpo NAME,PARTTYPE "$DISK" | awk 'tolower($2) == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" { print $1; exit }')
    if [[ -n $esp ]]; then
        # Usados em 'partition' para manter o PARTUUID da ESP (entrada NVRAM do Windows Boot Manager).
        lsblk -nro PARTUUID "$esp" > "$BACKUP/old-esp.partuuid"; printf '%s\n' "$esp" > "$BACKUP/old-esp.dev"
        mkdir -p "$mp"; mount -o ro "$esp" "$mp"
        cp -r --preserve=timestamps "$mp/." "$BACKUP/esp/" || warn "copia da ESP incompleta"
        umount "$mp"
    else
        warn "nenhuma ESP encontrada em $DISK"
    fi
    du -sh "$BACKUP"; log "copie $BACKUP para o PC (scp -r) ANTES de rodar partition"
}

phase_partition() {
    need_root; need_tools; need_live; need_disk
    [[ ${1:-} == --yes-erase-nvme0n1 ]] || die "partition exige o argumento --yes-erase-nvme0n1"
    local serial; serial=$(disk_serial)
    [[ -n ${CONFIRM_SERIAL:-} && $CONFIRM_SERIAL == "$serial" ]] || die "CONFIRM_SERIAL nao confere com o serial do disco"
    [[ -s $BACKUP/parted.txt ]] || die "rode backup-info antes (e copie $BACKUP para o PC)"
    [[ -z $(disk_mounts) ]] || die "$DISK montado: rode '$0 umount'"
    log "APAGANDO $DISK (serial $serial)"
    local p
    for p in $(lsblk -nrpo NAME "$DISK" | tail -n +2); do run wipefs -a "$p"; done
    run wipefs -a "$DISK"
    run blkdiscard -f "$DISK" || warn "blkdiscard falhou (segue sem TRIM total)"
    make_gpt "$DISK"
    run partprobe "$DISK"; run udevadm settle
    # HIPOTESE: o firmware casa a entrada 'Windows Boot Manager' pelo GUID da particao 1; manter o GUID
    # antigo faz essa entrada achar a nova ESP (ver copia em EFI/Microsoft/Boot na fase bootloader).
    if command -v sfdisk >/dev/null && [[ -s $BACKUP/old-esp.partuuid && $(< "$BACKUP/old-esp.dev") == "$(part 1)" ]]; then
        run sfdisk --part-uuid "$DISK" 1 "$(< "$BACKUP/old-esp.partuuid")" || warn "nao foi possivel manter o PARTUUID da ESP"
        run partprobe "$DISK"; run udevadm settle
    fi
    # O layout antigo tambem tinha p1-p4: sem esta conferencia um mkfs poderia cair na geometria velha.
    if [[ -z ${DRY_RUN:-} ]]; then
        local n=1 want got
        for want in $((P_ESP_END - 1)) $((P_BOOT_END - P_ESP_END)) $((P_SWAP_END - P_BOOT_END)); do
            got=$(lsblk -bndo SIZE "$(part "$n")")
            [[ $got -eq $((want * 1024 * 1024)) ]] || die "kernel nao releu a tabela: $(part "$n") tem $got bytes, esperado $want MiB (nada foi formatado)"
            n=$((n + 1))
        done
        [[ -b $(part 4) ]] || die "kernel nao releu a tabela: $(part 4) ausente"
    fi
    run mkfs.vfat -F 32 -n YOGA-ESP "$(part 1)"
    run mkfs.ext4 -F -q -L yoga-boot "$(part 2)"
    run mkswap -L yoga-swap "$(part 3)"
    run mkfs.btrfs -f -q -L yoga-root "$(part 4)"
    local top=$TOP_MNT s
    run mkdir -p "$top"; run mount "$(part 4)" "$top"
    for s in root home var_log snapshots; do run btrfs subvolume create "$top/$s"; done
    run btrfs subvolume set-default "$top/root"
    run umount "$top"; run udevadm settle
    lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID,PARTUUID "$DISK"
}

phase_copy() {
    need_root; need_live; need_disk; mount_target
    chroot_umount       # reexecucao depois de configure: nao rodar rsync sobre proc/sys/dev/run montados
    log "rsync $BASE -> $T (base erofs intocada, nao o overlay)"
    # Fora: ESP da imagem (firmware de Raspberry Pi; a ESP real e FAT), resgate e initramfs do live (regerado).
    # '/boot/efi' inteiro (nao '/boot/efi/*'): o diretorio ja existe (mount_target) e e a raiz do vfat, onde
    # o rsync -X falharia ao gravar o xattr SELinux e sairia com 23 com o disco ja apagado.
    rsync -aHAXSx --numeric-ids --info=stats1 \
        --exclude='/boot/efi' --exclude='/boot/*rescue*' --exclude="/boot/initramfs-$KVER.img" \
        --exclude='/boot/loader/entries/*' --exclude='/dev/*' --exclude='/proc/*' --exclude='/sys/*' \
        --exclude='/run/*' --exclude='/tmp/*' "$BASE/" "$T/"
    [[ -x $T/usr/bin/bash && -d $T/lib/modules/$KVER ]] || die "copia incompleta"
    log "copy OK (rodar de novo sobrescreve /etc: repita configure depois)"
}

phase_configure() {
    need_root; need_live; mount_target; load_uuids
    [[ -x $T/usr/bin/bash ]] || die "rode copy antes"
    local sc="systemctl --root=$T" f
    gen_fstab > "$T/etc/fstab"
    tr -d '-' < /proc/sys/kernel/random/uuid > "$T/etc/machine-id"
    printf '%s\n' "$NEW_HOSTNAME" > "$T/etc/hostname"

    grep -q "^$USER_LOGIN:" "$T/etc/passwd" || in_chroot useradd -m -c "$USER_GECOS" -G wheel -s /bin/bash "$USER_LOGIN"
    in_chroot passwd -d "$USER_LOGIN" >/dev/null     # sem senha inicial; sshd so aceita chave
    for f in "$T/root" "$T/home/$USER_LOGIN"; do
        install -d -m 700 "$f/.ssh"; install -m 600 /root/.ssh/authorized_keys "$f/.ssh/authorized_keys"
    done
    # Sessao padrao GNOME (Niri nao roda sem GPU) e sem o assistente de primeiro login.
    install -d "$T/var/lib/AccountsService/users" "$T/home/$USER_LOGIN/.config"
    printf '[User]\nSession=gnome\nXSession=gnome\nSystemAccount=false\n' > "$T/var/lib/AccountsService/users/$USER_LOGIN"
    printf 'yes' > "$T/home/$USER_LOGIN/.config/gnome-initial-setup-done"
    in_chroot chown -R "$USER_LOGIN:$USER_LOGIN" "/home/$USER_LOGIN"

    # So de live: livesys (cria liveuser e autologin a cada boot) e o autostart do instalador.
    $sc disable livesys.service livesys-late.service 2>/dev/null || true
    $sc mask livesys.service livesys-late.service
    rm -f "$T/etc/xdg/autostart/liveinst-setup.desktop"
    sed -i '/^AutomaticLogin/d;/^TimedLogin/d' "$T/etc/gdm/custom.conf"
    install -d "$T/etc/systemd/system-preset"
    printf 'enable sshd.service\ndisable livesys.service\ndisable livesys-late.service\n' > "$T/etc/systemd/system-preset/00-yoga.preset"
    $sc enable sshd.service NetworkManager.service
    # Acesso remoto: suspensao nunca foi testada neste hardware e o GDM suspende sozinho quando ocioso.
    # O caminho de suspend derruba link e PHY do NVMe (raiz) e depende de um resume nunca testado.
    # shellcheck disable=SC2086  # uma palavra por unit
    $sc mask $SLEEP_UNITS
    install -d "$T/etc/systemd/sleep.conf.d"
    printf '%s\n' '[Sleep]' AllowSuspend=no AllowHibernation=no AllowHybridSleep=no AllowSuspendThenHibernate=no \
        > "$T/etc/systemd/sleep.conf.d/yoga.conf"
    install -d "$T/etc/systemd/logind.conf.d"
    printf '[Login]\nHandleLidSwitch=ignore\nHandleLidSwitchExternalPower=ignore\n' > "$T/etc/systemd/logind.conf.d/yoga.conf"

    install -d -m 700 "$T/etc/NetworkManager/system-connections"
    install -m 600 /etc/NetworkManager/system-connections/*.nmconnection "$T/etc/NetworkManager/system-connections/"
    # O kernel nao le firmware .xz (CONFIG_FW_LOADER_COMPRESS desligado).
    install -d "$T/usr/lib/firmware/ath12k/WCN7850/hw2.0"
    install -m 644 /usr/lib/firmware/ath12k/WCN7850/hw2.0/*.bin "$T/usr/lib/firmware/ath12k/WCN7850/hw2.0/"

    # shellcheck disable=SC2086  # uma linha por modulo
    printf 'blacklist %s\n' $VIDEO_BLACKLIST > "$T/etc/modprobe.d/yoga-video-blacklist.conf"
    printf '%s\n' "# pwrctrl/pwrseq antes do PHY PCIe: sem isso o controlador liga e desliga e a tela apaga." \
        "softdep phy-qcom-qmp-pcie pre: $PCIE_PRE" > "$T/etc/modprobe.d/yoga-pcie.conf"
    # Initramfs generico (nao hostonly): gerado a partir do live, cujo "host" tem raiz em overlay/erofs;
    # hostonly so segue os ancestrais do disco e perderia fornecedores (PHY, clocks, pwrseq).
    cat > "$T/etc/dracut.conf.d/90-yoga.conf" <<EOF
hostonly="no"
hostonly_cmdline="no"
compress="zstd"
add_drivers+=" $INITRD_MODS "
force_drivers+=" $PCIE_PRE "
omit_drivers+=" $VIDEO_BLACKLIST ath12k "
install_items+=" /etc/modprobe.d/yoga-pcie.conf /etc/modprobe.d/yoga-video-blacklist.conf "
omit_dracutmodules+=" plymouth dmsquash-live dmsquash-live-autooverlay dmsquash-live-ntfs livenet network network-manager systemd-networkd nfs cifs iscsi nbd fcoe fcoe-uefi multipath nvmf lvm mdraid dmraid crypt stratis stratis-clevis bluetooth qemu qemu-net "
EOF
    install -d "$T/etc/kernel"; printf '%s %s\n' "$(gen_cmdline root)" "$NVME_SAFE_ARGS" > "$T/etc/kernel/cmdline"
    # O boot nao usa os pacotes: um shim/grub2 atualizado regrava EFI/BOOT e EFI/fedora e o shim passa a
    # encadear um grub sem o nosso grub.cfg; um kernel de pacote nao tem DTB nem estes modulos.
    grep -q '^excludepkgs=' "$T/etc/dnf/dnf.conf" || printf '%s\n' 'excludepkgs=shim-* grub2-* kernel*' >> "$T/etc/dnf/dnf.conf"
    # SELinux: permissivo no arquivo E enforcing=0 na cmdline (kernel custom, rotulos nunca validados);
    # rotulos refeitos agora com setfiles, sem /.autorelabel (evita um reboot extra sem supervisao).
    sed -i 's/^SELINUX=.*/SELINUX=permissive/' "$T/etc/selinux/config"
    cat > "$T/usr/local/sbin/yoga-boot-once" <<'EOF'
#!/bin/sh
# uso: yoga-boot-once [try|good|current|recovery] - entrada do GRUB so para o proximo boot.
exec grub2-editenv /boot/efi/EFI/BOOT/grubenv set "next_entry=${1:-try}"
EOF
    chmod 755 "$T/usr/local/sbin/yoga-boot-once"
    log "setfiles (rotulos SELinux)"
    in_chroot setfiles -F -e /proc -e /sys -e /dev -e /run /etc/selinux/targeted/contexts/files/file_contexts \
        / /home /var/log /boot || warn "setfiles falhou (sistema permissivo, segue)"
    log "configure OK"
}

phase_bootloader() {
    need_root; need_live; mount_target; load_uuids
    local esp=$T/boot/efi/EFI slots=$T/boot/yoga dtb=$DTB_DIR/$DTB_NAME shim grub mm
    check_dtb "$dtb" required
    [[ -f $T/etc/dracut.conf.d/90-yoga.conf ]] || die "rode configure antes"
    if [[ -n ${ESP_SRC:-} ]]; then
        shim=$(find "$ESP_SRC" -maxdepth 1 -iname bootaa64.efi | head -n1); grub=$ESP_SRC/grubaa64.efi; mm=$ESP_SRC/mmaa64.efi
    else    # gcdaa64.efi = grub com prefixo /EFI/BOOT, o mesmo binario de EFI/BOOT/grubaa64.efi da ISO
        shim=$BASE/boot/efi/EFI/BOOT/BOOTAA64.EFI; grub=$BASE/boot/efi/EFI/fedora/gcdaa64.efi; mm=$BASE/boot/efi/EFI/fedora/mmaa64.efi
    fi
    [[ -s $shim && -s $grub && -s $mm ]] || die "binarios EFI ausentes (shim=$shim grub=$grub mm=$mm)"
    install -d "$esp/BOOT" "$esp/Microsoft/Boot" "$esp/fedora" "$slots/current" "$slots/good" "$slots/try"

    log "slot current: kernel + $DTB_NAME + initramfs"
    cp "$T/boot/vmlinuz-$KVER" "$slots/current/vmlinuz"
    cp "$dtb" "$slots/current/board.dtb"
    printf '%s %s\n' "$(sha_of "$dtb")" "$DTB_NAME" > "$slots/current/SOURCE"
    in_chroot dracut --force --kver "$KVER" /boot/yoga/current/initramfs.img
    [[ -s $slots/current/initramfs.img ]] || die "dracut nao gerou o initramfs"
    gen_slot_args current > "$slots/current/args.cfg"
    # 'good' so e criado na primeira vez: reexecutar com outro DTB nao pode destruir a entrada boa.
    [[ -s $slots/good/vmlinuz ]] || cp -a "$slots/current/." "$slots/good/"
    [[ -e $slots/try/args.cfg ]] || gen_slot_args try > "$slots/try/args.cfg"

    log "ESP: caminho de fallback EFI/BOOT (sem variaveis EFI) + copia em EFI/Microsoft/Boot"
    cp "$shim" "$esp/BOOT/BOOTAA64.EFI"; cp "$grub" "$esp/BOOT/grubaa64.efi"; cp "$mm" "$esp/BOOT/mmaa64.efi"
    gen_grub_cfg > "$esp/BOOT/grub.cfg"
    grub2-script-check "$esp/BOOT/grub.cfg" || die "grub.cfg invalido"
    [[ -s $esp/BOOT/grubenv ]] || grub2-editenv "$esp/BOOT/grubenv" create
    grub2-editenv "$esp/BOOT/grubenv" set saved_entry=current
    grub2-editenv "$esp/BOOT/grubenv" unset next_entry
    cp "$shim" "$esp/Microsoft/Boot/bootmgfw.efi"; cp "$grub" "$esp/Microsoft/Boot/grubaa64.efi"; cp "$mm" "$esp/Microsoft/Boot/mmaa64.efi"
    gen_grub_stub > "$esp/Microsoft/Boot/grub.cfg"
    # Se um shim/grub de pacote voltar para EFI/fedora (prefixo /EFI/fedora), ainda chega ao grub.cfg real.
    gen_grub_stub > "$esp/fedora/grub.cfg"

    # Raiz de recuperacao gravavel: sistema recem-instalado, com Wi-Fi e sshd, para consertar a raiz principal.
    if [[ -d $T/.snapshots/root-recovery ]]; then
        warn "snapshot root-recovery ja existe (mantido; apague-o para recriar)"
    else
        btrfs subvolume snapshot "$T" "$T/.snapshots/root-recovery"
    fi
    sync; log "bootloader OK"
}

phase_verify() {
    need_root; mount_target; load_uuids
    local bad=0 esp=$T/boot/efi/EFI slots=$T/boot/yoga u f m lst
    ok()  { printf '  ok    %s\n' "$*"; }
    bad() { printf '  FALHA %s\n' "$*"; bad=$((bad + 1)); }
    chk() { local d=$1; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
    log "particoes"; lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINTS "$DISK"; btrfs subvolume list "$T"
    log "fstab"; cat "$T/etc/fstab"
    # shellcheck disable=SC2013  # UUIDs nao tem espacos
    for u in $(awk '/^UUID=/ { sub("UUID=", "", $1); print $1 }' "$T/etc/fstab" | sort -u); do chk "fstab UUID $u existe" blkid -U "$u"; done
    for u in "$ESP_UUID" "$BOOT_UUID" "$ROOT_UUID"; do chk "grub.cfg cita $u" grep -q "$u" "$esp/BOOT/grub.cfg"; done
    chk "grub.cfg sintaxe" grub2-script-check "$esp/BOOT/grub.cfg"
    for f in "$esp"/BOOT/{BOOTAA64.EFI,grubaa64.efi,mmaa64.efi,grub.cfg,grubenv} "$esp"/Microsoft/Boot/{bootmgfw.efi,grubaa64.efi,grub.cfg} "$esp/fedora/grub.cfg" \
             "$slots"/{current,good}/{vmlinuz,initramfs.img,args.cfg}; do chk "existe ${f#"$T"}" test -s "$f"; done
    for f in "$slots"/{current,good}/board.dtb; do chk "DTB valido ${f#"$T"}" is_dtb "$f"; done
    chk "DTB do slot current = sha256 gravado em SOURCE" grep -q "^$(sha_of "$slots/current/board.dtb") " "$slots/current/SOURCE"
    [[ -z ${DTB_SHA256:-} ]] || chk "DTB do slot current = DTB_SHA256" test "$(sha_of "$slots/current/board.dtb")" = "${DTB_SHA256,,}"
    log "cmdline"
    for m in clk_ignore_unused pd_ignore_unused regulator_ignore_unused systemd.zram=0 efi=noruntime; do
        chk "grub.cfg tem $m" grep -Eq "^ *linux .* $m( |\$)" "$esp/BOOT/grub.cfg"
    done
    for f in "$slots"/{current,good}/args.cfg; do for m in $NVME_SAFE_ARGS; do chk "${f#"$T"} tem $m" grep -q -- "$m" "$f"; done; done
    chk "sem rd.driver.blacklist / rd.live / earlycon" bash -c '! grep -Eq "rd\.driver\.blacklist|rd\.live|earlycon" "$@"' _ \
        "$esp/BOOT/grub.cfg" "$slots"/{current,good,try}/args.cfg "$T/etc/kernel/cmdline"
    chk "PHY PCIe fora das blacklists" bash -c '! grep -rEq "phy[-_]qcom[-_]qmp[-_]pcie" "$1" --include="*blacklist*"' _ "$T/etc/modprobe.d"
    chk "kernel do slot = /boot/vmlinuz-$KVER" cmp "$slots/current/vmlinuz" "$T/boot/vmlinuz-$KVER"
    log "initramfs"; lst=$(lsinitrd "$slots/current/initramfs.img")
    for m in $INITRD_MODS; do chk "modulo $m" grep -Eq "/${m//-/[-_]}\.ko" <<<"$lst"; done
    chk "softdep do PCIe no initramfs" grep -q 'etc/modprobe.d/yoga-pcie.conf' <<<"$lst"
    chk "rd.driver.pre do pwrctrl (20-force_drivers.conf)" grep -q 'etc/cmdline.d/20-force_drivers.conf' <<<"$lst"
    # Ordem: rd.driver.pre (modprobe sincrono antes do udev) + softdep garantem pwrseq/pwrctrl antes do PHY.
    lst=$(lsinitrd -f etc/cmdline.d/20-force_drivers.conf "$slots/current/initramfs.img" 2>/dev/null; \
          lsinitrd -f etc/modprobe.d/yoga-pcie.conf "$slots/current/initramfs.img" 2>/dev/null) || true
    for m in $PCIE_PRE; do
        chk "$m em rd.driver.pre" grep -Eq "rd\.driver\.pre=${m//-/[-_]}( |\$)" <<<"$lst"
        chk "$m no softdep do PHY" grep -Eq "^softdep phy-qcom-qmp-pcie pre:.* $m( |\$)" <<<"$lst"
    done
    chk "PHY nao esta em rd.driver.pre/blacklist do initramfs" bash -c '! grep -Eq "(pre|blacklist)=phy[-_]qcom" <<<"$1"' _ "$lst"
    lst=$(lsinitrd "$slots/current/initramfs.img")
    # So aviso: a guarda real contra os modulos de video e modprobe.blacklist na cmdline.
    ! grep -Eq '/(msm|dispcc[-_]glymur|gpucc[-_]glymur|ath12k)\.ko' <<<"$lst" || warn "modulos de video/ath12k presentes no initramfs"
    log "sistema"
    chk "hostname $NEW_HOSTNAME" grep -qx "$NEW_HOSTNAME" "$T/etc/hostname"
    chk "machine-id" grep -Eqx '[0-9a-f]{32}' "$T/etc/machine-id"
    chk "usuario $USER_LOGIN ($USER_GECOS)" grep -q "^$USER_LOGIN:[^:]*:[^:]*:[^:]*:$USER_GECOS:" "$T/etc/passwd"
    chk "$USER_LOGIN sem senha" grep -q "^$USER_LOGIN::" "$T/etc/shadow"
    chk "$USER_LOGIN no grupo wheel" grep -Eq "^wheel:.*[:,]$USER_LOGIN(,|\$)" "$T/etc/group"
    chk "sshd habilitado" test -L "$T/etc/systemd/system/multi-user.target.wants/sshd.service"
    for u in $SLEEP_UNITS; do chk "$u mascarado" test "$(readlink "$T/etc/systemd/system/$u")" = /dev/null; done
    for m in AllowSuspend AllowHibernation AllowHybridSleep AllowSuspendThenHibernate; do
        chk "sleep.conf.d $m=no" grep -qx "$m=no" "$T/etc/systemd/sleep.conf.d/yoga.conf"
    done
    chk "dnf exclui shim/grub2/kernel" grep -qx 'excludepkgs=shim-\* grub2-\* kernel\*' "$T/etc/dnf/dnf.conf"
    chk "livesys mascarado" test "$(readlink "$T/etc/systemd/system/livesys.service")" = /dev/null
    chk "sem autologin no GDM" bash -c '! grep -q "^AutomaticLogin" "$1"' _ "$T/etc/gdm/custom.conf"
    for f in "$T/root" "$T/home/$USER_LOGIN"; do chk "authorized_keys em ${f#"$T"}" test -s "$f/.ssh/authorized_keys"; done
    chk "perfil Wi-Fi" compgen -G "$T/etc/NetworkManager/system-connections/*.nmconnection"
    chk "firmware ath12k sem .xz" test -s "$T/usr/lib/firmware/ath12k/WCN7850/hw2.0/amss.bin"
    chk "SELinux permissivo" grep -qx 'SELINUX=permissive' "$T/etc/selinux/config"
    chk "snapshot root-recovery" test -x "$T/.snapshots/root-recovery/usr/bin/bash"
    log "grubenv"; grub2-editenv "$esp/BOOT/grubenv" list
    log "resumo"; du -sh "$slots"/*/ 2>/dev/null; cat "$slots/current/SOURCE"
    sha256sum "$esp"/BOOT/*.EFI "$esp"/BOOT/*.efi 2>/dev/null | sed "s|$T||"
    grep -m1 'linux ' "$esp/BOOT/grub.cfg"
    ((bad == 0)) || die "$bad verificacao(oes) falharam"
    log "verify OK: '$0 umount' e reinicie sem o pendrive (retorno: F12 + pendrive)"
}

# Sem root e sem tocar em dispositivo de bloco: gera os artefatos em um diretorio temporario.
phase_selftest() {
    local d; d=$(mktemp -d)
    # shellcheck disable=SC2064  # expandir agora: 'd' e local e nao existe mais no EXIT
    trap "rm -rf '$d'" EXIT
    ESP_UUID=AB12-CD34 BOOT_UUID=11111111-1111-4111-8111-111111111111
    SWAP_UUID=22222222-2222-4222-8222-222222222222 ROOT_UUID=33333333-3333-4333-8333-333333333333
    gen_grub_cfg > "$d/grub.cfg"; gen_fstab > "$d/fstab"; gen_grub_stub > "$d/stub.cfg"
    gen_slot_args current > "$d/args-current.cfg"; gen_slot_args try > "$d/args-try.cfg"
    local f w linux
    if command -v grub2-script-check >/dev/null; then
        for f in grub.cfg stub.cfg args-current.cfg args-try.cfg; do grub2-script-check "$d/$f" || die "selftest: $f invalido"; done
    fi
    [[ $(grep -c '^menuentry ' "$d/grub.cfg") -eq 4 ]] || die "selftest: grub.cfg sem 4 entradas"
    [[ $(grep -c '^UUID=' "$d/fstab") -eq 7 ]] || die "selftest: fstab sem 7 linhas"
    # fallback=1 tem de ser a entrada 'good' (segunda).
    grep -qx 'set fallback=1' "$d/grub.cfg" || die "selftest: fallback nao e 1"
    [[ $(grep '^menuentry ' "$d/grub.cfg" | sed -n 2p) == *'--id good '* ]] || die "selftest: a segunda entrada nao e 'good'"
    [[ $(grep -c '^ *linux ' "$d/grub.cfg") -eq 1 ]] || die "selftest: esperava uma unica linha linux"
    linux=$(grep '^ *linux ' "$d/grub.cfg")
    [[ $linux == *"root=UUID=$ROOT_UUID ro rootflags=subvol=\$2 acpi=off "* ]] || die "selftest: root/rootflags errados"
    for w in clk_ignore_unused pd_ignore_unused regulator_ignore_unused systemd.zram=0 efi=noruntime enforcing=0; do
        [[ " $linux " == *" $w "* ]] || die "selftest: cmdline sem $w"
    done
    [[ $linux == *' $yoga_slot_args' ]] || die "selftest: linha linux nao termina em \$yoga_slot_args"
    if grep -Eq 'rd\.live|earlycon|rd\.driver\.blacklist' "$d/grub.cfg" "$d"/args-*.cfg; then die "selftest: parametro proibido na cmdline"; fi
    if [[ $VIDEO_BLACKLIST == *phy* || $linux == *blacklist=*phy* ]]; then die "selftest: PHY em blacklist"; fi
    for w in pcie_aspm=off nvme_core.default_ps_max_latency_us=0; do     # literais: nao derivar da constante
        grep -q -- "$w" "$d/args-current.cfg" || die "selftest: args.cfg (current) sem $w"
        grep -q -- "$w" "$d/args-try.cfg" || die "selftest: args.cfg (try) sem $w"
        grep -q -- "set yoga_slot_args=\".*$w" "$d/grub.cfg" || die "selftest: padrao do grub.cfg sem $w"
    done
    grep -q 'panic=30' "$d/args-try.cfg" || die "selftest: slot try sem panic=30"
    grep -q 'if \[ ! -s .*/vmlinuz -o ! -s .*/board.dtb -o ! -s .*/initramfs.img \]' "$d/grub.cfg" || die "selftest: sem guarda de slot incompleto"
    # PHY so depois do pwrseq/pwrctrl: os dois tem de estar em PCIE_PRE (force_drivers + softdep) e no initramfs.
    for w in pwrseq-qcom-wcn pci-pwrctrl-pwrseq; do
        [[ " $PCIE_PRE " == *" $w "* && " $INITRD_MODS " == *" $w "* ]] || die "selftest: $w fora de PCIE_PRE/INITRD_MODS"
    done
    if [[ " $PCIE_PRE " == *" phy-qcom-qmp-pcie "* ]]; then die "selftest: PHY dentro de PCIE_PRE"; fi
    # check_dtb: magic + sha256 (em subshell: die sai do subshell, nao do selftest).
    printf '\xd0\x0d\xfe\xed%s' conteudo > "$d/ok.dtb"; printf 'nao-e-dtb' > "$d/ruim.dtb"
    (DTB_SHA256=$(sha_of "$d/ok.dtb"); check_dtb "$d/ok.dtb" required) || die "selftest: check_dtb recusou o hash certo"
    if (DTB_SHA256=$(sha_of "$d/ruim.dtb"); check_dtb "$d/ok.dtb" required) 2>/dev/null; then die "selftest: check_dtb aceitou hash errado"; fi
    if (unset DTB_SHA256; check_dtb "$d/ok.dtb" required) 2>/dev/null; then die "selftest: check_dtb aceitou sem DTB_SHA256"; fi
    if (DTB_SHA256=$(sha_of "$d/ruim.dtb"); check_dtb "$d/ruim.dtb" required) 2>/dev/null; then die "selftest: check_dtb aceitou arquivo sem magic"; fi
    if command -v parted >/dev/null; then
        truncate -s 20G "$d/disk.img"; make_gpt "$d/disk.img"
        parted -sm "$d/disk.img" unit MiB print | tee "$d/gpt.txt"
        [[ $(grep -c '^[1-4]:' "$d/gpt.txt") -eq 4 ]] || die "selftest: GPT sem 4 particoes"
        grep -q '^1:1.00MiB:1025MiB:1024MiB:.*esp' "$d/gpt.txt" || die "selftest: particao 1 (ESP) fora do esperado"
        grep -q '^2:1025MiB:5121MiB:4096MiB:' "$d/gpt.txt" || die "selftest: particao 2 (/boot) fora do esperado"
        grep -q '^3:5121MiB:13313MiB:8192MiB:' "$d/gpt.txt" || die "selftest: particao 3 (swap) fora do esperado"
    fi
    cat "$d/grub.cfg" "$d/args-current.cfg" "$d/args-try.cfg" "$d/fstab"; echo "selftest OK"
}

usage() { sed -n '3,/^set -euo/{/^#/p}' "$0"; }

case ${1:-} in
    preflight)   phase_preflight ;;
    backup-info) phase_backup_info ;;
    partition)   shift; phase_partition "$@" ;;
    copy)        phase_copy ;;
    configure)   phase_configure ;;
    bootloader)  phase_bootloader ;;
    verify)      phase_verify ;;
    umount)      phase_umount ;;
    selftest)    phase_selftest ;;
    -h|--help|help) usage ;;
    *) usage >&2; exit 2 ;;
esac
