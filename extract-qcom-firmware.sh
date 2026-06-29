#!/bin/bash
# =============================================================================
# extract-qcom-firmware.sh
# Extrai firmware Qualcomm do ASUS Vivobook 14 X1407Q. Executar no Fedora.
#
# Uso:
#   sudo ./extract-qcom-firmware.sh                  # monta a partição Windows
#   sudo ./extract-qcom-firmware.sh <dir-do-dump>    # usa dump de pendrive
#                                                    # (extract-firmware-windows.bat)
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; }
info() { echo -e "${CYAN}[i]${NC} $1"; }

FW_DEST="/lib/firmware/qcom"
WIN_MOUNT="/mnt/windows"
SOURCE_DIR="${1:-}"   # opcional: dump do pendrive (gerado por extract-firmware-windows.bat)
MOUNTED=0

cleanup_fw() {
    [[ "$MOUNTED" == "1" ]] && sudo umount "${WIN_MOUNT}" 2>/dev/null || true
}
trap cleanup_fw EXIT

echo "============================================"
echo " Extrator de Firmware Qualcomm"
echo " ASUS Vivobook 14 X1407Q (Snapdragon X)"
echo "============================================"
echo ""

# Instalar qcom-firmware-extract se disponível
if ! command -v qcom-firmware-extract &>/dev/null; then
    log "Tentando instalar qcom-firmware-extract..."
    if command -v dnf &>/dev/null; then
        sudo dnf install -y qcom-firmware-extract 2>/dev/null || true
    fi
    if ! command -v qcom-firmware-extract &>/dev/null; then
        if command -v pip &>/dev/null || command -v pip3 &>/dev/null; then
            pip3 install qcom-firmware-extract 2>/dev/null || true
        fi
    fi
fi

if [[ -n "${SOURCE_DIR}" ]]; then
    # Origem = dump do pendrive (extract-firmware-windows.bat). Sem montar nada.
    if [[ ! -d "${SOURCE_DIR}" ]]; then
        err "Diretório de origem não existe: ${SOURCE_DIR}"
        exit 1
    fi
    if [[ ! -d "${SOURCE_DIR}/Windows/System32" ]]; then
        warn "${SOURCE_DIR} não parece um dump válido (sem Windows/System32/)"
        info "Use a pasta 'vivobook-qcom-firmware' gerada pelo .bat."
    fi
    WIN_MOUNT="${SOURCE_DIR}"
    log "Usando dump do pendrive: ${SOURCE_DIR}"
else
    # Encontrar e montar partição Windows
    log "Procurando partição Windows..."
    win_part=""

    for part in $(lsblk -rno NAME,FSTYPE | grep -E 'ntfs' | awk '{print $1}'); do
        mnt_test="/tmp/win-test-$$"
        mkdir -p "${mnt_test}"
        if sudo mount -o ro "/dev/${part}" "${mnt_test}" 2>/dev/null; then
            if [[ -d "${mnt_test}/Windows/System32" ]]; then
                win_part="/dev/${part}"
                sudo umount "${mnt_test}"
                rmdir "${mnt_test}"
                break
            fi
            sudo umount "${mnt_test}"
        fi
        rmdir "${mnt_test}" 2>/dev/null || true
    done

    if [[ -z "${win_part}" ]]; then
        err "Partição Windows não encontrada!"
        info "Certifique-se que o Windows está instalado no NVMe."
        info "Ou gere o dump no Windows (extract-firmware-windows.bat) e rode:"
        info "  sudo $0 /caminho/do/pendrive/vivobook-qcom-firmware"
        exit 1
    fi

    log "Partição Windows: ${win_part}"
    sudo mkdir -p "${WIN_MOUNT}"
    sudo mount -o ro "${win_part}" "${WIN_MOUNT}"
    MOUNTED=1
fi

# Extrair firmware
log "Extraindo firmware..."
sudo mkdir -p "${FW_DEST}"

if command -v qcom-firmware-extract &>/dev/null; then
    log "Usando qcom-firmware-extract..."
    sudo qcom-firmware-extract --source "${WIN_MOUNT}" --destination /lib/firmware
else
    warn "qcom-firmware-extract não disponível. Extração manual..."
    driver_store="${WIN_MOUNT}/Windows/System32/DriverStore/FileRepository"

    if [[ ! -d "${driver_store}" ]]; then
        err "DriverStore não encontrado em ${driver_store}"
        exit 1
    fi

    # WiFi (ath12k / WCN7850)
    log "Extraindo firmware WiFi..."
    find "${driver_store}" -ipath "*qcwlan*" -name "*.bin" -exec sudo cp -v {} "${FW_DEST}/" \; 2>/dev/null || true
    find "${driver_store}" -ipath "*wlan*" -name "*.bin" -exec sudo cp -v {} "${FW_DEST}/" \; 2>/dev/null || true

    # Bluetooth
    log "Extraindo firmware Bluetooth..."
    find "${driver_store}" -ipath "*qcbt*" -name "*.bin" -exec sudo cp -v {} "${FW_DEST}/" \; 2>/dev/null || true
    find "${driver_store}" -ipath "*bluetooth*" -name "*.bin" -exec sudo cp -v {} "${FW_DEST}/" \; 2>/dev/null || true

    # GPU (Adreno X1-45)
    log "Extraindo firmware GPU..."
    find "${driver_store}" -ipath "*qcdx*" \( -name "*.mbn" -o -name "*.bin" \) -exec sudo cp -v {} "${FW_DEST}/" \; 2>/dev/null || true

    # Audio DSP
    log "Extraindo firmware Audio DSP..."
    find "${driver_store}" -ipath "*qcadsp*" \( -name "*.mbn" -o -name "*.bin" \) -exec sudo cp -v {} "${FW_DEST}/" \; 2>/dev/null || true

    # Compute DSP
    log "Extraindo firmware Compute DSP..."
    find "${driver_store}" -ipath "*qccdsp*" \( -name "*.mbn" -o -name "*.bin" \) -exec sudo cp -v {} "${FW_DEST}/" \; 2>/dev/null || true

    # Subsystem firmware
    log "Extraindo firmware de subsistemas..."
    find "${driver_store}" -ipath "*qcsubsys*" \( -name "*.mbn" -o -name "*.bin" \) -exec sudo cp -v {} "${FW_DEST}/" \; 2>/dev/null || true

    # Qualcomm genérico
    find "${driver_store}" -iname "qc_*.mbn" -exec sudo cp -v {} "${FW_DEST}/" \; 2>/dev/null || true
fi

fw_count=$(find "${FW_DEST}" -type f 2>/dev/null | wc -l)
log "Total: ${fw_count} arquivos de firmware em ${FW_DEST}"

echo ""
log "Firmware extraído com sucesso!"
info "Reinicie para aplicar: sudo reboot"
info "Após reiniciar, WiFi/Bluetooth/GPU devem funcionar melhor."
