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
| **WiFi** | :white_check_mark: Working | WCN6855 (ath11k_pci) - fixed via DKMS kernel module + board.bin (see [WiFi Fix](#wifi-fix)) |
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

## WiFi Fix

WiFi is working on the installed system via a DKMS kernel module + custom board data file. No DTB override needed.

### The Problem

Two bugs prevent WiFi from working on kernel 6.19:

1. **PCIe PERST# race condition** (known upstream bug, fix targeting kernel ~6.21): the `qcom-pcie` driver deasserts PERST# and scans the bus **before** `pci-pwrctrl-pwrseq` powers on the WiFi chip. The PCIe link trains briefly (Gen.3 x1) but the chip isn't ready — `DLActive` never becomes true and config space reads return `0xFFFFFFFF`.

2. **Regulator cleanup**: the Linux regulator framework disables WCN voltage regulators ~30s after boot (no active consumer holds them), killing any chance of late enumeration.

3. **Missing board data**: the upstream `board-2.bin` has no entry for subsystem device `105b:e130` (QCNFA765 as used in this laptop).

### The Fix (2 parts)

#### Part 1: DKMS kernel module `wcn_regulator_fix`

A kernel module loaded early via initramfs that:

1. **Holds WCN regulators** via the regulator consumer API (`regulator_get` + `regulator_enable`), preventing the ~30s cleanup
2. **Patches the Device Tree** with `regulator-always-on` on all 3 WCN regulator nodes (belt and suspenders)
3. **Schedules delayed PCIe bus rescans** every 5s (up to 6 attempts) — the WiFi chip is found on the first attempt (~6s after boot)

```
[    0.847] wcn-wifi-fix: loading (regulator hold + delayed PCIe rescan)
[    0.847] wcn-wifi-fix: holding VREG_WCN_0P95 enabled
[    0.847] wcn-wifi-fix: holding VREG_WCN_1P9 enabled
[    0.847] wcn-wifi-fix: holding VREG_WCN_3P3 enabled
[    0.847] wcn-wifi-fix: held 3/3 regulators
[    6.115] wcn-wifi-fix: PCIe rescan attempt 1
[    6.135] wcn-wifi-fix: WiFi device FOUND! 17cb:1103
```

**Install:**

```bash
# Source is in /usr/src/wcn-regulator-fix-1.0/
sudo dkms add /usr/src/wcn-regulator-fix-1.0
sudo dkms build wcn-regulator-fix/1.0
sudo dkms install wcn-regulator-fix/1.0

# Load early via initramfs
echo "force_drivers+=\" wcn_regulator_fix \"" | sudo tee /etc/dracut.conf.d/wcn-regulator-fix.conf
echo "wcn_regulator_fix" | sudo tee /etc/modules-load.d/wcn-regulator-fix.conf

# Add to kernel cmdline for early loading
sudo grubby --update-kernel=ALL --args="rd.driver.pre=wcn_regulator_fix"

# Rebuild initramfs
sudo dracut --force
```

#### Part 2: WiFi board data (`board.bin`)

The `ath11k` driver needs calibration data matching our hardware identifiers:

```
bus=pci,vendor=17cb,device=1103,subsystem-vendor=105b,subsystem-device=e130,
qmi-chip-id=18,qmi-board-id=255,variant=UX3407Q
```

No matching entry exists in the upstream `board-2.bin`. As a workaround, board data from a similar WCN6855 variant (`105b:e0ce`, same chip-id/board-id) is provided as a fallback `board.bin`:

```bash
# Already installed at:
/lib/firmware/ath11k/WCN6855/hw2.1/board.bin
```

> **Note:** This uses generic calibration data. For optimal RF performance, extract the device-specific board data (`bdwlan_wcn685x_2p1_nfa765a_AS_SA_X14QA.elf`) from the Windows driver (see [GUIA-EXTRAIR-FIRMWARE.md](GUIA-EXTRAIR-FIRMWARE.md)).

### WiFi hardware details

| Property | Value |
|----------|-------|
| **Module** | Qualcomm QCNFA765 |
| **Chip** | WCN6855 hw2.1 |
| **PCI ID** | `17cb:1103` (subsystem `105b:e130`) |
| **PCIe bus** | `0004:01:00.0` |
| **Driver** | `ath11k_pci` |
| **PMU** | `qcom,wcn6855-pmu` in DTB |
| **Firmware** | WLAN.HSP.1.1-03125 (2024-04-17) |
| **Interface** | `wlP4p1s0` |
| **Calibration variant** | `UX3407Q` |

### Upstream status

The PCIe PERST# race condition is being fixed upstream by Manivannan Sadhasivam (Qualcomm/Linaro) in a [15-patch series](https://lkml.org/lkml/2026/1/15/415) "PCI/pwrctrl: Major rework to integrate pwrctrl devices with controller drivers". Expected to land in kernel ~6.21, which will make the DKMS module unnecessary.

## Other Debugging Findings

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

## Technical Notes

- Windows has BitLocker enabled - firmware must be extracted from Windows itself, not from Linux
- Firmware was extracted via PowerShell and injected into the ISO's squashfs
- `UX3407QA` (X1P) vs `UX3407RA` (X1E): only ADSP firmware differs; CDSP and GPU are identical
- `qcom-firmware-extract` (Debian tool) can automate extraction but requires Windows partition access
- Bash gotcha: `((var++))` with var=0 returns exit code 1 under `set -e` - use `var=$((var + 1))` instead
- GRUB gotcha: `search --file` cannot find files on FAT32 partitions unless `insmod fat` is loaded first; the search fails silently and the variable remains unset

## WiFi DTB Override — Failed Attempts (historical)

> **Note:** These attempts are no longer relevant — WiFi was fixed via a [kernel module approach](#wifi-fix) that bypasses the DTB entirely.

<details>
<summary>7 failed methods to load custom DTB on installed system (click to expand)</summary>

The initial approach was to patch the DTB with `regulator-always-on` on WCN regulators. Loading it on the installed system proved impossible due to INSYDE firmware controlling the DTB.

| # | Method | Why it fails |
|---|--------|-------------|
| 1 | **GRUB BLS `devicetree` directive** | GRUB `blscfg` on Fedora aarch64 **ignores** the `devicetree` field in BLS entries |
| 2 | **Replacing DTB in `/boot/dtb/`** | Kernel does **not** use DTBs from `/boot/dtb/` — the DTB comes from UEFI firmware (INSYDE), embedded in firmware ROM |
| 3 | **Custom GRUB entry with `insmod fdt` + `devicetree`** (no modules) | `insmod fdt` failed silently — GRUB modules didn't exist in `/boot/grub2/arm64-efi/` |
| 4 | **dtbloader.efi as EFI Driver** (pre-built) | INSYDE firmware **ignores EFI Driver variables** (`DriverOrder`/`Driver####`) — dtbloader never executes |
| 5 | **dtbloader.efi custom-built** with Vivobook X1407QA hwids | Same as #4 — INSYDE ignores EFI drivers regardless of device matching |
| 6 | **EFI stub `dtb=` kernel parameter** | `CONFIG_EFI_ARMSTUB_DTB_LOADER=y` exists but adding `dtb=` to cmdline **prevents boot entirely** |
| 7 | **Custom GRUB entry with `insmod fdt` + `devicetree`** (modules installed) | Confirmed booted from custom entry, fdt module loaded, but `devicetree` command **still cannot override UEFI-provided DTB** on INSYDE firmware |

**Key facts:**
- The DTB comes from **UEFI firmware (INSYDE)**, not from `/boot/dtb/`
- GRUB on aarch64 **cannot override** the firmware DTB on INSYDE
- No `regulator_ignore_unused` kernel parameter exists (unlike `clk_ignore_unused`)
- No ConfigFS DT overlay support (`OF_CONFIGFS` not compiled in kernel)

</details>

## Next Steps

1. ~~**WiFi**~~ :white_check_mark: Solved — DKMS module + board.bin (see [WiFi Fix](#wifi-fix))
2. **Extract device-specific board data** from Windows driver (`bdwlan_wcn685x_2p1_nfa765a_AS_SA_X14QA.elf`) for optimal RF calibration
3. **Custom DTB** - Create a DTB for the X1407Q (for keyboard/battery/audio support)
4. **Upstream contribution** - Submit DTB patches to the Linux kernel
5. **Kernel ~6.21** - PCIe pwrctrl fix will land upstream, making the DKMS module unnecessary

## Contributing

If you have an ASUS Vivobook 14 X1407Q or similar Snapdragon X laptop and want to help:

1. Test the ISO and report results
2. Help map I2C/GPIO peripherals for a custom DTB
3. Share `dmesg` and `lspci` output from successful boots

## License

Scripts are provided as-is under MIT license. Qualcomm firmware files are proprietary and NOT included in this repository - you must extract them from your own Windows installation.
