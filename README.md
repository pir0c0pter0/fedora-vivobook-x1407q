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
| **NPU** | Hexagon 45 TOPS |
| **BIOS** | _ASUS_ - 8380 |

## Current Status

| Feature | Status | Notes |
|---------|--------|-------|
| **Boot** | :white_check_mark: Working | Fedora 44 Beta boots with custom GRUB + Zenbook A14 DTB |
| **Display** | :white_check_mark: Working | Via Adreno X1-45 GPU |
| **Touchpad** | :white_check_mark: Working | Built-in touchpad works out-of-the-box with Zenbook A14 DTB (since v1) |
| **USB ports** | :white_check_mark: Working | USB-C, USB-A, HDMI |
| **NVMe** | :white_check_mark: Working | PCIe 4.0 detected and functional |
| **USB Keyboard** | :white_check_mark: Working | External USB keyboards work fine |
| **WiFi** | :construction: Testing v4 fix | WCN6855 (ath11k_pci) - regulators disabled during boot; v4 DTB adds `regulator-always-on` + GRUB fix to load it |
| **Battery** | :x: Not working | PMIC glink failures - DTB mismatch on power connector mapping |
| **Built-in keyboard** | :x: Not working | Requires custom DTB (I2C/GPIO mapping) |
| **Bluetooth** | :white_check_mark: Working | FastConnect 6900 UART - works out-of-the-box since v1 (no extra firmware needed) |
| **GPU acceleration** | :construction: Untested | Adreno X1-45, firmware injected |
| **Audio** | :x: Not working | ADSP firmware present but no codec mapping in DTB |
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

### WiFi firmware (ath11k/WCN6855/hw2.x/)

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
| v1 (`Fedora-44-VivoBook-X1407Q.iso`) | First attempt - custom GRUB, no firmware injection | Boots, touchpad + Bluetooth work |
| v2 (`Fedora-44-VivoBook-v2.iso`) | Added firmware but in wrong path (`/qcom/` root) | Firmware not loaded |
| v3 (`Fedora-44-VivoBook-v3.iso`) | Firmware in correct device path | Boots, touchpad+BT work, WiFi/keyboard/battery not loading |
| **v4** (`Fedora-44-VivoBook-v4.iso`) | DTB patched: `regulator-always-on` on WCN regulators | GRUB failed to load DTB from EFI partition (missing `insmod fat`) - fix applied |
| **v4.1** (USB hotfix) | GRUB config fixed: explicit `(hd0,gpt2)` + `insmod fat` for EFI partition | **Testing** - DTB now loads correctly from EFI partition |

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

## Debugging Findings (v3 test - 2026-03-12)

### WiFi not loading
```
VREG_WCN_3P3: disabling
VREG_WCN_0P95: disabling
VREG_WCN_1P9: disabling
ath11k_pci 0004:01:00.0: pci device id mismatch: 0xffff 0x1103
ath11k_pci 0004:01:00.0: probe with driver ath11k_pci failed with error -5
```
**Root cause:** Linux regulator framework disables WCN voltage regulators (no active consumer claims them in time). WiFi chip loses power, PCI reads return `0xffff`.

**Fix (v4):** Added `regulator-always-on` to `VREG_WCN_3P3`, `VREG_WCN_0P95`, `VREG_WCN_1P9` in the DTB.

### GRUB failed to load WiFi-fix DTB (v4 test - 2026-03-12)

The v4 DTB with `regulator-always-on` was correctly placed on the USB EFI partition (sda2, FAT32), but GRUB silently failed to load it. The live FDT (`/sys/firmware/fdt`) did not contain the fix — regulators were still being disabled.

**Root cause:** The GRUB config used `search --file --set=efipart /x1p42100-asus-zenbook-a14-wifi-fix.dtb` to find the EFI partition containing the fixed DTB. However, the `fat` filesystem module was not loaded at that point, so GRUB could not read the FAT32 partition. The `search` command failed silently, `$efipart` remained empty, and the `devicetree ($efipart)/...` command fell back to the original DTB from the ISO (iso9660 partition).

**Fix (v4.1):** Updated GRUB config on the EFI partition to:
1. Load `insmod fat` and `insmod part_gpt` before referencing the EFI partition
2. Use explicit `set efipart=(hd0,gpt2)` instead of `search --file`

```grub
insmod fat
insmod part_gpt
set efipart=(hd0,gpt2)

menuentry "Fedora 44 - Vivobook X1407Q - WiFi Fix DTB" {
    devicetree ($efipart)/x1p42100-asus-zenbook-a14-wifi-fix.dtb
}
```

**Verification after reboot:**
```bash
sudo dtc -I dtb -O dts /sys/firmware/fdt | grep -A5 "regulator-wcn-0p95"
# Should show: regulator-always-on;
```

### GPU firmware
```
msm_dpu ae01000.display-controller: Direct firmware load for qcom/gen71500_sqe.fw failed with error -2
[drm:adreno_request_fw [msm]] *ERROR* failed to load gen71500_sqe.fw
```
Files exist as `.xz` compressed (`gen71500_sqe.fw.xz`, `gen71500_gmu.bin.xz`). SELinux was blocking `firmware_load`. After `setenforce 0`, display works.

### Battery / PMIC
```
qcom_pmic_glink pmic-glink: Failed to create device link (0x180) with supplier ...
```
PMIC glink connector mapping differs between Zenbook A14 and Vivobook 14. Needs custom DTB.

### WiFi hardware details
- **Chip:** Qualcomm QCNFA765 (WCN6855) - NOT WCN7850 as initially assumed
- **PCI ID:** `17cb:1103` at bus `0004:01:00.0`
- **Driver:** `ath11k_pci` (not ath12k)
- **PMU:** `qcom,wcn6855-pmu` in DTB
- **Firmware path:** `ath11k/WCN6855/hw2.x/` (not ath12k/WCN7850)

## Technical Notes

- Windows has BitLocker enabled - firmware must be extracted from Windows itself, not from Linux
- Firmware was extracted via PowerShell and injected into the ISO's squashfs
- `UX3407QA` (X1P) vs `UX3407RA` (X1E): only ADSP firmware differs; CDSP and GPU are identical
- `qcom-firmware-extract` (Debian tool) can automate extraction but requires Windows partition access
- Bash gotcha: `((var++))` with var=0 returns exit code 1 under `set -e` - use `var=$((var + 1))` instead
- GRUB gotcha: `search --file` cannot find files on FAT32 partitions unless `insmod fat` is loaded first; the search fails silently and the variable remains unset

## Next Steps

1. **Reboot with v4.1 GRUB fix** - Verify DTB with `regulator-always-on` is loaded and WiFi powers up
2. **Test WiFi** - Check if `ath11k_pci` probes successfully and `wlan0` appears
3. **Custom DTB** - Create a DTB for the X1407Q (for keyboard/battery support)
4. **Upstream contribution** - Submit DTB patches to the Linux kernel
5. **Wait for Fedora 44 final** (April 2026) - May have better out-of-the-box support

## Contributing

If you have an ASUS Vivobook 14 X1407Q or similar Snapdragon X laptop and want to help:

1. Test the ISO and report results
2. Help map I2C/GPIO peripherals for a custom DTB
3. Share `dmesg` and `lspci` output from successful boots

## License

Scripts are provided as-is under MIT license. Qualcomm firmware files are proprietary and NOT included in this repository - you must extract them from your own Windows installation.
