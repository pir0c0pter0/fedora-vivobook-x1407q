#!/bin/bash
# =============================================================================
# setup-vivobook.sh — Apply all 16 ASUS Vivobook X1407QA fixes on installed Fedora
#
# Substitui: setup-all.sh (que não tinha lid/suspend, UCM2, dconf system-wide)
#
# Pré-requisitos:
#   - Fedora 44 aarch64 instalado no NVMe
#   - Firmware extraído em /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/
#   - WiFi board.bin em /usr/lib/firmware/ath11k/WCN6855/hw2.1/
#   - Módulos DKMS em /usr/src/ (wcn-regulator-fix, vivobook-kbd-fix, etc.)
#
# Usage: sudo bash setup-vivobook.sh
# =============================================================================

set -uo pipefail

VERSION="2.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~${REAL_USER}")

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
step()   { echo -e "${GREEN}[${1}/${2}]${NC} ${3}"; }

# ─── Root check ──────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    err "Execute como root: sudo bash setup-vivobook.sh"
    exit 1
fi

# ─── Dependencies ────────────────────────────────────────────────────────────
check_deps() {
    local missing=()
    for cmd in dkms dracut grubby grub2-mkconfig modprobe; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        warn "Dependências faltando: ${missing[*]}"
        info "Instalando..."
        dnf install -y dkms dracut grub2-tools kmod 2>/dev/null || true
    fi
    if ! command -v gcc &>/dev/null; then
        warn "gcc não encontrado — instalando para compilar DKMS e vk_pool_fix.so"
        dnf install -y gcc kernel-devel 2>/dev/null || true
    fi
}

# ─── Prompt ───────────────────────────────────────────────────────────────────
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

# ─── DKMS helper ─────────────────────────────────────────────────────────────
install_dkms_module() {
    local mod_name="$1"  # e.g. wcn-regulator-fix
    local mod_src="/usr/src/${mod_name}-1.0"

    if [[ ! -d "$mod_src" ]]; then
        warn "  ${mod_src} não encontrado — pulando"
        return 1
    fi

    if dkms status 2>/dev/null | grep -q "${mod_name}.*installed"; then
        log "  ${mod_name} já instalado"
        return 0
    fi

    dkms add "$mod_src" 2>/dev/null || true
    if dkms build "${mod_name}/1.0" && dkms install "${mod_name}/1.0"; then
        log "  ${mod_name} compilado e instalado"
        return 0
    else
        err "  ${mod_name} FALHOU — verificar kernel-devel e gcc"
        return 1
    fi
}

# =============================================================================
#  MAIN
# =============================================================================

echo ""
echo -e "${BOLD}════════════════════════════════════════════${NC}"
echo -e "${BOLD}  ASUS Vivobook X1407QA — Setup v${VERSION}${NC}"
echo -e "${BOLD}  Todas as 16 melhorias — Fedora 44 aarch64${NC}"
echo -e "${BOLD}════════════════════════════════════════════${NC}"
echo ""

check_deps

# ─── Pre-flight: firmware check ──────────────────────────────────────────────
FW_DIR="/usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14"
if [[ ! -f "${FW_DIR}/qcadsp8380.mbn" ]]; then
    warn "Firmware ADSP não encontrado em ${FW_DIR}/"
    warn "Extraia o firmware do Windows primeiro: extract-qcom-firmware.sh"
    if ! prompt_yn "Continuar sem firmware? (bateria e GPU podem não funcionar)" "n"; then
        exit 1
    fi
fi

TOTAL=16
dkms_ok=0
dkms_fail=0

# ─── 1. GRUB kernel parameters ──────────────────────────────────────────────
step 1 $TOTAL "Parâmetros de kernel (GRUB)..."
if ! grep -q "clk_ignore_unused" /etc/default/grub 2>/dev/null; then
    sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet rhgb clk_ignore_unused pd_ignore_unused rd.systemd.mask=dev-tpm0.device rd.systemd.mask=dev-tpmrm0.device"/' /etc/default/grub
fi
grubby --update-kernel=ALL --args="clk_ignore_unused pd_ignore_unused rd.driver.pre=wcn_regulator_fix rd.systemd.mask=dev-tpm0.device rd.systemd.mask=dev-tpmrm0.device" 2>/dev/null || true
log "  GRUB configurado"

# ─── 2. WiFi — DKMS wcn_regulator_fix ───────────────────────────────────────
step 2 $TOTAL "WiFi (wcn_regulator_fix)..."
if install_dkms_module "wcn-regulator-fix"; then
    ((dkms_ok++))
else
    ((dkms_fail++))
fi
echo "wcn_regulator_fix" > /etc/modules-load.d/wcn-regulator-fix.conf
echo 'force_drivers+=" wcn_regulator_fix "' > /etc/dracut.conf.d/wcn-regulator-fix.conf

# ─── 3. Teclado — DKMS vivobook_kbd_fix ─────────────────────────────────────
step 3 $TOTAL "Teclado (vivobook_kbd_fix)..."
if install_dkms_module "vivobook-kbd-fix"; then
    ((dkms_ok++))
else
    ((dkms_fail++))
fi
echo "vivobook_kbd_fix" > /etc/modules-load.d/vivobook-kbd-fix.conf
echo 'force_drivers+=" vivobook_kbd_fix "' > /etc/dracut.conf.d/vivobook-kbd-fix.conf

# ─── 4. Bateria — ADSP firmware no initramfs ────────────────────────────────
step 4 $TOTAL "Bateria (ADSP firmware initramfs)..."
cat > /etc/dracut.conf.d/qcom-adsp-firmware.conf << 'EOF'
install_items+=" /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/qcadsp8380.mbn /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/adsp_dtbs.elf /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/adspr.jsn /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/adsps.jsn /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/adspua.jsn /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/battmgr.jsn "
EOF
log "  dracut ADSP config"

# ─── 5. Brilho — DKMS vivobook_bl_fix ───────────────────────────────────────
step 5 $TOTAL "Brilho (vivobook_bl_fix)..."
if install_dkms_module "vivobook-bl-fix"; then
    ((dkms_ok++))
else
    ((dkms_fail++))
fi
echo "vivobook_bl_fix" > /etc/modules-load.d/vivobook-bl-fix.conf

# ─── 6. Hotkeys Fn — DKMS vivobook_hotkey_fix ───────────────────────────────
step 6 $TOTAL "Hotkeys Fn (vivobook_hotkey_fix)..."
if install_dkms_module "vivobook-hotkey-fix"; then
    ((dkms_ok++))
else
    ((dkms_fail++))
fi
echo "vivobook_hotkey_fix" > /etc/modules-load.d/vivobook-hotkey-fix.conf

# ─── 7. GPU — Firmware no initramfs ─────────────────────────────────────────
step 7 $TOTAL "GPU (firmware initramfs)..."
cat > /etc/dracut.conf.d/qcom-gpu-firmware.conf << 'EOF'
install_items+=" /usr/lib/firmware/qcom/gen71500_sqe.fw.xz /usr/lib/firmware/qcom/gen71500_gmu.bin.xz /usr/lib/firmware/qcom/x1p42100/gen71500_zap.mbn /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/qcdxkmsucpurwa.mbn "
EOF
log "  dracut GPU config"

# ─── 8. Boot time — Mask TPM fantasma ───────────────────────────────────────
step 8 $TOTAL "Boot time (mask TPM fantasma)..."
systemctl mask dev-tpm0.device dev-tpmrm0.device 2>/dev/null || true
echo 'omit_dracutmodules+=" tpm2-tss systemd-pcrphase "' > /etc/dracut.conf.d/no-tpm.conf
echo 'omit_dracutmodules+=" nfs "' > /etc/dracut.conf.d/no-nfs.conf
log "  TPM masked, NFS omitido"

# ─── 9. Terminal flicker — Vulkan pool fix ───────────────────────────────────
step 9 $TOTAL "Terminal flicker (vk_pool_fix.so + .desktop)..."
mkdir -p /usr/local/lib64 /usr/local/bin

local_vk_installed=false
if [[ -f "${SCRIPT_DIR}/vk_pool_fix.c" ]] && command -v gcc &>/dev/null; then
    if gcc -shared -fPIC -o /usr/local/lib64/vk_pool_fix.so "${SCRIPT_DIR}/vk_pool_fix.c" -ldl 2>/dev/null; then
        local_vk_installed=true
        log "  vk_pool_fix.so compilado"
    fi
fi
if [[ "$local_vk_installed" == false && -f "${SCRIPT_DIR}/vk_pool_fix.so" ]]; then
    cp "${SCRIPT_DIR}/vk_pool_fix.so" /usr/local/lib64/vk_pool_fix.so
    local_vk_installed=true
    log "  vk_pool_fix.so pre-built copiado"
fi
if [[ "$local_vk_installed" == false ]]; then
    warn "  vk_pool_fix.so não disponível — terminal pode ter flicker"
fi

# Wrapper script
cat > /usr/local/bin/ptyxis-fixed << 'WRAPPER'
#!/bin/sh
export LD_PRELOAD=/usr/local/lib64/vk_pool_fix.so
exec /usr/bin/ptyxis "$@"
WRAPPER
chmod +x /usr/local/bin/ptyxis-fixed

# D-Bus service override (Ptyxis usa D-Bus activation)
mkdir -p "${REAL_HOME}/.local/share/dbus-1/services"
cat > "${REAL_HOME}/.local/share/dbus-1/services/org.gnome.Ptyxis.service" << 'DBUS'
[D-BUS Service]
Name=org.gnome.Ptyxis
Exec=/usr/local/bin/ptyxis-fixed --gapplication-service
DBUS

# Desktop entry override
mkdir -p "${REAL_HOME}/.local/share/applications"
if [[ -f /usr/share/applications/org.gnome.Ptyxis.desktop ]]; then
    cp /usr/share/applications/org.gnome.Ptyxis.desktop "${REAL_HOME}/.local/share/applications/"
    sed -i 's|^Exec=ptyxis|Exec=/usr/local/bin/ptyxis-fixed|g' \
        "${REAL_HOME}/.local/share/applications/org.gnome.Ptyxis.desktop"
    log "  .desktop override criado"
else
    warn "  Ptyxis .desktop não encontrado — criar manualmente após instalar"
fi
chown -R "${REAL_USER}:${REAL_USER}" "${REAL_HOME}/.local/share/dbus-1" "${REAL_HOME}/.local/share/applications"

# ─── 10. Tempo bateria — Extensão GNOME ─────────────────────────────────────
step 10 $TOTAL "Tempo bateria (extensão GNOME)..."
if [[ -f "${SCRIPT_DIR}/install-battery-time-ext.sh" ]]; then
    sudo -u "${REAL_USER}" bash "${SCRIPT_DIR}/install-battery-time-ext.sh"
    log "  Extensão battery-time instalada"
else
    warn "  install-battery-time-ext.sh não encontrado — pulando"
fi

# ─── 11. Touchpad — click-method areas ──────────────────────────────────────
step 11 $TOTAL "Touchpad (click-method: areas)..."
sudo -u "${REAL_USER}" gsettings set org.gnome.desktop.peripherals.touchpad click-method 'areas' 2>/dev/null || true
# dconf system-wide fallback
mkdir -p /etc/dconf/db/local.d /etc/dconf/profile
cat > /etc/dconf/db/local.d/01-vivobook << 'EOF'
[org/gnome/desktop/peripherals/touchpad]
click-method='areas'

[org/gnome/software]
download-updates=false
download-updates-notify=false
EOF
cat > /etc/dconf/profile/user << 'EOF'
user-db:user
system-db:local
EOF
dconf update 2>/dev/null || true
log "  Touchpad + dconf defaults"

# ─── 12. Áudio — UCM2 regex fix ─────────────────────────────────────────────
step 12 $TOTAL "Áudio (UCM2 regex — Vivobook 14)..."
UCM_CONF="/usr/share/alsa/ucm2/conf.d/x1e80100/x1e80100.conf"
if [[ -f "$UCM_CONF" ]]; then
    if ! grep -qi "vivobook" "$UCM_CONF"; then
        if grep -q "Zenbook A14" "$UCM_CONF"; then
            sed -i 's/Zenbook A14/Zenbook A14|Vivobook 14/' "$UCM_CONF"
            log "  Vivobook 14 adicionado ao regex UCM2"
        else
            warn "  Regex UCM2 não reconhecido — patch manual necessário"
            info "  Arquivo: ${UCM_CONF}"
        fi
    else
        log "  Vivobook já presente no UCM2"
    fi
else
    warn "  UCM2 x1e80100.conf não encontrado — instalar alsa-ucm-conf"
fi

# ─── 13. Lid close — Suspend desabilitado ───────────────────────────────────
step 13 $TOTAL "Lid close (suspend desabilitado, lid = lock)..."
mkdir -p /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/no-suspend.conf << 'EOF'
[Login]
HandleLidSwitch=lock
HandleLidSwitchExternalPower=lock
HandleLidSwitchDocked=lock
IdleAction=ignore
EOF
for target in suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target sleep.target; do
    systemctl mask "$target" 2>/dev/null || true
done
systemctl mask dev-tpm0.device dev-tpmrm0.device 2>/dev/null || true
log "  Suspend disabled, lid = lock screen"

# ─── 14. cpufreq — scmi_cpufreq autoload ────────────────────────────────────
step 14 $TOTAL "CPU frequency scaling (scmi_cpufreq)..."
echo "scmi_cpufreq" > /etc/modules-load.d/scmi-cpufreq.conf
modprobe scmi_cpufreq 2>/dev/null || true
log "  cpufreq autoload"

# ─── 15. CDSP/NPU — Firmware no initramfs ───────────────────────────────────
step 15 $TOTAL "CDSP/NPU (firmware initramfs)..."
cat > /etc/dracut.conf.d/qcom-cdsp-firmware.conf << 'EOF'
install_items+=" /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/qccdsp8380.mbn /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/cdsp_dtbs.elf /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/cdspr.jsn "
EOF
log "  dracut CDSP config"

# ─── 16. Charge control — udev rule 80% ─────────────────────────────────────
step 16 $TOTAL "Charge control (limite 80%)..."
echo 'SUBSYSTEM=="power_supply", KERNEL=="qcom-battmgr-bat", ATTR{charge_control_end_threshold}="80"' > /etc/udev/rules.d/99-battery-charge-limit.rules
udevadm control --reload-rules 2>/dev/null || true
echo 80 > /sys/class/power_supply/qcom-battmgr-bat/charge_control_end_threshold 2>/dev/null || true
log "  Charge limit 80%"

# ─── Extras ──────────────────────────────────────────────────────────────────

# Disable auto-updates
log "Desabilitando auto-updates..."
systemctl disable --now dnf-makecache.timer 2>/dev/null || true
systemctl mask packagekit.service 2>/dev/null || true

# Install vivobook-update
if [[ -f "${SCRIPT_DIR}/vivobook-update.sh" ]]; then
    cp "${SCRIPT_DIR}/vivobook-update.sh" /usr/local/bin/vivobook-update
    chmod +x /usr/local/bin/vivobook-update
    log "vivobook-update instalado em /usr/local/bin/"
fi

# ─── Rebuild initramfs ──────────────────────────────────────────────────────
log "Regenerando initramfs..."
if ! dracut --force; then
    err "dracut falhou! Verificar configs em /etc/dracut.conf.d/"
    warn "Continuar sem initramfs atualizado pode causar problemas no boot"
fi

# ─── Update GRUB ────────────────────────────────────────────────────────────
log "Atualizando GRUB..."
grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null || \
    grub2-mkconfig -o /boot/efi/EFI/fedora/grub.cfg 2>/dev/null || true

# ─── Limpar scripts antigos ─────────────────────────────────────────────────
log "Removendo scripts antigos (substituídos por build-vivobook-iso.sh + setup-vivobook.sh)..."
removed=0
for old_script in \
    "${SCRIPT_DIR}/prepare-fedora-snapdragon.sh" \
    "${SCRIPT_DIR}/build-v3-iso.sh" \
    "${SCRIPT_DIR}/build-v4-iso.sh" \
    "${SCRIPT_DIR}/setup-all.sh" \
    "${SCRIPT_DIR}/fix.sh"; do
    if [[ -f "$old_script" ]]; then
        rm -f "$old_script"
        log "  Removido: $(basename "$old_script")"
        ((removed++))
    fi
done
if [[ $removed -eq 0 ]]; then
    info "  Nenhum script antigo encontrado"
else
    log "  ${removed} scripts removidos"
fi

# ─── Resultado ──────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}════════════════════════════════════════════${NC}"
echo -e "${BOLD}  SETUP COMPLETO — 16/16 MELHORIAS${NC}"
echo -e "${BOLD}════════════════════════════════════════════${NC}"
echo ""
echo -e "  DKMS: ${GREEN}${dkms_ok} OK${NC}, ${RED}${dkms_fail} falhas${NC}"
echo ""

if [[ $dkms_fail -gt 0 ]]; then
    warn "Módulos DKMS com falha — verificar gcc e kernel-devel:"
    info "  sudo dnf install gcc kernel-devel-\$(uname -r)"
    info "  sudo dkms autoinstall"
    info "  sudo dracut --force"
    echo ""
fi

info "Reboot para aplicar: ${BOLD}sudo reboot${NC}"
echo ""
info "Após o reboot, verificar:"
echo "    WiFi:     ip link show wlP4p1s0"
echo "    Teclado:  dmesg | grep vivobook-kbd"
echo "    Bateria:  cat /sys/class/power_supply/qcom-battmgr-bat/capacity"
echo "    Brilho:   ls /sys/class/backlight/vivobook-backlight/"
echo "    GPU:      glxinfo | grep renderer"
echo "    Boot:     systemd-analyze"
echo "    Áudio:    pactl list sinks short"
echo "    cpufreq:  cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor"
echo "    CDSP:     cat /sys/class/remoteproc/remoteproc1/state"
echo "    Carga:    cat /sys/class/power_supply/qcom-battmgr-bat/charge_control_end_threshold"
echo "    Suspend:  systemctl is-enabled suspend.target"
echo ""
info "Fazer logout/login para ativar a extensão de bateria"
echo ""
info "Scripts atuais:"
echo "    build-vivobook-iso.sh  — Criar ISO customizada"
echo "    setup-vivobook.sh      — Este script (setup pós-install)"
echo "    vivobook-update        — Updates seguros (sudo vivobook-update)"
echo ""
