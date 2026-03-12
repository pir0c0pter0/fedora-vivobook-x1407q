#!/bin/bash
# =============================================================================
# post-install-protect.sh
# Protege o ASUS Vivobook 14 X1407Q contra atualizacoes de kernel que
# quebram o boot ao perder o DTB customizado e os parametros do GRUB.
#
# O QUE FAZ:
#   1. Salva o DTB wifi-fix em /boot/dtb-custom/ (nao e tocado por updates)
#   2. Instala hook kernel-install que roda automaticamente em cada update:
#      - Copia DTB wifi-fix para o diretorio do novo kernel
#      - Adiciona "devicetree" na entrada BLS padrao
#      - Cria entrada BLS extra "WiFi Fix" para o novo kernel
#   3. Garante que /etc/default/grub tem clk_ignore_unused pd_ignore_unused
#   4. Adiciona devicetree em TODAS as entradas BLS existentes
#
# USO:
#   sudo ./post-install-protect.sh
#
# REQUISITOS:
#   - Executar no sistema instalado (NVMe), NAO no live USB
#   - Executar como root
#   - DTB wifi-fix disponivel (do repo ou do /boot/)
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[x]${NC} $1"; }
info() { echo -e "${CYAN}[i]${NC} $1"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MACHINE_ID=$(cat /etc/machine-id)

# DTB customizado - procurar em varias localizacoes
WIFI_FIX_DTB=""
for candidate in \
    "${SCRIPT_DIR}/x1p42100-asus-zenbook-a14-wifi-fix.dtb" \
    "/boot/dtb-custom/qcom/x1p42100-asus-zenbook-a14-wifi-fix.dtb" \
    "/boot/dtb/qcom/x1p42100-asus-zenbook-a14-wifi-fix.dtb" \
    ; do
    if [[ -f "${candidate}" ]]; then
        WIFI_FIX_DTB="${candidate}"
        break
    fi
done

# =============================================================================
# Verificacoes
# =============================================================================

if [[ $EUID -ne 0 ]]; then
    err "Execute como root: sudo $0"
    exit 1
fi

if [[ -z "${WIFI_FIX_DTB}" ]]; then
    err "DTB wifi-fix nao encontrado!"
    err "Coloque x1p42100-asus-zenbook-a14-wifi-fix.dtb no mesmo diretorio deste script"
    exit 1
fi

log "DTB wifi-fix encontrado: ${WIFI_FIX_DTB}"

# =============================================================================
# Etapa 1: Salvar DTB customizado em local seguro
# =============================================================================

save_custom_dtb() {
    log "Salvando DTB customizado em /boot/dtb-custom/..."
    mkdir -p /boot/dtb-custom/qcom/
    cp "${WIFI_FIX_DTB}" /boot/dtb-custom/qcom/x1p42100-asus-zenbook-a14-wifi-fix.dtb
    log "DTB salvo em /boot/dtb-custom/qcom/"
}

# =============================================================================
# Etapa 2: Instalar hook kernel-install
# =============================================================================

install_kernel_hook() {
    log "Instalando hook kernel-install..."

    mkdir -p /etc/kernel/install.d/

    cat > /etc/kernel/install.d/99-snapdragon-dtb.install << 'HOOKEOF'
#!/bin/bash
# =============================================================================
# 99-snapdragon-dtb.install
# Hook kernel-install para ASUS Vivobook 14 X1407Q (Snapdragon X)
#
# Roda automaticamente quando um kernel novo e instalado/removido.
# Copia os DTBs customizados e cria entrada BLS com WiFi fix.
# =============================================================================

COMMAND="$1"
KERNEL_VERSION="$2"
BOOT_DIR_ABS="$3"
KERNEL_IMAGE="$4"

CUSTOM_DTB_DIR="/boot/dtb-custom/qcom"
WIFI_FIX_DTB="x1p42100-asus-zenbook-a14-wifi-fix.dtb"
STANDARD_DTB="x1p42100-asus-zenbook-a14.dtb"
MACHINE_ID=$(cat /etc/machine-id)

case "${COMMAND}" in
    add)
        DTB_DEST="/boot/dtb-${KERNEL_VERSION}/qcom"

        # 1. Copiar DTB customizado (wifi-fix) para o diretorio do novo kernel
        if [[ -f "${CUSTOM_DTB_DIR}/${WIFI_FIX_DTB}" ]] && [[ -d "${DTB_DEST}" ]]; then
            cp "${CUSTOM_DTB_DIR}/${WIFI_FIX_DTB}" "${DTB_DEST}/${WIFI_FIX_DTB}"
            echo "snapdragon-dtb: DTB wifi-fix copiado para ${DTB_DEST}/"
        fi

        # 2. Adicionar devicetree na entrada BLS padrao (se nao tiver)
        BLS_ENTRY="/boot/loader/entries/${MACHINE_ID}-${KERNEL_VERSION}.conf"
        if [[ -f "${BLS_ENTRY}" ]]; then
            if ! grep -q "^devicetree" "${BLS_ENTRY}"; then
                sed -i '/^grub_users/i devicetree /dtb/qcom/'"${STANDARD_DTB}" "${BLS_ENTRY}"
                echo "snapdragon-dtb: devicetree adicionado em ${BLS_ENTRY}"
            fi
        fi

        # 3. Criar entrada BLS com WiFi fix para o novo kernel
        BLS_WIFI="${BLS_ENTRY%.conf}-wifi-fix.conf"
        if [[ -f "${BLS_ENTRY}" ]] && [[ ! -f "${BLS_WIFI}" ]]; then
            cp "${BLS_ENTRY}" "${BLS_WIFI}"
            sed -i "s/^title .*/& - WiFi Fix/" "${BLS_WIFI}"
            sed -i "s/^version .*/&-wifi-fix/" "${BLS_WIFI}"
            sed -i "s|^devicetree .*|devicetree /dtb/qcom/${WIFI_FIX_DTB}|" "${BLS_WIFI}"
            echo "snapdragon-dtb: entrada WiFi Fix criada: ${BLS_WIFI}"
        fi

        echo "snapdragon-dtb: kernel ${KERNEL_VERSION} configurado para Vivobook X1407Q"
        ;;
    remove)
        BLS_WIFI="/boot/loader/entries/${MACHINE_ID}-${KERNEL_VERSION}-wifi-fix.conf"
        if [[ -f "${BLS_WIFI}" ]]; then
            rm -f "${BLS_WIFI}"
            echo "snapdragon-dtb: entrada WiFi Fix removida: ${BLS_WIFI}"
        fi
        ;;
esac

exit 0
HOOKEOF

    chmod +x /etc/kernel/install.d/99-snapdragon-dtb.install
    log "Hook instalado: /etc/kernel/install.d/99-snapdragon-dtb.install"
}

# =============================================================================
# Etapa 3: Garantir parametros de kernel no GRUB
# =============================================================================

fix_grub_defaults() {
    log "Verificando /etc/default/grub..."

    local grub_file="/etc/default/grub"
    local needs_update=false

    if ! grep -q "clk_ignore_unused" "${grub_file}"; then
        needs_update=true
    fi
    if ! grep -q "pd_ignore_unused" "${grub_file}"; then
        needs_update=true
    fi

    if [[ "${needs_update}" == "true" ]]; then
        # Adicionar parametros ao GRUB_CMDLINE_LINUX_DEFAULT
        if grep -q "^GRUB_CMDLINE_LINUX_DEFAULT=" "${grub_file}"; then
            sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 clk_ignore_unused pd_ignore_unused"/' "${grub_file}"
        else
            echo 'GRUB_CMDLINE_LINUX_DEFAULT="quiet rhgb clk_ignore_unused pd_ignore_unused"' >> "${grub_file}"
        fi
        log "Parametros clk_ignore_unused pd_ignore_unused adicionados ao GRUB"
    else
        info "Parametros de kernel ja presentes no GRUB"
    fi

    # Garantir timeout para poder escolher no menu
    if grep -q "^GRUB_TIMEOUT=0" "${grub_file}"; then
        sed -i 's/^GRUB_TIMEOUT=0/GRUB_TIMEOUT=10/' "${grub_file}"
        log "GRUB_TIMEOUT alterado de 0 para 10"
    fi
}

# =============================================================================
# Etapa 4: Corrigir TODAS as entradas BLS existentes
# =============================================================================

fix_existing_bls() {
    log "Corrigindo entradas BLS existentes..."

    local fixed=0

    for bls_entry in /boot/loader/entries/${MACHINE_ID}-*.conf; do
        [[ -f "${bls_entry}" ]] || continue

        local basename
        basename=$(basename "${bls_entry}")

        # Pular entradas de rescue
        if [[ "${basename}" == *"rescue"* ]]; then
            continue
        fi

        # Pular entradas wifi-fix (ja tem devicetree correto)
        if [[ "${basename}" == *"wifi-fix"* ]]; then
            continue
        fi

        # Adicionar devicetree se nao tem
        if ! grep -q "^devicetree" "${bls_entry}"; then
            sed -i '/^grub_users/i devicetree /dtb/qcom/x1p42100-asus-zenbook-a14.dtb' "${bls_entry}"
            log "  devicetree adicionado: ${basename}"
            fixed=$((fixed + 1))
        fi

        # Extrair versao do kernel desta entrada
        local kver
        kver=$(grep "^version " "${bls_entry}" | awk '{print $2}')

        # Verificar se DTB wifi-fix existe no diretorio deste kernel
        local dtb_dir="/boot/dtb-${kver}/qcom"
        if [[ -d "${dtb_dir}" ]] && [[ ! -f "${dtb_dir}/x1p42100-asus-zenbook-a14-wifi-fix.dtb" ]]; then
            cp /boot/dtb-custom/qcom/x1p42100-asus-zenbook-a14-wifi-fix.dtb \
               "${dtb_dir}/x1p42100-asus-zenbook-a14-wifi-fix.dtb"
            log "  DTB wifi-fix copiado para dtb-${kver}/"
        fi

        # Criar entrada wifi-fix se nao existe
        local wifi_entry="${bls_entry%.conf}-wifi-fix.conf"
        if [[ ! -f "${wifi_entry}" ]]; then
            cp "${bls_entry}" "${wifi_entry}"
            sed -i "s/^title .*/& - WiFi Fix/" "${wifi_entry}"
            sed -i "s/^version .*/&-wifi-fix/" "${wifi_entry}"
            sed -i "s|^devicetree .*|devicetree /dtb/qcom/x1p42100-asus-zenbook-a14-wifi-fix.dtb|" "${wifi_entry}"
            log "  entrada WiFi Fix criada: $(basename "${wifi_entry}")"
            fixed=$((fixed + 1))
        fi
    done

    log "Entradas BLS corrigidas: ${fixed} modificacoes"
}

# =============================================================================
# Etapa 5: Regenerar GRUB
# =============================================================================

regenerate_grub() {
    log "Regenerando grub.cfg..."

    if [[ -f /boot/efi/EFI/fedora/grub.cfg ]]; then
        grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null
        log "grub.cfg regenerado"
    else
        warn "grub.cfg nao encontrado no caminho esperado, pulando regeneracao"
        info "Execute manualmente: grub2-mkconfig -o /boot/grub2/grub.cfg"
    fi
}

# =============================================================================
# Verificacao final
# =============================================================================

verify() {
    echo ""
    log "=== VERIFICACAO FINAL ==="
    echo ""

    info "DTB customizado salvo:"
    ls -la /boot/dtb-custom/qcom/ 2>/dev/null || warn "  Nao encontrado!"

    echo ""
    info "Hook kernel-install:"
    ls -la /etc/kernel/install.d/99-snapdragon-dtb.install 2>/dev/null || warn "  Nao encontrado!"

    echo ""
    info "/etc/default/grub:"
    grep "GRUB_CMDLINE_LINUX" /etc/default/grub

    echo ""
    info "Entradas BLS com devicetree:"
    for entry in /boot/loader/entries/${MACHINE_ID}-*.conf; do
        [[ -f "${entry}" ]] || continue
        local has_dt="N"
        grep -q "^devicetree" "${entry}" && has_dt="S"
        printf "  [%s] %s\n" "${has_dt}" "$(basename "${entry}")"
    done

    echo ""
    info "Kernels disponiveis:"
    ls /boot/vmlinuz-* 2>/dev/null | sed 's|/boot/vmlinuz-|  |'

    echo ""
    log "=== PROTECAO ATIVA ==="
    info "Proximas atualizacoes de kernel serao automaticamente configuradas"
    info "para o Vivobook X1407Q com DTB Zenbook A14 + WiFi fix."
    echo ""
}

# =============================================================================
# Main
# =============================================================================

echo "============================================"
echo " Post-Install Protect"
echo " ASUS Vivobook 14 X1407Q (Snapdragon X)"
echo "============================================"
echo ""
info "Este script protege contra atualizacoes de kernel"
info "que quebram o boot ao perder o DTB customizado."
echo ""

save_custom_dtb
install_kernel_hook
fix_grub_defaults
fix_existing_bls
regenerate_grub
verify

log "Concluido! O sistema esta protegido contra futuras atualizacoes."
