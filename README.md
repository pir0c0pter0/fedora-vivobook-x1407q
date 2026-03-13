# Linux on ASUS Vivobook 14 X1407QA (Snapdragon X)

> Full Linux support for the ASUS Vivobook 14 X1407QA with Qualcomm Snapdragon X (X1-26-100) on Fedora 44 aarch64 — from zero to daily driver.

**Author:** Pir0c0pter0 — pir0c0pter0000@gmail.com

## Hardware

| Component | Details |
|-----------|---------|
| **Model** | ASUS Vivobook 14 X1407QA |
| **SoC** | Qualcomm Snapdragon X X1-26-100 (8 cores, 2.97GHz, die "Purwa" — x1p42100) |
| **GPU** | Adreno X1-45 (freedreno / turnip / Mesa) |
| **RAM** | 16GB LPDDR5X |
| **Storage** | NVMe PCIe 4.0 |
| **Display** | 14" Samsung ATANA33XC20, eDP, 1920x1200 IPS, 60Hz |
| **WiFi** | Qualcomm QCNFA765 (WCN6855 hw2.1) — ath11k_pci, PCI `17cb:1103` |
| **Bluetooth** | FastConnect 6900 (UART) |
| **Keyboard** | ASUS I2C-HID, VID `0x0b05`, PID `0x4543`, bus 4 (`b94000`), addr `0x3a` |
| **Touchpad** | ELAN I2C-HID clickpad, VID `0x04f3`, PID `0x3313`, bus 1 (`b80000`), addr `0x15` |
| **Battery** | 50Wh Li-ion X321-42, driver `qcom_battmgr` via `pmic_glink` |

## Achievements

Starting from a laptop that **refused to boot** Linux, every fix was reverse-engineered from scratch — no upstream support, no documentation, no community guides for this model.

| # | Achievement | Method | Impact |
|---|------------|--------|--------|
| 1 | **Booted Fedora** | Custom ISO + Zenbook A14 DTB (same Qualcomm die) | From brick to bootable |
| 2 | **WiFi working** | DKMS module `wcn_regulator_fix` + custom board.bin | PCIe race condition + regulator fix |
| 3 | **Keyboard working** | DKMS module `vivobook_kbd_fix` | Different I2C bus/address than Zenbook |
| 4 | **Battery reporting** | ADSP firmware injected into initramfs | `qcom-battmgr` was failing at early boot |
| 5 | **Brightness control** | DKMS module `vivobook_bl_fix` | Direct PMIC PWM register manipulation |
| 6 | **Fn hotkeys** | DKMS module `vivobook_hotkey_fix` | ASUS vendor HID init + key mapping |
| 7 | **GPU acceleration** | Firmware in initramfs (4 files including ZAP shader) | Adreno X1-45 with full 3D |
| 8 | **Boot time: 1min47s -> 8s** | TPM timeout elimination + initrd cleanup | Masked phantom TPM devices, removed unused modules |
| 9 | **Terminal flicker fixed** | LD_PRELOAD Vulkan pool fix (`vk_pool_fix.so`) | GTK4/turnip descriptor pool fragmentation → 952 errors eliminated |
| 10 | **Battery time in panel** | GNOME Shell extension `battery-time@wifiteste` | Hover over battery icon shows time remaining (weighted rolling average) |
| 11 | **Touchpad right-click** | gsettings `click-method` → `areas` | Clickpad only reports BTN_LEFT; area-based mapping restores right-click |

**5 custom kernel modules**, **1 Vulkan driver fix**, **1 GNOME extension**, **0 kernel patches** — everything done at runtime via DKMS/LD_PRELOAD because the INSYDE UEFI blocks DTB overrides.

## Current Status

| Feature | Status | Notes |
|---------|--------|-------|
| **Boot** | :white_check_mark: Working | Fedora 44 via Zenbook A14 DTB |
| **Boot time** | :white_check_mark: 8s | Was ~2min (see [Boot Time Fix](#8-boot-time-fix)) |
| **Display** | :white_check_mark: Working | GPU firmware in initramfs (see [GPU Firmware Fix](#7-gpu-firmware-fix)) |
| **WiFi** | :white_check_mark: Working | DKMS module + board.bin (see [WiFi Fix](#2-wifi-fix)) |
| **Bluetooth** | :white_check_mark: Working | FastConnect 6900 UART — out-of-the-box |
| **Keyboard** | :white_check_mark: Working | DKMS module (see [Keyboard Fix](#3-keyboard-fix)) |
| **Touchpad** | :white_check_mark: Working | Clickpad — `click-method: areas` for right-click (see [Touchpad Fix](#11-touchpad-right-click-fix)) |
| **Battery** | :white_check_mark: Working | ADSP firmware in initramfs (see [Battery Fix](#4-battery-fix)) |
| **Brightness** | :white_check_mark: Working | DKMS module (see [Brightness Fix](#5-brightness-fix)) |
| **Brightness keys** | :white_check_mark: Working | DKMS module (see [Hotkey Fix](#6-fn-hotkey-fix)) |
| **USB ports** | :white_check_mark: Working | USB-C, USB-A, HDMI |
| **NVMe** | :white_check_mark: Working | PCIe 4.0 |
| **Audio** | :x: Not working | ADSP codec not mapped in DTB |
| **Camera** | :x: Not working | No driver support |

---

## Quick Start — Complete Installation Guide

### Prerequisites

| Item | Details |
|------|---------|
| **ISO** | Fedora Workstation 44 aarch64 (Live) |
| **Download** | https://download.fedoraproject.org/pub/fedora/linux/releases/44/Workstation/aarch64/iso/ |
| **ISO used** | `Fedora-Workstation-Live-44_Beta-1.2.aarch64.iso` (used for original development; final release also works) |
| **Kernel** | `6.19.6-300.fc44.aarch64` |
| **USB drive** | 8GB+ for ISO, 32GB+ recommended for persistence |
| **Second machine** | To prepare the USB (or use Windows on the Vivobook itself) |

### Step 0 — Prepare BIOS

1. Power off the Vivobook completely
2. Hold **F2** and power on to enter UEFI/BIOS
3. **Disable Secure Boot** (Security → Secure Boot → Disabled)
4. **Enable USB boot** (Boot → USB Boot → Enabled)
5. Save and exit (F10)

### Step 1 — Download ISO and Flash USB

```bash
# Download Fedora 44 aarch64 Workstation Live ISO
wget https://download.fedoraproject.org/pub/fedora/linux/releases/44/Workstation/aarch64/iso/Fedora-Workstation-Live-aarch64-44-1.1.iso

# Flash to USB (REPLACE /dev/sdX with your USB device!)
sudo dd if=Fedora-Workstation-Live-aarch64-44-1.1.iso of=/dev/sdX bs=4M status=progress oflag=sync
sync
```

Or use the custom ISO builder script from this repo:

```bash
bash prepare-fedora-snapdragon.sh
```

This script modifies the ISO to include `clk_ignore_unused pd_ignore_unused` kernel parameters and a GRUB DTB selection menu.

### Step 2 — Boot from USB

1. Connect the USB drive
2. Hold **F12** (or **ESC**) during power-on for boot menu
3. Select the USB drive
4. At the GRUB menu, press **e** to edit the boot entry and add to the `linux` line:
   ```
   clk_ignore_unused pd_ignore_unused
   ```
5. Press **Ctrl+X** to boot
6. The system will boot using the **Zenbook A14 DTB** (`x1p42100-asus-zenbook-a14.dtb`) — same Qualcomm "Purwa" die

> **Why Zenbook A14 DTB?** There is no DTB for the Vivobook X1407QA in the kernel. The Zenbook A14 uses the same Qualcomm x1p42100 SoC. The INSYDE UEFI firmware provides the DTB and **cannot be overridden** from GRUB on aarch64 (7 methods tested: BLS devicetree, GRUB fdt module, dtbloader.efi, EFI stub — all fail). So we boot with the Zenbook DTB and fix all hardware differences via runtime kernel modules.

### Step 3 — Install Fedora to NVMe

1. Once booted into the Live environment, open the installer
2. Install Fedora to the NVMe drive (default btrfs layout)
3. Reboot into the installed system

> **Important:** At first boot from NVMe, edit GRUB again with `clk_ignore_unused pd_ignore_unused` — you'll make this permanent in Step 5.

### Step 4 — Extract Firmware from Windows

The Qualcomm firmware is proprietary and must be extracted from the Windows partition. BitLocker prevents direct access from Linux, so run this **from Windows** (PowerShell as Administrator):

See [GUIA-EXTRAIR-FIRMWARE.md](GUIA-EXTRAIR-FIRMWARE.md) for the full PowerShell scripts.

Quick version — copy the extracted firmware to a USB drive, then on the Linux side:

```bash
# Mount the USB with the extracted firmware
sudo mount /dev/sdX1 /mnt

# Copy firmware to the correct paths
sudo mkdir -p /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/
sudo cp /mnt/qcom-firmware/*.mbn /mnt/qcom-firmware/*.elf \
    /mnt/qcom-firmware/*.jsn /mnt/qcom-firmware/*.bin \
    /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/

# WiFi board data
sudo mkdir -p /lib/firmware/ath11k/WCN6855/hw2.1/
sudo cp /mnt/qcom-firmware/board*.bin /lib/firmware/ath11k/WCN6855/hw2.1/board.bin

sudo umount /mnt
```

### Step 5 — Apply All Fixes (Automated)

Clone this repo and run the complete setup script:

```bash
git clone https://github.com/pir0c0pter0/fedora-vivobook-x1407q.git
cd fedora-vivobook-x1407q
sudo bash setup-all.sh
```

Or apply each fix manually — see [Detailed Fix Guide](#detailed-fix-guide) below.

### Step 6 — Reboot and Verify

```bash
sudo reboot
```

After reboot, verify everything:

```bash
# WiFi
ip link show wlP4p1s0

# Keyboard (should already be working)
dmesg | grep vivobook-kbd

# Battery
cat /sys/class/power_supply/qcom-battmgr-bat/capacity

# Brightness
cat /sys/class/backlight/vivobook-backlight/brightness

# GPU
glxinfo | grep "OpenGL renderer"

# Hotkeys (press Fn+F5/F6)
dmesg | grep vivobook_hotkey

# Boot time
systemd-analyze
```

---

## Complete Setup Script

The `setup-all.sh` script applies all 11 fixes in the correct order. It assumes firmware has already been extracted (Step 4).

```bash
#!/bin/bash
# setup-all.sh — Apply all ASUS Vivobook X1407QA fixes
# Run as root after firmware extraction
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'
log() { echo -e "${GREEN}[+]${NC} $1"; }
err() { echo -e "${RED}[✗]${NC} $1"; exit 1; }

[[ $EUID -eq 0 ]] || err "Execute como root: sudo bash setup-all.sh"

# ─── 1. Kernel parameters (GRUB) ────────────────────────────────────────
log "1/11 — Configurando parâmetros de kernel no GRUB..."
if ! grep -q "clk_ignore_unused" /etc/default/grub; then
    sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet rhgb clk_ignore_unused pd_ignore_unused rd.systemd.mask=dev-tpm0.device rd.systemd.mask=dev-tpmrm0.device"/' /etc/default/grub
fi
grubby --update-kernel=ALL --args="clk_ignore_unused pd_ignore_unused rd.driver.pre=wcn_regulator_fix rd.systemd.mask=dev-tpm0.device rd.systemd.mask=dev-tpmrm0.device"

# ─── 2. WiFi — DKMS wcn_regulator_fix ───────────────────────────────────
log "2/11 — Instalando módulo WiFi (wcn_regulator_fix)..."
if ! dkms status | grep -q "wcn-regulator-fix"; then
    dkms add /usr/src/wcn-regulator-fix-1.0
    dkms build wcn-regulator-fix/1.0
    dkms install wcn-regulator-fix/1.0
fi
echo "wcn_regulator_fix" > /etc/modules-load.d/wcn-regulator-fix.conf
echo 'force_drivers+=" wcn_regulator_fix "' > /etc/dracut.conf.d/wcn-regulator-fix.conf

# ─── 3. Keyboard — DKMS vivobook_kbd_fix ─────────────────────────────────
log "3/11 — Instalando módulo teclado (vivobook_kbd_fix)..."
if ! dkms status | grep -q "vivobook-kbd-fix"; then
    dkms add /usr/src/vivobook-kbd-fix-1.0
    dkms build vivobook-kbd-fix/1.0
    dkms install vivobook-kbd-fix/1.0
fi
echo "vivobook_kbd_fix" > /etc/modules-load.d/vivobook-kbd-fix.conf
echo 'force_drivers+=" vivobook_kbd_fix "' > /etc/dracut.conf.d/vivobook-kbd-fix.conf

# ─── 4. Battery — ADSP firmware in initramfs ─────────────────────────────
log "4/11 — Adicionando firmware ADSP ao initramfs..."
cat > /etc/dracut.conf.d/qcom-adsp-firmware.conf << 'EOF'
install_items+=" /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/qcadsp8380.mbn /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/adsp_dtbs.elf /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/adspr.jsn /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/adsps.jsn /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/adspua.jsn /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/battmgr.jsn "
EOF

# ─── 5. Brightness — DKMS vivobook_bl_fix ────────────────────────────────
log "5/11 — Instalando módulo brilho (vivobook_bl_fix)..."
if ! dkms status | grep -q "vivobook-bl-fix"; then
    dkms add /usr/src/vivobook-bl-fix-1.0
    dkms build vivobook-bl-fix/1.0
    dkms install vivobook-bl-fix/1.0
fi
echo "vivobook_bl_fix" > /etc/modules-load.d/vivobook-bl-fix.conf

# ─── 6. Fn Hotkeys — DKMS vivobook_hotkey_fix ───────────────────────────
log "6/11 — Instalando módulo hotkeys (vivobook_hotkey_fix)..."
if ! dkms status | grep -q "vivobook-hotkey-fix"; then
    dkms add /usr/src/vivobook-hotkey-fix-1.0
    dkms build vivobook-hotkey-fix/1.0
    dkms install vivobook-hotkey-fix/1.0
fi
echo "vivobook_hotkey_fix" > /etc/modules-load.d/vivobook-hotkey-fix.conf

# ─── 7. GPU — Firmware in initramfs ──────────────────────────────────────
log "7/11 — Adicionando firmware GPU ao initramfs..."
cat > /etc/dracut.conf.d/qcom-gpu-firmware.conf << 'EOF'
install_items+=" /usr/lib/firmware/qcom/gen71500_sqe.fw.xz /usr/lib/firmware/qcom/gen71500_gmu.bin.xz /usr/lib/firmware/qcom/x1p42100/gen71500_zap.mbn /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/qcdxkmsucpurwa.mbn "
EOF

# ─── 8. Boot time — Mask phantom TPM ─────────────────────────────────────
log "8/11 — Otimizando boot time (masking TPM fantasma)..."
systemctl mask dev-tpm0.device dev-tpmrm0.device 2>/dev/null || true
echo 'omit_dracutmodules+=" tpm2-tss systemd-pcrphase "' > /etc/dracut.conf.d/no-tpm.conf
echo 'omit_dracutmodules+=" nfs "' > /etc/dracut.conf.d/no-nfs.conf

# ─── 9. Terminal flicker — Vulkan pool fix ───────────────────────────────
log "9/11 — Instalando fix Vulkan (vk_pool_fix.so)..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Build if source exists
if [[ -f "${SCRIPT_DIR}/vk_pool_fix.c" ]]; then
    gcc -shared -fPIC -o /usr/local/lib64/vk_pool_fix.so "${SCRIPT_DIR}/vk_pool_fix.c" -ldl
elif [[ -f "${SCRIPT_DIR}/vk_pool_fix.so" ]]; then
    cp "${SCRIPT_DIR}/vk_pool_fix.so" /usr/local/lib64/vk_pool_fix.so
fi

# Wrapper script (needed because Ptyxis uses D-Bus activation)
cat > /usr/local/bin/ptyxis-fixed << 'WRAPPER'
#!/bin/sh
export LD_PRELOAD=/usr/local/lib64/vk_pool_fix.so
exec /usr/bin/ptyxis "$@"
WRAPPER
chmod +x /usr/local/bin/ptyxis-fixed

# D-Bus service override (this is what actually launches Ptyxis)
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~${REAL_USER}")
mkdir -p "${REAL_HOME}/.local/share/dbus-1/services"
cat > "${REAL_HOME}/.local/share/dbus-1/services/org.gnome.Ptyxis.service" << 'DBUS'
[D-BUS Service]
Name=org.gnome.Ptyxis
Exec=/usr/local/bin/ptyxis-fixed --gapplication-service
DBUS

# Desktop entry override
mkdir -p "${REAL_HOME}/.local/share/applications"
cp /usr/share/applications/org.gnome.Ptyxis.desktop "${REAL_HOME}/.local/share/applications/" 2>/dev/null || true
sed -i 's|^Exec=ptyxis|Exec=/usr/local/bin/ptyxis-fixed|g' \
    "${REAL_HOME}/.local/share/applications/org.gnome.Ptyxis.desktop" 2>/dev/null || true
chown -R "${REAL_USER}:${REAL_USER}" "${REAL_HOME}/.local/share/dbus-1" "${REAL_HOME}/.local/share/applications"

# ─── 10. Battery time extension ──────────────────────────────────────────
log "10/11 — Instalando extensão GNOME (battery-time)..."
sudo -u "${REAL_USER}" bash "${SCRIPT_DIR}/install-battery-time-ext.sh"

# ─── 11. Touchpad right-click ────────────────────────────────────────────
log "11/11 — Configurando touchpad (click-method: areas)..."
sudo -u "${REAL_USER}" gsettings set org.gnome.desktop.peripherals.touchpad click-method 'areas'

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
grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null || true

echo ""
echo "============================================"
echo " INSTALAÇÃO COMPLETA"
echo "============================================"
echo ""
echo " Reboot para aplicar: sudo reboot"
echo ""
echo " Após o reboot, verificar:"
echo "   - WiFi: ip link show wlP4p1s0"
echo "   - Teclado: dmesg | grep vivobook-kbd"
echo "   - Bateria: cat /sys/class/power_supply/qcom-battmgr-bat/capacity"
echo "   - Brilho: ls /sys/class/backlight/vivobook-backlight/"
echo "   - GPU: glxinfo | grep renderer"
echo "   - Boot time: systemd-analyze"
echo ""
echo " ATENÇÃO: Faça logout e login para ativar a extensão de bateria"
echo ""
```

---

## Detailed Fix Guide

### 1. Boot Fix

**Problem:** Fedora 44 aarch64 does not boot out of the box — there is no DTB for the Vivobook X1407QA in kernel 6.19.

**Solution:** Boot using the Zenbook A14 DTB (`x1p42100-asus-zenbook-a14.dtb`) which shares the same Qualcomm "Purwa" die. The INSYDE UEFI firmware cannot be overridden (7 methods tested), so all hardware differences are fixed via runtime kernel modules.

**Kernel parameters** (required in GRUB):

| Parameter | Purpose |
|-----------|---------|
| `clk_ignore_unused` | Prevents kernel from disabling Qualcomm clocks needed by firmware |
| `pd_ignore_unused` | Prevents kernel from disabling power domains needed by firmware |
| `rd.driver.pre=wcn_regulator_fix` | Loads WiFi regulator fix before PCIe scan |
| `rd.systemd.mask=dev-tpm0.device` | Skips TPM wait in initrd |
| `rd.systemd.mask=dev-tpmrm0.device` | Skips TPM resource manager wait in initrd |

**Full kernel cmdline used:**

```
BOOT_IMAGE=/vmlinuz-6.19.6-300.fc44.aarch64 root=UUID=<your-uuid> ro rootflags=subvol=root quiet rhgb clk_ignore_unused pd_ignore_unused rd.driver.pre=wcn_regulator_fix rd.systemd.mask=dev-tpm0.device rd.systemd.mask=dev-tpmrm0.device
```

### 2. WiFi Fix

DKMS module `wcn_regulator_fix` + custom `board.bin`.

**Problem:**
1. **PCIe race condition** (upstream bug, fix ~6.21): `qcom-pcie` scans before WiFi chip is powered on
2. **Regulator cleanup**: kernel disables WCN regulators ~30s after boot
3. **Missing board data**: no `board-2.bin` entry for subsystem `105b:e130`

**Module** (`/usr/src/wcn-regulator-fix-1.0/`):
- Holds WCN regulators via consumer API
- Patches DT with `regulator-always-on`
- Schedules delayed PCIe bus rescans (device found ~6s after boot)

**Board data**: fallback `board.bin` from similar WCN6855 variant at `/lib/firmware/ath11k/WCN6855/hw2.1/board.bin`

```bash
sudo dkms add /usr/src/wcn-regulator-fix-1.0
sudo dkms build wcn-regulator-fix/1.0
sudo dkms install wcn-regulator-fix/1.0
echo "force_drivers+=\" wcn_regulator_fix \"" | sudo tee /etc/dracut.conf.d/wcn-regulator-fix.conf
echo "wcn_regulator_fix" | sudo tee /etc/modules-load.d/wcn-regulator-fix.conf
sudo grubby --update-kernel=ALL --args="rd.driver.pre=wcn_regulator_fix"
sudo dracut --force
```

| Property | Value |
|----------|-------|
| **Chip** | WCN6855 hw2.1, PCI `17cb:1103` (subsystem `105b:e130`) |
| **Driver** | `ath11k_pci` |
| **Interface** | `wlP4p1s0` |
| **Firmware** | WLAN.HSP.1.1-03125 |

### 3. Keyboard Fix

DKMS module `vivobook_kbd_fix`.

**Problem:** The Zenbook DTB maps the keyboard to `i2c@a80000:0x15`. On the Vivobook, it's on a completely different bus: `i2c@b94000` (bus 4) at address `0x3a`.

**Module** (`/usr/src/vivobook-kbd-fix-1.0/`):
- Registers I2C HID driver (`vivobook-kbd`)
- Maps TLMM GPIO 67 to IRQ via `irq_create_fwspec_mapping()` (legacy `gpio_to_irq()` doesn't work on Qualcomm TLMM)
- Creates I2C device on correct bus/address
- Calls exported `i2c_hid_core_probe()` from `i2c_hid` module

```bash
sudo dkms add /usr/src/vivobook-kbd-fix-1.0
sudo dkms build vivobook-kbd-fix/1.0
sudo dkms install vivobook-kbd-fix/1.0
echo "vivobook_kbd_fix" | sudo tee /etc/modules-load.d/vivobook-kbd-fix.conf
echo 'force_drivers+=" vivobook_kbd_fix "' | sudo tee /etc/dracut.conf.d/vivobook-kbd-fix.conf
sudo dracut --force
```

| Property | Value |
|----------|-------|
| **Controller** | ASUS I2C-HID, VID `0x0b05`, PID `0x4543` |
| **I2C bus** | 4 (`b94000.i2c`) |
| **I2C address** | `0x3a` |
| **HID descriptor** | Register `0x0001` |
| **Interrupt** | TLMM GPIO 67, level-low |

### 4. Battery Fix

ADSP firmware in initramfs so `qcom-battmgr` can communicate with the PMIC.

**Problem:** The `qcom-battmgr` driver returns `EAGAIN` on all reads. The ADSP remoteproc fails at early boot because its firmware (`qcadsp8380.mbn`) isn't in the initramfs — the rootfs isn't mounted yet at 1.7s when the kernel requests it.

```bash
echo 'install_items+=" /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/qcadsp8380.mbn /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/adsp_dtbs.elf /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/adspr.jsn /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/adsps.jsn /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/adspua.jsn /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/battmgr.jsn "' | sudo tee /etc/dracut.conf.d/qcom-adsp-firmware.conf
sudo dracut --force
```

| Property | Value |
|----------|-------|
| **Driver** | `qcom_battmgr` (via `pmic_glink`) |
| **Dependency** | ADSP remoteproc (`qcadsp8380.mbn`) |
| **Battery** | X321-42, 50Wh, Li-ion |
| **sysfs** | `/sys/class/power_supply/qcom-battmgr-bat/` |

### 5. Brightness Fix

DKMS module `vivobook_bl_fix`.

**Problem:** The panel uses an external PWM signal for brightness. The PMIC (PMK8550) has an LPG channel pre-configured as 12-bit PWM at 19.2 MHz, but the DTB node is `status = "disabled"`. The PWM signal is not routed to the output GPIO, leaving the screen stuck at 100%.

**Module** (`/usr/src/vivobook-bl-fix-1.0/`):
- Finds PMK8550 regmap via DT child platform device lookup
- Enables DTEST3 routing: writes `0x01` to LPG TEST register E2 via SEC_ACCESS unlock
- Writes PWM value + PWM_SYNC (offset 0x47) to latch values into hardware
- Registers `/sys/class/backlight/vivobook-backlight` (4096 levels)
- GNOME Quick Settings slider + Fn brightness keys work automatically

**Signal path**: `LPG ch0 PWM -> DTEST3 bus -> GPIO5 (DIG_OUT_SRC=0x04) -> panel backlight`

```bash
sudo dkms add /usr/src/vivobook-bl-fix-1.0
sudo dkms build vivobook-bl-fix/1.0
sudo dkms install vivobook-bl-fix/1.0
echo "vivobook_bl_fix" | sudo tee /etc/modules-load.d/vivobook-bl-fix.conf
```

| Property | Value |
|----------|-------|
| **PMIC** | PMK8550 (SPMI SID 0, pmic@0) |
| **LPG channel** | ch0, base 0xE800, HI_RES_PWM (subtype 0x0C) |
| **Resolution** | 12-bit (4096 levels) |
| **GPIO** | PMK8550 GPIO5 (0xBC00), sources DTEST3 (DIG_OUT_SRC=0x04) |
| **Key registers** | TEST3 (0xE8E2, SEC_ACCESS protected), PWM_SYNC (0xE847) |
| **Backlight enable** | PMC8380_3 GPIO4 (on/off, already HIGH) |

> **WARNING**: Never change GPIO5 DIG_OUT_SOURCE_CTL to 0x00 (func3) or force GPIO output LOW — this kills the display and requires a forced reboot.

### 6. Fn Hotkey Fix

DKMS module `vivobook_hotkey_fix`.

**Problem:** The keyboard firmware requires an ASUS-specific init sequence before forwarding Fn hotkey events. The standard `hid-asus` driver is disabled in Fedora's aarch64 kernel (`CONFIG_HID_ASUS is not set`) and PID `0x4543` isn't in its device table. Without the init, Fn+F5/F6 and other hotkeys are silently swallowed.

**Module** (`/usr/src/vivobook-hotkey-fix-1.0/`):
- Registers as HID driver for `0x0B05:0x4543`, binding instead of `hid-generic`
- Sends ASUS init sequence (`"ASUS Tech.Inc.\0"`) via SET_FEATURE to report `0x5A`
- Maps vendor page `0xFF31` hotkeys to standard input events
- Returns 0 for all other HID usages so generic layer handles standard keyboard

```bash
sudo dkms add /usr/src/vivobook-hotkey-fix-1.0
sudo dkms build vivobook-hotkey-fix/1.0
sudo dkms install vivobook-hotkey-fix/1.0
echo "vivobook_hotkey_fix" | sudo tee /etc/modules-load.d/vivobook-hotkey-fix.conf
```

> **Note**: Must load BEFORE `vivobook_kbd_fix` so the HID driver is registered when the I2C device is created. The `modules-load.d` alphabetical order handles this automatically.

| Hotkey | Vendor Usage | Mapped Key |
|--------|-------------|------------|
| Fn+F5 | `0xFF31:0x10` | `KEY_BRIGHTNESSDOWN` |
| Fn+F6 | `0xFF31:0x20` | `KEY_BRIGHTNESSUP` |
| Mic mute | `0xFF31:0x7c` | `KEY_MICMUTE` |
| Camera | `0xFF31:0x82` | `KEY_CAMERA` |
| Airplane | `0xFF31:0x88` | `KEY_RFKILL` |
| Kbd backlight | `0xFF31:0xc7` | `KEY_KBDILLUMTOGGLE` |

### 7. GPU Firmware Fix

GPU firmware in initramfs for early loading.

**Problem:** The Adreno X1-45 GPU requires four firmware files. The generic firmware is only available compressed (`.xz`) and the kernel's direct loader fails during early boot. The ZAP shader (`qcdxkmsucpurwa.mbn`) uses the MDT loader which does NOT retry — if it's not available immediately, GPU init fails completely (no 3D acceleration).

```bash
echo 'install_items+=" /usr/lib/firmware/qcom/gen71500_sqe.fw.xz /usr/lib/firmware/qcom/gen71500_gmu.bin.xz /usr/lib/firmware/qcom/x1p42100/gen71500_zap.mbn /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/qcdxkmsucpurwa.mbn "' | sudo tee /etc/dracut.conf.d/qcom-gpu-firmware.conf
sudo dracut --force
```

| Firmware | Path | Purpose |
|----------|------|---------|
| `gen71500_sqe.fw.xz` | `qcom/` | Shader Queue Engine |
| `gen71500_gmu.bin.xz` | `qcom/` | Graphics Management Unit |
| `gen71500_zap.mbn` | `qcom/x1p42100/` | ZAP shader (generic) |
| `qcdxkmsucpurwa.mbn` | `qcom/x1p42100/ASUSTeK/zenbook-a14/` | ZAP shader (device-specific) |

| Property | Value |
|----------|-------|
| **GPU** | Adreno X1-45 (freedreno / Mesa) |
| **Driver** | `msm_dpu` (display), `adreno` (GPU) |
| **Panel** | Samsung ATANA33XC20, eDP, 1920x1200@60Hz, 10-bit (XR30) |

> **WARNING**: The `qcdxkmsucpurwa.mbn` ZAP shader is critical. Without it the MDT loader fails immediately with `gpu hw init failed: -2` and the GPU has no 3D acceleration.

### 8. Boot Time Fix

TPM device masking + initrd cleanup — from 1min47s to **8 seconds**.

**Problem:** The system has no TPM chip (`ima: No TPM chip found, activating TPM-bypass!`), but systemd waits for `/dev/tpm0` and `/dev/tpmrm0` — twice:

| Phase | Wait time | Cause |
|-------|-----------|-------|
| initrd | ~45s | `dev-tpm0.device` and `dev-tpmrm0.device` timeout |
| userspace | ~45s | Same devices, timeout again after pivot-root |
| **Total wasted** | **~90s** | Devices that will never appear (no fTPM in Linux for Snapdragon X) |

**Fix:**

```bash
# Mask in userspace
sudo systemctl mask dev-tpm0.device dev-tpmrm0.device

# Remove TPM and NFS modules from initrd (unnecessary on laptop)
echo 'omit_dracutmodules+=" tpm2-tss systemd-pcrphase "' | sudo tee /etc/dracut.conf.d/no-tpm.conf
echo 'omit_dracutmodules+=" nfs "' | sudo tee /etc/dracut.conf.d/no-nfs.conf

# Add TPM mask to kernel cmdline for initrd (already in /etc/default/grub)
# rd.systemd.mask=dev-tpm0.device rd.systemd.mask=dev-tpmrm0.device

# Regenerate
sudo grub2-mkconfig -o /boot/grub2/grub.cfg
sudo dracut --force
```

| Before | After |
|--------|-------|
| 1min 47s total | **7.8s total** |
| 46s initrd | 2.3s initrd |
| 60s userspace | 5s userspace |

### 9. Terminal Flicker Fix

LD_PRELOAD fix for GTK4/turnip Vulkan descriptor pool fragmentation.

**Problem:** GTK4's Vulkan renderer (GSK) creates descriptor pools with `maxSets=100` and `VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT`. The freedreno `turnip` driver (`tu_descriptor_set.cc:649`) fragments these small pools under rapid alloc/free cycles from terminal text rendering. After ~30 minutes, pools are exhausted — the allocation loop iterates all fragmented pools, generating hundreds of `VK_ERROR_OUT_OF_POOL_MEMORY` errors per minute and causing visible flicker.

**Root cause** (in GTK4 `gsk/gpu/gskvulkandevice.c`):
```c
// GSK creates pools with only 100 sets — too small for sustained rendering
.flags = VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT,  // enables fragmentation
.maxSets = 100,
.descriptorCount = 100,
```

**Fix:** LD_PRELOAD library that intercepts `vkCreateDescriptorPool` and increases pool sizes by 50x (100 → 5000 sets), eliminating fragmentation:

```bash
# Build
gcc -shared -fPIC -o vk_pool_fix.so vk_pool_fix.c -ldl

# Install library
sudo cp vk_pool_fix.so /usr/local/lib64/vk_pool_fix.so

# Create wrapper script (needed because Ptyxis uses D-Bus activation,
# which ignores Exec= in .desktop and LD_PRELOAD env vars)
sudo tee /usr/local/bin/ptyxis-fixed << 'WRAPPER'
#!/bin/sh
export LD_PRELOAD=/usr/local/lib64/vk_pool_fix.so
exec /usr/bin/ptyxis "$@"
WRAPPER
sudo chmod +x /usr/local/bin/ptyxis-fixed

# Override D-Bus service (this is what actually launches Ptyxis)
mkdir -p ~/.local/share/dbus-1/services
cat > ~/.local/share/dbus-1/services/org.gnome.Ptyxis.service << 'DBUS'
[D-BUS Service]
Name=org.gnome.Ptyxis
Exec=/usr/local/bin/ptyxis-fixed --gapplication-service
DBUS

# Override desktop entry (for manual launches)
mkdir -p ~/.local/share/applications
cp /usr/share/applications/org.gnome.Ptyxis.desktop ~/.local/share/applications/
sed -i 's|^Exec=ptyxis|Exec=/usr/local/bin/ptyxis-fixed|g' \
    ~/.local/share/applications/org.gnome.Ptyxis.desktop
update-desktop-database ~/.local/share/applications/
```

> **Important**: Ptyxis uses `DBusActivatable=true` — the D-Bus service file override is required, not just the desktop entry. Without it, systemd launches `/usr/bin/ptyxis` directly, bypassing LD_PRELOAD.

**Result:** 952 errors → 0 errors. Vulkan renderer preserved (better performance than GL fallback).

| Property | Value |
|----------|-------|
| **Affected app** | Ptyxis (GNOME Terminal) and any GTK4 Vulkan app on turnip |
| **Root cause** | GTK4 GSK `maxSets=100` + turnip pool fragmentation |
| **Error** | `VK_ERROR_OUT_OF_POOL_MEMORY` at `tu_descriptor_set.cc:649` |
| **Fix** | `vk_pool_fix.so` — increases pool size 50x via LD_PRELOAD |
| **Alternative** | `GSK_RENDERER=ngl` (forces GL, avoids Vulkan entirely) |

> **Note**: This is an interaction bug between GTK4 and Mesa/turnip — GTK4 creates pools too small for turnip's linear allocator. May be fixed upstream in future GTK4 or Mesa releases. To check: remove the LD_PRELOAD and monitor with `journalctl -f | grep VK_ERROR`.

### 10. Battery Time Extension

GNOME Shell extension to show battery time remaining on hover.

**Problem:** GNOME 50 shows battery percentage but not time remaining. No existing extension supports GNOME 50 yet. UPower's instantaneous estimate fluctuates with power draw changes (e.g., brightness adjustments).

**Fix:** Custom GNOME Shell extension `battery-time@wifiteste`:

```bash
bash install-battery-time-ext.sh
# Logout and login (Wayland requires session restart for new extensions)
```

| Property | Value |
|----------|-------|
| **Display** | Hover over battery icon → `4:12` (hours:minutes) |
| **Estimation** | Weighted rolling average (30 samples × 30s = 15min window) |
| **Data source** | sysfs `/sys/class/power_supply/qcom-battmgr-bat/` |
| **Updates** | Every 30 seconds |
| **States** | Discharging (time remaining) and charging (time to full) |

### 11. Touchpad Right-Click Fix

gsettings `click-method` from `fingers` to `areas`.

**Problem:** The ELAN touchpad (04F3:3313) is a clickpad (`INPUT_PROP_BUTTONPAD`) — a single physical button under the entire pad surface, reporting only `BTN_LEFT` at the kernel level. GNOME defaults to `click-method: fingers` (2-finger click = right-click), but area-based clicking (bottom-right corner = right-click) is the expected behavior.

**Fix:**

```bash
gsettings set org.gnome.desktop.peripherals.touchpad click-method 'areas'
```

| Property | Value |
|----------|-------|
| **Touchpad** | ELAN I2C HID, VID `0x04f3`, PID `0x3313` |
| **I2C bus** | 1 (`b80000.i2c`) |
| **I2C address** | `0x15` |
| **Type** | Clickpad (`INPUT_PROP_BUTTONPAD`) — single physical button |
| **Multi-touch** | 5 slots (`ABS_MT_SLOT` max 4) |
| **Resolution** | 3905×2382 @ 31 units/mm (126×77mm) |
| **Fix** | `click-method: areas` — bottom-left = left click, bottom-right = right click |

---

## System Configuration Summary

### Files modified on the system

```
/etc/default/grub
    GRUB_CMDLINE_LINUX_DEFAULT="quiet rhgb clk_ignore_unused pd_ignore_unused
        rd.systemd.mask=dev-tpm0.device rd.systemd.mask=dev-tpmrm0.device"

/etc/dracut.conf.d/
    wcn-regulator-fix.conf     → force_drivers+=" wcn_regulator_fix "
    vivobook-kbd-fix.conf      → force_drivers+=" vivobook_kbd_fix "
    qcom-adsp-firmware.conf    → install_items+=" qcadsp8380.mbn adsp_dtbs.elf ... "
    qcom-gpu-firmware.conf     → install_items+=" gen71500_sqe.fw.xz gen71500_gmu.bin.xz ... "
    no-tpm.conf                → omit_dracutmodules+=" tpm2-tss systemd-pcrphase "
    no-nfs.conf                → omit_dracutmodules+=" nfs "

/etc/modules-load.d/
    wcn-regulator-fix.conf     → wcn_regulator_fix
    vivobook-kbd-fix.conf      → vivobook_kbd_fix
    vivobook-bl-fix.conf       → vivobook_bl_fix
    vivobook-hotkey-fix.conf   → vivobook_hotkey_fix

/usr/src/
    wcn-regulator-fix-1.0/     → DKMS module source
    vivobook-kbd-fix-1.0/      → DKMS module source
    vivobook-bl-fix-1.0/       → DKMS module source
    vivobook-hotkey-fix-1.0/   → DKMS module source

/usr/local/lib64/
    vk_pool_fix.so             → Vulkan pool fix library

/usr/local/bin/
    ptyxis-fixed               → Wrapper script with LD_PRELOAD

~/.local/share/gnome-shell/extensions/battery-time@wifiteste/
    extension.js               → Battery time GNOME extension
    metadata.json

~/.local/share/dbus-1/services/
    org.gnome.Ptyxis.service   → D-Bus override for LD_PRELOAD

~/.local/share/applications/
    org.gnome.Ptyxis.desktop   → Desktop entry override

/usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/
    qcadsp8380.mbn, adsp_dtbs.elf, adspr.jsn, adsps.jsn, adspua.jsn, battmgr.jsn
    qcdxkmsucpurwa.mbn

/lib/firmware/ath11k/WCN6855/hw2.1/
    board.bin
```

### Disable Auto Updates

Prevents kernel/mesa updates from breaking the custom setup:

```bash
sudo systemctl disable --now dnf-makecache.timer
sudo systemctl mask packagekit.service
gsettings set org.gnome.software download-updates false
gsettings set org.gnome.software download-updates-notify false
```

### Protect Against Kernel Updates

Run the post-install protection script to ensure new kernels get the correct DTB and boot parameters:

```bash
sudo bash post-install-protect.sh
```

See [GUIA-POS-INSTALACAO.md](GUIA-POS-INSTALACAO.md) for details.

---

## Future Development

### Audio (priority 1)

The ADSP firmware boots successfully, but there is no codec node mapped in the DTB. The audio hardware uses WCD938x (headphone/speaker codec) and WSA883x (smart amplifier). Fixing this requires:

1. **Identify the codec I2C/SoundWire addresses** — probe I2C bus for WCD938x, check SoundWire bus for WSA883x
2. **Create a DKMS module** that registers the codec devices at the correct bus/address (same approach as the keyboard fix)
3. **Route ADSP → codec** via the audio DSP path (qcom_q6v5_pas → APR/GPR services)
4. Three unknown I2C devices on bus 4 (`0x43`, `0x5b`, `0x76`) may include audio codec components

### Camera (priority 2)

No driver support exists yet. Needs:

1. **Identify the camera sensor** — check I2C bus, ACPI, and Windows driver info
2. **Check if CCI (Camera Control Interface)** is mapped in the DTB
3. **Write or adapt a sensor driver** using the V4L2 subsystem
4. This likely requires upstream kernel work

### WiFi Calibration

Current WiFi works with a fallback `board.bin` from a similar WCN6855 variant. For optimal performance:

1. **Extract device-specific board data** from the Windows ath11k driver (subsystem `105b:e130`)
2. **Create a proper `board-2.bin`** entry for this specific hardware

### Upstream DTB

Submit Device Tree patches for the Vivobook X1407QA to the mainline Linux kernel:

1. **Create `x1p42100-asus-vivobook-x1407qa.dts`** based on the Zenbook A14 DTS
2. **Add all hardware mappings** discovered via these runtime fixes
3. **Submit to linux-arm-msm mailing list** for review
4. This would eventually eliminate the need for most DKMS modules

### Upstream Fixes

| Fix | Upstream status | Target kernel |
|-----|----------------|---------------|
| PCIe race condition | 15-patch series by Konrad Dybcio | ~6.21 |
| Zenbook A14 DTB | Patches by Alex Vinarskis | Merged in 6.19 |
| Vivobook X1407QA DTB | Not submitted yet | TBD |

---

## Scripts

| Script | Purpose |
|--------|---------|
| `setup-all.sh` | **Complete setup** — applies all 11 fixes in correct order |
| `prepare-fedora-snapdragon.sh` | Creates custom ISO with GRUB DTB menu + firmware |
| `build-v3-iso.sh` | Rebuilds ISO with firmware in correct path |
| `build-v4-iso.sh` | ISO with patched DTB (regulator fix) |
| `extract-qcom-firmware.sh` | Extracts firmware from Windows partition |
| `post-install-protect.sh` | Protects boot against kernel updates |
| `install-battery-time-ext.sh` | Installs GNOME Shell battery time extension |
| `vk_pool_fix.c` | Source for Vulkan descriptor pool fix |

## Known Issues

- **DTB override impossible** on INSYDE firmware — all hardware fixes must use kernel modules
- **Audio**: ADSP firmware present but no codec mapping in DTB
- **GPU**: Firmware must be in initramfs for early loading. SELinux may block `.xz` firmware (`setenforce 0` as workaround)
- **TPM**: No fTPM support in Linux for Snapdragon X — devices masked to avoid boot delay
- **3 unknown I2C devices** on bus 4: addresses `0x43`, `0x5b`, `0x76`

## Upstream References

- [Zenbook A14 patches](https://patchew.org/linux/20250523131605.6624-1-alex.vinarskis@gmail.com/) by Alex Vinarskis
- [PCIe pwrctrl fix](https://lkml.org/lkml/2026/1/15/415) — 15-patch series targeting kernel ~6.21
- [linux-x1e80100-zenbook-a14](https://github.com/alexVinarskis/linux-x1e80100-zenbook-a14) — Custom kernel repo

## License

Scripts are MIT. Qualcomm firmware is proprietary — extract from your own Windows installation.
