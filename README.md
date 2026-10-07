<div align="center">
  <p>
    <img src="https://cdn.simpleicons.org/linux/FCC624" alt="Linux" height="58">
    &nbsp;&nbsp;&nbsp;&nbsp;
    <img src="https://cdn.simpleicons.org/fedora/51A2DA" alt="Fedora Linux" height="58">
    &nbsp;&nbsp;&nbsp;&nbsp;
    <img src="https://cdn.simpleicons.org/qualcomm/3253DC" alt="Qualcomm Snapdragon" height="58">
  </p>

  <h1>Fedora 44 on the ASUS VivoBook 14 X1407QA</h1>

  <p><strong>Published Linux 7.2 ISO · Linux 7.3-rc6 development kernel · Snapdragon X</strong></p>

  <p>
    <img src="https://img.shields.io/badge/Fedora-44-51A2DA?style=flat-square&logo=fedora&logoColor=white" alt="Fedora 44">
    <img src="https://img.shields.io/badge/Linux-7.2-FCC624?style=flat-square&logo=linux&logoColor=black" alt="Linux 7.2">
    <img src="https://img.shields.io/badge/tested-7.3--rc6-f59e0b?style=flat-square&logo=linux&logoColor=white" alt="Linux 7.3-rc6 tested">
    <img src="https://img.shields.io/badge/Architecture-AArch64-111827?style=flat-square" alt="AArch64">
    <a href="https://github.com/pir0c0pter0/fedora-vivobook-x1407q/releases/latest"><img src="https://img.shields.io/github/v/release/pir0c0pter0/fedora-vivobook-x1407q?style=flat-square&label=release" alt="Latest release"></a>
  </p>
</div>

A community-maintained Fedora image and hardware support stack for the
**ASUS VivoBook 14 X1407QA**, powered by the Snapdragon X1-26-100. The project
turns the machine into a usable Fedora workstation while the remaining
model-specific support works its way upstream.

> [!WARNING]
> This project targets the **X1407QA only**. Keep Secure Boot disabled, use
> `s2idle` instead of `deep` suspend, and keep the live USB available for
> recovery.

## Download the ISO

### [Download the latest release →](https://github.com/pir0c0pter0/fedora-vivobook-x1407q/releases/tag/fedora44-x1407qa-2026.08.24)

| Image | Value |
|---|---|
| File | `Fedora-44-X1407QA-Linux-7.2-all-2026-08-24.iso` |
| Size | 2,982,281,216 bytes |
| SHA-256 | `00c1660804557c666bf98312a8290f440f28b246ca6cc424894ab25e5bc3bd37` |
| Source snapshot | `caaa24b0a789891417f42345983875f0e4739bab` |

The release is distributed as two XZ parts so every GitHub asset stays below
2 GiB. Download both parts and all checksum files into the same directory:

```bash
sha256sum -c Fedora-44-X1407QA-Linux-7.2-all-2026-08-24.iso.xz.parts.sha256
cat Fedora-44-X1407QA-Linux-7.2-all-2026-08-24.iso.xz.part01 \
    Fedora-44-X1407QA-Linux-7.2-all-2026-08-24.iso.xz.part02 \
    > Fedora-44-X1407QA-Linux-7.2-all-2026-08-24.iso.xz
sha256sum -c Fedora-44-X1407QA-Linux-7.2-all-2026-08-24.iso.xz.sha256
xz -dk Fedora-44-X1407QA-Linux-7.2-all-2026-08-24.iso.xz
sha256sum -c Fedora-44-X1407QA-Linux-7.2-all-2026-08-24.iso.sha256
```

The rebuilt ISO passed filesystem, boot layout, kernel, initramfs, firmware,
permissions, payload, archive, and checksum validation. Its first physical
USB boot and installation cycle is still pending.

## Linux 7.3-rc6 development update — October 7, 2026

The installed X1407QA now runs the speed-oriented development kernel
`7.3.0-rc6-x1407qa-perf`. This kernel is validated on the physical notebook,
but it is **not yet the kernel shipped by the downloadable ISO above**. The
public ISO remains the published Linux 7.2 baseline. Its automated artifact
checks passed, but its first physical USB boot and installation are pending.

### What improved

| Area | Improvement in the 7.3-rc6 development build | Validation |
|---|---|---|
| Fedora userspace | Refreshed the Fedora 44 installation in one successful 825-package DNF transaction; installed the native kernel build toolchain | DNF transactions 22 and 23 completed with `Status: Ok` |
| Kernel responsiveness | Built from upstream `v7.3-rc6` with `CONFIG_PREEMPT=y`, 250 Hz timer, `schedutil`, performance compiler optimization, 4 KiB pages, and no LTO | Booted as `7.3.0-rc6-x1407qa-perf`; graphical target reached in 3.762 s |
| Battery reporting | Recognizes the ASUS firmware chemistry code `OOD` as lithium-ion | `/sys/class/power_supply/qcom-battmgr-bat/technology` reports `Li-ion` |
| Battery performance policy | Moved the 2.3808 GHz battery / 2.9568 GHz external-power cap into a tested helper, udev coldplug path, and initramfs | Both CPU-frequency policies switch to the expected limit in regression tests |
| Audio codec controls | Marks WCD938x headphone type and impedance controls read-only and volatile, matching their hardware-detection role | Rebuilt module loads with exact kernel vermagic; speakers and microphones are published by PipeWire |
| Bluetooth | Enables RFCOMM as a kernel module, restoring the Bluetooth serial profile expected by BlueZ | `rfcomm` is loaded after a clean boot; Bluetooth has zero service restarts |
| Desktop sandboxing | Enables the Landlock LSM, which was listed in `CONFIG_LSM` but missing from the old build | Kernel reports `capability,landlock`; LocalSearch starts normally |
| NPU / CDSP boot | Replaces the repeatable first-client CDSP firmware crash with one controlled remoteproc cycle in a separate non-restarting unit, waits 10 seconds for the new FastRPC device, and starts `cdsprpcd` once | Cold boot has no `sleep_statsi` crash, CDSP is `running`, and `NRestarts=0`; a failed attempt cannot cycle it again in the same boot |
| ADSP FastRPC | Starts `adsprpcd` with the explicit `audiopd adsp` arguments instead of relying on an invalid/default domain | `adsprpcd_audiopd.service` is active with zero restarts |
| QNN/HTP inference | Preserves real Hexagon execution after the boot hardening | ONNX Runtime reports `NPU devices: 1` and passes with CPU fallback disabled |
| Display color control | Loads the color-control module at `graphical.target`, after DRM and the camera service, instead of too early in the initramfs | Dedicated systemd unit and regression test verify ordering |

The final cold-boot audit found zero failed systemd units. Audio, Bluetooth,
battery, both cameras, Landlock/LocalSearch, CDSP, and QNN/HTP inference were
all exercised on the notebook. See the
[October 7 build report](docs/BUILD-REPORT-2026-10-07.md) for the build inputs,
patches, commands, evidence, and rollback boundary.

### What is still missing

- **Publish a refreshed ISO:** package the validated Linux 7.3 kernel and new
  service/runtime fixes into an ISO, then repeat physical USB boot,
  installation, recovery, and checksum validation. The Linux 7.2 image above
  remains the published artifact, not yet physically validated recovery media.
- **Upstream the local kernel fixes:** battery chemistry `OOD` handling and
  the WCD938x read-only control semantics remain local patches.
- **USB4 / Thunderbolt tunneling:** USB-C, USB 3, charging, and DisplayPort
  work, but Qualcomm's upstream host-router stack is still incomplete.
- **Deep suspend:** `deep` remains unsafe; keep `s2idle` selected.
- **Native X1P42100 QNN identification:** the current Qualcomm runtime does
  not recognize SoC ID `635`; NPU applications still use the per-process
  `tools/npu-run` override. No global SoC spoof is installed.
- **Monochrome IR in libcamera soft-ISP:** the hardware and V4L2 capture path
  work, but native `R10_CSI2P` soft-ISP support is still missing.
- **Harmless boot-log noise:** PMIC device-link retries, device-tree overlay
  removal warnings, optional FastRPC `.farf` lookups, and an early PipeWire
  route probe remain visible even though the corresponding hardware is
  operational. They are documented rather than hidden.

## Current status

The table describes the installed Fedora system validated on the X1407QA on
October 7, 2026. It does not replace the pending physical test of a refreshed
ISO build.

| Area | State |
|---|---|
| Linux 7.3-rc6 development kernel | ✅ Working on the installed notebook; not yet published as an ISO |
| Fedora boot and NVMe | ✅ Working |
| Wi-Fi and Bluetooth | ✅ Working |
| Keyboard, touchpad, brightness and hotkeys | ✅ Working |
| Battery reporting, charge limit and power-dependent CPU cap | ✅ Working; chemistry now reports `Li-ion` |
| GPU acceleration and Vulkan | ✅ Working |
| Audio | ✅ Working |
| RGB camera and PipeWire | ✅ Working |
| IR camera and illuminator | ✅ Working; 700 mA PM8550 IR torch follows the stream lifecycle |
| CDSP and QNN/HTP NPU inference | ✅ Working; clean cold boot with zero CDSP restarts |
| Suspend | ✅ `s2idle` only; `deep` is unsafe |
| USB-C, USB 3 and DisplayPort | ✅ Working |
| USB4 / Thunderbolt tunneling | ❌ Waiting for the upstream Qualcomm host-router stack |

The IR result was verified after a clean reboot with 30-frame
dark → illuminated → dark captures. Mean luminance changed
`7.98 → 14.17 → 7.98` and p95 changed `9 → 36 → 9`; direct PM8550
readback showed the module/channels active only during the illuminated stream
and back at `ee46=00`, `ee4e=00` after close. Capture a contrast-stretched PNG
through V4L2 with:

```bash
sudo tools/ir-camera-capture.sh 30 /tmp/camera-ir.png
```

The native libcamera soft-ISP still rejects monochrome `R10_CSI2P`; this is a
userspace format limitation, not a sensor or illuminator failure.

## Quick start

1. Download, verify, join, and decompress the release assets above.
2. Write the ISO to a USB drive with Fedora Media Writer or another raw-image
   writer.
3. Disable Secure Boot in firmware settings.
4. Boot **Fedora 44 X1407QA — Linux 7.2 (RAM, principal)** from GRUB.
5. Install Fedora and keep the live USB until the installed system has booted.
6. On the installed system, apply the bundled userspace stack:

```bash
sudo /opt/vivobook-fixes/setup-vivobook.sh
```

If the installed system does not boot, return to the live environment and run:

```bash
sudo rescue-installed-boot --repair
```

## Documentation

| Document | Purpose |
|---|---|
| [Current build state](BUILD-STATE.md) | Exact validated state, release hashes, and remaining work |
| [Detailed technical guide](docs/TECHNICAL-GUIDE.md) | Full installation history, fix guide, commands, and implementation notes |
| [October 7 kernel 7.3 build report](docs/BUILD-REPORT-2026-10-07.md) | Package refresh, kernel configuration, runtime fixes, boot evidence, and remaining work |
| [August 24 build report](docs/BUILD-REPORT-2026-08-24.md) | Full-system ISO/build validation baseline; IR hardware proof is documented above |
| [Firmware extraction guide](docs/GUIA-EXTRAIR-FIRMWARE.md) | Recovering Qualcomm firmware from Windows |
| [Post-install guide](docs/GUIA-POS-INSTALACAO.md) | Current post-install checks and accelerator validation |
| [USB4/TB3 investigation](USB4-TB3-investigation.md) | Host-router reverse engineering and upstream blockers |
| [Research archive](docs/research/) | Camera, Wi-Fi, suspend, USB4, and hardware notes |

## Testing another Snapdragon X device?

Reports from other Snapdragon X laptops are welcome, but support outside the
X1407QA is experimental. Open a
[compatibility report](https://github.com/pir0c0pter0/fedora-vivobook-x1407q/issues/new)
with the exact laptop model, Snapdragon SoC, boot result, working and broken
hardware, and any relevant logs from the detailed guide.

## Scope and licensing

Scripts are MIT-licensed. Files under `firmware/` are proprietary Qualcomm or
ASUS firmware and are not covered by the MIT license; see
[`firmware/README.md`](firmware/README.md).

This is an independent community project and is not affiliated with or
endorsed by ASUS, Fedora, Red Hat, Qualcomm, or the Linux Foundation. Linux,
Fedora, Snapdragon, Qualcomm, and related logos are trademarks of their
respective owners.
