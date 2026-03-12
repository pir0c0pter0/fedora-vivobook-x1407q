#!/bin/bash
# =============================================================================
# prepare-fedora-snapdragon.sh
# Prepara Fedora 44 Beta aarch64 ISO para ASUS Vivobook 14 X1407Q
# SoC: Qualcomm Snapdragon X (X1-26-100) - Plataforma "Purwa"
# =============================================================================

set -euo pipefail

WORK_DIR="$(cd "$(dirname "$0")" && pwd)"
ISO_ORIGINAL="${WORK_DIR}/Fedora-Workstation-Live-44_Beta-1.2.aarch64.iso"
ISO_MODIFIED="${WORK_DIR}/Fedora-44-VivoBook-X1407Q.iso"
MOUNT_ISO="/tmp/fedora-iso-mount"
EXTRACT_DIR="/tmp/fedora-iso-extract"
SQUASH_MOUNT="/tmp/fedora-squash-mount"
SQUASH_EXTRACT="/tmp/fedora-squash-extract"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()   { echo -e "${GREEN}[+]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
err()   { echo -e "${RED}[✗]${NC} $1"; }
info()  { echo -e "${CYAN}[i]${NC} $1"; }

cleanup() {
    log "Limpando diretórios temporários..."
    sudo umount "${MOUNT_ISO}" 2>/dev/null || true
    sudo umount "${SQUASH_MOUNT}" 2>/dev/null || true
    sudo rm -rf "${MOUNT_ISO}" "${SQUASH_MOUNT}"
}
trap cleanup EXIT

# =============================================================================
# Verificações
# =============================================================================

check_deps() {
    local missing=()
    for cmd in xorriso unsquashfs mksquashfs; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        warn "Dependências faltando: ${missing[*]}"
        log "Instalando dependências..."
        sudo dnf install -y xorriso squashfs-tools genisoimage
    fi
}

check_iso() {
    if [[ ! -f "${ISO_ORIGINAL}" ]]; then
        err "ISO não encontrada: ${ISO_ORIGINAL}"
        err "Baixe com: wget https://dl.fedoraproject.org/pub/fedora/linux/releases/test/44_Beta/Workstation/aarch64/iso/Fedora-Workstation-Live-44_Beta-1.2.aarch64.iso"
        exit 1
    fi
    log "ISO encontrada: $(basename "${ISO_ORIGINAL}")"
}

# =============================================================================
# Etapa 1: Extrair ISO
# =============================================================================

extract_iso() {
    log "Extraindo conteúdo da ISO..."
    rm -rf "${EXTRACT_DIR}"
    mkdir -p "${EXTRACT_DIR}"

    xorriso -osirrox on -indev "${ISO_ORIGINAL}" -extract / "${EXTRACT_DIR}" 2>/dev/null
    chmod -R u+w "${EXTRACT_DIR}"
    log "ISO extraída em ${EXTRACT_DIR}"
}

# =============================================================================
# Etapa 2: Verificar DTBs disponíveis para Snapdragon X
# =============================================================================

check_dtbs() {
    log "Verificando DTBs disponíveis para Snapdragon X..."

    # Procurar DTBs no squashfs da live image
    local squashfs_path
    squashfs_path=$(find "${EXTRACT_DIR}" -name "squashfs.img" -o -name "*.squashfs" 2>/dev/null | head -1)

    if [[ -z "${squashfs_path}" ]]; then
        # Fedora 44 pode usar formato diferente
        squashfs_path=$(find "${EXTRACT_DIR}" -name "rootfs.img" 2>/dev/null | head -1)
    fi

    if [[ -z "${squashfs_path}" ]]; then
        warn "Squashfs não encontrado. Verificando estrutura da ISO..."
        find "${EXTRACT_DIR}" -name "*.img" -o -name "*.squashfs" 2>/dev/null
        return
    fi

    log "Squashfs encontrado: ${squashfs_path}"
    mkdir -p "${SQUASH_MOUNT}"
    sudo mount -o loop,ro "${squashfs_path}" "${SQUASH_MOUNT}"

    info "DTBs Qualcomm Snapdragon X disponíveis:"
    echo "---"

    # x1e = Snapdragon X Elite, x1p = Snapdragon X Plus/X
    local found_dtbs=0
    for pattern in "x1e" "x1p"; do
        if ls "${SQUASH_MOUNT}"/usr/lib/modules/*/dtb/qcom/${pattern}* 2>/dev/null; then
            found_dtbs=1
        fi
        if ls "${SQUASH_MOUNT}"/boot/dtb/qcom/${pattern}* 2>/dev/null; then
            found_dtbs=1
        fi
    done

    if [[ ${found_dtbs} -eq 0 ]]; then
        warn "Nenhum DTB Snapdragon X encontrado no squashfs!"
        warn "Verificando todos os DTBs qcom..."
        find "${SQUASH_MOUNT}" -path "*/qcom/*.dtb" 2>/dev/null | head -20
    fi

    echo "---"
    sudo umount "${SQUASH_MOUNT}"
}

# =============================================================================
# Etapa 3: Modificar configuração de boot (GRUB/EFI)
# =============================================================================

modify_boot_config() {
    log "Modificando configuração de boot para Snapdragon X..."

    # Parâmetros de kernel essenciais para Snapdragon X
    local SNAP_PARAMS="clk_ignore_unused pd_ignore_unused"

    # Encontrar e modificar grub.cfg
    local grub_cfgs
    grub_cfgs=$(find "${EXTRACT_DIR}" -name "grub.cfg" 2>/dev/null)

    if [[ -z "${grub_cfgs}" ]]; then
        warn "grub.cfg não encontrado. Verificando estrutura EFI..."
        find "${EXTRACT_DIR}/EFI" -type f 2>/dev/null || true
        return
    fi

    for grub_cfg in ${grub_cfgs}; do
        log "Modificando: ${grub_cfg}"
        cp "${grub_cfg}" "${grub_cfg}.bak"

        # Adicionar parâmetros de kernel para Snapdragon X em todas as entradas linux
        # Adiciona clk_ignore_unused pd_ignore_unused ao final da linha linux/linuxefi
        sed -i 's/\(linux\(efi\)\?.*\)$/\1 '"${SNAP_PARAMS}"'/' "${grub_cfg}"

        # Verificar se o Fedora 44 Beta já tem seleção automática de DTB
        if grep -q "devicetree\|dtb" "${grub_cfg}" 2>/dev/null; then
            info "Configuração de DTB já presente no grub.cfg (Fedora 44 auto-DTB)"
        else
            info "Adicionando referência genérica de DTB..."
        fi

        log "grub.cfg modificado com parâmetros Snapdragon X"
    done

    # Modificar também as entradas do systemd-boot se existirem
    local boot_entries
    boot_entries=$(find "${EXTRACT_DIR}" -path "*/loader/entries/*.conf" 2>/dev/null)
    for entry in ${boot_entries}; do
        log "Modificando entrada boot: ${entry}"
        if ! grep -q "clk_ignore_unused" "${entry}"; then
            sed -i "s/^options .*/& ${SNAP_PARAMS}/" "${entry}"
        fi
    done
}

# =============================================================================
# Etapa 4: Adicionar script de pós-boot para firmware Qualcomm
# =============================================================================

add_firmware_helper() {
    log "Criando helper de firmware Qualcomm..."

    local helper_dir="${EXTRACT_DIR}/firmware-helper"
    mkdir -p "${helper_dir}"

    cat > "${helper_dir}/extract-qcom-firmware.sh" << 'FWEOF'
#!/bin/bash
# =============================================================================
# extract-qcom-firmware.sh
# Extrai firmware Qualcomm da partição Windows do ASUS Vivobook 14 X1407Q
# Executar APÓS o boot do Fedora (no live ou instalado)
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; }

FW_DEST="/lib/firmware/qcom"
WIN_MOUNT="/mnt/windows"

# Verificar se qcom-firmware-extract está disponível
install_extractor() {
    if ! command -v qcom-firmware-extract &>/dev/null; then
        log "Instalando qcom-firmware-extract..."
        if command -v dnf &>/dev/null; then
            sudo dnf install -y qcom-firmware-extract 2>/dev/null || {
                warn "Pacote não disponível no DNF. Tentando pip..."
                pip install qcom-firmware-extract 2>/dev/null || {
                    warn "Instalando do GitHub..."
                    git clone https://github.com/JustRadical/qcom-firmware-extract.git /tmp/qcom-fw-extract
                    cd /tmp/qcom-fw-extract && sudo python3 setup.py install
                }
            }
        fi
    fi
}

# Encontrar e montar partição Windows
find_windows() {
    log "Procurando partição Windows..."
    local win_part=""

    # Procurar partição NTFS/FAT com Windows
    for part in $(lsblk -rno NAME,FSTYPE | grep -E 'ntfs|vfat' | awk '{print $1}'); do
        local mnt_test="/tmp/win-test-$$"
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
        err "Firmware Qualcomm precisa ser extraído do Windows."
        err "Alternativa: copie C:\\Windows\\System32\\DriverStore de outra máquina."
        exit 1
    fi

    log "Partição Windows encontrada: ${win_part}"
    sudo mkdir -p "${WIN_MOUNT}"
    sudo mount -o ro "${win_part}" "${WIN_MOUNT}"
}

# Extrair firmware
extract_firmware() {
    log "Extraindo firmware Qualcomm..."
    sudo mkdir -p "${FW_DEST}"

    if command -v qcom-firmware-extract &>/dev/null; then
        sudo qcom-firmware-extract --source "${WIN_MOUNT}" --destination "${FW_DEST}"
    else
        # Fallback manual: copiar firmwares conhecidos
        local driver_store="${WIN_MOUNT}/Windows/System32/DriverStore/FileRepository"
        if [[ -d "${driver_store}" ]]; then
            log "Copiando firmware manualmente do DriverStore..."

            # Firmware WiFi (ath12k)
            find "${driver_store}" -path "*qcwlan*" -name "*.bin" -exec sudo cp {} "${FW_DEST}/" \; 2>/dev/null || true

            # Firmware Bluetooth
            find "${driver_store}" -path "*qcbt*" -name "*.bin" -exec sudo cp {} "${FW_DEST}/" \; 2>/dev/null || true

            # Firmware GPU (Adreno)
            find "${driver_store}" -path "*qcdx*" -name "*.mbn" -exec sudo cp {} "${FW_DEST}/" \; 2>/dev/null || true

            # Firmware DSP/NPU
            find "${driver_store}" -path "*qcadsp*" -name "*.mbn" -exec sudo cp {} "${FW_DEST}/" \; 2>/dev/null || true
            find "${driver_store}" -path "*qccdsp*" -name "*.mbn" -exec sudo cp {} "${FW_DEST}/" \; 2>/dev/null || true

            # Firmware genérico Qualcomm
            find "${driver_store}" -iname "qc*.mbn" -exec sudo cp {} "${FW_DEST}/" \; 2>/dev/null || true
            find "${driver_store}" -iname "qc*.bin" -exec sudo cp {} "${FW_DEST}/" \; 2>/dev/null || true
        fi
    fi

    local fw_count
    fw_count=$(find "${FW_DEST}" -type f 2>/dev/null | wc -l)
    log "Firmware extraído: ${fw_count} arquivos em ${FW_DEST}"
}

# Limpar
cleanup_fw() {
    sudo umount "${WIN_MOUNT}" 2>/dev/null || true
}
trap cleanup_fw EXIT

echo "============================================"
echo " Extrator de Firmware Qualcomm"
echo " ASUS Vivobook 14 X1407Q (Snapdragon X)"
echo "============================================"
echo ""

install_extractor
find_windows
extract_firmware

log "Firmware extraído com sucesso!"
log "Reinicie para aplicar: sudo reboot"

FWEOF

    chmod +x "${helper_dir}/extract-qcom-firmware.sh"
    log "Helper de firmware criado"
}

# =============================================================================
# Etapa 5: Reconstruir ISO
# =============================================================================

rebuild_iso() {
    log "Reconstruindo ISO modificada..."

    # Determinar o volume ID e boot catalog da ISO original
    local vol_id
    vol_id=$(xorriso -indev "${ISO_ORIGINAL}" -report_el_torito cmd 2>&1 | grep "Volume id" | head -1 || echo "Fedora-WS-Live-44")

    # Reconstruir ISO com suporte EFI boot
    local efi_img
    efi_img=$(find "${EXTRACT_DIR}" -name "efiboot.img" -o -name "efi.img" 2>/dev/null | head -1)

    if [[ -z "${efi_img}" ]]; then
        warn "EFI boot image não encontrada, procurando alternativas..."
        efi_img=$(find "${EXTRACT_DIR}" -name "*.img" -path "*/images/*" 2>/dev/null | head -1)
    fi

    local efi_rel_path="${efi_img#${EXTRACT_DIR}/}"

    xorriso -as mkisofs \
        -o "${ISO_MODIFIED}" \
        -R -J -joliet-long \
        -V "Fedora-44-VivoBook" \
        -e "${efi_rel_path}" \
        -no-emul-boot \
        -append_partition 2 0xef "${efi_img}" \
        -appended_part_as_gpt \
        "${EXTRACT_DIR}"

    local iso_size
    iso_size=$(du -h "${ISO_MODIFIED}" | cut -f1)
    log "ISO modificada criada: ${ISO_MODIFIED} (${iso_size})"
}

# =============================================================================
# Etapa 6: Gravar no USB
# =============================================================================

flash_usb() {
    echo ""
    info "========================================"
    info "  GRAVAR ISO NO USB"
    info "========================================"
    echo ""

    # Listar dispositivos USB
    log "Dispositivos USB disponíveis:"
    echo "---"
    lsblk -d -o NAME,SIZE,MODEL,TRAN | grep -i usb || {
        warn "Nenhum dispositivo USB encontrado."
        info "Conecte um pendrive e execute manualmente:"
        info "  sudo dd if=${ISO_MODIFIED} of=/dev/sdX bs=4M status=progress oflag=sync"
        return
    }
    echo "---"

    read -rp "Digite o dispositivo USB (ex: sda): " usb_dev
    usb_dev="/dev/${usb_dev}"

    if [[ ! -b "${usb_dev}" ]]; then
        err "Dispositivo ${usb_dev} não existe!"
        return 1
    fi

    warn "ATENÇÃO: Todos os dados em ${usb_dev} serão APAGADOS!"
    read -rp "Confirmar? (sim/não): " confirm
    if [[ "${confirm}" != "sim" ]]; then
        log "Operação cancelada."
        return
    fi

    log "Gravando ISO em ${usb_dev}..."
    sudo dd if="${ISO_MODIFIED}" of="${usb_dev}" bs=4M status=progress oflag=sync
    sync

    log "ISO gravada com sucesso em ${usb_dev}!"
}

# =============================================================================
# Menu principal
# =============================================================================

show_instructions() {
    echo ""
    info "========================================"
    info "  INSTRUÇÕES PARA BOOT"
    info "========================================"
    echo ""
    info "1. Grave a ISO no pendrive USB"
    info "2. No Vivobook X1407Q:"
    info "   - Desligue completamente"
    info "   - Segure F2 e ligue para entrar na BIOS/UEFI"
    info "   - Desabilite Secure Boot"
    info "   - Habilite boot USB"
    info "   - Salve e saia"
    info "3. Conecte o pendrive e ligue segurando F12 (ou ESC)"
    info "4. Selecione o USB no menu de boot"
    info "5. No GRUB, edite a entrada (tecla 'e') e confirme que tem:"
    info "   clk_ignore_unused pd_ignore_unused"
    info "6. Após o boot, execute o extrator de firmware:"
    info "   /run/initramfs/live/firmware-helper/extract-qcom-firmware.sh"
    info "   OU copie de: ${WORK_DIR}/extract-qcom-firmware.sh"
    echo ""
    info "Hardware esperado funcional com kernel 6.19:"
    info "  ✓ Teclado, touchpad, display (via DTB automático)"
    info "  ✓ USB-C, USB-A, HDMI"
    info "  ✓ WiFi 6E (pode precisar firmware)"
    info "  ✓ NVMe SSD"
    info "  ~ Bluetooth (pode precisar kernel COPR)"
    info "  ✗ Áudio, câmera (suporte parcial/ausente)"
    echo ""
    warn "NOTA: O Snapdragon X X1-26-100 é relativamente novo."
    warn "Se o boot automático falhar, pode ser necessário"
    warn "especificar um DTB manualmente no GRUB:"
    warn "  devicetree /dtb/qcom/x1p42100-asus-vivobook-s15.dtb"
    warn "(o mais próximo disponível no kernel)"
    echo ""
}

# =============================================================================
# Main
# =============================================================================

echo "============================================"
echo " Fedora 44 → ASUS Vivobook 14 X1407Q"
echo " Qualcomm Snapdragon X (X1-26-100)"
echo "============================================"
echo ""

check_deps
check_iso

echo ""
echo "O que deseja fazer?"
echo "  1) Extrair, modificar e reconstruir ISO"
echo "  2) Apenas gravar ISO original no USB (Fedora 44 já tem auto-DTB)"
echo "  3) Mostrar instruções de boot"
echo "  4) Extrair firmware Qualcomm (executar no laptop alvo)"
echo ""
read -rp "Opção [1-4]: " choice

case "${choice}" in
    1)
        extract_iso
        check_dtbs
        modify_boot_config
        add_firmware_helper
        rebuild_iso
        show_instructions
        echo ""
        read -rp "Deseja gravar no USB agora? (s/n): " do_flash
        if [[ "${do_flash}" == "s" ]]; then
            flash_usb
        fi
        ;;
    2)
        ISO_MODIFIED="${ISO_ORIGINAL}"
        flash_usb
        show_instructions
        ;;
    3)
        show_instructions
        ;;
    4)
        # Executar extração de firmware diretamente
        source "${WORK_DIR}/extract-qcom-firmware.sh" 2>/dev/null || {
            add_firmware_helper
            bash "${EXTRACT_DIR:-/tmp/fedora-iso-extract}/firmware-helper/extract-qcom-firmware.sh"
        }
        ;;
    *)
        err "Opção inválida"
        exit 1
        ;;
esac

log "Concluído!"
