<div align="center">
  <p>
    <img src="https://cdn.simpleicons.org/linux/FCC624" alt="Linux" height="58">
    &nbsp;&nbsp;&nbsp;&nbsp;
    <img src="https://cdn.simpleicons.org/fedora/51A2DA" alt="Fedora Linux" height="58">
    &nbsp;&nbsp;&nbsp;&nbsp;
    <img src="https://cdn.simpleicons.org/qualcomm/3253DC" alt="Qualcomm Snapdragon" height="58">
  </p>

  <h1>Fedora 44 on the ASUS VivoBook 14 X1407QA</h1>

  <p><strong>Linux 7.2 · Snapdragon X · AArch64 hardware enablement</strong></p>

  <p>
    <img src="https://img.shields.io/badge/Fedora-44-51A2DA?style=flat-square&logo=fedora&logoColor=white" alt="Fedora 44">
    <img src="https://img.shields.io/badge/Linux-7.2-FCC624?style=flat-square&logo=linux&logoColor=black" alt="Linux 7.2">
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

## Current status

The table describes the installed Fedora system validated on the X1407QA on
August 24, 2026. It does not replace the pending physical test of the latest
ISO rebuild.

| Area | State |
|---|---|
| Fedora boot and NVMe | ✅ Working |
| Wi-Fi and Bluetooth | ✅ Working |
| Keyboard, touchpad, brightness and hotkeys | ✅ Working |
| Battery reporting and charge limit | ✅ Working |
| GPU acceleration and Vulkan | ✅ Working |
| Audio | ✅ Working |
| RGB camera and PipeWire | ✅ Working |
| IR camera stream | ⚠️ Working without an IR illuminator |
| CDSP and QNN/HTP NPU inference | ✅ Working |
| Suspend | ✅ `s2idle` only; `deep` is unsafe |
| USB-C, USB 3 and DisplayPort | ✅ Working |
| USB4 / Thunderbolt tunneling | ❌ Waiting for the upstream Qualcomm host-router stack |

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
| [August 24 build report](docs/BUILD-REPORT-2026-08-24.md) | Latest hardware validation evidence |
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
