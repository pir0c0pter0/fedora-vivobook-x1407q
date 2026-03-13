# Linux on ASUS Vivobook 14 X1407QA (Snapdragon X)

> Full Linux support for the ASUS Vivobook 14 X1407QA with Qualcomm Snapdragon X (X1-26-100) on Fedora 44 aarch64 — from zero to daily driver.

## Hardware

| Component | Details |
|-----------|---------|
| **Model** | ASUS Vivobook 14 X1407QA |
| **SoC** | Qualcomm Snapdragon X X1-26-100 (8 cores, 2.97GHz, die "Purwa") |
| **GPU** | Adreno X1-45 (freedreno / Mesa) |
| **RAM** | 16GB LPDDR5X |
| **Storage** | NVMe PCIe 4.0 |
| **Display** | 14" 1920x1200 IPS, 60Hz |
| **WiFi** | Qualcomm QCNFA765 (WCN6855) — ath11k_pci |
| **Bluetooth** | FastConnect 6900 (UART) |
| **Battery** | 50Wh Li-ion (X321-42) |

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
| 10 | **Battery time in panel** | GNOME Shell extension `battery-time@wifiteste` | Weighted rolling average, shows `43% 4:12` in top bar |

**5 custom kernel modules**, **1 Vulkan driver fix**, **1 GNOME extension**, **0 kernel patches** — everything done at runtime via DKMS/LD_PRELOAD because the INSYDE UEFI blocks DTB overrides.

## Current Status

| Feature | Status | Notes |
|---------|--------|-------|
| **Boot** | :white_check_mark: Working | Fedora 44 via Zenbook A14 DTB |
| **Boot time** | :white_check_mark: 8s | Was ~2min (see [Boot Time Fix](#boot-time-fix)) |
| **Display** | :white_check_mark: Working | GPU firmware in initramfs (see [GPU Firmware Fix](#gpu-firmware-fix)) |
| **WiFi** | :white_check_mark: Working | DKMS module + board.bin (see [WiFi Fix](#wifi-fix)) |
| **Bluetooth** | :white_check_mark: Working | FastConnect 6900 UART — out-of-the-box |
| **Keyboard** | :white_check_mark: Working | DKMS module (see [Keyboard Fix](#keyboard-fix)) |
| **Touchpad** | :white_check_mark: Working | Out-of-the-box with Zenbook DTB |
| **Battery** | :white_check_mark: Working | ADSP firmware in initramfs (see [Battery Fix](#battery-fix)) |
| **Brightness** | :white_check_mark: Working | DKMS module (see [Brightness Fix](#brightness-fix)) |
| **Brightness keys** | :white_check_mark: Working | DKMS module (see [Hotkey Fix](#hotkey-fix)) |
| **USB ports** | :white_check_mark: Working | USB-C, USB-A, HDMI |
| **NVMe** | :white_check_mark: Working | PCIe 4.0 |
| **Audio** | :x: Not working | ADSP codec not mapped in DTB |
| **Camera** | :x: Not working | No driver support |

## Still TODO

1. **Audio** — ADSP boots successfully, but no codec node mapped in DTB. Needs WCD938x/WSA883x codec routing
2. **Identify I2C devices** — 3 unknown devices on bus 4: `0x43`, `0x5b`, `0x76`
3. **WiFi calibration** — Extract device-specific board data from Windows driver for optimal performance
4. **Upstream DTB** — Submit Device Tree patches for Vivobook X1407QA to mainline kernel

---

## The Challenge

Fedora 44 aarch64 **does not boot** out of the box — there is no DTB for this laptop in kernel 6.19. The closest match is the **Zenbook A14** (`x1p42100-asus-zenbook-a14.dtb`) which shares the same Qualcomm "Purwa" die and ASUS manufacturer, but maps completely different peripherals.

The INSYDE UEFI firmware provides the DTB and **cannot be overridden** from GRUB on aarch64 (7 methods tested: BLS devicetree, GRUB fdt module, dtbloader.efi, EFI stub — all fail). This means every hardware difference must be fixed via **runtime kernel modules**, not DTB patches.

## The Approach

1. **Custom Fedora ISO** with GRUB DTB selection menu + Qualcomm firmware injected into squashfs
2. **5 DKMS kernel modules** to fix hardware that differs from the Zenbook A14 at runtime
3. **Firmware extracted from Windows** via PowerShell (BitLocker prevents Linux access)
4. **initramfs tuning** for firmware loading and boot time optimization

---

## Fixes

### WiFi Fix

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

### Keyboard Fix

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

### Battery Fix

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

### Brightness Fix

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

### Hotkey Fix

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

### GPU Firmware Fix

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

### Boot Time Fix

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

# Add TPM mask to kernel cmdline for initrd
# In /etc/grub.d/08_vivobook, add to linux line:
#   rd.systemd.mask=dev-tpm0.device rd.systemd.mask=dev-tpmrm0.device

# Regenerate
sudo grub2-mkconfig -o /boot/grub2/grub.cfg
sudo dracut --force
```

| Before | After |
|--------|-------|
| 1min 47s total | **7.8s total** |
| 46s initrd | 2.3s initrd |
| 60s userspace | 5s userspace |

---

## System Configuration

### GRUB

Custom GRUB entry at `/etc/grub.d/08_vivobook` that loads the correct DTB and all kernel parameters:

```bash
sudo cat > /etc/grub.d/08_vivobook << 'SCRIPT'
#!/usr/bin/sh
cat << 'GRUBENTRY'
menuentry 'Fedora 6.19.6 - ASUS Vivobook' --class fedora {
    insmod fdt
    search --no-floppy --fs-uuid --set=root <your-boot-uuid>
    linux /vmlinuz-6.19.6-300.fc44.aarch64 root=UUID=<your-root-uuid> ro rootflags=subvol=root quiet rhgb clk_ignore_unused pd_ignore_unused rd.driver.pre=wcn_regulator_fix rd.systemd.mask=dev-tpm0.device rd.systemd.mask=dev-tpmrm0.device
    initrd /initramfs-6.19.6-300.fc44.aarch64.img
    devicetree /dtb/qcom/x1p42100-asus-vivobook-x1407qa.dtb
}
GRUBENTRY
SCRIPT
chmod +x /etc/grub.d/08_vivobook
sudo grub2-mkconfig -o /boot/grub2/grub.cfg
sudo grub2-set-default "Fedora 6.19.6 - ASUS Vivobook"
```

| Parameter | Purpose |
|-----------|---------|
| `clk_ignore_unused` | Prevents kernel from disabling Qualcomm clocks needed by firmware |
| `pd_ignore_unused` | Prevents kernel from disabling power domains needed by firmware |
| `rd.driver.pre=wcn_regulator_fix` | Loads WiFi regulator fix before PCIe scan |
| `rd.systemd.mask=dev-tpm0.device` | Skips TPM wait in initrd |
| `rd.systemd.mask=dev-tpmrm0.device` | Skips TPM resource manager wait in initrd |
| `devicetree` | Loads Vivobook-specific DTB instead of UEFI-provided Zenbook DTB |

### Disable Auto Updates

Prevents kernel/mesa updates from breaking the custom setup:

```bash
sudo systemctl disable --now dnf-makecache.timer
sudo systemctl mask packagekit.service
gsettings set org.gnome.software download-updates false
gsettings set org.gnome.software download-updates-notify false
```

### Firmware

Firmware must be extracted from Windows (BitLocker enabled). See [GUIA-EXTRAIR-FIRMWARE.md](GUIA-EXTRAIR-FIRMWARE.md).

| Path | Contents |
|------|----------|
| `/usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/` | ADSP, GPU, ZAP shader |
| `/lib/firmware/ath11k/WCN6855/hw2.1/` | WiFi board data |

### Scripts

| Script | Purpose |
|--------|---------|
| `prepare-fedora-snapdragon.sh` | Creates custom ISO with GRUB DTB menu + firmware |
| `build-v3-iso.sh` | Rebuilds ISO with firmware in correct path |
| `build-v4-iso.sh` | ISO with patched DTB (regulator fix) |
| `extract-qcom-firmware.sh` | Extracts firmware from Windows partition |
| `post-install-protect.sh` | Protects boot against kernel updates |
| `vk_pool_fix.c` | LD_PRELOAD fix for GTK4/turnip Vulkan descriptor pool fragmentation |
| `install-battery-time-ext.sh` | Installs GNOME Shell battery time remaining extension |

## Known Issues

- **DTB override impossible** on INSYDE firmware — all hardware fixes must use kernel modules
- **Audio**: ADSP firmware present but no codec mapping in DTB
- **GPU**: Firmware must be in initramfs for early loading. SELinux may block `.xz` firmware (`setenforce 0` as workaround)
- **Terminal flicker (Ptyxis/Vulkan)**: :white_check_mark: **Fixed** — GTK4/turnip descriptor pool fragmentation, solved via LD_PRELOAD (see [Terminal Flicker Fix](#terminal-flicker-fix))
- **TPM**: No fTPM support in Linux for Snapdragon X — devices masked to avoid boot delay
- **3 unknown I2C devices** on bus 4: addresses `0x43`, `0x5b`, `0x76`

### Terminal Flicker Fix

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

# Install
sudo cp vk_pool_fix.so /usr/local/lib64/vk_pool_fix.so

# Apply to Ptyxis
mkdir -p ~/.local/share/applications
cp /usr/share/applications/org.gnome.Ptyxis.desktop ~/.local/share/applications/
sed -i 's|^Exec=ptyxis|Exec=env LD_PRELOAD=/usr/local/lib64/vk_pool_fix.so ptyxis|g' \
    ~/.local/share/applications/org.gnome.Ptyxis.desktop
update-desktop-database ~/.local/share/applications/
```

**Result:** 952 errors → 0 errors. Vulkan renderer preserved (better performance than GL fallback).

| Property | Value |
|----------|-------|
| **Affected app** | Ptyxis (GNOME Terminal) and any GTK4 Vulkan app on turnip |
| **Root cause** | GTK4 GSK `maxSets=100` + turnip pool fragmentation |
| **Error** | `VK_ERROR_OUT_OF_POOL_MEMORY` at `tu_descriptor_set.cc:649` |
| **Fix** | `vk_pool_fix.so` — increases pool size 50x via LD_PRELOAD |
| **Alternative** | `GSK_RENDERER=ngl` (forces GL, avoids Vulkan entirely) |
| **Scope** | Per-app (desktop entry override) |

> **Note**: This is an interaction bug between GTK4 and Mesa/turnip — GTK4 creates pools too small for turnip's linear allocator. May be fixed upstream in future GTK4 or Mesa releases. To check: remove the LD_PRELOAD and monitor with `journalctl -f | grep VK_ERROR`.

### Battery Time Extension

GNOME Shell extension to show battery time remaining in the panel.

**Problem:** GNOME 50 shows battery percentage but not time remaining. No existing extension supports GNOME 50 yet. UPower's instantaneous estimate fluctuates with power draw changes (e.g., brightness adjustments).

**Fix:** Custom GNOME Shell extension `battery-time@wifiteste`:

```bash
bash install-battery-time-ext.sh
# Logout and login (Wayland requires session restart for new extensions)
```

| Property | Value |
|----------|-------|
| **Display** | `43% 4:12` (percentage + hours:minutes) |
| **Estimation** | Weighted rolling average (30 samples × 30s = 15min window) |
| **Data source** | sysfs `/sys/class/power_supply/qcom-battmgr-bat/` |
| **Updates** | Every 30 seconds |
| **States** | Discharging (time remaining) and charging (time to full) |

## Upstream References

- [Zenbook A14 patches](https://patchew.org/linux/20250523131605.6624-1-alex.vinarskis@gmail.com/) by Alex Vinarskis
- [PCIe pwrctrl fix](https://lkml.org/lkml/2026/1/15/415) — 15-patch series targeting kernel ~6.21
- [linux-x1e80100-zenbook-a14](https://github.com/alexVinarskis/linux-x1e80100-zenbook-a14) — Custom kernel repo

## License

Scripts are MIT. Qualcomm firmware is proprietary — extract from your own Windows installation.
