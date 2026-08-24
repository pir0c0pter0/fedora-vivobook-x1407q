#!/bin/bash
# =============================================================================
# build-vivobook-iso.sh — PARTE 1: builder do ISO bootável (roda em QUALQUER PC)
# ASUS Vivobook X1407QA (Snapdragon X) — Fedora 44 aarch64
#
# Faz o mínimo para BOOTAR e INSTALAR o Linux no Vivobook:
#   - Detecta gerenciador de pacotes (dnf/apt/pacman/zypper)
#   - Baixa/verifica (SHA256) o ISO Fedora aarch64
#   - Injeta parâmetros de boot Snapdragon no GRUB do live
#   - Empacota o payload da PARTE 2 em /opt/vivobook-fixes/ (setup-vivobook.sh
#     + scripts + modules/ + firmware/ bundled + fontes .c)
#   - Reconstrói squashfs + ISO, verifica, grava USB
#
# Os fixes de hardware NÃO são aplicados aqui — isso é a PARTE 2:
#   no Vivobook já bootado, rodar: sudo /opt/vivobook-fixes/setup-vivobook.sh
# =============================================================================

set -uo pipefail

VERSION="1.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR=""  # set to unique mktemp dir in build_complete()

# Fedora download settings (override via env: FEDORA_VERSION=44 ./build-vivobook-iso.sh)
FEDORA_VERSION="${FEDORA_VERSION:-44}"
FEDORA_ARCH="aarch64"
FEDORA_EDITION="Workstation"
FEDORA_MIRROR="https://dl.fedoraproject.org/pub/fedora/linux"

# Overlay de firmware bundled no repo (espelha /usr/lib/firmware) — opcional.
# Se presente, tem prioridade sobre o firmware do host. Permite build em qualquer PC.
FW_BUNDLE="${SCRIPT_DIR}/firmware"

# Globals set during build
ISO_INPUT=""
ISO_OUTPUT=""
ISO_DIR=""
SQUASH_DIR=""
ROOTFS=""
ROOTFS_TYPE=""  # "mounted" or "direct"

# Cleanup tracking
CLEANUP_MOUNTS=()
CLEANUP_DIRS=()

# ─── Colors & logging ────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()    { echo -e "${GREEN}[+]${NC} $*"; }
warn()   { echo -e "${YELLOW}[!]${NC} $*"; }
err()    { echo -e "${RED}[x]${NC} $*"; }
info()   { echo -e "${CYAN}[i]${NC} $*"; }
header() { echo ""; echo -e "${BOLD}$*${NC}"; echo ""; }
step()   { echo -e "${GREEN}[${1}/${2}]${NC} ${3}"; }

# ─── Cleanup ─────────────────────────────────────────────────────────────────
cleanup() {
    for mnt in "${CLEANUP_MOUNTS[@]}"; do
        sudo umount "$mnt" 2>/dev/null || true
    done
    for dir in "${CLEANUP_DIRS[@]}"; do
        sudo rm -rf "$dir" 2>/dev/null || true
    done
}
trap cleanup EXIT

# ─── Prompts ─────────────────────────────────────────────────────────────────
prompt_yn() {
    local msg="$1" default="${2:-s}"
    local choice
    if [[ "$default" == "s" ]]; then
        read -rp "$(echo -e "${msg} [${BOLD}S${NC}/n]: ")" choice </dev/tty || choice=""
        [[ -z "$choice" || "$choice" =~ ^[Ss]$ ]]
    else
        read -rp "$(echo -e "${msg} [s/${BOLD}N${NC}]: ")" choice </dev/tty || choice=""
        [[ "$choice" =~ ^[Ss]$ ]]
    fi
}

# ─── Dependencies ────────────────────────────────────────────────────────────
# Instala só os comandos faltando, mapeando comando -> pacote por gerenciador.
# brew vem primeiro: não precisa de sudo e funciona em distros atômicas
# (Bazzite/Silverblue), onde `dnf` é redirecionado pro rpm-ostree e recusa instalar.
install_deps_pkgs() {
    local cmds=("$@")
    [[ ${#cmds[@]} -eq 0 ]] && return 0

    local mgr=""
    if   command -v brew    &>/dev/null; then mgr=brew
    elif command -v dnf     &>/dev/null; then mgr=dnf
    elif command -v apt-get &>/dev/null; then mgr=apt
    elif command -v pacman  &>/dev/null; then mgr=pacman
    elif command -v zypper  &>/dev/null; then mgr=zypper
    else
        err "Gerenciador de pacotes não reconhecido (brew/dnf/apt/pacman/zypper)."
        info "Instale manualmente os equivalentes a: ${cmds[*]}"
        return 1
    fi

    local c pkg; local -A seen=(); local pkgs=()
    for c in "${cmds[@]}"; do
        case "$c" in
            xorriso)            case "$mgr" in pacman) pkg=libisoburn;;     *) pkg=xorriso;;        esac ;;
            unsquashfs|mksquashfs) case "$mgr" in brew|zypper) pkg=squashfs;; *) pkg=squashfs-tools;; esac ;;
            e2fsck|resize2fs)   pkg=e2fsprogs ;;
            sha256sum)          pkg=coreutils ;;
            curl)               pkg=curl ;;
            *)                  pkg="$c" ;;
        esac
        [[ -n "${seen[$pkg]:-}" ]] && continue
        seen[$pkg]=1; pkgs+=("$pkg")
    done

    log "Instalando via ${mgr}: ${pkgs[*]}"
    case "$mgr" in
        brew)   brew install "${pkgs[@]}" ;;
        dnf)    sudo dnf install -y "${pkgs[@]}" ;;
        apt)    sudo apt-get update && sudo apt-get install -y "${pkgs[@]}" ;;
        pacman) sudo pacman -Sy --needed --noconfirm "${pkgs[@]}" ;;
        zypper) sudo zypper install -y "${pkgs[@]}" ;;
    esac
}

# Retorna o primeiro diretório existente da lista (repo-bundled tem prioridade sobre host)
first_dir() {
    local d
    for d in "$@"; do [[ -d "$d" ]] && { echo "$d"; return 0; }; done
    return 1
}

check_deps() {
    local missing=()
    for cmd in xorriso unsquashfs mksquashfs sha256sum curl e2fsck resize2fs; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        warn "Dependências faltando: ${missing[*]}"
        if prompt_yn "Instalar automaticamente?"; then
            install_deps_pkgs "${missing[@]}" || { err "Falha ao instalar dependências."; exit 1; }
            # Re-checa: nomes de pacote variam por distro, confirma que resolveu
            local still=()
            for cmd in xorriso unsquashfs mksquashfs sha256sum curl e2fsck resize2fs; do
                command -v "$cmd" &>/dev/null || still+=("$cmd")
            done
            if [[ ${#still[@]} -gt 0 ]]; then
                err "Ainda faltam após instalar: ${still[*]}"
                info "Instale manualmente e rode de novo."
                exit 1
            fi
        else
            err "Instale manualmente e tente novamente."
            exit 1
        fi
    fi
    # gcc é opcional (pode usar .so pre-built)
    if ! command -v gcc &>/dev/null; then
        warn "gcc não encontrado — vk_pool_fix.so será copiado pre-built (se disponível)"
    fi
    log "Dependências OK"
}

# ─── Space check ─────────────────────────────────────────────────────────────
check_space() {
    local required_gb="${1:-12}"
    local path="${2:-/tmp}"
    local avail_mb
    avail_mb=$(df -BM "$path" | tail -1 | awk '{print $4}' | tr -d 'M')
    local required_mb=$((required_gb * 1024))
    if [[ $avail_mb -lt $required_mb ]]; then
        err "Precisa de pelo menos ${required_gb}GB livres em ${path} (tem $((avail_mb / 1024))GB)"
        exit 1
    fi
    log "Espaço em ${path}: $((avail_mb / 1024))GB (precisa ${required_gb}GB)"
}

# ─── ISO Download ────────────────────────────────────────────────────────────
fedora_iso_urls() {
    # Release first, then Beta
    echo "${FEDORA_MIRROR}/releases/${FEDORA_VERSION}/${FEDORA_EDITION}/${FEDORA_ARCH}/iso/"
    echo "${FEDORA_MIRROR}/releases/test/${FEDORA_VERSION}_Beta/${FEDORA_EDITION}/${FEDORA_ARCH}/iso/"
}

download_iso() {
    header "══════════════════════════════════════════
  DOWNLOAD — Fedora ${FEDORA_VERSION} ${FEDORA_EDITION} ${FEDORA_ARCH}
══════════════════════════════════════════"

    # Find available ISO on Fedora mirrors
    local base_url="" iso_name="" checksum_name=""

    while IFS= read -r url; do
        info "Verificando: ${url}"
        local listing
        listing=$(curl -sf --max-time 15 "$url" 2>/dev/null) || continue

        # Parse HTML directory listing for Live ISO filename
        iso_name=$(echo "$listing" | grep -oP 'Fedora-[^"]*Live[^"]*\.'"${FEDORA_ARCH}"'\.iso' | sort -V | tail -1)
        if [[ -n "$iso_name" ]]; then
            base_url="$url"
            checksum_name=$(echo "$listing" | grep -oP 'Fedora-[^"]*-'"${FEDORA_ARCH}"'-CHECKSUM' | head -1)
            break
        fi
    done < <(fedora_iso_urls)

    if [[ -z "$base_url" || -z "$iso_name" ]]; then
        err "Não encontrou ISO no mirror Fedora."
        info "Verifique: ${FEDORA_MIRROR}/releases/${FEDORA_VERSION}/"
        info "Ou baixe manualmente: https://fedoraproject.org/workstation/download"
        return 1
    fi

    local iso_url="${base_url}${iso_name}"
    local iso_dest="${SCRIPT_DIR}/${iso_name}"

    log "ISO: ${iso_name}"
    info "URL: ${iso_url}"
    echo ""

    # Check if already downloaded
    if [[ -f "$iso_dest" ]]; then
        local existing_size
        existing_size=$(du -h "$iso_dest" | cut -f1)
        warn "Já existe: ${iso_name} (${existing_size})"
        if ! prompt_yn "Baixar novamente (resume se parcial)?"; then
            ISO_INPUT="$iso_dest"
            return 0
        fi
    fi

    # Download CHECKSUM first
    if [[ -n "$checksum_name" ]]; then
        local checksum_dest="${SCRIPT_DIR}/${checksum_name}"
        log "Baixando checksum..."
        curl -f --max-time 30 -o "$checksum_dest" "${base_url}${checksum_name}" 2>/dev/null || \
            warn "Checksum não baixado"
    fi

    # Download ISO with resume support
    log "Baixando ISO (~2.5GB)..."
    info "Suporta resume — se interromper, rode novamente para continuar"
    echo ""

    if curl -f -C - --progress-bar -o "$iso_dest" "$iso_url"; then
        log "Download concluído: ${iso_name}"
    else
        err "Falha no download!"
        info "Rode novamente — curl retoma de onde parou."
        return 1
    fi

    # Verify checksum
    if [[ -n "$checksum_name" && -f "${SCRIPT_DIR}/${checksum_name}" ]]; then
        log "Verificando SHA256..."
        local expected_hash
        expected_hash=$(grep "$iso_name" "${SCRIPT_DIR}/${checksum_name}" 2>/dev/null \
            | grep -oP '[a-f0-9]{64}' | head -1)
        if [[ -n "$expected_hash" ]]; then
            local actual_hash
            actual_hash=$(sha256sum "$iso_dest" | awk '{print $1}')
            if [[ "$actual_hash" == "$expected_hash" ]]; then
                log "SHA256 OK: ${actual_hash:0:16}..."
            else
                err "SHA256 NÃO CONFERE — ISO corrompida!"
                err "Delete e tente novamente: rm \"${iso_dest}\""
                return 1
            fi
        else
            warn "Hash não encontrado no checksum para ${iso_name}"
        fi
    fi

    ISO_INPUT="$iso_dest"
    log "ISO pronta: ${iso_dest}"
}

# ─── ISO Discovery ───────────────────────────────────────────────────────────
discover_isos() {
    local isos=()
    while IFS= read -r iso; do
        isos+=("$iso")
    done < <(find "$SCRIPT_DIR" -maxdepth 1 -name "*.iso" -printf "%f\n" 2>/dev/null | sort)

    if [[ ${#isos[@]} -eq 0 ]]; then
        warn "Nenhuma ISO encontrada em ${SCRIPT_DIR}/"
        if prompt_yn "Baixar Fedora ${FEDORA_VERSION} ${FEDORA_ARCH} automaticamente?"; then
            download_iso || exit 1
            return
        else
            err "Coloque uma ISO Fedora aarch64 neste diretório e tente novamente."
            exit 1
        fi
    fi

    header "ISOs encontradas:"
    for i in "${!isos[@]}"; do
        local size
        size=$(du -h "${SCRIPT_DIR}/${isos[$i]}" | cut -f1)
        echo -e "  ${BOLD}$((i + 1))${NC}) ${isos[$i]} (${size})"
    done
    echo ""

    local choice
    read -rp "Selecione a ISO [1]: " choice </dev/tty || choice="1"
    choice="${choice:-1}"
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 || "$choice" -gt ${#isos[@]} ]]; then
        err "Opção inválida"
        exit 1
    fi

    ISO_INPUT="${SCRIPT_DIR}/${isos[$((choice - 1))]}"
    log "ISO selecionada: $(basename "$ISO_INPUT")"
}

# ─── ISO Verification ────────────────────────────────────────────────────────
verify_iso() {
    local iso_path="$1"
    local iso_name
    iso_name=$(basename "$iso_path")

    header "══════════════════════════════════════════
  VERIFICAÇÃO: ${iso_name}
══════════════════════════════════════════"

    if [[ ! -f "$iso_path" ]]; then
        err "ISO não encontrada: $iso_path"
        return 1
    fi

    local iso_size
    iso_size=$(du -h "$iso_path" | cut -f1)
    log "Tamanho: ${iso_size}"

    # --- SHA256 checksum ---
    local checksum_file=""
    for candidate in \
        "${iso_path}.sha256" \
        "${iso_path%.*}-CHECKSUM" \
        "${SCRIPT_DIR}/SHA256SUMS" \
        "${SCRIPT_DIR}"/Fedora-Workstation-*-"${FEDORA_ARCH}"-CHECKSUM; do
        if [[ -f "$candidate" ]]; then
            checksum_file="$candidate"
            break
        fi
    done

    if [[ -n "$checksum_file" ]]; then
        log "Checksum encontrado: $(basename "$checksum_file")"
        local expected_hash
        # Handle both "HASH  filename" and "SHA256 (filename) = HASH" formats
        expected_hash=$(grep "$iso_name" "$checksum_file" 2>/dev/null | grep -oP '[a-f0-9]{64}' | head -1)

        if [[ -n "$expected_hash" ]]; then
            info "Calculando SHA256 (pode demorar ~1 min)..."
            local actual_hash
            actual_hash=$(sha256sum "$iso_path" | awk '{print $1}')
            if [[ "$actual_hash" == "$expected_hash" ]]; then
                log "SHA256 OK: ${actual_hash:0:16}..."
            else
                err "SHA256 NÃO CONFERE!"
                err "  Esperado: ${expected_hash:0:32}..."
                err "  Obtido:   ${actual_hash:0:32}..."
                if ! prompt_yn "Continuar mesmo assim?" "n"; then
                    return 1
                fi
            fi
        else
            warn "ISO não encontrada no arquivo de checksum"
        fi
    else
        warn "Arquivo de checksum não encontrado (.sha256 ou SHA256SUMS)"
        info "Para verificar, baixe o checksum do Fedora e coloque junto à ISO."
    fi

    # --- Structure check ---
    info "Verificando estrutura..."
    if ! xorriso -indev "$iso_path" -ls / >/dev/null 2>&1; then
        err "Falha ao ler estrutura da ISO — arquivo corrompido?"
        return 1
    fi
    log "Estrutura ISO válida"

    local has_live=false has_efi=false has_grub=false
    xorriso -indev "$iso_path" -ls /LiveOS/ >/dev/null 2>&1 && has_live=true
    xorriso -indev "$iso_path" -ls /EFI/ >/dev/null 2>&1 && has_efi=true
    xorriso -indev "$iso_path" -find / -name "grub.cfg" 2>/dev/null | grep -q grub && has_grub=true

    if [[ "$has_live" == true ]]; then log "LiveOS presente"; else warn "LiveOS não encontrado"; fi
    if [[ "$has_efi" == true ]]; then log "EFI boot presente"; else warn "EFI boot não encontrado"; fi
    if [[ "$has_grub" == true ]]; then log "GRUB config presente"; else warn "GRUB config não encontrado"; fi

    return 0
}

# ─── Extract ISO ──────────────────────────────────────────────────────────────
extract_iso() {
    ISO_DIR="${WORK_DIR}/iso"
    rm -rf "$ISO_DIR"
    mkdir -p "$ISO_DIR"

    log "Extraindo ISO..."
    if ! xorriso -osirrox on -indev "$ISO_INPUT" -extract / "$ISO_DIR" 2>/dev/null; then
        err "Falha ao extrair ISO com xorriso"
        exit 1
    fi
    chmod -R u+w "$ISO_DIR"
    if [[ ! -d "${ISO_DIR}/LiveOS" ]]; then
        err "Extração incompleta — LiveOS ausente em ${ISO_DIR}"
        exit 1
    fi
    log "ISO extraída"
}

# ─── Extract squashfs & get rootfs ────────────────────────────────────────────
extract_squashfs() {
    local squash_img="${ISO_DIR}/LiveOS/squashfs.img"
    if [[ ! -f "$squash_img" ]]; then
        squash_img=$(find "$ISO_DIR" -name "squashfs.img" 2>/dev/null | head -1)
    fi
    if [[ -z "$squash_img" || ! -f "$squash_img" ]]; then
        err "squashfs.img não encontrado na ISO"
        exit 1
    fi

    SQUASH_DIR="${WORK_DIR}/squash"
    rm -rf "$SQUASH_DIR"
    log "Extraindo squashfs (demora ~2-3 min)..."
    sudo unsquashfs -d "$SQUASH_DIR" "$squash_img"

    # Detect Fedora LiveOS layout (squashfs > rootfs.img) vs direct rootfs
    local rootfs_img="${SQUASH_DIR}/LiveOS/rootfs.img"
    if [[ -f "$rootfs_img" ]]; then
        ROOTFS_TYPE="mounted"
        log "Layout Fedora LiveOS (rootfs.img ext4)"

        # Expand rootfs.img by 500MB to fit patches
        info "Expandindo rootfs.img em 500MB para caber os patches..."
        sudo truncate -s +500M "$rootfs_img"
        sudo e2fsck -fy "$rootfs_img" 2>/dev/null || true
        sudo resize2fs "$rootfs_img" 2>/dev/null || true

        ROOTFS="${WORK_DIR}/rootfs"
        mkdir -p "$ROOTFS"
        sudo mount -o loop "$rootfs_img" "$ROOTFS"
        CLEANUP_MOUNTS+=("$ROOTFS")
        log "rootfs.img montado em ${ROOTFS}"
    else
        ROOTFS_TYPE="direct"
        ROOTFS="$SQUASH_DIR"
        log "Layout squashfs direto"
    fi

    # Show available space
    if [[ "$ROOTFS_TYPE" == "mounted" ]]; then
        local avail
        avail=$(df -BM "$ROOTFS" | tail -1 | awk '{print $4}')
        log "Espaço disponível no rootfs: ${avail}"
    fi
}

# ─── Bundle do payload da Parte 2 ───────────────────────────────────────────────
# Copia setup-vivobook.sh + tudo que ele precisa para /opt/vivobook-fixes/ no rootfs.
# NENHUMA config de hardware é aplicada aqui — isso é trabalho da Parte 2, rodada
# no Vivobook já bootado (sudo /opt/vivobook-fixes/setup-vivobook.sh).
bundle_payload() {
    header "══════════════════════════════════════════
  BUNDLE DO PAYLOAD (Parte 2) NO SQUASHFS
══════════════════════════════════════════"

    local dest="${ROOTFS}/opt/vivobook-fixes"
    sudo mkdir -p "$dest"

    # Parte 2 + auxiliares (.c são compilados na Parte 2)
    local payload=(
        setup-vivobook.sh
        extract-qcom-firmware.sh
        install-battery-time-ext.sh
        vivobook-update.sh
        post-install-protect.sh
        vk_pool_fix.c
    )
    local copied=0 missing=()
    local f
    for f in "${payload[@]}"; do
        if [[ -f "${SCRIPT_DIR}/${f}" ]]; then
            sudo cp "${SCRIPT_DIR}/${f}" "$dest/"
            [[ "$f" == *.sh ]] && sudo chmod +x "$dest/${f}"
            ((copied++))
        else
            missing+=("$f")
        fi
    done
    log "  ${copied} scripts/arquivos em /opt/vivobook-fixes/"
    [[ ${#missing[@]} -gt 0 ]] && warn "  Ausentes no repo: ${missing[*]}"

    if [[ ! -f "${dest}/setup-vivobook.sh" ]]; then
        err "setup-vivobook.sh (Parte 2) não encontrado no repo — ISO ficaria sem os fixes!"
        exit 1
    fi

    # Módulos DKMS (cam/color/usb4 do repo; os 4 core entram se bundled em modules/)
    if [[ -d "${SCRIPT_DIR}/modules" ]]; then
        sudo cp -a "${SCRIPT_DIR}/modules" "$dest/"
        local nmod
        nmod=$(find "${SCRIPT_DIR}/modules" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
        log "  modules/ copiado (${nmod} módulos DKMS)"
    else
        warn "  modules/ não encontrado no repo"
    fi

    local CORE_DKMS_MISSING=()
    local core_module
    for core_module in wcn-regulator-fix vivobook-kbd-fix vivobook-bl-fix vivobook-hotkey-fix; do
        if [[ ! -d "${SCRIPT_DIR}/modules/${core_module}-1.0" ]]; then
            CORE_DKMS_MISSING+=("$core_module")
        fi
    done
    if [[ ${#CORE_DKMS_MISSING[@]} -gt 0 ]]; then
        warn "  FONTES DKMS ESSENCIAIS AUSENTES: ${CORE_DKMS_MISSING[*]}"
        printf '%s\n' "${CORE_DKMS_MISSING[@]}" | sudo tee "${dest}/CORE_DKMS_MISSING" >/dev/null
        warn "  A ISO será de recuperação/experimentos; esses recursos não serão declarados funcionais."
    fi

    # Firmware bundled (opcional). Se ausente, a Parte 2 extrai do Windows.
    if [[ -d "$FW_BUNDLE" ]]; then
        sudo cp -a "$FW_BUNDLE" "${dest}/firmware"
        log "  firmware/ bundled copiado para o payload"
    else
        info "  firmware/ não bundled — Parte 2 extrai do Windows (extract-qcom-firmware.sh)"
    fi

    # Instruções no payload
    sudo tee "${dest}/LEIA-ME.txt" >/dev/null << 'README'
ASUS Vivobook X1407QA — Fixes de hardware (Parte 2)

Rode ESTES passos no Vivobook DEPOIS de instalar o Fedora:

  1) (se o firmware não veio no ISO) extrair do Windows:
       - da partição Windows:  sudo /opt/vivobook-fixes/extract-qcom-firmware.sh
       - OU de um dump em pendrive (gerado no Windows pelo
         extract-firmware-windows.bat):
           sudo /opt/vivobook-fixes/extract-qcom-firmware.sh \
                /run/media/$USER/PENDRIVE/vivobook-qcom-firmware

  2) aplicar todos os fixes (DKMS, firmware initramfs, áudio,
     brilho, WiFi, bateria, terminal, suspend, etc.):
       sudo /opt/vivobook-fixes/setup-vivobook.sh

  3) reiniciar:
       sudo reboot

A Parte 1 (build do ISO) só preparou o boot e copiou estes arquivos.
README
    log "  LEIA-ME.txt criado"
    echo ""
    log "Payload da Parte 2 embutido no squashfs"
}

# ─── Modify GRUB ─────────────────────────────────────────────────────────────
modify_grub() {
    log "Modificando GRUB..."
    local snap_params="clk_ignore_unused pd_ignore_unused systemd.tpm2_wait=0 modprobe.blacklist=qcom_q6v5_pas"

    # grub.cfg files
    while IFS= read -r grub_cfg; do
        [[ -f "$grub_cfg" ]] || continue
        if ! grep -q "modprobe.blacklist=qcom_q6v5_pas" "$grub_cfg"; then
            sed -i '/^[[:space:]]*linux\(efi\)\?[[:space:]]/s/$/ '"$snap_params"'/' "$grub_cfg"
            log "  GRUB: ${grub_cfg#"$ISO_DIR"/}"
        fi
    done < <(find "$ISO_DIR" -name "grub.cfg" 2>/dev/null)

    # BLS entries
    while IFS= read -r entry; do
        [[ -f "$entry" ]] || continue
        if ! grep -q "modprobe.blacklist=qcom_q6v5_pas" "$entry"; then
            sed -i "/^options /s/$/ $snap_params/" "$entry"
            log "  BLS: $(basename "$entry")"
        fi
    done < <(find "$ISO_DIR" -path "*/loader/entries/*.conf" 2>/dev/null)
}

# ─── Rebuild squashfs ─────────────────────────────────────────────────────────
rebuild_squashfs() {
    local squash_dest="${ISO_DIR}/LiveOS/squashfs.img"

    if [[ "$ROOTFS_TYPE" == "mounted" ]]; then
        log "Desmontando rootfs.img..."
        if ! sudo umount "$ROOTFS"; then
            err "Falha ao desmontar rootfs! Verificando processos..."
            sudo fuser -vm "$ROOTFS" 2>&1 || true
            err "Abortando — rootfs ainda montado, squashfs ficaria corrompido."
            exit 1
        fi
        # Remove from cleanup
        local new_mounts=()
        for mnt in "${CLEANUP_MOUNTS[@]}"; do
            [[ "$mnt" != "$ROOTFS" ]] && new_mounts+=("$mnt")
        done
        CLEANUP_MOUNTS=("${new_mounts[@]}")

        # Shrink rootfs.img back (remove free space)
        local rootfs_img="${SQUASH_DIR}/LiveOS/rootfs.img"
        info "Compactando rootfs.img..."
        sudo e2fsck -fy "$rootfs_img" 2>/dev/null || true
        sudo resize2fs -M "$rootfs_img" 2>/dev/null || true
    fi

    log "Recriando squashfs (demora ~5 min)..."
    sudo rm -f "$squash_dest"
    if ! sudo mksquashfs "$SQUASH_DIR" "$squash_dest" \
        -comp xz -b 1M -Xdict-size 100% -no-recovery -processors "$(nproc)"; then
        err "mksquashfs falhou — ISO não será gerada"
        exit 1
    fi
    if [[ ! -f "$squash_dest" ]]; then
        err "squashfs.img não foi criado em ${squash_dest}"
        exit 1
    fi

    local new_size
    new_size=$(du -h "$squash_dest" | cut -f1)
    log "Squashfs: ${new_size}"
}

# ─── Rebuild ISO ──────────────────────────────────────────────────────────────
rebuild_iso() {
    log "Reconstruindo ISO..."
    xorriso \
        -indev "$ISO_INPUT" \
        -outdev "$ISO_OUTPUT" \
        -update "$ISO_DIR" / \
        -boot_image any replay \
        2>&1 | tail -5

    if [[ -f "$ISO_OUTPUT" ]]; then
        local size
        size=$(du -h "$ISO_OUTPUT" | cut -f1)
        log "ISO criada: $(basename "$ISO_OUTPUT") (${size})"
    else
        err "Falha ao criar ISO!"
        exit 1
    fi
}

# ─── Verify output ISO ───────────────────────────────────────────────────────
verify_output() {
    header "══════════════════════════════════════════
  VERIFICAÇÃO DA ISO GERADA
══════════════════════════════════════════"

    info "Estrutura:"
    xorriso -indev "$ISO_OUTPUT" -ls /LiveOS/ 2>&1 | \
        grep -v "^xorriso\|^Drive\|^Media\|^Boot\|^Volume\|^libisofs" || true

    log "Gerando SHA256..."
    local checksum
    checksum=$(sha256sum "$ISO_OUTPUT" | awk '{print $1}')
    echo "${checksum}  $(basename "$ISO_OUTPUT")" > "${ISO_OUTPUT}.sha256"
    log "SHA256: ${checksum:0:16}..."
    log "Checksum: $(basename "${ISO_OUTPUT}.sha256")"
}

# ─── Flash USB ────────────────────────────────────────────────────────────────
flash_usb() {
    local iso_path="$1"

    header "══════════════════════════════════════════
  GRAVAR ISO NO USB
══════════════════════════════════════════"

    log "Dispositivos USB:"
    echo "---"
    lsblk -d -o NAME,SIZE,MODEL,TRAN | grep -i usb || {
        warn "Nenhum USB encontrado."
        return
    }
    echo "---"

    local usb_dev
    read -rp "Dispositivo (ex: sda, Enter para cancelar): " usb_dev </dev/tty || return
    [[ -z "$usb_dev" ]] && return

    # Validate input: only alphanumeric device names
    if ! [[ "$usb_dev" =~ ^[a-z][a-z0-9]*$ ]]; then
        err "Nome de dispositivo inválido: ${usb_dev}"
        return 1
    fi

    usb_dev="/dev/${usb_dev}"
    if [[ ! -b "$usb_dev" ]]; then
        err "${usb_dev} não existe!"
        return 1
    fi

    # Safety: refuse to write to mounted devices
    if grep -q "^${usb_dev}" /proc/mounts 2>/dev/null; then
        err "${usb_dev} está montado! Desmonte antes de gravar."
        return 1
    fi

    # Safety: verify it's a USB device
    local dev_tran
    dev_tran=$(lsblk -ndo TRAN "$usb_dev" 2>/dev/null)
    if [[ "$dev_tran" != "usb" ]]; then
        warn "${usb_dev} não é USB (tipo: ${dev_tran:-desconhecido})"
        if ! prompt_yn "Tem certeza que quer gravar neste dispositivo?" "n"; then
            info "Cancelado."
            return
        fi
    fi

    warn "TODOS os dados em ${usb_dev} serão APAGADOS!"
    warn "ISO: $(basename "$iso_path") ($(du -h "$iso_path" | cut -f1))"
    if ! prompt_yn "Confirmar?" "n"; then
        info "Cancelado."
        return
    fi

    log "Gravando em ${usb_dev}..."
    sudo dd if="$iso_path" of="$usb_dev" bs=4M status=progress oflag=sync
    sync
    log "Gravação concluída!"
}

# ─── Show instructions ────────────────────────────────────────────────────────
show_instructions() {
    header "Instruções de Boot — Vivobook X1407QA"
    info "1. Grave o ISO no pendrive (opção 4)"
    info "2. BIOS (F2): Desabilite Secure Boot, habilite USB boot"
    info "3. Boot menu (F12): Selecione USB"
    info "4. Fedora boota (GRUB já tem os workarounds Snapdragon — Parte 1)"
    info "5. Instale no NVMe normalmente e reboote no sistema instalado"
    info "6. PARTE 2 — aplicar os fixes de hardware (no Vivobook):"
    info "     sudo /opt/vivobook-fixes/extract-qcom-firmware.sh  (se preciso)"
    info "     sudo /opt/vivobook-fixes/setup-vivobook.sh"
    info "     sudo reboot"
    echo ""
    info "Hardware funcional após a Parte 2:"
    info "  + WiFi (WCN6855, ath11k + wcn_regulator_fix)"
    info "  + Teclado (vivobook_kbd_fix)"
    info "  + Brilho (vivobook_bl_fix)"
    info "  + Hotkeys Fn (vivobook_hotkey_fix)"
    info "  + Bateria (ADSP firmware)"
    info "  + GPU (Adreno X1-45)"
    info "  + Audio (UCM2 regex fix)"
    info "  + Terminal (vk_pool_fix.so)"
    info "  + CPU scaling (scmi_cpufreq)"
    info "  + CDSP/FastRPC (firmware initramfs)"
    info "  + Câmera RGB (autostart gráfico; warnings conhecidos)"
    info "  - NPU QNN/HTP e câmera IR"
}

# ─── Build complete ISO ──────────────────────────────────────────────────────
build_complete() {
    header "══════════════════════════════════════════
  BUILD ISO COMPLETA — Vivobook X1407QA
══════════════════════════════════════════"

    discover_isos
    verify_iso "$ISO_INPUT" || exit 1
    check_space 12
    check_space 4 "$SCRIPT_DIR"  # espaço para a ISO de saída + .sha256

    local input_name
    input_name=$(basename "$ISO_INPUT" .iso)
    ISO_OUTPUT="${SCRIPT_DIR}/${input_name}-VivoBook-patched.iso"

    info "Saída: $(basename "$ISO_OUTPUT")"
    echo ""
    if ! prompt_yn "Iniciar build?"; then
        return
    fi

    WORK_DIR=$(mktemp -d /tmp/vivobook-iso-build.XXXXXX)
    CLEANUP_DIRS+=("$WORK_DIR")

    extract_iso
    extract_squashfs
    modify_grub
    bundle_payload
    rebuild_squashfs
    rebuild_iso
    verify_output

    header "══════════════════════════════════════════
  BUILD COMPLETA (Parte 1)
══════════════════════════════════════════"
    log "ISO: ${ISO_OUTPUT}"
    echo ""
    info "O ISO contém (mínimo para bootar + instalar):"
    info "  + Parâmetros de boot Snapdragon (GRUB live)"
    info "  + Payload em /opt/vivobook-fixes/:"
    info "      setup-vivobook.sh (Parte 2) + scripts auxiliares"
    info "      modules/ (DKMS) + firmware/ (se bundled) + .c"
    echo ""
    info "Workflow:"
    info "  1. Grave o ISO no USB (opção 4) e instale o Fedora no Vivobook"
    info "  2. Boote o sistema instalado"
    info "  3. (se preciso) sudo /opt/vivobook-fixes/extract-qcom-firmware.sh"
    info "  4. sudo /opt/vivobook-fixes/setup-vivobook.sh   ← Parte 2: todos os fixes"
    info "  5. sudo reboot"
    echo ""

    if prompt_yn "Gravar no USB agora?"; then
        flash_usb "$ISO_OUTPUT"
    fi
}

# ─── Main menu ────────────────────────────────────────────────────────────────
main() {
    echo ""
    echo -e "${BOLD}════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  ASUS Vivobook X1407QA — ISO Builder v${VERSION}${NC}"
    echo -e "${BOLD}  Snapdragon X / Fedora 44 aarch64${NC}"
    echo -e "${BOLD}════════════════════════════════════════════${NC}"
    echo ""
    echo "  1) Build ISO bootável (Parte 1 — boot + payload)"
    echo "  2) Baixar ISO Fedora ${FEDORA_VERSION} aarch64"
    echo "  3) Verificar ISO existente"
    echo "  4) Gravar ISO no USB"
    echo "  5) Extrair firmware do Windows"
    echo "  6) Instruções de boot"
    echo "  7) Sair"
    echo ""

    local choice
    read -rp "Opção [1-7]: " choice </dev/tty || choice="7"

    case "$choice" in
        1)
            check_deps
            build_complete
            ;;
        2)
            download_iso
            ;;
        3)
            discover_isos
            verify_iso "$ISO_INPUT"
            ;;
        4)
            discover_isos
            flash_usb "$ISO_INPUT"
            ;;
        5)
            if [[ -f "${SCRIPT_DIR}/extract-qcom-firmware.sh" ]]; then
                sudo bash "${SCRIPT_DIR}/extract-qcom-firmware.sh"
            else
                err "extract-qcom-firmware.sh não encontrado"
            fi
            ;;
        6)
            show_instructions
            ;;
        7)
            exit 0
            ;;
        *)
            err "Opção inválida"
            exit 1
            ;;
    esac
}

main "$@"
