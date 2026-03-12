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
| **WiFi** | Qualcomm FastConnect 6900 (WCN785x) - ath12k driver |
| **Bluetooth** | FastConnect 6900 (UART) |
| **NPU** | Hexagon 45 TOPS |
| **BIOS** | _ASUS_ - 8380 |

## Current Status

| Feature | Status | Notes |
|---------|--------|-------|
| **Boot** | :white_check_mark: Working | Fedora 44 Beta boots with custom GRUB + Zenbook A14 DTB |
| **Display** | :white_check_mark: Working | Via Adreno X1-45 GPU |
| **USB ports** | :white_check_mark: Working | USB-C, USB-A, HDMI |
| **NVMe** | :white_check_mark: Working | PCIe 4.0 detected and functional |
| **USB Keyboard** | :white_check_mark: Working | External USB keyboards work fine |
| **WiFi** | :construction: Needs firmware | FastConnect 6900 - firmware extracted from Windows |
| **Bluetooth** | :construction: Needs firmware | FastConnect 6900 UART |
| **GPU acceleration** | :construction: Needs firmware | Adreno X1-45, firmware extracted |
| **Built-in keyboard** | :x: Not working | Requires custom DTB (I2C/GPIO mapping) |
| **Built-in touchpad** | :x: Not working | Same DTB issue as keyboard |
| **Audio** | :x: Not working | ADSP firmware loaded but no codec mapping in DTB |
| **Camera** | :x: Not working | No driver support yet |

## The Problem

The Fedora 44 Beta aarch64 ISO **does not boot** on this laptop out of the box because:

1. **No DTB exists** for the Snapdragon X X1-26-100 / Vivobook 14 X1407Q in kernel 6.19
2. **Fedora's auto-DTB** (via systemd-stub) fails to select a compatible DTB
3. **Firmware is proprietary** and must be extracted from Windows (which has BitLocker enabled)

## The Solution

We built a custom Fedora 44 ISO that:

1. **Custom GRUB** with manual DTB selection menu (Zenbook A14 DTB works - same die "Purwa")
2. **Injected Qualcomm firmware** extracted from Windows into the squashfs
3. **Correct firmware paths** matching what the kernel expects for the Zenbook A14 DTB

### Boot Configuration

```
set snapdragon_params="clk_ignore_unused pd_ignore_unused"
devicetree ($root)/boot/aarch64/loader/dtb/qcom/x1p42100-asus-zenbook-a14.dtb
```

The GRUB menu offers multiple DTB options:
- **Zenbook A14** (default - works!) - `x1p42100-asus-zenbook-a14.dtb`
- **CRD** - `x1p42100-crd.dtb`
- **Vivobook S15** - `x1e80100-asus-vivobook-s15.dtb`
- **Auto DTB** - Let systemd pick (doesn't work on this model)
- **Troubleshooting** - Boot with extra debug params

## Scripts

### `prepare-fedora-snapdragon.sh`

Main script that takes the original Fedora 44 Beta ISO and creates a modified version with:
- Custom GRUB configuration with Snapdragon X kernel params
- DTB selection menu
- Firmware extraction helper bundled in the ISO

```bash
./prepare-fedora-snapdragon.sh
```

### `build-v3-iso.sh`

Takes the v2 ISO (which had firmware in the wrong path) and rebuilds it with firmware in the correct location:

```
/usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/
```

This path is determined by the DTB being used (`x1p42100-asus-zenbook-a14`), confirmed via upstream kernel patches.

```bash
sudo ./build-v3-iso.sh
```

### `extract-qcom-firmware.sh`

Post-boot script to extract Qualcomm firmware from the Windows partition (if accessible). Run this after booting Fedora on the laptop.

```bash
sudo ./extract-qcom-firmware.sh
```

### `fix.sh`

Quick one-liner firmware extractor for emergency use.

## Firmware Details

### Extracted from Windows (144 files total)

The firmware was extracted from Windows via PowerShell (see [GUIA-EXTRAIR-FIRMWARE.md](GUIA-EXTRAIR-FIRMWARE.md)) because BitLocker prevents mounting the Windows partition from Linux.

### Device-specific firmware path (24 files)

The kernel with `x1p42100-asus-zenbook-a14` DTB expects firmware at:
```
/usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/
```

**Critical (remoteproc):**
| File | Purpose |
|------|---------|
| `qcdxkmsucpurwa.mbn` | GPU (Adreno X1-45, Purwa variant) |
| `qcadsp8380.mbn` + `adsp_dtbs.elf` | Audio DSP |
| `qccdsp8380.mbn` + `cdsp_dtbs.elf` | Compute DSP |
| `adspr.jsn`, `adsps.jsn`, `adspua.jsn` | ADSP configs |
| `battmgr.jsn` | Battery manager |
| `cdspr.jsn` | CDSP config |
| `wpssr.jsn` | WPSS config |

**GPU extras:**
| File | Purpose |
|------|---------|
| `qcdxkmsuc8380.mbn` | GPU microcode |
| `qcdxkmbase8380*.bin` (8 variants) | GPU base firmware |
| `qcdxkmext8380_CRD.bin` | GPU extension |
| `qcav1e8380.mbn` | AV1 encoder |
| `qcvss8380.mbn`, `qcvss8380_pa.mbn` | Video subsystem |

### WiFi firmware (ath12k/WCN7850/hw2.0/)

- `amss.bin`, `board-2.bin`, `m3.bin`, `m320.bin`, `regdb.bin`
- `bdwlan_wcn785x_2p0_ncm825_UX3407Q.elf` (Vivobook-specific)
- `bdwlan_wcn685x_2p1_nfa765a_AS_SA_X14QA.elf` (X14QA-specific)
- 14 bdwlan files total

### Bluetooth firmware

- `hmtbtfw20.tlv`, `hmtnv20.bin` + variants
- `hpbtfw21.tlv`, `hpnv21*.b*`

## ISO Versions

| Version | Description | Status |
|---------|-------------|--------|
| v1 (`Fedora-44-VivoBook-X1407Q.iso`) | First attempt - custom GRUB, no firmware injection | Boots but no peripherals |
| v2 (`Fedora-44-VivoBook-v2.iso`) | Added firmware but in wrong path (`/qcom/` root) | Firmware not loaded |
| **v3** (`Fedora-44-VivoBook-v3.iso`) | Firmware in correct device path | **Latest - needs testing** |

## How to Reproduce

### Prerequisites

- Fedora 44 Beta aarch64 ISO
- Access to Windows on the Vivobook (for firmware extraction)
- USB drive (8GB+)
- Linux machine with `xorriso` and `squashfs-tools`

### Step 1: Extract firmware from Windows

Boot into Windows on the Vivobook and run the PowerShell commands from [GUIA-EXTRAIR-FIRMWARE.md](GUIA-EXTRAIR-FIRMWARE.md) to copy firmware to a USB drive.

### Step 2: Build the ISO

```bash
# First build (creates v2 with custom GRUB + firmware)
./prepare-fedora-snapdragon.sh

# Fix firmware paths (creates v3)
sudo ./build-v3-iso.sh
```

### Step 3: Flash to USB

```bash
sudo dd if=Fedora-44-VivoBook-v3.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

### Step 4: Boot

1. Enter BIOS (F2 at boot)
2. Disable Secure Boot
3. Enable USB boot
4. Boot from USB (F12 at boot)
5. Select "Zenbook A14 DTB" from GRUB menu

## DTB Situation

The Snapdragon X X1-26-100 ("Purwa" die) is very new and has **no dedicated DTB** in the mainline kernel as of 6.19. The closest match is:

- `x1p42100-asus-zenbook-a14.dtb` - Same die (Purwa), same manufacturer (ASUS), boots successfully

The built-in keyboard/touchpad don't work because the Zenbook A14's DTB maps different I2C/GPIO peripherals than the Vivobook 14. A custom DTB for the X1407Q would be needed upstream.

### Relevant upstream work

- [Zenbook A14 patches](https://patchew.org/linux/20250523131605.6624-1-alex.vinarskis@gmail.com/) by Alex Vinarskis
- [linux-x1e80100-zenbook-a14](https://github.com/alexVinarskis/linux-x1e80100-zenbook-a14) - Custom kernel repo
- [qcom-firmware-updater](https://github.com/alejandroqh/qcom-firmware-updater) - Firmware management tool
- [linux-firmware-qcom](https://archlinux.org/packages/core/any/linux-firmware-qcom/files/) - Arch package

## Technical Notes

- Windows has BitLocker enabled - firmware must be extracted from Windows itself, not from Linux
- Firmware was extracted via PowerShell and injected into the ISO's squashfs
- `UX3407QA` (X1P) vs `UX3407RA` (X1E): only ADSP firmware differs; CDSP and GPU are identical
- `qcom-firmware-extract` (Debian tool) can automate extraction but requires Windows partition access
- Bash gotcha: `((var++))` with var=0 returns exit code 1 under `set -e` - use `var=$((var + 1))` instead

## Next Steps

1. **Test v3 ISO** - Write to USB and boot on the Vivobook
2. **Check dmesg** - Verify firmware loads from the correct path
3. **Custom DTB** - Create a DTB for the X1407Q (for keyboard/touchpad support)
4. **Upstream contribution** - Submit DTB patches to the Linux kernel
5. **Wait for Fedora 44 final** (April 2026) - May have better out-of-the-box support

## Contributing

If you have an ASUS Vivobook 14 X1407Q or similar Snapdragon X laptop and want to help:

1. Test the ISO and report results
2. Help map I2C/GPIO peripherals for a custom DTB
3. Share `dmesg` and `lspci` output from successful boots

## License

Scripts are provided as-is under MIT license. Qualcomm firmware files are proprietary and NOT included in this repository - you must extract them from your own Windows installation.
