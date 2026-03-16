#!/bin/bash
# =============================================================================
# build-vivobook-iso.sh — Unified interactive ISO builder
# ASUS Vivobook X1407QA (Snapdragon X) — Fedora 44 aarch64
#
# Substitui: prepare-fedora-snapdragon.sh, build-v3-iso.sh, build-v4-iso.sh
#
# Features:
#   - Menu interativo
#   - Verificação SHA256 da ISO source
#   - Injeta TODOS os patches no squashfs (firmware, DKMS, configs, etc.)
#   - Serviço first-boot para DKMS build + initramfs
#   - Verificação da ISO de saída
#   - Flash USB opcional
# =============================================================================

set -uo pipefail

VERSION="1.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="/tmp/vivobook-iso-build"

# Fedora download settings (override via env: FEDORA_VERSION=44 ./build-vivobook-iso.sh)
FEDORA_VERSION="${FEDORA_VERSION:-44}"
FEDORA_ARCH="aarch64"
FEDORA_EDITION="Workstation"
FEDORA_MIRROR="https://dl.fedoraproject.org/pub/fedora/linux"

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
DIM='\033[2m'
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
check_deps() {
    local missing=()
    for cmd in xorriso unsquashfs mksquashfs sha256sum curl; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        warn "Dependências faltando: ${missing[*]}"
        if prompt_yn "Instalar automaticamente?"; then
            sudo dnf install -y xorriso squashfs-tools coreutils curl
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
    local avail_mb
    avail_mb=$(df -BM /tmp | tail -1 | awk '{print $4}' | tr -d 'M')
    local required_mb=$((required_gb * 1024))
    if [[ $avail_mb -lt $required_mb ]]; then
        err "Precisa de pelo menos ${required_gb}GB livres em /tmp (tem $((avail_mb / 1024))GB)"
        exit 1
    fi
    log "Espaço em /tmp: $((avail_mb / 1024))GB (precisa ${required_gb}GB)"
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
        "${SCRIPT_DIR}/Fedora-Workstation-44-1.1-aarch64-CHECKSUM"; do
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

    [[ "$has_live" == true ]] && log "LiveOS presente" || warn "LiveOS não encontrado"
    [[ "$has_efi" == true ]] && log "EFI boot presente" || warn "EFI boot não encontrado"
    [[ "$has_grub" == true ]] && log "GRUB config presente" || warn "GRUB config não encontrado"

    return 0
}

# ─── Extract ISO ──────────────────────────────────────────────────────────────
extract_iso() {
    ISO_DIR="${WORK_DIR}/iso"
    rm -rf "$ISO_DIR"
    mkdir -p "$ISO_DIR"

    log "Extraindo ISO..."
    xorriso -osirrox on -indev "$ISO_INPUT" -extract / "$ISO_DIR" 2>/dev/null
    chmod -R u+w "$ISO_DIR"
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

# ─── Inject all patches ──────────────────────────────────────────────────────
inject_patches() {
    local total=12
    local n=0

    header "══════════════════════════════════════════
  INJETANDO PATCHES NO SQUASHFS
══════════════════════════════════════════"

    # --- 1. Firmware Qualcomm ---
    ((n++)); step $n $total "Firmware Qualcomm..."
    local fw_device="${ROOTFS}/usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14"
    sudo mkdir -p "$fw_device"

    local fw_source="/usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14"
    if [[ -d "$fw_source" ]]; then
        sudo cp -a "$fw_source"/* "$fw_device/" 2>/dev/null || true
        local fw_count
        fw_count=$(ls "$fw_device" 2>/dev/null | wc -l)
        log "  Firmware copiado do sistema: ${fw_count} arquivos"
    else
        warn "  Firmware não encontrado em ${fw_source}"
        warn "  Extrair do Windows após boot: /opt/vivobook-fixes/extract-qcom-firmware.sh"
    fi

    # WiFi board.bin (ath11k WCN6855)
    local wifi_src="/lib/firmware/ath11k/WCN6855/hw2.1"
    local wifi_dst="${ROOTFS}/lib/firmware/ath11k/WCN6855/hw2.1"
    if [[ -d "$wifi_src" ]]; then
        sudo mkdir -p "$wifi_dst"
        sudo cp -a "$wifi_src"/* "$wifi_dst/" 2>/dev/null || true
        log "  WiFi firmware (ath11k/WCN6855) copiado"
    fi

    # GPU firmware
    for fw in gen71500_sqe.fw gen71500_sqe.fw.xz gen71500_gmu.bin gen71500_gmu.bin.xz; do
        [[ -f "/usr/lib/firmware/qcom/$fw" ]] && \
            sudo cp "/usr/lib/firmware/qcom/$fw" "${ROOTFS}/usr/lib/firmware/qcom/" 2>/dev/null || true
    done
    if [[ -f "/usr/lib/firmware/qcom/x1p42100/gen71500_zap.mbn" ]]; then
        sudo mkdir -p "${ROOTFS}/usr/lib/firmware/qcom/x1p42100"
        sudo cp "/usr/lib/firmware/qcom/x1p42100/gen71500_zap.mbn" "${ROOTFS}/usr/lib/firmware/qcom/x1p42100/"
    fi

    # --- 2. DKMS module sources ---
    ((n++)); step $n $total "Módulos DKMS (sources)..."
    local dkms_copied=0
    for mod in wcn-regulator-fix vivobook-kbd-fix vivobook-bl-fix vivobook-hotkey-fix; do
        local mod_src="/usr/src/${mod}-1.0"
        if [[ -d "$mod_src" ]]; then
            sudo cp -a "$mod_src" "${ROOTFS}/usr/src/"
            ((dkms_copied++))
            log "  ${mod}-1.0 copiado"
        fi
    done
    if [[ $dkms_copied -eq 0 ]]; then
        warn "  Nenhum módulo DKMS encontrado em /usr/src/"
        warn "  Copie os módulos para /usr/src/ antes de rodar, ou instale manualmente pós-boot"
    else
        log "  ${dkms_copied}/4 módulos DKMS copiados"
    fi

    # --- 3. dracut configs ---
    ((n++)); step $n $total "Configs dracut..."
    sudo mkdir -p "${ROOTFS}/etc/dracut.conf.d"

    sudo tee "${ROOTFS}/etc/dracut.conf.d/wcn-regulator-fix.conf" >/dev/null <<< \
        'force_drivers+=" wcn_regulator_fix "'
    sudo tee "${ROOTFS}/etc/dracut.conf.d/vivobook-kbd-fix.conf" >/dev/null <<< \
        'force_drivers+=" vivobook_kbd_fix "'
    sudo tee "${ROOTFS}/etc/dracut.conf.d/qcom-adsp-firmware.conf" >/dev/null << 'EOF'
install_items+=" /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/qcadsp8380.mbn /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/adsp_dtbs.elf /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/adspr.jsn /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/adsps.jsn /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/adspua.jsn /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/battmgr.jsn "
EOF
    sudo tee "${ROOTFS}/etc/dracut.conf.d/qcom-gpu-firmware.conf" >/dev/null << 'EOF'
install_items+=" /usr/lib/firmware/qcom/gen71500_sqe.fw.xz /usr/lib/firmware/qcom/gen71500_gmu.bin.xz /usr/lib/firmware/qcom/x1p42100/gen71500_zap.mbn /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/qcdxkmsucpurwa.mbn "
EOF
    sudo tee "${ROOTFS}/etc/dracut.conf.d/qcom-cdsp-firmware.conf" >/dev/null << 'EOF'
install_items+=" /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/qccdsp8380.mbn /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/cdsp_dtbs.elf /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/cdspr.jsn "
EOF
    sudo tee "${ROOTFS}/etc/dracut.conf.d/no-tpm.conf" >/dev/null <<< \
        'omit_dracutmodules+=" tpm2-tss systemd-pcrphase "'
    sudo tee "${ROOTFS}/etc/dracut.conf.d/no-nfs.conf" >/dev/null <<< \
        'omit_dracutmodules+=" nfs "'
    log "  7 configs dracut criados"

    # --- 4. modules-load.d ---
    ((n++)); step $n $total "Autoload de módulos..."
    sudo mkdir -p "${ROOTFS}/etc/modules-load.d"
    echo "wcn_regulator_fix"   | sudo tee "${ROOTFS}/etc/modules-load.d/wcn-regulator-fix.conf" >/dev/null
    echo "vivobook_kbd_fix"    | sudo tee "${ROOTFS}/etc/modules-load.d/vivobook-kbd-fix.conf" >/dev/null
    echo "vivobook_bl_fix"     | sudo tee "${ROOTFS}/etc/modules-load.d/vivobook-bl-fix.conf" >/dev/null
    echo "vivobook_hotkey_fix" | sudo tee "${ROOTFS}/etc/modules-load.d/vivobook-hotkey-fix.conf" >/dev/null
    echo "scmi_cpufreq"        | sudo tee "${ROOTFS}/etc/modules-load.d/scmi-cpufreq.conf" >/dev/null
    log "  5 configs modules-load.d"

    # --- 5. Logind / Suspend ---
    ((n++)); step $n $total "Lid close / suspend..."
    sudo mkdir -p "${ROOTFS}/etc/systemd/logind.conf.d"
    sudo tee "${ROOTFS}/etc/systemd/logind.conf.d/no-suspend.conf" >/dev/null << 'EOF'
[Login]
HandleLidSwitch=lock
HandleLidSwitchExternalPower=lock
HandleLidSwitchDocked=lock
IdleAction=ignore
EOF
    sudo mkdir -p "${ROOTFS}/etc/systemd/system"
    for target in suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target sleep.target; do
        sudo ln -sf /dev/null "${ROOTFS}/etc/systemd/system/${target}"
    done
    sudo ln -sf /dev/null "${ROOTFS}/etc/systemd/system/dev-tpm0.device"
    sudo ln -sf /dev/null "${ROOTFS}/etc/systemd/system/dev-tpmrm0.device"
    log "  Suspend desabilitado, TPM masked"

    # --- 6. Udev rules ---
    ((n++)); step $n $total "Udev rules (charge limit 80%)..."
    sudo mkdir -p "${ROOTFS}/etc/udev/rules.d"
    echo 'SUBSYSTEM=="power_supply", KERNEL=="qcom-battmgr-bat", ATTR{charge_control_end_threshold}="80"' \
        | sudo tee "${ROOTFS}/etc/udev/rules.d/99-battery-charge-limit.rules" >/dev/null
    log "  Charge limit 80%"

    # --- 7. Vulkan pool fix ---
    ((n++)); step $n $total "Vulkan pool fix (vk_pool_fix.so)..."
    sudo mkdir -p "${ROOTFS}/usr/local/lib64" "${ROOTFS}/usr/local/bin"

    local vk_installed=false
    if [[ -f "${SCRIPT_DIR}/vk_pool_fix.c" ]] && command -v gcc &>/dev/null; then
        if gcc -shared -fPIC -o /tmp/vk_pool_fix.so "${SCRIPT_DIR}/vk_pool_fix.c" -ldl 2>/dev/null; then
            sudo cp /tmp/vk_pool_fix.so "${ROOTFS}/usr/local/lib64/"
            rm -f /tmp/vk_pool_fix.so
            vk_installed=true
            log "  Compilado e instalado"
        fi
    fi
    if [[ "$vk_installed" == false && -f "${SCRIPT_DIR}/vk_pool_fix.so" ]]; then
        sudo cp "${SCRIPT_DIR}/vk_pool_fix.so" "${ROOTFS}/usr/local/lib64/"
        vk_installed=true
        log "  Pre-built copiado"
    fi
    if [[ "$vk_installed" == false ]]; then
        warn "  vk_pool_fix.so não disponível — compilar pós-boot"
    fi

    # Ptyxis wrapper
    sudo tee "${ROOTFS}/usr/local/bin/ptyxis-fixed" >/dev/null << 'WRAPPER'
#!/bin/sh
export LD_PRELOAD=/usr/local/lib64/vk_pool_fix.so
exec /usr/bin/ptyxis "$@"
WRAPPER
    sudo chmod +x "${ROOTFS}/usr/local/bin/ptyxis-fixed"

    # --- 8. Setup scripts ---
    ((n++)); step $n $total "Scripts de setup..."
    sudo mkdir -p "${ROOTFS}/opt/vivobook-fixes"
    for script in setup-all.sh vivobook-update.sh extract-qcom-firmware.sh \
                  install-battery-time-ext.sh post-install-protect.sh; do
        if [[ -f "${SCRIPT_DIR}/${script}" ]]; then
            sudo cp "${SCRIPT_DIR}/${script}" "${ROOTFS}/opt/vivobook-fixes/"
            sudo chmod +x "${ROOTFS}/opt/vivobook-fixes/${script}"
        fi
    done
    [[ -f "${SCRIPT_DIR}/vk_pool_fix.c" ]] && \
        sudo cp "${SCRIPT_DIR}/vk_pool_fix.c" "${ROOTFS}/opt/vivobook-fixes/"

    # vivobook-update in PATH
    if [[ -f "${SCRIPT_DIR}/vivobook-update.sh" ]]; then
        sudo cp "${SCRIPT_DIR}/vivobook-update.sh" "${ROOTFS}/usr/local/bin/vivobook-update"
        sudo chmod +x "${ROOTFS}/usr/local/bin/vivobook-update"
    fi
    log "  Scripts em /opt/vivobook-fixes/"

    # --- 9. First-boot service ---
    ((n++)); step $n $total "Serviço first-boot..."
    sudo tee "${ROOTFS}/opt/vivobook-fixes/first-boot.sh" >/dev/null << 'FIRSTBOOT'
#!/bin/bash
# Vivobook X1407QA — First boot auto-setup
# Compila DKMS, configura GRUB, rebuilda initramfs
set -uo pipefail
exec &>/var/log/vivobook-first-boot.log

echo "=== Vivobook First Boot Setup — $(date) ==="
echo "Kernel: $(uname -r)"

# DKMS build
for mod_dir in /usr/src/wcn-regulator-fix-1.0 /usr/src/vivobook-kbd-fix-1.0 \
               /usr/src/vivobook-bl-fix-1.0 /usr/src/vivobook-hotkey-fix-1.0; do
    [[ -d "$mod_dir" ]] || continue
    mod_name=$(basename "$mod_dir" | sed 's/-1.0$//')
    echo "DKMS build: $mod_name"
    dkms add "$mod_dir" 2>/dev/null || true
    dkms build "${mod_name}/1.0" || true
    dkms install "${mod_name}/1.0" || true
done

# GRUB params
grubby --update-kernel=ALL --args="clk_ignore_unused pd_ignore_unused rd.driver.pre=wcn_regulator_fix rd.systemd.mask=dev-tpm0.device rd.systemd.mask=dev-tpmrm0.device" 2>/dev/null || true

# /etc/default/grub
if [[ -f /etc/default/grub ]] && ! grep -q "clk_ignore_unused" /etc/default/grub; then
    sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet rhgb clk_ignore_unused pd_ignore_unused rd.systemd.mask=dev-tpm0.device rd.systemd.mask=dev-tpmrm0.device"/' /etc/default/grub
fi

# Rebuild initramfs
dracut --force 2>/dev/null || true

# GRUB config
grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null || \
    grub2-mkconfig -o /boot/efi/EFI/fedora/grub.cfg 2>/dev/null || true

# Disable auto-updates
systemctl disable --now dnf-makecache.timer 2>/dev/null || true
systemctl mask packagekit.service 2>/dev/null || true

# Disable self
systemctl disable vivobook-first-boot.service 2>/dev/null || true

echo "=== First Boot Setup Complete — $(date) ==="
echo "Reboot recomendado para ativar módulos DKMS."
FIRSTBOOT
    sudo chmod +x "${ROOTFS}/opt/vivobook-fixes/first-boot.sh"

    sudo tee "${ROOTFS}/etc/systemd/system/vivobook-first-boot.service" >/dev/null << 'UNIT'
[Unit]
Description=ASUS Vivobook X1407QA First Boot Setup
After=multi-user.target
ConditionPathExists=/opt/vivobook-fixes/first-boot.sh

[Service]
Type=oneshot
ExecStart=/opt/vivobook-fixes/first-boot.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
    sudo mkdir -p "${ROOTFS}/etc/systemd/system/multi-user.target.wants"
    sudo ln -sf /etc/systemd/system/vivobook-first-boot.service \
        "${ROOTFS}/etc/systemd/system/multi-user.target.wants/vivobook-first-boot.service"
    log "  Serviço first-boot configurado"

    # --- 10. GNOME extension (battery-time) ---
    ((n++)); step $n $total "Extensão GNOME battery-time..."
    local ext_dir="${ROOTFS}/usr/share/gnome-shell/extensions/battery-time@wifiteste"
    sudo mkdir -p "$ext_dir"

    sudo tee "${ext_dir}/metadata.json" >/dev/null << 'META'
{
  "uuid": "battery-time@wifiteste",
  "name": "Battery Time Remaining",
  "description": "Shows battery time remaining in the panel with improved estimation (rolling average)",
  "shell-version": ["50", "50.rc", "51"],
  "version": 1
}
META

    # Copy extension.js from install script if available
    if [[ -f "${SCRIPT_DIR}/install-battery-time-ext.sh" ]]; then
        # Extract the extension.js content between the EXTJS markers
        sed -n "/^cat > \"\$EXT_DIR\/extension.js\" << 'EXTJS'/,/^EXTJS$/p" \
            "${SCRIPT_DIR}/install-battery-time-ext.sh" \
            | sed '1d;$d' \
            | sudo tee "${ext_dir}/extension.js" >/dev/null
        if [[ -s "${ext_dir}/extension.js" ]]; then
            log "  Extensão instalada system-wide"
        else
            # Fallback: copy from installed location
            local user_ext="$HOME/.local/share/gnome-shell/extensions/battery-time@wifiteste/extension.js"
            if [[ -f "$user_ext" ]]; then
                sudo cp "$user_ext" "${ext_dir}/extension.js"
                log "  Extensão copiada da instalação local"
            else
                warn "  extension.js não extraído — usar install-battery-time-ext.sh pós-boot"
            fi
        fi
    fi

    # --- 11. UCM2 Audio ---
    ((n++)); step $n $total "Áudio UCM2..."
    local ucm_conf="${ROOTFS}/usr/share/alsa/ucm2/conf.d/x1e80100/x1e80100.conf"
    if [[ -f "$ucm_conf" ]]; then
        if ! sudo grep -qi "vivobook" "$ucm_conf"; then
            # Add Vivobook to ASUS regex — handle various patterns
            if sudo grep -q "Zenbook A14" "$ucm_conf"; then
                sudo sed -i 's/Zenbook A14/Zenbook A14|Vivobook 14/' "$ucm_conf"
                log "  Vivobook 14 adicionado ao regex UCM2"
            elif sudo grep -q "ASUS" "$ucm_conf"; then
                warn "  Regex UCM2 não reconhecido — patch manual necessário após boot"
            fi
        else
            log "  Vivobook já presente no UCM2"
        fi
    else
        info "  UCM2 x1e80100.conf não presente na ISO (será configurado pós-install)"
    fi

    # --- 12. Touchpad + dconf defaults ---
    ((n++)); step $n $total "Touchpad e defaults..."
    sudo mkdir -p "${ROOTFS}/etc/dconf/db/local.d" "${ROOTFS}/etc/dconf/profile"
    sudo tee "${ROOTFS}/etc/dconf/db/local.d/01-vivobook" >/dev/null << 'EOF'
[org/gnome/desktop/peripherals/touchpad]
click-method='areas'

[org/gnome/software]
download-updates=false
download-updates-notify=false
EOF
    # dconf profile to read local db
    sudo tee "${ROOTFS}/etc/dconf/profile/user" >/dev/null << 'EOF'
user-db:user
system-db:local
EOF
    log "  dconf defaults configurados"

    echo ""
    log "Todos os 12 patches injetados"
}

# ─── Modify GRUB ─────────────────────────────────────────────────────────────
modify_grub() {
    log "Modificando GRUB..."
    local snap_params="clk_ignore_unused pd_ignore_unused"

    # grub.cfg files
    while IFS= read -r grub_cfg; do
        [[ -f "$grub_cfg" ]] || continue
        if ! grep -q "clk_ignore_unused" "$grub_cfg"; then
            sed -i '/^[[:space:]]*linux\(efi\)\?[[:space:]]/s/$/ '"$snap_params"'/' "$grub_cfg"
            log "  GRUB: $(echo "$grub_cfg" | sed "s|${ISO_DIR}/||")"
        fi
    done < <(find "$ISO_DIR" -name "grub.cfg" 2>/dev/null)

    # BLS entries
    while IFS= read -r entry; do
        [[ -f "$entry" ]] || continue
        if ! grep -q "clk_ignore_unused" "$entry"; then
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
        sudo umount "$ROOTFS"
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
    sudo mksquashfs "$SQUASH_DIR" "$squash_dest" \
        -comp xz -b 1M -Xdict-size 100% -no-recovery -processors "$(nproc)"

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

    usb_dev="/dev/${usb_dev}"
    if [[ ! -b "$usb_dev" ]]; then
        err "${usb_dev} não existe!"
        return 1
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
    info "1. Grave a ISO no pendrive (opção 3)"
    info "2. BIOS (F2): Desabilite Secure Boot, habilite USB boot"
    info "3. Boot menu (F12): Selecione USB"
    info "4. Fedora boot com patches (GRUB já tem clk_ignore_unused)"
    info "5. Instale no NVMe normalmente"
    info "6. Primeiro boot roda setup automático (DKMS + initramfs)"
    info "7. Reboot para ativar módulos"
    info "8. Opcional: /opt/vivobook-fixes/install-battery-time-ext.sh"
    echo ""
    info "Hardware funcional:"
    info "  + WiFi (WCN6855, ath11k + wcn_regulator_fix)"
    info "  + Teclado (vivobook_kbd_fix)"
    info "  + Brilho (vivobook_bl_fix)"
    info "  + Hotkeys Fn (vivobook_hotkey_fix)"
    info "  + Bateria (ADSP firmware)"
    info "  + GPU (Adreno X1-45)"
    info "  + Audio (UCM2 regex fix)"
    info "  + Terminal (vk_pool_fix.so)"
    info "  + CPU scaling (scmi_cpufreq)"
    info "  + CDSP/NPU (firmware initramfs)"
    info "  - Camera (patches upstream ~6.21/6.22)"
}

# ─── Build complete ISO ──────────────────────────────────────────────────────
build_complete() {
    header "══════════════════════════════════════════
  BUILD ISO COMPLETA — Vivobook X1407QA
══════════════════════════════════════════"

    discover_isos
    verify_iso "$ISO_INPUT" || exit 1
    check_space 12

    local input_name
    input_name=$(basename "$ISO_INPUT" .iso)
    ISO_OUTPUT="${SCRIPT_DIR}/${input_name}-VivoBook-patched.iso"

    info "Saída: $(basename "$ISO_OUTPUT")"
    echo ""
    if ! prompt_yn "Iniciar build?"; then
        return
    fi

    mkdir -p "$WORK_DIR"
    CLEANUP_DIRS+=("$WORK_DIR")

    extract_iso
    extract_squashfs
    inject_patches
    modify_grub
    rebuild_squashfs
    rebuild_iso
    verify_output

    header "══════════════════════════════════════════
  BUILD COMPLETA
══════════════════════════════════════════"
    log "ISO: ${ISO_OUTPUT}"
    echo ""
    info "Patches incluídos na ISO:"
    info "  + Firmware (ADSP, GPU, CDSP, WiFi)"
    info "  + DKMS sources (/usr/src/)"
    info "  + dracut configs (firmware initramfs)"
    info "  + modules-load.d (autoload)"
    info "  + Suspend disabled (lid = lock)"
    info "  + TPM masked (boot time)"
    info "  + vk_pool_fix.so (Vulkan)"
    info "  + Charge limit 80%"
    info "  + GRUB boot params"
    info "  + UCM2 audio regex"
    info "  + GNOME battery-time extension"
    info "  + First-boot service (DKMS build + initramfs)"
    info "  + vivobook-update em /usr/local/bin/"
    echo ""
    info "Após instalar e rebootar:"
    info "  1. First boot faz DKMS + initramfs automaticamente"
    info "  2. Segundo reboot ativa tudo"
    info "  3. Rodar: /opt/vivobook-fixes/install-battery-time-ext.sh"
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
    echo "  1) Build ISO completa (todos os patches)"
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
