# Linux on ASUS Vivobook 14 X1407QA (Snapdragon X)

> Full Linux support for the ASUS Vivobook 14 X1407QA with Qualcomm Snapdragon X (X1-26-100) on Fedora 44 aarch64 — from zero to daily driver.

**Author:** Pir0c0pter0 — pir0c0pter0000@gmail.com

> **Build reproduzível de 2026-08-20:** consulte o
> [relatório completo do Fedora 44 com Linux 7.2](docs/BUILD-REPORT-2026-08-20.md)
> e o [estado final da construção](BUILD-STATE.md).

> **Regra de recuperação:** USB e USB tethering são infraestrutura crítica.
> Kernels experimentais devem herdar a configuração do kernel estável e são
> rejeitados se alterarem qualquer opção USB/Type-C/UCSI ou perderem
> `CONFIG_USB_NET_RNDIS_HOST=m`. A referência confiável é
> `/boot/config-7.2.0-x1407qa` com SHA-256
> `35763b73052b88433a942b93555a1ce931d81abc67f9e465821c10683ac26199`.
> Experimentos de Wi-Fi nunca devem resetar,
> descarregar, reconfigurar ou colocar USB em risco.

> **ISO personalizada atual:**
> `Fedora-44-X1407QA-Linux-7.2-hardware-ram.iso`, SHA-256
> `ffd0f459c07e8b5cf5ae591818c6bafae0e626a444b37dae72f1bf113a7a5cbf`.
> Ela corrige a ordem de inicialização do WCN6855, inclui tethering USB/PAN e
> restaura as permissões do live rootfs. Foi auditada e relida do pendrive, mas
> ainda aguarda boot físico; o percentual da bateria permanece pendente. No
> GRUB, teste primeiro **RAM, principal**.

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
| **Camera RGB** | OV02C10 (2MP, 1080p) on CCI1 bus 1 (AON), addr `0x36`, CSIPHY4, MCLK4 19.2MHz |
| **Camera IR** | 1× IR sensor (Windows Hello), pm8010 PMIC absent — not functional |
| **Privacy shutter** | Mechanical slide cover — no electronic switch, no GPIO event |
| **Battery** | 50Wh Li-ion X321-42, driver `qcom_battmgr` via `pmic_glink` |

## Achievements

Starting from a laptop that **refused to boot** Linux, every fix was reverse-engineered from scratch — no upstream support, no documentation, no community guides for this model. **19 achievements** and counting.

| # | Achievement | Method | Impact |
|---|------------|--------|--------|
| 1 | **Booted Fedora** | Custom ISO + Zenbook A14 DTB (same Qualcomm die) | From brick to bootable |
| 2 | **WiFi working on Linux 7.2** | Native `pwrseq_qcom_wcn` + the hw2.1 `wlanfw20.mbn` variant + X1407QA board data | Fixes the MHI `-110` caused by the wrong signed AMSS variant |
| 3 | **Keyboard working** | DKMS module `vivobook_kbd_fix` | Different I2C bus/address than Zenbook |
| 4 | **Battery reporting** | ADSP firmware injected into initramfs | `qcom-battmgr` was failing at early boot |
| 5 | **Brightness control** | DKMS module `vivobook_bl_fix` | Direct PMIC PWM register manipulation |
| 6 | **Fn hotkeys** | DKMS module `vivobook_hotkey_fix` | ASUS vendor HID init + key mapping |
| 7 | **GPU acceleration** | Firmware in initramfs (3 files: `sqe.fw`, `gmu.bin`, device-specific ZAP shader) | Adreno X1-45 with full 3D |
| 8 | **Boot time: 1min47s -> 8s** | TPM timeout elimination + initrd cleanup | Masked phantom TPM devices, removed unused modules |
| 9 | **Terminal flicker fixed** | LD_PRELOAD Vulkan pool fix (`vk_pool_fix.so`) | GTK4/turnip descriptor pool fragmentation → 952 errors eliminated |
| 10 | **Battery time in panel** | GNOME Shell extension `battery-time@wifiteste` | Hover over battery icon shows time remaining (weighted rolling average) |
| 11 | **Touchpad right-click** | gsettings `click-method` → `areas` | Clickpad only reports BTN_LEFT; area-based mapping restores right-click |
| 12 | **Audio working** | ALSA UCM2 regex fix for Vivobook 14 | Speaker, headphones, internal mic, headset mic, HDMI audio |
| 13 | **Lid close = s2idle suspend** | `mem_sleep_default=s2idle` + logind `HandleLidSwitch=suspend` | deep (S3) still crashes and stays disabled; s2idle validated 2026-08-24 — ~0.80W suspended vs 2.85W idle on |
| 14 | **CPU frequency scaling** | Autoload in-tree `scmi_cpufreq` module | CPU scales 710MHz–2.96GHz, battery savings + thermal protection |
| 15 | **CDSP / NPU online** | CDSP firmware in initramfs | Hexagon Compute DSP boots at early boot — fastrpc compute contexts available |
| 16 | **Battery charge limit** | udev rule sets 80% threshold | Charge stops at 80%, starts at 50% — extends battery lifespan |
| 17 | **RGB camera fully working** | `vivobook_cam_fix` + `libcamera` OV02C10 data + `qcom_camss` override | OV02C10 on CCI1 — clean `cam -l`, still frame, 720p30 video, Snapshot/PipeWire, on-demand via `vivobook-camera start` |
| 18 | **Claude Code flicker-free** | PTY proxy `sync_render` with Mode 2026 synchronized output | Coalesces rapid terminal writes into atomic frames — zero flicker on ARM/Wayland |
| 19 | **Display color control** | DKMS module `vivobook_color_ctrl` — CTM via DRM atomic commit from kernel space | msm_dpu exposes CTM/PCC but not GAMMA_LUT — wl-gammarelay-rs and zwlr_gamma_control both fail; kernel module bypasses DRM master restriction |

**7 custom kernel modules**, **1 in-tree kernel module override** (`qcom-camss`), **1 Vulkan driver fix**, **1 PTY sync proxy**, **1 GNOME extension**, **1 UCM2 config fix**, **1 suspend fix**, **1 cpufreq fix**, **1 CDSP firmware fix**, **1 charge control fix** — everything needed for daily-driver use currently runs at runtime via DKMS/module overrides/LD_PRELOAD because the INSYDE UEFI blocks DTB overrides. USB4/TB3 is the first area that still appears to require a real custom-kernel path.

## Current Status

Esta tabela descreve o sistema Fedora previamente instalado e configurado. O
estado específico da nova ISO live está no aviso acima e em
[`BUILD-STATE.md`](BUILD-STATE.md); não confunda validação histórica do sistema
instalado com validação física da reconstrução atual.

| Feature | Status | Notes |
|---------|--------|-------|
| **Boot** | :white_check_mark: Working | Fedora 44 via Zenbook A14 DTB |
| **Boot time** | :white_check_mark: 8s | Was ~2min (see [Boot Time Fix](#8-boot-time-fix)) |
| **Display** | :white_check_mark: Working | GPU firmware in initramfs (see [GPU Firmware Fix](#7-gpu-firmware-fix)) |
| **WiFi** | :white_check_mark: Working | Native WCN sequencing + `wlanfw20.mbn` as `amss.bin` + X1407QA board data (see [WiFi Fix](#2-wifi-fix)) |
| **Bluetooth** | :white_check_mark: Working | FastConnect 6900 UART — out-of-the-box |
| **Keyboard** | :white_check_mark: Working | DKMS module (see [Keyboard Fix](#3-keyboard-fix)) |
| **Touchpad** | :white_check_mark: Working | Clickpad — `click-method: areas` for right-click (see [Touchpad Fix](#11-touchpad-right-click-fix)) |
| **Battery** | :white_check_mark: Working | ADSP firmware in initramfs (see [Battery Fix](#4-battery-fix)) |
| **Brightness** | :white_check_mark: Working | DKMS module (see [Brightness Fix](#5-brightness-fix)) |
| **Brightness keys** | :white_check_mark: Working | DKMS module (see [Hotkey Fix](#6-fn-hotkey-fix)) |
| **USB ports** | :white_check_mark: Working | USB-C, USB-A, HDMI |
| **NVMe** | :white_check_mark: Working | PCIe 4.0 |
| **Audio** | :white_check_mark: Working | UCM2 regex fix (see [Audio Fix](#12-audio-fix)) |
| **Lid close** | :white_check_mark: Working | Lid close = s2idle suspend, ~0.80W (see [Lid Close Fix](#13-lid-close-fix)) |
| **Suspend (s2idle)** | :white_check_mark: Working | s2idle validated 2026-08-24 on installed `7.2.0-x1407qa` — 2 clean cycles, ~0.80W suspended. deep (S3) still crashes and stays disabled (see [Lid Close Fix](#13-lid-close-fix)) |
| **cpufreq** | :white_check_mark: Working | SCMI cpufreq via autoload — 710MHz–2.96GHz, schedutil governor (see [CPU Frequency Fix](#14-cpu-frequency-fix)) |
| **CDSP / NPU** | :white_check_mark: Working | CDSP firmware in initramfs — Hexagon compute online (see [CDSP/NPU Fix](#15-cdspnpu-fix)) |
| **Charge control** | :white_check_mark: Working | Charge limit 80% via udev rule (see [Charge Control Fix](#16-battery-charge-control-fix)) |
| **USB-C DP alt-mode** | :white_check_mark: Working | Both ports, tested DP-2 up to 2560×1600. Device link errors at boot are cosmetic ([#6](https://github.com/pir0c0pter0/fedora-vivobook-x1407q/issues/6)) |
| **USB4 / TB3 tunneling** | :x: Not working | DP alt-mode works, but Thunderbolt tunneling is blocked by missing Qualcomm x1e80100 host/router support in current kernels. See [USB4/TB3 Status](#usb4tb3-status-mar-2026) |
| **Camera RGB** | :white_check_mark: Working | OV02C10 via DKMS overlay + `qcom_camss` override, clean still/video and clean kernel log on-demand `vivobook-camera start` (see [Camera Fix](#17-rgb-camera-fix)) |
| **Camera IR** | :x: Not working | pm8010 PMIC physically absent — sensor has no power (see [Camera Research](#camera-research)) |
| **Display color control** | :white_check_mark: Working | CTM saturation + contrast via DKMS module (see [Display Color Control Fix](#19-display-color-control-fix)) |

---

## USB4/TB3 Status (Mar 2026)

The laptop exposes two USB-C ports with USB4/TB3-capable hardware, and plain
USB-C DP alt-mode already works on both ports. The remaining problem is
specifically Thunderbolt tunneling for docks like the Elgato TB3 Dock.

Current findings:

- `data_role` can come up as `host [device]` on both Type-C ports; forcing `host`
  is enough to make the dock appear as a USB Billboard fallback device
- UCSI reports `ALT_MODE_DETAILS`, but **not** `ALT_MODE_OVERRIDE`; direct
  `SET_NEW_CAM` requests fail with `Operation not supported`
- the firmware path behind `pmic_glink_altmode` never sends `USBC_NOTIFY` for the dock,
  so the PS8833 retimer is never programmed for TB3 by the normal path
- experimental synthetic TB3 entry now reaches `typec_thunderbolt`, but crashes in
  the `ps883x` retimer path, so that route is disabled for safety
- the blocker is no longer just DT or retimer setup: current Linux kernels still
  lack Qualcomm `x1e80100` USB4 host/router support, so `/sys/bus/usb4/` never appears

Practical conclusion:

- **USB-C DP alt-mode:** working
- **USB4/TB3 dock tunneling:** blocked upstream
- **Next step:** custom kernel once a public Qualcomm USB4 host/router patch stack is available

Documents:

- [USB4-TB3-investigation.md](USB4-TB3-investigation.md)
- [docs/research/2026-03-24-usb4-custom-kernel-plan.md](docs/research/2026-03-24-usb4-custom-kernel-plan.md)
- [docs/research/2026-03-24-usb4-upstream-patch-checklist.md](docs/research/2026-03-24-usb4-upstream-patch-checklist.md)

External tracking:

- [Qualcomm Linux `kernel-topics` issue #825: public DTS/DTB support request for ASUS Vivobook 14 X1407QA](https://github.com/qualcomm-linux/kernel-topics/issues/825)
- [Technical follow-up comment on issue #825 with current USB4/TB3 blockers](https://github.com/qualcomm-linux/kernel-topics/issues/825#issuecomment-4118158804)

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

> ⚠️ **Do Step 1 while Windows still exists.** Installing Fedora wipes the
> Windows partition, and the Qualcomm firmware lives *only* there. Dump it to a
> pendrive first — without it WiFi, GPU, audio and battery won't work.

### Step 1 — Extract firmware from Windows (do this FIRST, before formatting)

The Qualcomm firmware is proprietary and exists only on the Windows partition
(ADSP, GPU ZAP shader, CDSP, WiFi). Dump it to a pendrive **before** wiping
Windows:

1. Copy **`extract-firmware-windows.bat`** to a USB pendrive (FAT32/exFAT).
2. On the Vivobook's Windows, double-click it from the pendrive — it
   self-elevates to Administrator (click *Yes*).
3. It copies the Qualcomm driver packages (`qc*`) from the `DriverStore`
   (keeping the `.inf` files, which the Linux tool needs to remap names) into
   `vivobook-qcom-firmware\` on the pendrive, and prints the next steps.
4. Keep this pendrive — you'll apply the firmware in **Step 6**.

> No Windows anymore? You can still dump the firmware from another ASUS
> Vivobook X1407QA, or recover it later from a Windows recovery image. There is
> no generic download — it is signed for this exact device family.

### Step 2 — Prepare BIOS

1. Power off the Vivobook completely
2. Hold **F2** and power on to enter UEFI/BIOS
3. **Disable Secure Boot** (Security → Secure Boot → Disabled)
4. **Enable USB boot** (Boot → USB Boot → Enabled)
5. Save and exit (F10)

### Step 3 — Download ISO and Flash USB

```bash
# Download Fedora 44 aarch64 Workstation Live ISO
wget https://download.fedoraproject.org/pub/fedora/linux/releases/44/Workstation/aarch64/iso/Fedora-Workstation-Live-aarch64-44-1.1.iso

# Flash to USB (REPLACE /dev/sdX with your USB device!)
sudo dd if=Fedora-Workstation-Live-aarch64-44-1.1.iso of=/dev/sdX bs=4M status=progress oflag=sync
sync
```

Or use the ISO builder from this repo (**Part 1** — runs on *any* PC / any distro):

```bash
bash build-vivobook-iso.sh
```

The build is split into two parts so the ISO can be built anywhere, with all
hardware configuration deferred to the actual laptop:

| Part | Script | Where it runs | What it does |
|------|--------|---------------|--------------|
| **1** | `build-vivobook-iso.sh` | any PC (dnf/apt/pacman/zypper) | downloads/verifies the Fedora ISO, injects Snapdragon boot params into the live GRUB, and bundles the **Part 2 payload** into `/opt/vivobook-fixes/` (setup script + helper scripts + `modules/` + bundled `firmware/` + `.c` sources). Rebuilds the squashfs/ISO and can flash USB. |
| **2** | `setup-vivobook.sh` | on the Vivobook, after install | applies *all* hardware fixes (DKMS, firmware initramfs, audio, brightness, WiFi, battery, terminal, suspend, …). Auto-stages bundled `modules/` → `/usr/src` and `firmware/` → `/usr/lib/firmware`. |

Part 1 only prepares boot + payload; it does **not** require the laptop's
firmware or DKMS modules to be present, so it works on any machine.

### Step 4 — Boot from USB

> Ao usar a ISO personalizada indicada no topo, escolha **RAM, principal** no
> GRUB; os parâmetros já estão incorporados. As instruções de edição abaixo são
> para a ISO Fedora genérica construída pelo fluxo original.

1. Connect the USB drive
2. Hold **F12** (or **ESC**) during power-on for boot menu
3. Select the USB drive
4. At the GRUB menu, press **e** to edit the boot entry and add to the `linux` line:
   ```
   clk_ignore_unused pd_ignore_unused systemd.tpm2_wait=0 modprobe.blacklist=qcom_q6v5_pas
   ```
5. Press **Ctrl+X** to boot
6. The system will boot using the **Zenbook A14 DTB** (`x1p42100-asus-zenbook-a14.dtb`) — same Qualcomm "Purwa" die

> Prefer a **USB-A port** for the installer. On USB-C, starting the ADSP resets
> the Type-C mux and makes the live drive disappear mid-boot; the temporary
> `qcom_q6v5_pas` blacklist prevents that reset. The ISO builder adds all four
> parameters automatically. See Fedora's
> [Snapdragon WoA install guide](https://fedoraproject.org/wiki/Snapdragon_WoA_Laptop_Install).

If the machine still hard-resets, remove `quiet rhgb` and add
`rd.break=cmdline rd.shell rd.debug log_buf_len=1M`. Reaching the dracut shell
proves the kernel entered the initramfs; otherwise, report the exact ISO/kernel,
BIOS version, USB port used, and a photo of the last visible line in
[#11](https://github.com/pir0c0pter0/fedora-vivobook-x1407q/issues/11).

> **Why Zenbook A14 DTB?** There is no DTB for the Vivobook X1407QA in the kernel. The Zenbook A14 uses the same Qualcomm x1p42100 SoC. The INSYDE UEFI firmware provides the DTB and **cannot be overridden** from GRUB on aarch64 (7 methods tested: BLS devicetree, GRUB fdt module, dtbloader.efi, EFI stub — all fail). So we boot with the Zenbook DTB and fix all hardware differences via runtime kernel modules.

### Step 5 — Install Fedora to NVMe

1. Once booted into the Live environment, open the installer
2. Install Fedora to the NVMe drive (default btrfs layout)
3. Reboot into the installed system

> **Important:** At first boot from NVMe, edit GRUB again with
> `clk_ignore_unused pd_ignore_unused systemd.tpm2_wait=0` (without the temporary
> `qcom_q6v5_pas` blacklist) — you'll make this permanent in Step 6.

### Step 6 — Apply firmware + all fixes (Part 2)

Now on the **installed Fedora**. First, plug in the pendrive from Step 1 and
install the firmware dump:

```bash
# Point the extractor at the dump on the pendrive (adjust the path):
sudo ./extract-qcom-firmware.sh /run/media/$USER/PENDRIVE/vivobook-qcom-firmware
# (or, if bundled in the ISO: sudo /opt/vivobook-fixes/extract-qcom-firmware.sh <dump>)
```

`extract-qcom-firmware.sh` uses `qcom-firmware-extract` (installing it if
needed) to place every file at its correct path under
`/usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/` and the WiFi board data
under `/usr/lib/firmware/ath11k/WCN6855/hw2.1/`.

> Still dual-booting? Run `sudo ./extract-qcom-firmware.sh` with **no argument**
> to mount the local Windows NTFS partition directly (no pendrive needed). For
> the manual PowerShell method see
> [docs/GUIA-EXTRAIR-FIRMWARE.md](docs/GUIA-EXTRAIR-FIRMWARE.md).

Then apply every hardware fix. If you built the ISO with Part 1, the setup
payload is already on the system:

```bash
sudo /opt/vivobook-fixes/setup-vivobook.sh
```

Otherwise, clone this repo and run it from there:

```bash
git clone https://github.com/pir0c0pter0/fedora-vivobook-x1407q.git
cd fedora-vivobook-x1407q
sudo bash setup-vivobook.sh
```

This applies all fixes: DKMS modules, firmware initramfs configs, GRUB params,
suspend/lid, UCM2 audio, Vulkan fix, `sync_render`, GNOME extension, charge
control, cpufreq, dconf defaults, on-demand camera, and cleans up old scripts.
When run from the bundled payload it also auto-stages `modules/` → `/usr/src`
and bundled `firmware/` → `/usr/lib/firmware` first, so it is self-contained.

### Safe recovery for the stable kernel 7.2 hardware path

For an existing X1407QA installation already booted on exactly
`7.2.0-x1407qa`, use the focused recovery runner instead of rerunning the
monolithic setup:

```bash
sudo -n bash tools/recover-stable-hardware.sh
```

The runner verifies Fedora 44, the DMI model and active kernel, captures a
read-only pre-reboot audit, installs only explicitly named dependencies that
are missing, builds and vermagic-checks all four core DKMS modules, runs one
`depmod`, and uses the tested candidate-initramfs primitive. The candidate is
inspected with `lsinitrd`, set to mode `0600`, and atomically promoted only
after every module and selected firmware file is present. The final gate
rechecks that every core module, plus the camera module when installed, resolves
inside canonical `/usr/lib/modules/7.2.0-x1407qa/` with exact
`7.2.0-x1407qa` vermagic. The `/lib/modules` usrmerge alias is accepted only
when it resolves exactly to `/usr/lib/modules`. It
prints `READY FOR REBOOT` only after the installed modules, initramfs, and
masked sleep targets pass. The reboot itself is always manual.

The first observed version of every overwritten non-RPM file is retained under
`/var/lib/vivobook-recovery/2026-08-20/backups/`; the strict, tab-delimited
record is `/var/lib/vivobook-recovery/2026-08-20/manifest.txt`. `BACKUP`,
`CREATED` and `SYMLINK` distinguish exact restore actions. A checksum-pinned
`backups/state-before.tar` captures the build tree/link, core `/usr/src`
targets, relevant `/var/lib/dkms` state, installed extra modules and all
`modules.*` metadata that `depmod` may replace. The archive preserves numeric
ownership, ACLs, xattrs and SELinux metadata. Recovery never rolls this state
back automatically. After reviewing the manifest, an administrator can invoke
the separate, explicit restore boundary:

```bash
sudo -n bash tools/restore-stable-hardware-backup.sh --apply
```

The helper takes the same exclusive lock, validates the exact manifest grammar,
archive and backup checksums, and rejects every path outside the recovery
allowlists. Exact or nested mountpoints, including bind mounts, abort before
publication. Each archived root and each `BACKUP`/`SYMLINK` replacement is
fully staged on the target filesystem first. Publication atomically renames the
current object into a retained rollback directory and the staged object into
place; any later tar/copy/sync/rename failure rolls every already-published
object back. Only after all roots and files succeed are rollback directories
removed. Consequently, descendants added by a failed recovery attempt cannot
survive a successful restore, while a failed restore leaves the prior objects
intact. It removes only paths recorded as `CREATED`, does not reboot, and is
deliberately never called by the recovery runner.

Every rerun validates the manifest grammar, rejects duplicate/unknown records,
and verifies every backup/archive checksum before proceeding. An exclusive
`runner.lock` serializes the complete mutable workflow. A pre-reboot audit exit
1 is recorded as the broken hardware baseline being repaired; status 2 or
higher means missing tooling or another infrastructure/internal audit failure
and stops the runner.

Camera IR, experimental USB4/TB3, and suspend/hibernate enablement are outside
this workflow. Sleep targets remain masked. The runner does not load the RGB
camera or display color-control modules; it leaves their existing activation
state unchanged, and the RGB camera remains on demand. It also does not perform
a general package update.

Historical safety note: an earlier DKMS hook rewrote only the old
`/boot/initramfs-6.19.10-300.fc44.aarch64.img`; the active 7.2 image remained
intact and both images passed `lsinitrd`. The leftover
`/var/tmp/dracut.dRkFu6m` is intentionally documented in the recovery manifest.
This runner performs no automatic rollback or cleanup of either artifact.

Or apply each fix manually — see [Detailed Fix Guide](#detailed-fix-guide) below.

### Step 7 — Reboot and Verify

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

# Audio
wpctl status | grep -A5 Sinks
```

---

## Setup Scripts

### Part 1 — Build the bootable ISO (any PC)

```bash
bash build-vivobook-iso.sh        # interactive menu
```

Detects the package manager (dnf/apt/pacman/zypper), downloads + verifies the
Fedora ISO, injects Snapdragon boot params into the live GRUB, bundles the
Part 2 payload into `/opt/vivobook-fixes/`, rebuilds the squashfs/ISO, and can
flash USB. No laptop firmware/DKMS needed — runs anywhere.

### Part 2 — Apply all fixes (on the Vivobook)

```bash
sudo /opt/vivobook-fixes/setup-vivobook.sh   # from the bundled payload
# or, from a repo clone:
sudo bash setup-vivobook.sh
```

Run **after** installing Fedora and (if needed) extracting the firmware. Applies
every hardware fix on the running system: DKMS modules, firmware initramfs,
GRUB params, suspend/lid, UCM2 audio, Vulkan fix, `sync_render`, GNOME
extension, charge control, cpufreq, dconf defaults, on-demand camera. Auto-stages
bundled modules/firmware and cleans up deprecated scripts.

### Windows firmware dump

```
extract-firmware-windows.bat      # run on Windows (auto-elevates), dumps to pendrive
```

Copies the Qualcomm `qc*` driver packages from the Windows `DriverStore` to a
pendrive, to be consumed on Linux by `extract-qcom-firmware.sh <dump-dir>`.

### Safe updates

```bash
sudo vivobook-update
```

Analyzes kernel, mesa, GNOME, firmware, and other sensitive updates for compatibility before applying. Checks DKMS module APIs, UCM2 regex, Vulkan symbols, and extension metadata.

---

### Deprecated scripts (removed)

The following scripts have been removed and replaced:

| Removed | Replaced by |
|---------|-------------|
| `setup-all.sh` | `setup-vivobook.sh` (all 16 fixes) |
| `prepare-fedora-snapdragon.sh` | `build-vivobook-iso.sh` |
| `build-v3-iso.sh` | `build-vivobook-iso.sh` |
| `build-v4-iso.sh` | `build-vivobook-iso.sh` |
| `fix.sh` | `setup-vivobook.sh` |
| `test-brightness.sh` | No longer needed (brightness fix stable) |

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
| `systemd.tpm2_wait=0` | Skips the two false TPM waits |
| `modprobe.blacklist=qcom_q6v5_pas` | Live USB only: prevents the ADSP restart from disconnecting USB-C storage |
| `rd.driver.pre=wcn_regulator_fix` | Loads WiFi regulator fix before PCIe scan |
| `rd.systemd.mask=dev-tpm0.device` | Skips TPM wait in initrd |
| `rd.systemd.mask=dev-tpmrm0.device` | Skips TPM resource manager wait in initrd |

**Full kernel cmdline used:**

```
BOOT_IMAGE=/vmlinuz-6.19.6-300.fc44.aarch64 root=UUID=<your-uuid> ro rootflags=subvol=root quiet rhgb clk_ignore_unused pd_ignore_unused systemd.tpm2_wait=0 rd.driver.pre=wcn_regulator_fix rd.systemd.mask=dev-tpm0.device rd.systemd.mask=dev-tpmrm0.device
```

### 2. WiFi Fix

Native `pwrseq_qcom_wcn` + the correct WCN6855 hw2.1 firmware set.

**Problem:**
Linux 7.2 powered the device, trained PCIe Gen3 x1 and allocated 32 MSI
vectors, but MHI waited 20 seconds for SBL/Mission mode and failed with `-110`.

**Root cause:**
The personal ISO had installed Windows `wlanfw.mbn` as `amss.bin`. It is a
validly signed WOS image, but it is the wrong runtime-selected variant for this
WCN6855 hw2.1 device. The first 512 KiB were accepted through BHI, but the
device never executed the image far enough to report an execution-environment
transition.

**Solution:**
Install `wlanfw20.mbn` as `amss.bin` together with the exact Windows
`NFA765a_AS_SA_X14QA` board data. The repository bundles the validated set at
`firmware/ath11k/WCN6855/hw2.1/`; `setup-vivobook.sh` stages it into
`/usr/lib/firmware`.

```bash
sudo ./setup-vivobook.sh
sudo poweroff  # wait at least 30 seconds before powering on
```

The stock linux-firmware `SILICONZ_LITE` image reached Mission mode but entered
RDDM while processing the Windows board-data exchange. `wlanfw20.mbn` completed
initialization, created `wlP4p1s0`, scanned and connected to Wi-Fi. The
post-reboot hardware audit passed 16/16 checks.

The legacy `wcn_regulator_fix` DKMS package remains available for older kernels
but is not loaded by the validated Linux 7.2 configuration.

| Property | Value |
|----------|-------|
| **Chip** | WCN6855 hw2.1, PCI `17cb:1103` (subsystem `105b:e130`) |
| **Driver** | `ath11k_pci` |
| **Interface** | `wlP4p1s0` |
| **AMSS source** | Windows `wlanfw20.mbn`, SHA-256 `00756e19aee2b5e6725f5029b7e6abea748caca0f53af5a7662cd32086dde4bd` |
| **Firmware build** | `WLAN.HSP.1.1.c5-00424-QCAHSPSWPL_V1_V2_SILICONZ_WOS-1` |
| **Board data** | `NFA765a_AS_SA_X14QA`, SHA-256 `aea74372b997b7b55c76c786b02f4670922489353923ef7d4a48dc83780f2c86` |

### 3. Keyboard Fix

DKMS module `vivobook_kbd_fix`.

**Problem:** The Zenbook DTB maps the keyboard to `i2c@a80000:0x15`. On the Vivobook, it's on a completely different bus: `i2c@b94000` at address `0x3a`.

**Module** (`/usr/src/vivobook-kbd-fix-1.0/`):
- Finds I2C adapter by **DT path** (`/soc@0/geniqup@bc0000/i2c@b94000`) — bus numbers are dynamic and shift when other I2C controllers (e.g., camera CCI) probe first
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
| **I2C controller** | `b94000.i2c` (DT path: `/soc@0/geniqup@bc0000/i2c@b94000`) |
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

**Problem:** The Adreno X1-45 GPU driver probes at ~t=2.0s, ~375ms before switchroot, so its firmware must be in the initramfs. `msm.ko` does not declare `MODULE_FIRMWARE`, so dracut never auto-pulls the GPU blobs — they have to be forced via `install_items`. The ZAP shader (`qcdxkmsucpurwa.mbn`) is referenced by name in the Zenbook A14 DTB override (`zap-shader.firmware-name`) and extracted from Windows — it is not in any Linux package.

```bash
echo 'install_items+=" /usr/lib/firmware/qcom/gen71500_sqe.fw.xz /usr/lib/firmware/qcom/gen71500_gmu.bin.xz /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/qcdxkmsucpurwa.mbn "' | sudo tee /etc/dracut.conf.d/qcom-gpu-firmware.conf
sudo dracut --force
```

| Firmware | Path | Purpose |
|----------|------|---------|
| `gen71500_sqe.fw.xz` | `qcom/` | Shader Queue Engine (package `qcom-firmware`) |
| `gen71500_gmu.bin.xz` | `qcom/` | Graphics Management Unit (package `qcom-firmware`) |
| `qcdxkmsucpurwa.mbn` | `qcom/x1p42100/ASUSTeK/zenbook-a14/` | ZAP shader (Windows blob, DTB-referenced) |

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

**Fix:** LD_PRELOAD library that intercepts `vkCreateDescriptorPool` and increases pool sizes by 200x (100 → 20000 sets), eliminating fragmentation. Also intercepts `vkGetDeviceProcAddr`/`vkGetInstanceProcAddr` to ensure the hook works even when apps resolve function pointers directly:

```bash
# Build
gcc -shared -fPIC -o vk_pool_fix.so vk_pool_fix.c -ldl

# Install library
sudo cp vk_pool_fix.so /usr/local/lib64/vk_pool_fix.so

# Create wrapper script (needed because Ptyxis uses D-Bus activation,
# which ignores Exec= in .desktop and LD_PRELOAD env vars)
# VK_DRIVER_FILES still needed: MR 37622 fixes device select but libvulkan_lvp.so
# still loads without it, degrading GTK4 rendering and causing terminal flicker
sudo tee /usr/local/bin/ptyxis-fixed << 'WRAPPER'
#!/bin/sh
export VK_DRIVER_FILES=/usr/share/vulkan/icd.d/freedreno_icd.aarch64.json
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

> **Compositor note**: `VkLayer_MESA_device_select` correctly picks turnip (Adreno X1-45) on Niri since Mesa 25.3.6 (MR 37622). However, without `VK_DRIVER_FILES`, `libvulkan_lvp.so` (Lavapipe) still gets loaded alongside freedreno — this degrades GTK4 rendering and causes visible flicker during Claude Code reloads. `VK_DRIVER_FILES` prevents LVP from loading entirely.

**Result:** 952 errors → 0 errors. Vulkan renderer preserved (better performance than GL fallback).

| Property | Value |
|----------|-------|
| **Affected app** | Ptyxis (GNOME Terminal) and any GTK4 Vulkan app on turnip |
| **Root cause** | GTK4 GSK `maxSets=100` + turnip pool fragmentation |
| **Error** | `VK_ERROR_OUT_OF_POOL_MEMORY` at `tu_descriptor_set.cc:649` |
| **Fix** | `vk_pool_fix.so` — increases pool size 200x via LD_PRELOAD + ProcAddr interception |
| **Compositor** | All Wayland compositors: turnip selected via MR 37622, but `VK_DRIVER_FILES` still needed to prevent LVP loading |
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

### 12. Audio Fix

ALSA UCM2 regex fix — adds Vivobook 14 to the X1E80100 machine matching table.

**Problem:** The audio hardware is fully functional at the kernel level — WCD938x codec, 2x WSA884x speaker amplifiers, all LPASS macros (rx, tx, wsa, va), SoundWire bus, and Q6APM DSP are loaded and running. However, PipeWire shows only "Dummy Output" because ALSA UCM2 (Use Case Manager) doesn't recognize the machine.

**Root cause:** The UCM2 config at `/usr/share/alsa/ucm2/conf.d/x1e80100/x1e80100.conf` uses DMI info to match machines. The regex includes `Zenbook A14` and `Vivobook S 15` but **not** `Vivobook 14`:

```
# DMI string constructed as: board_vendor-product_family-board_name
# Vivobook 14: "ASUSTeK COMPUTER INC.-ASUS Vivobook 14-X1407QA"

# Before (doesn't match):
Regex "...ASUSTeK COMPUTER.*ASUS (Zenbook A14|Vivobook S 15)..."

# After (matches):
Regex "...ASUSTeK COMPUTER.*ASUS (Zenbook A14|Vivobook S 15|Vivobook 14)..."
```

Without UCM2 profile matching, WirePlumber cannot configure the ALSA mixer routing (`RX_CODEC_DMA_RX_0`, `WSA_CODEC_DMA_RX_0`, etc.) and falls back to a dummy sink.

**Fix:**

```bash
# Add "Vivobook 14" to the UCM2 regex (both copies)
sudo sed -i 's/Vivobook S 15/Vivobook S 15|Vivobook 14/' \
    /usr/share/alsa/ucm2/conf.d/x1e80100/x1e80100.conf \
    /usr/share/alsa/ucm2/Qualcomm/x1e80100/x1e80100.conf

# Restart audio services
systemctl --user restart pipewire pipewire-pulse wireplumber
```

**UCM2 profile used:** `LENOVO-T14s.conf` → `T14s-HiFi.conf` (2 WSA884x speakers, WCD938x codec) — the same profile shared by ThinkPad T14s Gen 6, HP Omnibook X, Zenbook A14, Vivobook S 15, Microsoft Surface Laptop 7th Edition, and now Vivobook 14.

**Audio devices enabled:**

| Device | Type | PCM | Details |
|--------|------|-----|---------|
| Speaker | Playback | `hw:0,1` | 2ch, WSA884x × 2, WSA_CODEC_DMA_RX_0 |
| Headphones | Playback | `hw:0,0` | WCD938x, RX_CODEC_DMA_RX_0 |
| HDMI 0/1/2 | Playback | `hw:0,0` | DisplayPort audio, DISPLAY_PORT_RX_0/1/2 |
| Internal Mic | Capture | `hw:0,3` | DMIC0 + DMIC1, VA_CODEC_DMA_TX_0 |
| Headset Mic | Capture | `hw:0,2` | WCD938x ADC2, TX_CODEC_DMA_TX_3 |

**SoundWire topology:**

| Master | Bus address | Device | Driver | DT node |
|--------|-------------|--------|--------|---------|
| sdw-master-1 | `soundwire@6b10000` | WSA884x × 2 | `wsa884x-codec` | `speaker@0,0` / `speaker@0,1` |
| sdw-master-2 | `soundwire@6ad0000` | WCD938x | `wcd9380-codec` | `codec@0,4` |
| sdw-master-3 | `soundwire@6d30000` | WCD938x | `wcd9380-codec` | `codec@0,3` |

| Property | Value |
|----------|-------|
| **Codec** | WCD938x (WCD9385), SoundWire, headphone/mic codec |
| **Amplifier** | WSA884x × 2, SoundWire, speaker amplifiers |
| **DSP** | ADSP via Q6APM (AudioReach), LPASS macros (rx, tx, wsa, va) |
| **ALSA card** | `X1E80100ASUSZen` (`snd_soc_x1e80100` driver) |
| **UCM2 files** | `x1e80100.conf` (matcher), `LENOVO-T14s.conf` (profile), `T14s-HiFi.conf` (HiFi verb) |
| **Fix location** | `/usr/share/alsa/ucm2/conf.d/x1e80100/x1e80100.conf` and `/usr/share/alsa/ucm2/Qualcomm/x1e80100/x1e80100.conf` |

> **WARNING**: This fix modifies system files owned by `alsa-ucm` package. It will be overwritten on `alsa-ucm` updates. The proper fix is a PR to [alsa-ucm-conf](https://github.com/alsa-project/alsa-ucm-conf) upstream to add `Vivobook 14` to the regex permanently.

> **Installed system, custom kernel `7.2.0-x1407qa` (2026-08-24):** audio was dead again — three stacked causes, all fixed on the machine:
> 1. Custom kernel lacks `CONFIG_FW_LOADER_COMPRESS`/`_XZ` → it cannot load the topology `qcom/x1e80100/X1E80100-ASUS-Zenbook-A14-tplg.bin.xz` (linux-firmware ships only the `.xz`). Local fix: `xz -dk` the file so the uncompressed `.bin` exists.
> 2. `snd_soc_wcd938x` did not autoload at boot (probe race; modalias is correct) → `/etc/modules-load.d/vivobook-audio.conf` with `snd_soc_wcd938x`.
> 3. The UCM2 regex fix above had never been applied to the installed system → same `sed` as above.

---

### 13. Lid Close Fix

**Problem:** Closing the laptop lid used to trigger S3 suspend (`PM: suspend entry (deep)`), and the Snapdragon X firmware (INSYDE) fails to save/restore power domain state — instead of resuming, the system cold reboots. The original workaround disabled suspend entirely (lid = screen off + lock), leaving the machine at ~2.85W with the lid closed — ~25–50% battery lost per closed-lid night.

**Root cause:** Only `deep` (S3) is broken — its firmware power-domain save/restore path crashes. `s2idle` (S0ix) never enters that firmware path and works on this hardware: validated 2026-08-24 on the installed system (kernel `7.2.0-x1407qa`) with 2 clean suspend/resume cycles (`PM: suspend entry (s2idle)` → exit), WiFi/BT/keyboard/audio all working after resume. Measured drain while suspended: 0.368Wh in 27.7min = **~0.80W** (vs 2.85W idle powered on).

**Solution:** Default to s2idle, make the lid suspend again, keep `deep` and hibernate disabled:

```bash
# 1. Kernel cmdline (BLS entry + custom.cfg): force s2idle as default suspend mode
#    mem_sleep_default=s2idle

# 2. logind: lid close = suspend (s2idle)
sudo mkdir -p /etc/systemd/logind.conf.d/
sudo tee /etc/systemd/logind.conf.d/no-suspend.conf > /dev/null << 'EOF'
[Login]
HandleLidSwitch=suspend
HandleLidSwitchExternalPower=suspend
HandleLidSwitchDocked=suspend
IdleAction=ignore
EOF

# 3. Unmask only the suspend path; hibernate stays masked (no swap)
sudo systemctl unmask sleep.target suspend.target
sudo systemctl mask hibernate.target hybrid-sleep.target suspend-then-hibernate.target
```

**Behavior after fix:**
- **Lid close** → s2idle suspend (~0.80W)
- **Lid open / power button** → resume; WiFi/BT/keyboard/audio come back
- **No timed wake** → the pm8xxx RTC has no alarm (no `wakealarm` in sysfs) — wake is always lid/power button

| Property | Value |
|----------|-------|
| **Lid switch device** | `gpio-keys` (`/dev/input/event0`), capability `SW_LID` |
| **Suspend mode used** | `s2idle` (S0ix) — validated 2026-08-24, 2 clean cycles |
| **Suspend mode that crashes** | `deep` (S3) — still disabled, never re-enable |
| **Power while suspended** | 0.368Wh / 27.7min = **~0.80W** (vs 2.85W idle on) |
| **Kernel cmdline** | `mem_sleep_default=s2idle` (BLS entry + `custom.cfg`) |
| **logind config** | `/etc/systemd/logind.conf.d/no-suspend.conf` — `HandleLidSwitch=suspend` (3 variants) + `IdleAction=ignore` |
| **Targets unmasked** | `sleep.target`, `suspend.target` |
| **Targets still masked** | `hibernate.target`, `hybrid-sleep.target`, `suspend-then-hibernate.target` (no swap) |
| **Wakeup sources** | Lid / power button only — pm8xxx RTC has no `wakealarm` |

---

### 14. CPU Frequency Fix

**Problem:** No CPU frequency scaling — `ls /sys/devices/system/cpu/cpufreq/` is empty, no `scaling_governor`, no frequency control. CPU runs at whatever frequency the firmware decides.

**Root cause:** The in-tree `scmi_cpufreq` module is not auto-loaded at boot. The SCMI firmware has a cosmetic bug (duplicate OPP entry at 2956800 for NCC1), but it doesn't prevent the module from working — it just doesn't get triggered automatically via device modalias matching.

**Evidence from dmesg:**
```
arm-scmi arm-scmi.0.auto: [Firmware Bug]: Failed to add opps_by_lvl at 2956800 for NCC1 - ret:-16
```

**Solution:** Autoload the existing in-tree `scmi_cpufreq` module at boot:

```bash
echo "scmi_cpufreq" | sudo tee /etc/modules-load.d/scmi-cpufreq.conf
```

**Result:** Two cpufreq policies created — efficiency cluster (CPUs 0-3) and performance cluster (CPUs 4-7):

```
policy0: CPUs 0-3, 710MHz–2.96GHz, governor schedutil
policy4: CPUs 4-7, 710MHz–2.96GHz, governor schedutil
```

**Verify:**
```bash
cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor    # → schedutil
cat /sys/devices/system/cpu/cpufreq/policy0/scaling_available_frequencies
# → 710400 806400 998400 1190400 1440000 1670400 1920000 2188800 2380800 2611200 2956800
```

| Property | Value |
|----------|-------|
| **SCMI protocol** | v2.0, Qualcomm firmware |
| **Perf domains** | 3 (2 CPU clusters + 1 unknown NCC1) |
| **Efficiency cluster** | CPUs 0-3, policy0 |
| **Performance cluster** | CPUs 4-7, policy4 |
| **Frequency range** | 710.4 MHz – 2956.8 MHz (11 OPPs) |
| **Default governor** | `schedutil` (frequency follows CPU utilization) |
| **Firmware bug** | Duplicate OPP 2956800 for NCC1 — cosmetic, `EEXIST` logged but non-fatal |
| **Config file** | `/etc/modules-load.d/scmi-cpufreq.conf` |
| **Battery cap** | `scaling_max_freq` 2380800 on battery, 2956800 on AC/USB — udev rule `99-battery-freq-cap.rules` runs `/usr/local/bin/vivobook-battery-freq-cap` on `qcom-battmgr-ac`/`-usb` events and at boot coldplug |

---

### 15. CDSP/NPU Fix

**Problem:** The Compute DSP (CDSP / Hexagon NPU) stays offline at boot — `remoteproc1` fails to load firmware with error `-2` (ENOENT).

**Root cause:** Same as achievement #4 (ADSP/battery). The `remoteproc` for CDSP probes during early boot when only the initramfs is available. The firmware `qccdsp8380.mbn` existed on the rootfs but wasn't included in the initramfs, so the kernel couldn't find it.

**Evidence from dmesg:**
```
remoteproc remoteproc1: cdsp is available
remoteproc remoteproc1: Direct firmware load for qcom/x1p42100/ASUSTeK/zenbook-a14/qccdsp8380.mbn failed with error -2
remoteproc remoteproc1: powering up cdsp
remoteproc remoteproc1: Direct firmware load for qcom/x1p42100/ASUSTeK/zenbook-a14/qccdsp8380.mbn failed with error -2
```

**Solution:** Add CDSP firmware to initramfs via dracut:

```bash
echo 'install_items+=" /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/qccdsp8380.mbn /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/cdsp_dtbs.elf /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/cdspr.jsn "' | sudo tee /etc/dracut.conf.d/qcom-cdsp-firmware.conf
sudo dracut --force
```

**Verify:**
```bash
cat /sys/class/remoteproc/remoteproc1/state    # → running
cat /sys/class/remoteproc/remoteproc1/name     # → cdsp
```

| Property | Value |
|----------|-------|
| **Remoteproc** | `remoteproc1` (CDSP) |
| **Firmware** | `qccdsp8380.mbn` (3.1MB, ELF Qualcomm DSP6) |
| **Support files** | `cdsp_dtbs.elf`, `cdspr.jsn` |
| **FastRPC contexts** | 13 compute callback contexts (cb@1 through cb@13) |
| **IOMMU groups** | Groups 15–26 |
| **Config file** | `/etc/dracut.conf.d/qcom-cdsp-firmware.conf` |

---

### 16. Battery Charge Control Fix

**Problem:** Battery charge thresholds read as 0 and `technology` reports "Unknown" — firmware sends string `OOD` which the kernel `qcom_battmgr` driver doesn't recognize.

**Root cause:** The thresholds were never "stuck" — they were simply unset (0 = no limit). The `qcom_battmgr` driver supports `charge_control_end_threshold` writes, which the ADSP firmware honors. The `OOD` technology string is a cosmetic firmware quirk that doesn't affect charge control functionality.

**Evidence from dmesg:**
```
Unknown battery technology 'OOD'
```

**Solution:** udev rule to set charge limit when the battery device appears:

```bash
echo 'SUBSYSTEM=="power_supply", KERNEL=="qcom-battmgr-bat", ATTR{charge_control_end_threshold}="80"' | sudo tee /etc/udev/rules.d/99-battery-charge-limit.rules
sudo udevadm control --reload-rules
```

**Verify:**
```bash
cat /sys/class/power_supply/qcom-battmgr-bat/charge_control_end_threshold    # → 80
cat /sys/class/power_supply/qcom-battmgr-bat/charge_control_start_threshold  # → 50 (auto-set by firmware)
```

| Property | Value |
|----------|-------|
| **Driver** | `qcom_battmgr` via `pmic_glink` |
| **Battery** | X321-42 50Wh, serial 10956 |
| **Charge stop** | 80% (`charge_control_end_threshold`) |
| **Charge start** | 50% (auto-set by firmware when end=80) |
| **Technology** | Reported as "OOD" by firmware — cosmetic, non-functional |
| **Config file** | `/etc/udev/rules.d/99-battery-charge-limit.rules` |

---

### 17. RGB Camera Fix

**Problem:** The Zenbook A14 DTB has no CAMSS, CAMCC, CCI, or CSIPHY device tree nodes. INSYDE firmware blocks all DTB override methods. Without these subsystems, the OV02C10 camera sensor has no I2C bus, no clocks, no ISP pipeline, and no power.

**Root cause:** 8 problems solved iteratively:

1. **No DT nodes** — overlay via `of_overlay_fdt_apply()` in a DKMS module
2. **Overlay -22 (EINVAL)** on CCI child nodes — solved with two-phase overlay (CCI disabled in phase 1, enabled in phase 2)
3. **CCI crash `list_add corruption`** — CCI1 only had `i2c-bus@1`, master[0] never initialized — added empty `i2c-bus@0`
4. **Regulator not registering** — RPMH parent already probed, overlay child ignored — created separate `regulators-9` block
5. **pm8010 absent** — camera PMIC doesn't exist physically. Power topology from AeoB firmware: AVDD/DVDD via `vreg_l7b_2p8` (PM8550B), DOVDD via `vreg_l3m_1p8` (RPMH fire-and-forget)
6. **`cam_cc_pll8 failed to enable!`** — runtime PM suspends CAMCC after probe, MMCX powers off, all PLL registers lost (L=0). Fix: `pm_runtime_get_sync(camcc_dev)` holds CAMCC awake
7. **Image upside down** — added `rotation = <180>` to sensor DT node
8. **`cam_cc_slow_ahb_clk_src` WARN on every `streamon`** — `qcom_camss` votes a `cpas_ahb` rate on `x1e80100` and trips `clk-rcg2.c:update_config()`. Fix: patched `qcom_camss` override skips the explicit `cpas_ahb` rate vote on `qcom,x1e80100-camss`

**Solution:** final RGB stack is three layers:

1. `vivobook_cam_fix` v2.0 — two-phase DT overlay + runtime PM holds for CAMCC/CAMSS/CCI
2. patched `libcamera` v0.7.0 — `ov02c10` static properties/YAML so `cam -l` is clean
3. patched `qcom_camss` override in `/lib/modules/$(uname -r)/updates/qcom-camss.ko` — removes the residual `cpas_ahb` rate vote that caused `cam_cc_slow_ahb_clk_src` warnings

Loaded on-demand:

```bash
# Load camera (creates /dev/video0, /dev/media0, etc.)
vivobook-camera start

# Or manually:
sudo systemctl start vivobook-camera

# Check status
vivobook-camera status
```

**Why on-demand (not auto-load):** CCI adapters create dynamic I2C buses that shift Geni I2C bus numbering. Auto-loading at boot could break keyboard and touchpad modules. The privacy shutter is purely mechanical (no GPIO/HID event), so software detection of open/close is not possible.

**What works:**
- `cam -l` (clean enumeration)
- `cam --capture=1` (libcamera direct)
- `cam -c 1 --capture=10 --stream role=video,width=1280,height=720` (~30 fps)
- GNOME Snapshot app (via PipeWire/WirePlumber)
- Any V4L2/libcamera/PipeWire app

**What doesn't work:**
- `rmmod vivobook_cam_fix` — CAMCC GDSC corruption on re-probe, kernel crash. Unload only via reboot
- IR camera — pm8010 PMIC physically absent, sensor has no power (see [Camera Research](#camera-research))

**Validated on clean boot (2026-03-24):**

- service starts cleanly
- `cam -l` clean
- still frame capture works
- 720p video stream works at ~30 fps
- `journalctl -k -b` stays clean for:
  - `cam_cc_slow_ahb_clk_src`
  - `Lucid PLL latch failed`
  - `cam_cc_pll8`
  - `clock enable failed`
  - `Oops` / `soft lockup`

Detailed bring-up log and timestamps: [docs/research/2026-03-24-rgb-camera-progress.md](docs/research/2026-03-24-rgb-camera-progress.md)
Kernel-side `qcom_camss` diff used for the final warning fix: [docs/research/qcom-camss-x1e80100-cpas-ahb-fix.patch](docs/research/qcom-camss-x1e80100-cpas-ahb-fix.patch)

| Property | Value |
|----------|-------|
| **Sensor** | OmniVision OV02C10, 2MP, 1920×1080 |
| **Bus** | CCI1 bus 1 (AON), GPIOs 235/236, addr `0x36` |
| **Clock** | `cam_cc_mclk4_clk` 19.2MHz, GPIO 100 |
| **Reset** | GPIO 237 (active low) |
| **Power** | AVDD/DVDD: `vreg_l7b_2p8` (2.8V), DOVDD: `vreg_l3m_1p8` (1.8V) |
| **Privacy LED** | GPIO 110 |
| **Privacy shutter** | Mechanical slide — no electronic event |
| **DKMS module** | `vivobook-cam-fix` v2.0 in `/usr/src/vivobook-cam-fix-2.0/` |
| **Kernel override** | `qcom-camss.ko` in `/lib/modules/$(uname -r)/updates/` |
| **libcamera state** | `ov02c10` properties + YAML installed, clean `cam -l` |
| **Service** | `vivobook-camera.service` (oneshot, on-demand, never enabled) |
| **Command** | `vivobook-camera start\|status` |

### 18. Claude Code Flicker Fix

PTY proxy that eliminates terminal flicker from Claude Code on ARM/Wayland.

**Problem:** Claude Code does erase+rewrite on every streamed token. On ARM/Wayland (Adreno GPU, Ptyxis/VTE), the redraw gap between erase and rewrite is visible — causing constant flicker during long conversations, especially during full conversation reloads/compaction. The Vulkan pool fix (#9) eliminates GPU-level fragmentation, but the terminal-level erase+rewrite pattern still produces flicker under sustained streaming.

**Root cause (two-layer):**

1. Each token from Claude Code (Ink.js) triggers cursor movement + erase + write, arriving as separate write syscalls at streaming speed.
2. **Critical:** Claude Code already wraps every individual write with Mode 2026 markers (`\e[?2026h...\e[?2026l`). When sync_render adds an outer Mode 2026 pair, VTE receives nested pairs and doesn't reference-count them — it renders after each inner `\e[?2026l`, causing ~200 renders during a conversation reload instead of one per coalescing window.

**Fix:** `sync_render` — a PTY proxy that:
1. Coalesces rapid writes within a 5ms window (catches all erase+rewrite pairs, typically <1ms apart)
2. **Strips inner `\e[?2026h`/`\e[?2026l` markers** from the coalesced buffer before wrapping
3. Wraps the entire batch with a single outer Mode 2026 pair — VTE renders once per 5ms window

```bash
# Build
gcc -o sync_render sync_render.c -lutil

# Use
./sync_render claude
./sync_render -- claude -p "hello"

# Install system-wide (optional)
sudo cp sync_render /usr/local/bin/
```

**Result:** Zero flicker. Terminal renders each update atomically instead of showing intermediate erase states.

The terminal profile runs every shell inside `sync_render` — so **all apps** launched from the terminal (claude, vim, any CLI) are automatically covered, with no per-app wrappers needed:

```bash
# Build and install sync_render
gcc -o sync_render sync_render.c -lutil
sudo cp sync_render /usr/local/bin/sync_render

# Configure Ptyxis profile to use sync_render as shell wrapper
UUID=$(dconf read /org/gnome/Ptyxis/default-profile-uuid | tr -d "'")
dconf write /org/gnome/Ptyxis/Profiles/${UUID}/use-custom-command true
dconf write /org/gnome/Ptyxis/Profiles/${UUID}/custom-command "'sync_render /bin/bash --login'"
```

Every new terminal tab starts `bash` running inside `sync_render`'s PTY proxy. Any app launched from that shell writes through the slave PTY, which sync_render intercepts at the master level — coalescing and Mode 2026 markers apply to everything transparently.

| Property | Value |
|----------|-------|
| **Affected app** | Claude Code (and any CLI that does rapid erase+rewrite) |
| **Root cause** | Nested Mode 2026 pairs (Ink.js wraps every write + sync_render outer) — VTE renders after each inner `\e[?2026l` |
| **Fix** | `sync_render` strips inner markers + coalesces 5ms + wraps with single outer Mode 2026 pair |
| **Protocol** | [Mode 2026 synchronized output](https://gist.github.com/fnky/458719343aabd01cfb17a3a4f7296797) |
| **Terminal support** | GNOME Terminal/VTE, kitty, foot, WezTerm (not alacritty) |
| **Latency** | 5ms coalescing window — imperceptible |
| **Activation** | Automatic — Ptyxis profile uses `sync_render /bin/bash --login` as shell |

> **Note**: Mode 2026 is supported by VTE-based terminals (Ptyxis, GNOME Terminal, kgx). Combined with the Vulkan pool fix (#9) and hardware Vulkan (`VK_DRIVER_FILES`), this eliminates both GPU-level and terminal-level flicker on any Wayland compositor.

---

### 19. Display Color Control Fix

CTM-based saturation and contrast control for the eDP panel via a kernel module that commits color matrices directly through the DRM atomic API.

**Problem:** The display has no hardware brightness curve control accessible from Linux userspace. The standard tools all fail:

- `ddcutil`: eDP panel does not expose DDC/CI over i2c — no response on any bus
- `wl-gammarelay-rs` / `zwlr_gamma_control_manager_v1`: requires `GAMMA_LUT` DRM property. msm_dpu calls `drm_crtc_enable_color_mgmt(crtc, 0, true, 0)` — CTM enabled, but `GAMMA_LUT` size is 0 (not supported by PCC hardware). niri logs: `couldn't get gamma properties: missing GAMMA_LUT property`

**Root cause:** The Qualcomm Display Processing Unit (`msm_dpu`) exposes a CTM (Color Transformation Matrix) through its PCC (Panel Color Correction) hardware block, but PCC does not implement a gamma lookup table. All userspace gamma tools depend on `GAMMA_LUT`.

**Fix:** `vivobook_color_ctrl` — a DKMS kernel module that:

1. Finds the DRM device via `bus_find_device_by_name(&platform_bus_type, NULL, "ae01000.display-controller")` + child device iteration (walking the "drm" class children to get `struct drm_minor *`)
2. Builds a 3×3 BT.709 luma-preserving saturation matrix combined with a contrast scalar
3. Commits it as a `drm_property_blob` via `drm_atomic_commit` from kernel space — bypassing the DRM master restriction that blocks userspace tools

**Two bugs worked around in msm_dpu:**

1. **`CONVERT_S3_15` sign bug** (`dpu_crtc.c`): The macro `(((u64)val & ~BIT_ULL(63)) >> 17) & GENMASK(17,0)` strips the sign bit, treating all CTM values as positive. Negative off-diagonal elements (needed for saturation > 1.0) become positive, adding brightness instead of subtracting. Fix: encode negative values as 18-bit 2's complement trick: `twos = (0x40000 - hw) & 0x3FFFF; return twos << 17`

2. **`color_mgmt_changed` not set**: `_dpu_crtc_setup_cp_blocks()` has guard `if (!state->color_mgmt_changed && !drm_atomic_crtc_needs_modeset(state)) return;` — setting `crtc_state->ctm` directly bypasses the DRM property path that normally sets this flag. Must set `crtc_state->color_mgmt_changed = true` explicitly.

```bash
# Build and load
cd ~/Documents/wifiteste/modules/vivobook-color-ctrl-1.0
make
sudo insmod vivobook_color_ctrl.ko

# Adjust (each write causes a brief display flash — expected)
echo "1.0" | sudo tee /sys/kernel/vivobook_color/saturation
echo "1.15" | sudo tee /sys/kernel/vivobook_color/contrast

# Current defaults: saturation=1.000 (neutral), contrast=1.150
```

| Property | Value |
|----------|-------|
| **Sysfs** | `/sys/kernel/vivobook_color/saturation`, `/sys/kernel/vivobook_color/contrast` |
| **Range** | 0.000 – 2.000 (1.000 = identity) |
| **Hardware** | msm_dpu PCC block, 18-bit S3.15 coefficients |
| **Display flash** | Expected on each write — PCC hardware reprogrammed via atomic commit |
| **DKMS** | `vivobook-color-ctrl` — autoinstall configured, manual `insmod` needed until boot autoload set up |

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
    qcom-cdsp-firmware.conf    → install_items+=" qccdsp8380.mbn cdsp_dtbs.elf cdspr.jsn "
    no-tpm.conf                → omit_dracutmodules+=" tpm2-tss systemd-pcrphase "
    no-nfs.conf                → omit_dracutmodules+=" nfs "

/etc/modules-load.d/
    wcn-regulator-fix.conf     → wcn_regulator_fix
    vivobook-kbd-fix.conf      → vivobook_kbd_fix
    vivobook-bl-fix.conf       → vivobook_bl_fix
    vivobook-hotkey-fix.conf   → vivobook_hotkey_fix
    scmi-cpufreq.conf          → scmi_cpufreq

/usr/src/
    wcn-regulator-fix-1.0/     → DKMS module source
    vivobook-kbd-fix-1.0/      → DKMS module source
    vivobook-bl-fix-1.0/       → DKMS module source
    vivobook-hotkey-fix-1.0/   → DKMS module source
    vivobook-cam-fix-2.0/      → DKMS camera module (on-demand, NOT auto-loaded)

/etc/systemd/system/
    vivobook-camera.service    → On-demand camera loader (never enabled)

/usr/local/lib64/
    vk_pool_fix.so             → Vulkan pool fix library

/usr/local/bin/
    ptyxis-fixed               → Wrapper script with VK_DRIVER_FILES + LD_PRELOAD
    sync_render                → PTY proxy binary
    vivobook-camera            → Camera on-demand start/status command

~/.local/share/gnome-shell/extensions/battery-time@wifiteste/
    extension.js               → Battery time GNOME extension
    metadata.json

~/.config/environment.d/
    vulkan-hardware.conf       → Force freedreno ICD (hardware Vulkan for all apps)

~/.local/share/dbus-1/services/
    org.gnome.Ptyxis.service   → D-Bus override for LD_PRELOAD

~/.local/share/applications/
    org.gnome.Ptyxis.desktop   → Desktop entry override

/usr/share/alsa/ucm2/conf.d/x1e80100/x1e80100.conf
    Regex: added "Vivobook 14" to ASUS match group
/usr/share/alsa/ucm2/Qualcomm/x1e80100/x1e80100.conf
    Regex: added "Vivobook 14" to ASUS match group (same change)

/etc/systemd/logind.conf.d/
    no-suspend.conf            → HandleLidSwitch=suspend (s2idle), IdleAction=ignore

systemd masked targets:
    hibernate.target, hybrid-sleep.target, suspend-then-hibernate.target
    (sleep.target and suspend.target unmasked since 2026-08-24 — s2idle validated)

/etc/udev/rules.d/
    99-battery-charge-limit.rules → charge_control_end_threshold=80

/usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/
    qcadsp8380.mbn, adsp_dtbs.elf, adspr.jsn, adsps.jsn, adspua.jsn, battmgr.jsn
    qccdsp8380.mbn, cdsp_dtbs.elf, cdspr.jsn
    qcdxkmsucpurwa.mbn

/usr/lib/firmware/ath11k/WCN6855/hw2.1/
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

## Camera Research

### Hardware — Sensors

The Vivobook 14 X1407QA has an FHD IR camera module. DSDT analysis (Zenbok A14 ACPI tables) shows **2 active camera devices** (CAMF + CAMI). The 4 physical lenses are: RGB, IR flood, IR dot projector, and auxiliary lens (same PCB, single controller).

| Sensor | Type | Status | Details |
|--------|------|--------|---------|
| **OV02C10** | RGB | :white_check_mark: **Working** | CCI1 bus 1 (AON), addr `0x36`, MCLK4, libcamera + Snapshot OK |
| **IR sensor** | IR | :x: **Blocked** | pm8010 PMIC physically absent — AVDD (LDO7_M 2.9V) has no power source |

**Privacy shutter:** Mechanical slide cover only — no GPIO, no HID event, no software detection possible. Confirmed by monitoring dmesg/journalctl during open/close cycles.

### Camera Pipeline (working)

```
OV02C10 → CCI1 bus 1 (I2C) → CSIPHY4 (MIPI CSI-2) → CSID → VFE/IFE → V4L2 → libcamera → PipeWire → App
```

All components loaded via DKMS two-phase DT overlay (`vivobook_cam_fix` v2.0):

| Component | Module | Status |
|-----------|--------|--------|
| Camera Clock Controller | `camcc-x1e80100` | Probes OK, held awake via `pm_runtime_get_sync` |
| Camera Subsystem | `qcom-camss` | Probes OK — CSID, VFE, CSIPHY registered |
| CCI (camera I2C) | `i2c-qcom-cci` | Probes OK — CCI1 bus 1 active |
| OV02C10 sensor | `ov02c10` | Probes OK — `/dev/video0`, `/dev/media0` |

### Problems solved (v1.0 → v2.0)

| # | Problem | Root cause | Fix |
|---|---------|-----------|-----|
| 1 | No DT nodes for camera | Zenbook A14 DTB has no CAMSS/CCI | Runtime DT overlay via `of_overlay_fdt_apply()` |
| 2 | Overlay -22 (EINVAL) | CCI probe during overlay apply conflicts with changeset | Two-phase overlay: CCI disabled in phase 1, enabled in phase 2 |
| 3 | CCI crash `list_add corruption` | CCI1 only had `i2c-bus@1`, master[0] uninitialized | Added empty `i2c-bus@0` |
| 4 | Regulator not registering | RPMH parent already probed, ignores overlay children | Separate `regulators-9` block |
| 5 | Sensor no power | pm8010 absent | Power from PM8550B: AVDD/DVDD `vreg_l7b_2p8`, DOVDD `vreg_l3m_1p8` (RPMH fire-and-forget) |
| 6 | PLL8 enable timeout (-110) | Runtime PM suspends CAMCC → MMCX off → PLL registers lost | `pm_runtime_get_sync(camcc_dev)` holds CAMCC awake |
| 7 | Image upside down | Sensor mounted 180° | `rotation = <180>` in DT node |

### IR Camera — Blocked

| Test | Result |
|------|--------|
| Replace AVDD with `vreg_l7b_2p8` (PM8550B) | Regulator OK but wrong physical wire — sensor NACK (-ENXIO) |
| RPMH direct write via `cmd_db_read_addr("ldom7")` | Write accepted (addr 0x41600) but no real voltage — pm8010 doesn't exist |
| `regulator-fixed` dummy + scan all CCI buses | All buses empty at all addresses |

**Conclusion:** pm8010 is in CMD-DB (from reference design) but not physically on the board. No one upstream has IR camera working on Snapdragon X Linux.

**Future paths:** (a) wait for upstream ISP support (Spectra 695), (b) find alternative LDO on the board, (c) extract DSDT from Windows laptop with same SoC.

### AeoB Firmware Data

**CAMF (RGB Front — Purwa variant):**

| Property | Value |
|----------|-------|
| AVDD + DVDD | `vreg_l7b_2p8` (PM8550B LDO7, 2.8V) — module has internal LDO for DVDD 1.2V |
| DOVDD | `vreg_l3m_1p8` (pm8010 LDO3, 1.8V) — RPMH fire-and-forget works |
| Clock | `cam_cc_mclk4_clk` (MCLK4, GPIO 100) |
| Reset | GPIO 237 (active low) |
| CCI | Bus 1 AON (GPIOs 235/236) |
| LED | GPIO 110 |

**CAMI (IR Camera — generic MTP, not Purwa-specific):**

| Property | Value |
|----------|-------|
| AVDD | `vreg_l7m` (pm8010 LDO7, 2.9V) — **BLOCKED: pm8010 absent** |
| DOVDD | `vreg_l4m` (pm8010 LDO4, 1.8V) |
| Clock | `cam_cc_mclk0_clk` (MCLK0, GPIO 96) |
| Reset | GPIO 109 (active low) |

### Upstream patch status

| Patch series | Author | Version | Target | Status |
|-------------|--------|---------|--------|--------|
| [x1e80100 CAMSS dt-bindings + dtsi](https://lkml.org/lkml/2026/2/25/1157) | Bryan O'Donoghue (Linaro) | v8→[v9](https://lkml.org/lkml/2026/2/26/1172) (7 patches) | linux-next | In review (Feb 2026) — v9 reduz para 7 patches + PHY API |
| [x1e/Hamoa camera DTSI](https://lkml.org/lkml/2026/2/26/1238) | Bryan O'Donoghue | v1 (11 patches) | linux-next | In review (Feb 2026) — cobre Dell/Lenovo, **não Purwa** |
| [CAMSS driver for X1 Elite](https://lore.kernel.org/all/20250314-b4-media-comitters-next-25-03-13-x1e80100-camss-driver-v2-7-d163d66fcc0d@linaro.org/T/) | Bryan O'Donoghue | v2 (7 patches) | media-committers/next | In review |
| [ov08x40 on x1e80100 CRD](https://lwn.net/Articles/992466/) | Bryan O'Donoghue | — | — | Merged/WIP |

---

## Future Development

### WiFi Calibration

WiFi now uses the device-specific Windows `NFA765a_AS_SA_X14QA` board data.
For upstream-friendly packaging:

1. **Create a proper `board-2.bin`** entry for subsystem `105b:e130`
2. **Determine redistribution/upstream licensing** for the vendor-derived board data

### Upstream Audio UCM2

Submit PR to [alsa-ucm-conf](https://github.com/alsa-project/alsa-ucm-conf) to add `Vivobook 14` to the X1E80100 machine regex permanently:

1. **File**: `ucm2/conf.d/x1e80100/x1e80100.conf` and `ucm2/Qualcomm/x1e80100/x1e80100.conf`
2. **Change**: Add `Vivobook 14` to the ASUS regex group: `(Zenbook A14|Vivobook S 15)` → `(Zenbook A14|Vivobook S 15|Vivobook 14)`
3. **Profile**: Uses existing `LENOVO-T14s.conf` (2 WSA884x speakers, WCD938x codec) — same audio topology as Zenbook A14

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
| UCM2 Vivobook 14 audio | Not submitted yet | alsa-ucm-conf |
| x1e80100 CAMSS (camera subsystem) | v9 por Bryan O'Donoghue (Linaro), 7 patches — só Hamoa | ~6.21/6.22 |
| x1e/Hamoa camera DTSI | v1 por Bryan O'Donoghue, 11 patches — Dell/Lenovo, não Purwa | ~6.21/6.22 |
| OV02C10 sensor driver | Merged (Hans de Goede) | 6.19 (available) |
| PDC wakeup + s2idle | v1 by Maulik Shah (Qualcomm), 5 patches | ~6.21/7.0 |

---

## Repository Structure

```
.
├── build-vivobook-iso.sh          # ISO builder — download, patch, flash
├── setup-vivobook.sh              # Post-install — apply all 19 fixes
├── vivobook-update.sh             # Safe update manager
├── extract-qcom-firmware.sh       # Extract firmware from Windows
├── install-battery-time-ext.sh    # GNOME battery time extension
├── post-install-protect.sh        # Kernel update boot protection
├── vk_pool_fix.c                  # Vulkan descriptor pool fix (source)
├── sync_render.c                  # PTY proxy for flicker-free terminal (source)
├── sync_render                    # PTY proxy binary
├── x1p42100-asus-zenbook-a14-wifi-fix.dtb  # Custom DTB with WiFi regulator
├── docs/
│   ├── GUIA-EXTRAIR-FIRMWARE.md   # Firmware extraction guide (PowerShell)
│   ├── GUIA-POS-INSTALACAO.md     # Post-install kernel protection guide
│   └── research/                  # Hardware research notes
│       ├── BRIGHTNESS-FIX-STATUS.md
│       ├── BRIGHTNESS-RESEARCH.md
│       ├── CAMERA_STATUS.md
│       ├── 2026-03-16-s2idle-suspend-fix.md
│       └── 2026-03-24-usb4-custom-kernel-plan.md
├── USB4-TB3-investigation.md      # USB4 / Thunderbolt 3 reverse-engineering notes
├── modules/
│   ├── vivobook-cam-fix-2.0/     # Camera DKMS module + systemd service
│   │   ├── vivobook_cam_fix.c
│   │   ├── vivobook_cam_phase1.dts
│   │   ├── vivobook_cam_phase2.dts
│   │   ├── vivobook-camera.service
│   │   ├── vivobook-camera
│   │   ├── Makefile
│   │   └── dkms.conf
│   └── vivobook-color-ctrl-1.0/  # Display color control — CTM saturation + contrast
│       ├── vivobook_color_ctrl.c
│       ├── Makefile
│       └── dkms.conf
└── CLAUDE.md                      # AI assistant project rules
```

## Known Issues

- **DTB override impossible** on INSYDE firmware — all hardware fixes must use kernel modules
- **Audio**: UCM2 fix modifies system file — will be overwritten by `alsa-ucm-conf` updates (needs upstream PR)
- **GPU**: Firmware must be in initramfs for early loading. SELinux may block `.xz` firmware (`setenforce 0` as workaround)
- **TPM**: No fTPM support in Linux for Snapdragon X — devices masked to avoid boot delay
- **Camera RGB**: Working on-demand (`vivobook-camera start`) with clean `libcamera`, still frame, and 720p30 video. Not auto-loaded at boot to avoid I2C bus renumbering. `rmmod` causes CAMCC GDSC corruption — reboot to unload (see [Camera Fix](#17-rgb-camera-fix))
- **Camera IR**: pm8010 PMIC physically absent — sensor has no power. No one upstream has IR camera working on Snapdragon X Linux (see [Camera Research](#camera-research))
- **Suspend**: `deep` (S3) still crashes and stays disabled. `s2idle` validated 2026-08-24 on the installed `7.2.0-x1407qa` — 2 clean cycles, ~0.80W suspended (see [Lid Close Fix](#13-lid-close-fix)). No RTC alarm on pm8xxx — wake by lid/power button only ([#4](https://github.com/pir0c0pter0/fedora-vivobook-x1407q/issues/4))
- **USB4 / Thunderbolt 3**: Plain DP alt-mode works, but TB3 dock tunneling is blocked. `data_role` may initialize wrong, UCSI exposes no `ALT_MODE_OVERRIDE`, the normal firmware path never delivers `USBC_NOTIFY`, and current kernels still lack Qualcomm `x1e80100` host/router support. See [USB4/TB3 Status](#usb4tb3-status-mar-2026)
- **~~cpufreq~~**: Fixed — `scmi_cpufreq` autoload via `/etc/modules-load.d/` ([#2](https://github.com/pir0c0pter0/fedora-vivobook-x1407q/issues/2))
- **~~CDSP/NPU offline~~**: Fixed — firmware in initramfs (see [CDSP/NPU Fix](#15-cdspnpu-fix)). Nota: Qualcomm **fechou a issue** sobre open-source dos headers DSP Snapdragon X (abr 2026) — não vão liberar. Proposta de driver alternativo QDA no kernel, mas incompatível com stack fastrpc existente.
- **~~Battery charge control~~**: Fixed — udev rule sets 80% charge limit (see [Charge Control Fix](#16-battery-charge-control-fix))
- **~~USB-C device links~~**: Cosmetic — `pmic_glink` logs `Failed to create device link (0x180)` for PS8833 retimers at boot. All functionality works ([#6](https://github.com/pir0c0pter0/fedora-vivobook-x1407q/issues/6))
- **1 unknown I2C device** on bus 4: address `0x5b` (may be camera sensor on CCI, not regular I2C)

## Upstream References

- [Zenbook A14 patches](https://patchew.org/linux/20250523131605.6624-1-alex.vinarskis@gmail.com/) by Alex Vinarskis
- [PCIe pwrctrl fix](https://lkml.org/lkml/2026/1/15/415) — 15-patch series targeting kernel ~6.21
- [linux-x1e80100-zenbook-a14](https://github.com/alexVinarskis/linux-x1e80100-zenbook-a14) — Custom kernel repo with camera patch
- [x1e80100 CAMSS patches v9](https://lkml.org/lkml/2026/2/26/1172) — Bryan O'Donoghue (Linaro), 7 patches, em review (Feb 2026) — **apenas x1e80100 (Hamoa), não cobre Purwa**
- [x1e80100 CAMSS patches v8](https://lkml.org/lkml/2026/2/25/1157) — versão anterior, 18 patches
- [x1e/Hamoa camera DTSI](https://lkml.org/lkml/2026/2/26/1238) — Device tree camera nodes para Dell/Lenovo x1e80100
- [Qualcomm QDA DSP Accelerator driver](https://www.phoronix.com/news/Qualcomm-DSP-Accel-Driver) — nova proposta de driver DSP no kernel (interface diferente do fastrpc existente)
- [CAMSS driver for X1 Elite](https://lore.kernel.org/all/20250314-b4-media-comitters-next-25-03-13-x1e80100-camss-driver-v2-7-d163d66fcc0d@linaro.org/T/) — Camera subsystem driver patches
- [ov08x40 on x1e80100 CRD](https://lwn.net/Articles/992466/) — OV08X40 sensor support for reference design
- [USB4 Host Router bindings RFC](https://lkml.org/lkml/2025/9/18/1281) — Qualcomm USB4 host/router bindings discussion

## License

Scripts are MIT. Files under `firmware/` are proprietary Qualcomm/ASUS
firmware and are not covered by the MIT license; see `firmware/README.md`.
