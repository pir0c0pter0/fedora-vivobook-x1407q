<div align="center">
  <p>
    <img src="https://cdn.simpleicons.org/linux/FCC624" alt="Linux" height="58">
    &nbsp;&nbsp;&nbsp;&nbsp;
    <img src="https://cdn.simpleicons.org/fedora/51A2DA" alt="Fedora Linux" height="58">
    &nbsp;&nbsp;&nbsp;&nbsp;
    <img src="https://cdn.simpleicons.org/qualcomm/3253DC" alt="Qualcomm Snapdragon" height="58">
  </p>

  <h1>Fedora on ASUS VivoBook 14 X1407QA &amp; Lenovo Yoga Slim 7 14Q8Y11</h1>

  <p><strong>Two AArch64 notebook ports · Snapdragon X and Snapdragon X2 Plus</strong></p>

  <p>
    <img src="https://img.shields.io/badge/ASUS-Fedora_44-51A2DA?style=flat-square&logo=fedora&logoColor=white" alt="ASUS: Fedora 44">
    <img src="https://img.shields.io/badge/Lenovo-Fedora_45-51A2DA?style=flat-square&logo=fedora&logoColor=white" alt="Lenovo: Fedora 45">
    <img src="https://img.shields.io/badge/Architecture-AArch64-111827?style=flat-square" alt="AArch64">
    <a href="https://github.com/pir0c0pter0/fedora-vivobook-x1407q/releases/latest"><img src="https://img.shields.io/github/v/release/pir0c0pter0/fedora-vivobook-x1407q?style=flat-square&label=ASUS%20release" alt="Latest ASUS release"></a>
  </p>
</div>

Community-maintained Fedora ports for two Qualcomm-powered notebooks:
**ASUS VivoBook 14 X1407QA** and **Lenovo Yoga Slim 7 14Q8Y11**. This
repository contains their model-specific kernel patches, hardware support,
installation tools, and validation records.

## Choose your notebook

Overview updated on **November 17, 2026**. Each port has its own validation
history and limitations.

| Notebook | Platform | Fedora / kernel | Status and guide |
|---|---|---|---|
| **ASUS VivoBook 14 X1407QA** | Snapdragon X, X1-26-100 | Fedora 44; published ISO: Linux 7.2; installed-system validation: Linux 7.3-rc6 | [ISO and installation](#asus-vivobook-14-x1407qa--download-the-iso). Hardware support validated on October 7; the test unit is now non-booting and under [EDL recovery investigation](docs/research/2026-11-03-edl-9008-recovery.md). |
| **Lenovo Yoga Slim 7 14Q8Y11 (83QR)** | Snapdragon X2 Plus, X2P-42-100 / Kalambo | Fedora 45; Linux 7.4.0-rc1-yoga-kalambo+ | [Port guide][yoga-guide] and [experimental live ISO][yoga-live]. The installed system boots from NVMe into accelerated GNOME. |

## What we have achieved on each notebook

ASUS results below were validated on **October 7, 2026**, before the unit
stopped booting and entered the EDL recovery investigation. Yoga results
reflect the working installation on **November 17, 2026**.

| Area | ASUS VivoBook 14 X1407QA | Lenovo Yoga Slim 7 14Q8Y11 |
|---|---|---|
| Fedora desktop | Fedora 44 booting from NVMe with the custom Linux 7.3-rc6 kernel | Fedora 45 booting automatically from NVMe into GNOME with Linux 7.4-rc1 |
| Graphics | GPU acceleration and Vulkan validated | Adreno X2-45 acceleration, OpenGL 4.6 / GLES 3.2; capped at 310 MHz pending calibration |
| Audio | Speakers and microphones working through PipeWire | Four speakers and two microphones validated through PipeWire |
| Cameras | RGB camera, IR capture, and IR illuminator validated | RGB 1080p/~30 fps and IR 640×480/~60 fps; partial Windows color tuning and IR pulse validated |
| NPU | Real QNN/HTP inference with CPU fallback disabled; controlled CDSP startup validated | 100 HTP V81 inferences per process across three boots, without CPU fallback; session reopening still blocks normal use |
| USB and video output | USB-C, USB3, charging, and DisplayPort validated | USB3 in both orientations: right port 5 Gbit/s, both left ports 10 Gbit/s |
| Everyday hardware | Wi-Fi, Bluetooth, input devices, battery, charge limit, and power-dependent CPU limits | Wi-Fi, Bluetooth, input devices, touchscreen, battery, CPU frequency control, EC, and hardware clock |
| Suspend | `s2idle` validated; `deep` unsafe | Disabled and untested |
| Installation media | Fedora 44 / Linux 7.2 ISO published; artifact checks passed, physical installation cycle pending | [Experimental live ISO][yoga-live]; the installed system was validated on one device |

Both ports still need work. The ASUS unit is currently non-booting; the Yoga
NPU remains disabled in normal boot, and USB4 is not enabled on either model.

> [!WARNING]
> Use only the files and instructions for your exact model. The published
> ISO and root-level `vivobook` scripts target the **ASUS X1407QA**.
> Lenovo files live under `ports/lenovo-yoga-slim7-14q8y11/`; they target the
> **X2 Plus / Kalambo** variant and are not interchangeable with ASUS or
> X2 Elite device trees.

## Lenovo Yoga Slim 7 14Q8Y11 — current port

Fedora 45 boots automatically from the internal SSD with a 1920×1200 60 Hz
display, brightness control, GNOME, Wi-Fi, Bluetooth, battery reporting,
keyboard, touchpad, touchscreen, hotkeys, and hardware clock.

- **GPU:** Adreno X2-45 acceleration with Mesa 26.2.3, OpenGL 4.6 and
  GLES 3.2. Frequency is capped at 310 MHz pending calibration; Vulkan is
  untested.
- **Audio:** four speakers and two microphones validated through PipeWire.
  External headphones and proprietary acoustic calibration remain untested.
- **Cameras:** RGB OV08X40 at 1080p/~30 fps and IR VD55G0 at 640×480/~60 fps
  validated through PipeWire. Windows color tuning is partially imported;
  full calibration, simultaneous capture, and continuous IR illumination
  in applications remain pending.
- **USB3:** right port at 5 Gbit/s and both left ports at 10 Gbit/s, tested
  in both plug orientations. Right-port Gen2 remains unstable; USB4 and
  USB-C video output remain unvalidated.
- **NPU:** 100 HTP V81 inferences per process passed across three boots,
  with CPU fallback disabled and experimental per-process SoC compatibility.
  Reopening a session still fails, including without QNN. **The NPU remains
  disabled during normal boot.**

Suspend is disabled and untested. The running kernel also lacks `nf_tables`
firewall support. The [experimental live ISO][yoga-live] runs from RAM. Read the [live guide][yoga-live-guide] before booting it.

The latest Yoga sources and documentation are on `main`. Start with the [Lenovo port README][yoga-guide],
the [current hardware state][yoga-state], and the
[NPU evidence and reproducer][yoga-npu].

[yoga-live]: https://github.com/pir0c0pter0/fedora-vivobook-x1407q/releases/tag/yoga14q8y11-live-2026.11.18
[yoga-live-guide]: ports/lenovo-yoga-slim7-14q8y11/iso/LIVE.md
[yoga-guide]: https://github.com/pir0c0pter0/fedora-vivobook-x1407q/blob/main/ports/lenovo-yoga-slim7-14q8y11/README.md
[yoga-state]: https://github.com/pir0c0pter0/fedora-vivobook-x1407q/blob/main/ports/lenovo-yoga-slim7-14q8y11/docs/ESTADO-ATUAL.md
[yoga-npu]: https://github.com/pir0c0pter0/fedora-vivobook-x1407q/blob/main/ports/lenovo-yoga-slim7-14q8y11/install/npu/README.md

## ASUS VivoBook 14 X1407QA — download the ISO

The following release, setup commands, and hardware results apply to the
ASUS only. Keep Secure Boot disabled and use `s2idle` instead of `deep`
suspend. The test unit currently responds in EDL 9008 but does not boot;
the [recovery report](docs/research/2026-11-03-edl-9008-recovery.md) records
the unresolved cause and available evidence.

### [Download the ASUS release →](https://github.com/pir0c0pter0/fedora-vivobook-x1407q/releases/tag/fedora44-x1407qa-2026.08.24)

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

## ASUS Linux 7.3-rc6 development update — October 7, 2026

The installed X1407QA was validated with the speed-oriented development kernel
`7.3.0-rc6-x1407qa-perf`. This kernel was tested on the physical notebook,
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
  work. Qualcomm's QMP USB4 PHY v5 has reached `linux-next`, but the public
  host-router driver, binding/DTS, firmware interface, and native-protocol
  integration are still incomplete. Do not remove the X1P42100 PS8833 USB4
  fallback quirk or enable the repository's unsafe synthetic-altmode path.
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

## ASUS validated hardware — October 7, 2026

The table describes the installed Fedora system validated on the X1407QA on
October 7, 2026, before the current EDL recovery case. These are historical
hardware results; they do not replace the pending physical test of a
refreshed ISO build.

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
| USB4 / Thunderbolt tunneling | ❌ PHY is in `linux-next`; still waiting for the public Qualcomm host-router stack |

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

## ASUS quick start

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

## ASUS documentation

| Document | Purpose |
|---|---|
| [October 7 build state](BUILD-STATE.md) | Validated build state, release hashes, and remaining work at that date |
| [Detailed technical guide](docs/TECHNICAL-GUIDE.md) | Full installation history, fix guide, commands, and implementation notes |
| [October 7 kernel 7.3 build report](docs/BUILD-REPORT-2026-10-07.md) | Package refresh, kernel configuration, runtime fixes, boot evidence, and remaining work |
| [August 24 build report](docs/BUILD-REPORT-2026-08-24.md) | Full-system ISO/build validation baseline; IR hardware proof is documented above |
| [Firmware extraction guide](docs/GUIA-EXTRAIR-FIRMWARE.md) | Recovering Qualcomm firmware from Windows |
| [Post-install guide](docs/GUIA-POS-INSTALACAO.md) | Current post-install checks and accelerator validation |
| [USB4/TB3 investigation](USB4-TB3-investigation.md) | October 7 live evidence, QMP PHY v5/PS8833 upstream status, host-router reverse engineering, safety gates, and remaining blockers |
| [EDL 9008 recovery status](docs/research/2026-11-03-edl-9008-recovery.md) | Concise source of truth for completed tests, rejected loaders, known limits, and risk-ranked experiments on the non-booting X1407QA |
| [Research archive](docs/research/) | Camera, Wi-Fi, suspend, USB4, and hardware notes |

## Testing another Snapdragon device?

Reports from other Snapdragon laptops are welcome. The model-specific files
here have only been tested on the two exact devices listed above. Open a
[compatibility report](https://github.com/pir0c0pter0/fedora-vivobook-x1407q/issues/new)
with the exact laptop model, Snapdragon SoC, boot result, working and broken
hardware, and any relevant logs from the detailed guide.

## Scope and licensing

Scripts are MIT-licensed. Files under `firmware/` are proprietary Qualcomm or
ASUS firmware and are not covered by the MIT license; see
[`firmware/README.md`](firmware/README.md).

This is an independent community project and is not affiliated with or
endorsed by ASUS, Lenovo, Fedora, Red Hat, Qualcomm, or the Linux Foundation. Linux,
Fedora, Snapdragon, Qualcomm, and related logos are trademarks of their
respective owners.
