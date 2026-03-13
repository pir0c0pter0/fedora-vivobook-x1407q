#!/bin/bash
# =============================================================================
# setup-all.sh — Apply all ASUS Vivobook X1407QA (Snapdragon X) Linux fixes
#
# Run as root after firmware has been extracted from Windows and placed in:
#   /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/
#   /lib/firmware/ath11k/WCN6855/hw2.1/board.bin
#
# DKMS module sources must be in /usr/src/:
#   wcn-regulator-fix-1.0/
#   vivobook-kbd-fix-1.0/
#   vivobook-bl-fix-1.0/
#   vivobook-hotkey-fix-1.0/
#
# Usage: sudo bash setup-all.sh
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }

[[ $EUID -eq 0 ]] || err "Execute como root: sudo bash setup-all.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~${REAL_USER}")

echo ""
echo "============================================"
echo " ASUS Vivobook X1407QA — Setup Completo"
echo " Fedora 44 aarch64 / Snapdragon X"
echo "============================================"
echo ""

# ─── Verificar firmware ─────────────────────────────────────────────────
if [[ ! -f /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/qcadsp8380.mbn ]]; then
    warn "Firmware ADSP não encontrado em /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/"
    warn "Extraia o firmware do Windows primeiro (ver GUIA-EXTRAIR-FIRMWARE.md)"
    warn "Continuando sem firmware — bateria e GPU podem não funcionar"
fi

# ─── 1. Kernel parameters (GRUB) ────────────────────────────────────────
log "1/12 — Configurando parâmetros de kernel no GRUB..."
if ! grep -q "clk_ignore_unused" /etc/default/grub 2>/dev/null; then
    sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet rhgb clk_ignore_unused pd_ignore_unused rd.systemd.mask=dev-tpm0.device rd.systemd.mask=dev-tpmrm0.device"/' /etc/default/grub
fi
grubby --update-kernel=ALL --args="clk_ignore_unused pd_ignore_unused rd.driver.pre=wcn_regulator_fix rd.systemd.mask=dev-tpm0.device rd.systemd.mask=dev-tpmrm0.device"

# ─── 2. WiFi — DKMS wcn_regulator_fix ───────────────────────────────────
log "2/12 — Instalando módulo WiFi (wcn_regulator_fix)..."
if [[ -d /usr/src/wcn-regulator-fix-1.0 ]]; then
    if ! dkms status 2>/dev/null | grep -q "wcn-regulator-fix.*installed"; then
        dkms add /usr/src/wcn-regulator-fix-1.0 2>/dev/null || true
        dkms build wcn-regulator-fix/1.0
        dkms install wcn-regulator-fix/1.0
    fi
    echo "wcn_regulator_fix" > /etc/modules-load.d/wcn-regulator-fix.conf
    echo 'force_drivers+=" wcn_regulator_fix "' > /etc/dracut.conf.d/wcn-regulator-fix.conf
    log "  WiFi module installed"
else
    warn "  /usr/src/wcn-regulator-fix-1.0 não encontrado — pulando WiFi fix"
fi

# ─── 3. Keyboard — DKMS vivobook_kbd_fix ─────────────────────────────────
log "3/12 — Instalando módulo teclado (vivobook_kbd_fix)..."
if [[ -d /usr/src/vivobook-kbd-fix-1.0 ]]; then
    if ! dkms status 2>/dev/null | grep -q "vivobook-kbd-fix.*installed"; then
        dkms add /usr/src/vivobook-kbd-fix-1.0 2>/dev/null || true
        dkms build vivobook-kbd-fix/1.0
        dkms install vivobook-kbd-fix/1.0
    fi
    echo "vivobook_kbd_fix" > /etc/modules-load.d/vivobook-kbd-fix.conf
    echo 'force_drivers+=" vivobook_kbd_fix "' > /etc/dracut.conf.d/vivobook-kbd-fix.conf
    log "  Keyboard module installed"
else
    warn "  /usr/src/vivobook-kbd-fix-1.0 não encontrado — pulando keyboard fix"
fi

# ─── 4. Battery — ADSP firmware in initramfs ─────────────────────────────
log "4/12 — Adicionando firmware ADSP ao initramfs..."
cat > /etc/dracut.conf.d/qcom-adsp-firmware.conf << 'EOF'
install_items+=" /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/qcadsp8380.mbn /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/adsp_dtbs.elf /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/adspr.jsn /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/adsps.jsn /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/adspua.jsn /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/battmgr.jsn "
EOF

# ─── 5. Brightness — DKMS vivobook_bl_fix ────────────────────────────────
log "5/12 — Instalando módulo brilho (vivobook_bl_fix)..."
if [[ -d /usr/src/vivobook-bl-fix-1.0 ]]; then
    if ! dkms status 2>/dev/null | grep -q "vivobook-bl-fix.*installed"; then
        dkms add /usr/src/vivobook-bl-fix-1.0 2>/dev/null || true
        dkms build vivobook-bl-fix/1.0
        dkms install vivobook-bl-fix/1.0
    fi
    echo "vivobook_bl_fix" > /etc/modules-load.d/vivobook-bl-fix.conf
    log "  Brightness module installed"
else
    warn "  /usr/src/vivobook-bl-fix-1.0 não encontrado — pulando brightness fix"
fi

# ─── 6. Fn Hotkeys — DKMS vivobook_hotkey_fix ───────────────────────────
log "6/12 — Instalando módulo hotkeys (vivobook_hotkey_fix)..."
if [[ -d /usr/src/vivobook-hotkey-fix-1.0 ]]; then
    if ! dkms status 2>/dev/null | grep -q "vivobook-hotkey-fix.*installed"; then
        dkms add /usr/src/vivobook-hotkey-fix-1.0 2>/dev/null || true
        dkms build vivobook-hotkey-fix/1.0
        dkms install vivobook-hotkey-fix/1.0
    fi
    echo "vivobook_hotkey_fix" > /etc/modules-load.d/vivobook-hotkey-fix.conf
    log "  Hotkey module installed"
else
    warn "  /usr/src/vivobook-hotkey-fix-1.0 não encontrado — pulando hotkey fix"
fi

# ─── 7. GPU — Firmware in initramfs ──────────────────────────────────────
log "7/12 — Adicionando firmware GPU ao initramfs..."
cat > /etc/dracut.conf.d/qcom-gpu-firmware.conf << 'EOF'
install_items+=" /usr/lib/firmware/qcom/gen71500_sqe.fw.xz /usr/lib/firmware/qcom/gen71500_gmu.bin.xz /usr/lib/firmware/qcom/x1p42100/gen71500_zap.mbn /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/qcdxkmsucpurwa.mbn "
EOF

# ─── 8. Boot time — Mask phantom TPM ─────────────────────────────────────
log "8/12 — Otimizando boot time (masking TPM fantasma)..."
systemctl mask dev-tpm0.device dev-tpmrm0.device 2>/dev/null || true
echo 'omit_dracutmodules+=" tpm2-tss systemd-pcrphase "' > /etc/dracut.conf.d/no-tpm.conf
echo 'omit_dracutmodules+=" nfs "' > /etc/dracut.conf.d/no-nfs.conf

# ─── 9. Terminal flicker — Vulkan pool fix ───────────────────────────────
log "9/12 — Instalando fix Vulkan (vk_pool_fix.so)..."
mkdir -p /usr/local/lib64

if [[ -f "${SCRIPT_DIR}/vk_pool_fix.c" ]]; then
    if command -v gcc &>/dev/null; then
        gcc -shared -fPIC -o /usr/local/lib64/vk_pool_fix.so "${SCRIPT_DIR}/vk_pool_fix.c" -ldl
        log "  Built vk_pool_fix.so from source"
    elif [[ -f "${SCRIPT_DIR}/vk_pool_fix.so" ]]; then
        cp "${SCRIPT_DIR}/vk_pool_fix.so" /usr/local/lib64/vk_pool_fix.so
        log "  Copied pre-built vk_pool_fix.so"
    fi
elif [[ -f "${SCRIPT_DIR}/vk_pool_fix.so" ]]; then
    cp "${SCRIPT_DIR}/vk_pool_fix.so" /usr/local/lib64/vk_pool_fix.so
    log "  Copied pre-built vk_pool_fix.so"
fi

# Wrapper script (needed because Ptyxis uses D-Bus activation)
cat > /usr/local/bin/ptyxis-fixed << 'WRAPPER'
#!/bin/sh
export LD_PRELOAD=/usr/local/lib64/vk_pool_fix.so
exec /usr/bin/ptyxis "$@"
WRAPPER
chmod +x /usr/local/bin/ptyxis-fixed

# D-Bus service override
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
fi
chown -R "${REAL_USER}:${REAL_USER}" "${REAL_HOME}/.local/share/dbus-1" "${REAL_HOME}/.local/share/applications"

# ─── 10. Battery time extension ──────────────────────────────────────────
log "10/12 — Instalando extensão GNOME (battery-time)..."
if [[ -f "${SCRIPT_DIR}/install-battery-time-ext.sh" ]]; then
    sudo -u "${REAL_USER}" bash "${SCRIPT_DIR}/install-battery-time-ext.sh"
else
    warn "  install-battery-time-ext.sh não encontrado — pulando"
fi

# ─── 11. Touchpad right-click ────────────────────────────────────────────
log "11/12 — Configurando touchpad (click-method: areas)..."
sudo -u "${REAL_USER}" gsettings set org.gnome.desktop.peripherals.touchpad click-method 'areas' 2>/dev/null || warn "  gsettings falhou (sem sessão gráfica?)"

# ─── 12. CPU frequency scaling — autoload scmi_cpufreq ──────────────────
log "12/12 — Habilitando CPU frequency scaling (scmi_cpufreq)..."
echo "scmi_cpufreq" > /etc/modules-load.d/scmi-cpufreq.conf
modprobe scmi_cpufreq 2>/dev/null || true
log "  cpufreq module configured for autoload"

# ─── Disable auto updates ────────────────────────────────────────────────
log "Desabilitando auto-updates (previne quebra dos módulos DKMS)..."
systemctl disable --now dnf-makecache.timer 2>/dev/null || true
systemctl mask packagekit.service 2>/dev/null || true
sudo -u "${REAL_USER}" gsettings set org.gnome.software download-updates false 2>/dev/null || true
sudo -u "${REAL_USER}" gsettings set org.gnome.software download-updates-notify false 2>/dev/null || true

# ─── Rebuild initramfs ───────────────────────────────────────────────────
log "Regenerando initramfs com todos os firmwares e módulos..."
dracut --force

# ─── Update GRUB ─────────────────────────────────────────────────────────
log "Atualizando GRUB..."
grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null || grub2-mkconfig -o /boot/efi/EFI/fedora/grub.cfg 2>/dev/null || true

echo ""
echo "============================================"
echo "  INSTALAÇÃO COMPLETA — 12/12 FIXES"
echo "============================================"
echo ""
echo "  Reboot para aplicar: sudo reboot"
echo ""
echo "  Após o reboot, verificar:"
echo "    WiFi:     ip link show wlP4p1s0"
echo "    Teclado:  dmesg | grep vivobook-kbd"
echo "    Bateria:  cat /sys/class/power_supply/qcom-battmgr-bat/capacity"
echo "    Brilho:   ls /sys/class/backlight/vivobook-backlight/"
echo "    GPU:      glxinfo | grep renderer"
echo "    Boot:     systemd-analyze"
echo "    cpufreq:  cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor"
echo ""
echo "  ATENÇÃO: Faça logout/login para ativar a extensão de bateria"
echo ""
