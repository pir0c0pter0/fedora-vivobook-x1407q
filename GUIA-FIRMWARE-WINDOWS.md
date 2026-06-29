# Extract Qualcomm firmware from Windows — `extract-firmware-windows.bat`

Guide for the **ASUS Vivobook 14 X1407QA (Snapdragon X)**.

The Qualcomm firmware (audio/ADSP, GPU, CDSP, WiFi) is **proprietary and signed
for this exact model**. It only exists on the factory **Windows** partition —
there is no generic download. This `.bat` copies that firmware to a USB drive so
you can use it later on Fedora.

---

## ⬇️ The ready-made ISO (download)

Bootable Fedora 44 aarch64 ISO already patched for the Vivobook X1407QA
(Snapdragon boot params + fix scripts bundled in):

- **Link:** https://temp.sh/lzVpY/Fedora-Workstation-Live-44-1.7.aarch64-VivoBook-patched.iso
- **Expires:** ~2026-07-02 (temp.sh keeps files for ~3 days — download soon)
- **SHA256:**
  ```
  0396b34c930bf0149c1d04ee8ff76957019dd6503b34037fe8541f4a82f5c263
  ```

**Download in a browser:** open the link and click *"Click here to download"*.

**Download from a terminal** (temp.sh serves it via POST):

```bash
curl -L -X POST \
  "https://temp.sh/lzVpY/Fedora-Workstation-Live-44-1.7.aarch64-VivoBook-patched.iso" \
  -o Fedora-Workstation-Live-44-1.7.aarch64-VivoBook-patched.iso
```

**Verify integrity** (must match the SHA256 above):

```bash
sha256sum Fedora-Workstation-Live-44-1.7.aarch64-VivoBook-patched.iso
```

**Write to a USB drive** (⚠️ erases the whole USB — double-check `/dev/sdX`):

```bash
sudo dd if=Fedora-Workstation-Live-44-1.7.aarch64-VivoBook-patched.iso \
  of=/dev/sdX bs=4M status=progress oflag=sync && sync
```

> The ISO does **not** include the Qualcomm firmware (proprietary). You extract
> it from your own Windows using the `.bat` below, **before** installing Fedora.

---

## ⚠️ Do this BEFORE you format / install Linux

Installing Fedora **wipes Windows**, and the firmware goes with it. If you've
already wiped Windows without extracting, you'll need the firmware from another
identical Vivobook X1407QA or from a Windows recovery image. **Extract it first.**

Without this firmware, once Linux is installed the following **won't work**:
WiFi, GPU (acceleration), audio, and battery.

---

## Requirements

- Vivobook still running the factory **Windows**.
- A **USB drive** formatted as **FAT32** or **exFAT** (NTFS also works).
- The **`extract-firmware-windows.bat`** file (shipped with this guide / in the project repo).

---

## Step by step (on Windows)

1. Copy **`extract-firmware-windows.bat`** to the **USB drive**.
2. Open the USB drive in File Explorer and **double-click** the `.bat`.
3. A User Account Control (UAC) prompt asks for administrator privileges —
   click **Yes**. (It's required because the firmware lives in a protected
   system folder.)
4. A black window opens and lists the packages it copies (`[+] qcadsp...`,
   `[+] qcdx...`, etc.). Wait until you see **"NEXT STEPS"**.
5. You can close the window. The dump is in the **`vivobook-qcom-firmware\`**
   folder, next to the `.bat`, **on the USB drive itself**.

> Running the `.bat` straight from the USB drive drops the dump onto the USB. If
> you ran it from another folder (e.g. Downloads), move the
> `vivobook-qcom-firmware` folder onto the USB afterwards.

**Keep this USB drive** — you'll use the dump after installing Fedora.

---

## What the `.bat` does (under the hood)

- Self-elevates to **Administrator** (relaunches via PowerShell `RunAs`).
- Reads `C:\Windows\System32\DriverStore\FileRepository`.
- Copies the Qualcomm driver packages **whole** (folders starting with `qc*`:
  `qcadsp*`, `qcdx*`, `qccdsp*`, `qcwlan*`, `qcsubsys*`, …), **including their
  `.inf` files**.
- Preserves the `Windows\System32\DriverStore\FileRepository\...` structure
  inside `vivobook-qcom-firmware\`.
- At the end, prints how many packages and how many `.mbn`/`.bin` files were copied.

> **Why copy whole packages and not just the `.mbn` files?** The Linux-side tool
> (`qcom-firmware-extract`) uses the **`.inf`** files to rename each firmware to
> the exact path/name the kernel expects. The bare `.mbn` files alone are not
> enough.

---

## Use the dump on Fedora (after installing)

On the **installed Fedora** on the Vivobook, plug in the USB drive and run
(adjust the USB path/name):

```bash
# the path is usually /run/media/YOUR_USER/USB_NAME/vivobook-qcom-firmware
sudo ./extract-qcom-firmware.sh /run/media/$USER/USB/vivobook-qcom-firmware

# if the ISO already bundled the scripts:
sudo /opt/vivobook-fixes/extract-qcom-firmware.sh /run/media/$USER/USB/vivobook-qcom-firmware
```

`extract-qcom-firmware.sh` installs/uses `qcom-firmware-extract` and places each
file in the right location:

- `/usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/` (ADSP, GPU ZAP, CDSP)
- `/usr/lib/firmware/ath11k/WCN6855/hw2.1/` (WiFi board data)

Then apply all fixes and reboot:

```bash
sudo /opt/vivobook-fixes/setup-vivobook.sh
sudo reboot
```

---

## Full flow (summary)

1. **(Windows, before formatting)** run `extract-firmware-windows.bat` → dump onto the USB.
2. Write the Vivobook ISO to a USB drive and boot it (F12) → install Fedora to the NVMe.
3. **(Fedora installed)** `extract-qcom-firmware.sh <usb>/vivobook-qcom-firmware`.
4. `setup-vivobook.sh` → all hardware fixes.
5. `sudo reboot`.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| "No Qualcomm driver packages (`qc*`) found" | Not the factory ASUS Windows, or the drivers were removed. Use the device's original Windows. |
| No UAC prompt / "access denied" | Run as administrator: right-click the `.bat` → **Run as administrator**. |
| Window closes instantly | Open **Command Prompt** as admin and run the `.bat` by its path to see the messages. |
| `.bat` opens in a text editor | Right-click → Open with → **Windows Command Processor**, or run it from `cmd`. |
| USB not visible on Fedora | Check the real path: `ls /run/media/$USER/` (or mount it via the file manager). |
| `0 firmware files` at the end | DriverStore has no Qualcomm firmware — confirm it's the correct Vivobook X1407QA. |

---

## What each firmware enables

| Package (Windows `qc*`) | Component on Linux |
|---|---|
| `qcadsp*` | Audio DSP + battery manager (ADSP) |
| `qcdx*` | Adreno X1-45 GPU (ZAP shader `qcdxkmsucpurwa.mbn`) |
| `qccdsp*` | Compute DSP / NPU (CDSP) |
| `qcwlan*` | WCN6855 WiFi (board data) |

> The firmware is **not** bundled in the shared ISO (it's proprietary and
> device-specific). That's why each person extracts it from their own Windows
> with this `.bat`.
