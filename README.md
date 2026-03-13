# Fedora on ASUS Vivobook 14 X1407Q (Snapdragon X)

> Running Linux on the ASUS Vivobook 14 X1407QA with Qualcomm Snapdragon X (X1-26-100)

## Hardware

| Component | Details |
|-----------|---------|
| **Model** | ASUS Vivobook 14 X1407QA |
| **SoC** | Qualcomm Snapdragon X X1-26-100 (8 cores, 2.97GHz, die "Purwa") |
| **GPU** | Adreno X1-45 |
| **RAM** | 16GB LPDDR5X |
| **Storage** | NVMe PCIe 4.0 |
| **WiFi** | Qualcomm QCNFA765 (WCN6855) - ath11k_pci driver |
| **Bluetooth** | FastConnect 6900 (UART) |

## Current Status

| Feature | Status | Notes |
|---------|--------|-------|
| **Boot** | :white_check_mark: Working | Fedora 44 via Zenbook A14 DTB (same die "Purwa") |
| **Display** | :white_check_mark: Working | Adreno X1-45 GPU |
| **Touchpad** | :white_check_mark: Working | Works out-of-the-box with Zenbook DTB |
| **USB ports** | :white_check_mark: Working | USB-C, USB-A, HDMI |
| **NVMe** | :white_check_mark: Working | PCIe 4.0 |
| **WiFi** | :white_check_mark: Working | DKMS module + board.bin (see [WiFi Fix](#wifi-fix)) |
| **Built-in keyboard** | :white_check_mark: Working | DKMS module (see [Keyboard Fix](#keyboard-fix)) |
| **Bluetooth** | :white_check_mark: Working | FastConnect 6900 UART - works out-of-the-box |
| **Battery** | :white_check_mark: Working | ADSP firmware in initramfs (see [Battery Fix](#battery-fix)) |
| **Brightness** | :white_check_mark: Working | DKMS module (see [Brightness Fix](#brightness-fix)) |
| **Audio** | :x: Not working | ADSP codec not mapped in DTB |
| **Brightness keys** | :x: Not working | Fn+F5/F6 keycodes registered but no events generated |
| **Camera** | :x: Not working | No driver support |

## The Problem

Fedora 44 aarch64 **does not boot** out of the box because there is no DTB for this laptop in kernel 6.19. The closest match is the **Zenbook A14** (`x1p42100-asus-zenbook-a14.dtb`) — same die, same manufacturer, boots successfully but maps different peripherals.

The INSYDE UEFI firmware provides the DTB and **cannot be overridden** from GRUB on aarch64 (7 methods tested: BLS devicetree, GRUB fdt module, dtbloader.efi, EFI stub — all fail). Hardware fixes must be done via **runtime kernel modules**.

## The Solution

1. **Custom Fedora ISO** with GRUB DTB selection menu + Qualcomm firmware injected into squashfs
2. **DKMS kernel modules** to fix hardware that differs from the Zenbook A14 at runtime
3. **Firmware extracted from Windows** via PowerShell (BitLocker prevents Linux access)

## WiFi Fix

DKMS module `wcn_regulator_fix` + custom `board.bin`.

### Problem

1. **PCIe race condition** (upstream bug, fix ~6.21): `qcom-pcie` scans before WiFi chip is powered on
2. **Regulator cleanup**: kernel disables WCN regulators ~30s after boot
3. **Missing board data**: no `board-2.bin` entry for subsystem `105b:e130`

### Fix

**Module** (`/usr/src/wcn-regulator-fix-1.0/`):
- Holds WCN regulators via consumer API
- Patches DT with `regulator-always-on`
- Schedules delayed PCIe bus rescans (device found ~6s after boot)

**Board data**: fallback `board.bin` from similar WCN6855 variant installed at `/lib/firmware/ath11k/WCN6855/hw2.1/board.bin`

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

## Keyboard Fix

DKMS module `vivobook_kbd_fix`.

### Problem

The Zenbook DTB maps the keyboard to `i2c@a80000:0x15`. On the Vivobook, it's on a completely different bus: `i2c@b94000` (bus 4) at address `0x3a`.

### Fix

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

## Battery Fix

ADSP firmware included in initramfs so `qcom-battmgr` can communicate with the PMIC.

### Problem

The `qcom-battmgr` driver registers power supply entries but all reads return `EAGAIN` ("Resource temporarily unavailable"). The ADSP remoteproc fails to boot at early boot because its firmware (`qcadsp8380.mbn`) is not in the initramfs — the rootfs isn't mounted yet at 1.7s when the kernel requests it.

### Fix

Include ADSP firmware in initramfs via dracut:

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

## Brightness Fix

DKMS module `vivobook_bl_fix`.

### Problem

The panel (Innolux N140JCA-ELK, IPS LCD) uses an external PWM signal for brightness control. The PMIC (PMK8550) has an LPG (Light Pulse Generator) channel pre-configured by firmware as a 12-bit PWM at 19.2 MHz, but the DTB node is `status = "disabled"`, so no kernel driver claims it. The PWM signal is not routed to the output GPIO, leaving the screen stuck at 100% brightness.

### Fix

**Module** (`/usr/src/vivobook-bl-fix-1.0/`):
- Finds PMK8550 regmap via DT child platform device lookup
- Enables DTEST3 routing: writes `0x01` to LPG TEST register E2 (offset 0xE2) via SEC_ACCESS unlock
- Writes PWM value + **PWM_SYNC** (offset 0x47) to latch values into hardware
- Registers `/sys/class/backlight/vivobook-backlight` (4096 levels)
- GNOME Quick Settings slider works automatically (may need logout/login after first install)
- On unload, restores DTEST3 to 0x00 (GPIO5 floats HIGH = 100% brightness, safe)

**Signal path**: `LPG ch0 PWM → DTEST3 bus → GPIO5 (DIG_OUT_SRC=0x04) → panel backlight`

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

## Scripts

| Script | Purpose |
|--------|---------|
| `prepare-fedora-snapdragon.sh` | Creates custom ISO with GRUB DTB menu + firmware |
| `build-v3-iso.sh` | Rebuilds ISO with firmware in correct path |
| `build-v4-iso.sh` | ISO with patched DTB (regulator fix) |
| `extract-qcom-firmware.sh` | Extracts firmware from Windows partition |
| `post-install-protect.sh` | Protects boot against kernel updates |

## Firmware

Firmware must be extracted from Windows (BitLocker enabled). See [GUIA-EXTRAIR-FIRMWARE.md](GUIA-EXTRAIR-FIRMWARE.md).

Key paths:
- Device-specific: `/usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/`
- WiFi: `/lib/firmware/ath11k/WCN6855/hw2.1/`

## Known Issues

- **DTB override impossible** on INSYDE firmware — all hardware fixes must use kernel modules
- **Battery**: Requires ADSP firmware in initramfs — without it, `qcom-battmgr` reads fail with EAGAIN
- **Audio**: ADSP firmware present but no codec mapping in DTB
- **GPU**: `setenforce 0` needed for firmware loading (SELinux blocks `.xz` firmware)
- **3 unknown I2C devices** on bus 4: addresses `0x43`, `0x5b`, `0x76`

## Upstream References

- [Zenbook A14 patches](https://patchew.org/linux/20250523131605.6624-1-alex.vinarskis@gmail.com/) by Alex Vinarskis
- [PCIe pwrctrl fix](https://lkml.org/lkml/2026/1/15/415) — 15-patch series targeting kernel ~6.21
- [linux-x1e80100-zenbook-a14](https://github.com/alexVinarskis/linux-x1e80100-zenbook-a14) — Custom kernel repo

## Next Steps

1. **Brightness keys** — Fn+F5/F6 keycodes registered in vivobook-kbd but no events generated
2. **Audio** — ADSP codec mapping (ADSP now boots, need codec node in DTB)
3. **Identify bus 4 devices** — 0x43, 0x5b, 0x76
4. **WiFi calibration** — Extract device-specific board data from Windows driver
5. **Upstream** — Submit DTB patches for Vivobook X1407QA

## License

Scripts are MIT. Qualcomm firmware is proprietary — extract from your own Windows installation.
