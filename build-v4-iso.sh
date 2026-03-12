#!/bin/bash
# =============================================================================
# build-v4-iso.sh
# Gera Fedora-44-VivoBook-v4.iso com DTB fixado para WiFi
#
# Fix: adiciona regulator-always-on nos reguladores WCN para evitar que
# o Linux desligue a energia do chip WiFi (WCN6855) durante o boot.
# =============================================================================

set -euo pipefail

WORK_DIR="$(cd "$(dirname "$0")" && pwd)"
ISO_INPUT="${WORK_DIR}/Fedora-44-VivoBook-v3.iso"
ISO_OUTPUT="${WORK_DIR}/Fedora-44-VivoBook-v4.iso"
DTB_FIXED="${WORK_DIR}/x1p42100-asus-zenbook-a14-wifi-fix.dtb"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[x]${NC} $1"; }
info() { echo -e "${CYAN}[i]${NC} $1"; }

EXTRACT_DIR="/tmp/v4-iso-extract"

cleanup() {
    log "Limpando temporarios..."
    rm -rf "${EXTRACT_DIR}"
}
trap cleanup EXIT

# =============================================================================
# Verificacoes
# =============================================================================

if [[ ! -f "${ISO_INPUT}" ]]; then
    err "ISO v3 nao encontrada: ${ISO_INPUT}"
    exit 1
fi

if [[ ! -f "${DTB_FIXED}" ]]; then
    err "DTB fixado nao encontrado: ${DTB_FIXED}"
    exit 1
fi

if ! command -v xorriso &>/dev/null; then
    err "xorriso nao encontrado. Instale com: sudo pacman -S xorriso"
    exit 1
fi

# =============================================================================
# Etapa 1: Extrair ISO
# =============================================================================

log "Extraindo ISO v3..."
rm -rf "${EXTRACT_DIR}"
mkdir -p "${EXTRACT_DIR}"
xorriso -osirrox on -indev "${ISO_INPUT}" -extract / "${EXTRACT_DIR}" 2>/dev/null
chmod -R u+w "${EXTRACT_DIR}"

# =============================================================================
# Etapa 2: Substituir DTB
# =============================================================================

DTB_PATH="${EXTRACT_DIR}/boot/aarch64/loader/dtb/qcom/x1p42100-asus-zenbook-a14.dtb"

if [[ ! -f "${DTB_PATH}" ]]; then
    err "DTB original nao encontrado na ISO: ${DTB_PATH}"
    exit 1
fi

info "DTB original: $(wc -c < "${DTB_PATH}") bytes"
cp "${DTB_FIXED}" "${DTB_PATH}"
info "DTB fixado:   $(wc -c < "${DTB_PATH}") bytes"
log "DTB substituido com regulator-always-on para WiFi"

# =============================================================================
# Etapa 3: Reconstruir ISO
# =============================================================================

log "Reconstruindo ISO v4..."
xorriso \
    -indev "${ISO_INPUT}" \
    -outdev "${ISO_OUTPUT}" \
    -update "${EXTRACT_DIR}" / \
    -boot_image any replay \
    2>&1 | tail -5

if [[ -f "${ISO_OUTPUT}" ]]; then
    local_size=$(du -h "${ISO_OUTPUT}" | cut -f1)
    log "ISO v4 criada: ${ISO_OUTPUT} (${local_size})"
else
    err "Falha ao criar ISO!"
    exit 1
fi

# =============================================================================
# Etapa 4: Verificar
# =============================================================================

log "Verificando DTB na ISO v4..."
xorriso -osirrox on -indev "${ISO_OUTPUT}" \
    -extract /boot/aarch64/loader/dtb/qcom/x1p42100-asus-zenbook-a14.dtb /tmp/v4-verify.dtb 2>/dev/null

verify_size=$(wc -c < /tmp/v4-verify.dtb)
fixed_size=$(wc -c < "${DTB_FIXED}")

if [[ "${verify_size}" -eq "${fixed_size}" ]]; then
    log "DTB verificado: ${verify_size} bytes (OK)"
else
    err "DTB na ISO (${verify_size}) difere do fixado (${fixed_size})!"
    exit 1
fi

rm -f /tmp/v4-verify.dtb

echo ""
log "=== RESUMO v4 ==="
info "ISO: ${ISO_OUTPUT}"
info "Fix: regulator-always-on em VREG_WCN_3P3, VREG_WCN_0P95, VREG_WCN_1P9"
info "Esperado: WiFi (WCN6855/ath11k_pci) deve receber energia e carregar"
echo ""
info "Para gravar no USB:"
info "  sudo dd if=${ISO_OUTPUT} of=/dev/sdX bs=4M status=progress oflag=sync"
echo ""
log "Concluido!"
