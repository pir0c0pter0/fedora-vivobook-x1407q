#!/bin/bash
# =============================================================================
# build-v3-iso.sh
# Gera Fedora-44-VivoBook-v3.iso com firmware no path correto:
#   /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/
#
# Corrige o problema da v2 onde firmware ficou na raiz do /qcom/
# =============================================================================

set -euo pipefail

WORK_DIR="$(cd "$(dirname "$0")" && pwd)"
ISO_INPUT="${WORK_DIR}/Fedora-44-VivoBook-v2.iso"
ISO_OUTPUT="${WORK_DIR}/Fedora-44-VivoBook-v3.iso"

EXTRACT_DIR="/tmp/v3-iso-extract"
SQUASH_DIR="/tmp/v3-squash"
SQUASH_NEW="/tmp/v3-squash-new"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[x]${NC} $1"; }
info() { echo -e "${CYAN}[i]${NC} $1"; }

# --- Path correto baseado no DTB x1p42100-asus-zenbook-a14 ---
FW_DEVICE_PATH="qcom/x1p42100/ASUSTeK/zenbook-a14"

# Firmware que o kernel/remoteproc procura neste path (confirmado via patches upstream)
CRITICAL_FW=(
    # GPU (Adreno X1-45, variante Purwa)
    "qcdxkmsucpurwa.mbn"
    # ADSP (Audio DSP)
    "qcadsp8380.mbn"
    "adsp_dtbs.elf"
    # CDSP (Compute DSP)
    "qccdsp8380.mbn"
    "cdsp_dtbs.elf"
    # Remoteproc JSON configs
    "adspr.jsn"
    "adsps.jsn"
    "adspua.jsn"
    "battmgr.jsn"
    "cdspr.jsn"
    "wpssr.jsn"
)

# GPU extras (do qcom-firmware-updater)
GPU_FW=(
    "qcdxkmsuc8380.mbn"
    "qcdxkmbase8380.bin"
    "qcdxkmbase8380_68.bin"
    "qcdxkmbase8380_110.bin"
    "qcdxkmbase8380_150.bin"
    "qcdxkmbase8380_pa.bin"
    "qcdxkmbase8380_pa_67.bin"
    "qcdxkmbase8380_pa_111.bin"
    "qcdxkmbase8380_pa_140.bin"
    "qcdxkmext8380_CRD.bin"
    "qcav1e8380.mbn"
    "qcvss8380.mbn"
    "qcvss8380_pa.mbn"
)

cleanup() {
    log "Limpando temporarios..."
    sudo umount /tmp/v3-iso-mount 2>/dev/null || true
    sudo umount /tmp/v3-squash-mount 2>/dev/null || true
    sudo rm -rf /tmp/v3-iso-mount /tmp/v3-squash-mount
}
trap cleanup EXIT

# =============================================================================
# Verificacoes
# =============================================================================

check_deps() {
    local missing=()
    for cmd in xorriso unsquashfs mksquashfs; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        err "Dependencias faltando: ${missing[*]}"
        info "Instale com: sudo pacman -S xorriso squashfs-tools"
        exit 1
    fi
}

check_space() {
    local avail_mb
    avail_mb=$(df -BM /tmp | tail -1 | awk '{print $4}' | tr -d 'M')
    if [[ ${avail_mb} -lt 8000 ]]; then
        err "Precisa de pelo menos 8GB livres em /tmp (tem ${avail_mb}MB)"
        exit 1
    fi
    log "Espaco em /tmp: ${avail_mb}MB (OK)"
}

# =============================================================================
# Etapa 1: Extrair ISO
# =============================================================================

extract_iso() {
    log "Extraindo ISO v2..."
    rm -rf "${EXTRACT_DIR}"
    mkdir -p "${EXTRACT_DIR}"
    xorriso -osirrox on -indev "${ISO_INPUT}" -extract / "${EXTRACT_DIR}" 2>/dev/null
    chmod -R u+w "${EXTRACT_DIR}"
    log "ISO extraida em ${EXTRACT_DIR}"
}

# =============================================================================
# Etapa 2: Extrair squashfs
# =============================================================================

extract_squashfs() {
    local squashfs_path="${EXTRACT_DIR}/LiveOS/squashfs.img"
    if [[ ! -f "${squashfs_path}" ]]; then
        err "squashfs.img nao encontrado em ${squashfs_path}"
        exit 1
    fi

    log "Extraindo squashfs (isso demora ~2min)..."
    rm -rf "${SQUASH_DIR}"
    sudo unsquashfs -d "${SQUASH_DIR}" "${squashfs_path}"
    log "Squashfs extraido em ${SQUASH_DIR}"
}

# =============================================================================
# Etapa 3: Organizar firmware no path correto
# =============================================================================

organize_firmware() {
    local fw_root="${SQUASH_DIR}/usr/lib/firmware"
    local fw_qcom="${fw_root}/qcom"
    local fw_dest="${fw_root}/${FW_DEVICE_PATH}"

    log "Criando diretorio: ${FW_DEVICE_PATH}"
    sudo mkdir -p "${fw_dest}"

    # --- Copiar firmware critico para o path do device ---
    local copied=0
    local missing=0

    info "Copiando firmware critico (remoteproc + GPU)..."
    for fw_file in "${CRITICAL_FW[@]}" "${GPU_FW[@]}"; do
        local src="${fw_qcom}/${fw_file}"
        if [[ -f "${src}" ]]; then
            sudo cp "${src}" "${fw_dest}/${fw_file}"
            copied=$((copied + 1))
        else
            warn "  Nao encontrado: ${fw_file}"
            missing=$((missing + 1))
        fi
    done

    log "Copiados: ${copied} arquivos | Nao encontrados: ${missing}"

    # --- Verificar arquivos criticos ---
    info "Verificando firmware critico no path correto..."
    local all_ok=true
    for fw_file in "${CRITICAL_FW[@]}"; do
        if [[ -f "${fw_dest}/${fw_file}" ]]; then
            echo -e "  ${GREEN}OK${NC}  ${FW_DEVICE_PATH}/${fw_file}"
        else
            echo -e "  ${RED}FALTA${NC} ${FW_DEVICE_PATH}/${fw_file}"
            all_ok=false
        fi
    done

    if [[ "${all_ok}" == "false" ]]; then
        warn "Alguns firmwares criticos estao faltando!"
        warn "O boot pode funcionar parcialmente."
    fi

    # --- Manter os originais na raiz tambem (fallback) ---
    info "Arquivos originais em qcom/ raiz mantidos como fallback."

    # --- Verificar firmware WiFi (ath12k) ---
    local ath12k_dir="${fw_root}/ath12k/WCN7850/hw2.0"
    if [[ -d "${ath12k_dir}" ]]; then
        local wifi_files
        wifi_files=$(ls "${ath12k_dir}"/bdwlan_wcn785x* 2>/dev/null | wc -l)
        log "WiFi firmware (ath12k/WCN7850): ${wifi_files} bdwlan files (OK)"

        if ls "${ath12k_dir}"/amss.bin &>/dev/null && \
           ls "${ath12k_dir}"/board-2.bin &>/dev/null && \
           ls "${ath12k_dir}"/m3.bin &>/dev/null; then
            log "WiFi core firmware (amss.bin, board-2.bin, m3.bin): OK"
        else
            warn "WiFi core firmware incompleto!"
        fi
    else
        warn "Diretorio ath12k/WCN7850/hw2.0 nao encontrado!"
    fi

    # --- Listar conteudo final ---
    echo ""
    info "Conteudo final de ${FW_DEVICE_PATH}/:"
    ls -la "${fw_dest}/" | tail -n +2
    echo ""
    info "Total: $(ls "${fw_dest}" | wc -l) arquivos"
}

# =============================================================================
# Etapa 4: Recriar squashfs
# =============================================================================

rebuild_squashfs() {
    local squashfs_dest="${EXTRACT_DIR}/LiveOS/squashfs.img"

    log "Recriando squashfs (isso demora ~5min)..."
    sudo rm -f "${squashfs_dest}"
    sudo mksquashfs "${SQUASH_DIR}" "${squashfs_dest}" \
        -comp xz \
        -b 1M \
        -Xdict-size 100% \
        -no-recovery \
        -processors "$(nproc)"

    local new_size
    new_size=$(du -h "${squashfs_dest}" | cut -f1)
    log "Novo squashfs: ${new_size}"
}

# =============================================================================
# Etapa 5: Reconstruir ISO
# =============================================================================

rebuild_iso() {
    log "Reconstruindo ISO v3..."

    # Extrair EFI partition da ISO v2 (30MB, offset em sectors de 2048 bytes)
    local efi_img="/tmp/v3-efi-part.img"
    local efi_start=1326088  # sector start (2048-byte sectors)
    local efi_size=61440     # size in 512-byte blocks = 30MB

    dd if="${ISO_INPUT}" bs=2048 skip="${efi_start}" count=$((efi_size / 4)) of="${efi_img}" 2>/dev/null
    log "EFI partition extraida ($(du -h "${efi_img}" | cut -f1))"

    # Extrair system area (MBR + GPT) da ISO v2
    local sysarea="/tmp/v3-sysarea.bin"
    dd if="${ISO_INPUT}" bs=2048 count=16 of="${sysarea}" 2>/dev/null

    # Reconstruir ISO usando xorriso nativo com replay dos boot records
    xorriso \
        -indev "${ISO_INPUT}" \
        -outdev "${ISO_OUTPUT}" \
        -update "${EXTRACT_DIR}" / \
        -boot_image any replay \
        2>&1 | tail -10

    if [[ -f "${ISO_OUTPUT}" ]]; then
        local iso_size
        iso_size=$(du -h "${ISO_OUTPUT}" | cut -f1)
        log "ISO v3 criada: ${ISO_OUTPUT} (${iso_size})"
    else
        err "Falha ao criar ISO!"
        exit 1
    fi

    rm -f "${efi_img}" "${sysarea}"
}

# =============================================================================
# Etapa 6: Verificar ISO
# =============================================================================

verify_iso() {
    log "Verificando ISO v3..."

    info "Estrutura de boot:"
    xorriso -indev "${ISO_OUTPUT}" -ls /boot/grub2/ 2>&1 | grep -v "^xorriso\|^Drive\|^Media\|^Boot\|^Volume\|^libisofs"

    info "LiveOS:"
    xorriso -indev "${ISO_OUTPUT}" -ls /LiveOS/ 2>&1 | grep -v "^xorriso\|^Drive\|^Media\|^Boot\|^Volume\|^libisofs"

    info "Volume ID:"
    xorriso -indev "${ISO_OUTPUT}" -report_el_torito cmd 2>&1 | grep "Volume id" || true

    echo ""
    log "=== RESUMO ==="
    info "ISO gerada: ${ISO_OUTPUT}"
    info "Firmware movido para: /usr/lib/firmware/${FW_DEVICE_PATH}/"
    info "DTB de boot: x1p42100-asus-zenbook-a14.dtb"
    info "GRUB: mantido da v2 (Zenbook A14 DTB como default)"
    echo ""
    info "Para gravar no USB:"
    info "  sudo dd if=${ISO_OUTPUT} of=/dev/sdX bs=4M status=progress oflag=sync"
}

# =============================================================================
# Main
# =============================================================================

echo "============================================"
echo " Fedora 44 - Vivobook X1407Q - ISO v3"
echo " Fix: firmware no path correto"
echo "   ${FW_DEVICE_PATH}/"
echo "============================================"
echo ""

if [[ ! -f "${ISO_INPUT}" ]]; then
    err "ISO v2 nao encontrada: ${ISO_INPUT}"
    exit 1
fi

check_deps
check_space

echo ""
info "Etapas:"
info "  1. Extrair ISO v2"
info "  2. Extrair squashfs"
info "  3. Mover firmware para ${FW_DEVICE_PATH}/"
info "  4. Recriar squashfs"
info "  5. Reconstruir ISO v3"
info "  6. Verificar"
echo ""
read -rp "Continuar? (s/n): " confirm
if [[ "${confirm}" != "s" ]]; then
    log "Cancelado."
    exit 0
fi

echo ""
extract_iso
extract_squashfs
organize_firmware
rebuild_squashfs
rebuild_iso
verify_iso

echo ""
log "Concluido!"
