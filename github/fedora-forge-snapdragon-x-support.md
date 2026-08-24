# [RFE] Improve Snapdragon X (X1P) support in Fedora — ASUS Vivobook X1407QA daily-driver status

## Summary

The **ASUS Vivobook 14 X1407QA** with **Qualcomm Snapdragon X (X1-26-100)**
is usable as a Linux daily driver on **Fedora 44 aarch64** with the custom
`7.2.0-x1407qa` kernel, DKMS/runtime overlays, initramfs firmware injection and
userspace fixes. Boot is validated at 7.301s total with the graphical target
reached in 3.278s userspace. GPU/Vulkan and the core desktop hardware work; the RGB
camera captures still/video with a clean log on the patched 7.2 kernel and libcamera,
and the IR camera streams through its own `hm1092` driver. QNN/HTP inference runs on the
NPU. USB4/TB3 tunneling is the one hardware feature still blocked, documented below.

This issue documents what works, what needed fixing, and what Fedora could integrate to make Snapdragon X laptops work out-of-the-box.

## Hardware

| Component | Details |
|-----------|---------|
| **Model** | ASUS Vivobook 14 X1407QA |
| **SoC** | Qualcomm Snapdragon X X1-26-100 (8 cores, 2.97GHz, die "Purwa" — x1p42100) |
| **GPU** | Adreno X1-45 (freedreno / turnip / Mesa) |
| **RAM** | 16GB LPDDR5X |
| **Display** | 14" Samsung ATANA33XC20, eDP, 1920x1200, 60Hz |
| **WiFi** | Qualcomm QCNFA765 (WCN6855 hw2.1) — ath11k_pci, PCI `17cb:1103` |
| **Audio** | WCD938x codec + WSA884x speakers via SoundWire, ADSP via Q6APM |
| **Keyboard** | ASUS I2C-HID, bus 4 (`b94000`), addr `0x3a` |
| **Camera RGB** | OV02C10 (2MP) on CCI1 bus 1 (AON), addr `0x36`, MCLK4 19.2MHz |
| **Camera IR** | Himax HM1092 on CCI0 bus 0, addr `0x24`, CSIPHY0, MCLK0 24MHz, reset GPIO 109 |
| **Battery** | 50Wh Li-ion X321-42, driver `qcom_battmgr` via `pmic_glink` |

---

## Detailed breakdown — 19 issues found and fixed

### 1. Boot — no DTB for this laptop in the kernel

**Problem:** Fedora 44 aarch64 has no native Device Tree Blob for the Vivobook
X1407QA. Early experiments with several EFI/GRUB paths failed; the installed
7.2 system now boots reliably with the Zenbook A14 DTB referenced by the BLS
entry. Model-specific differences still need runtime fixes.

**How it was fixed:** Boot using the **Zenbook A14 DTB** (`x1p42100-asus-zenbook-a14.dtb`) — same Qualcomm "Purwa" die (x1p42100). All hardware differences between the two laptops are corrected at runtime via DKMS kernel modules. Required kernel parameters:

```text
live/recovery:    clk_ignore_unused pd_ignore_unused
installed stable: clk_ignore_unused mem_sleep_default=s2idle systemd.zram=0 plymouth.enable=0
```

The live image still carries both guards. On the installed 7.2 system,
`clk_ignore_unused` remains required while `pd_ignore_unused` was removed after
physical validation.

**What Fedora could do:** submit a proper Vivobook X1407QA DTB and preserve the
required clocks/power domains in DT/drivers so broad ignore flags are no longer
needed.

---

### 2. WiFi — PCIe race condition + missing regulator + missing board data

**Problem:** WiFi chip (WCN6855) never appears on PCI bus. Three separate issues:
1. `qcom-pcie` scans the bus **before** the WiFi chip is powered on (PCIe race condition, upstream fix expected ~6.21)
2. Kernel disables WCN regulators ~30s after boot (regulator cleanup)
3. No `board-2.bin` entry for subsystem ID `105b:e130`

**How it was fixed:** DKMS module `wcn_regulator_fix`:
- Holds WCN regulators via consumer API to prevent cleanup
- Patches DT with `regulator-always-on` flag
- Schedules delayed PCIe bus rescans — device appears ~6s after boot
- Fallback `board.bin` from similar WCN6855 variant installed to `/usr/lib/firmware/ath11k/WCN6855/hw2.1/`
- Module loaded **before PCIe scan** via `rd.driver.pre=wcn_regulator_fix` in kernel cmdline

**Result:** WiFi interface `wlP4p1s0` comes up reliably every boot.

**What Fedora could do:** The upstream PCIe race condition fix (expected 6.21) would eliminate the need for this module entirely.

---

### 3. Keyboard — wrong I2C bus and address in DTB

**Problem:** Keyboard doesn't work. The Zenbook DTB maps the keyboard to `i2c@a80000:0x15`. On the Vivobook it's on a **completely different bus**: `i2c@b94000` at address `0x3a`.

**How it was fixed:** DKMS module `vivobook_kbd_fix`:
- Finds the correct I2C adapter by **DT path** (`/soc@0/geniqup@bc0000/i2c@b94000`) — bus numbers are dynamic and shift when other I2C controllers probe
- Maps TLMM GPIO 67 to IRQ via `irq_create_fwspec_mapping()` (legacy `gpio_to_irq()` doesn't work on Qualcomm TLMM)
- Creates I2C device at the correct bus/address (`0x3a`)
- Calls exported `i2c_hid_core_probe()` from the `i2c_hid` module

**Key detail:** ASUS I2C-HID controller, VID `0x0b05`, PID `0x4543`, HID descriptor register `0x0001`, IRQ GPIO 67 (level-low).

**What Fedora could do:** A proper Vivobook DTB with the correct I2C bus/address/GPIO mappings would eliminate this module.

---

### 4. Battery — ADSP firmware not available at early boot

**Problem:** `qcom-battmgr` driver returns `EAGAIN` on all sysfs reads. Battery percentage, voltage, current — all fail.

**Root cause:** The `qcom-battmgr` driver communicates with the battery via the ADSP remoteproc. The ADSP probes at ~1.7s during boot, but its firmware (`qcadsp8380.mbn`) is on the rootfs — which isn't mounted yet. The ADSP fails to start, and `pmic_glink` (the communication channel) never comes up.

**How it was fixed:** Added ADSP firmware to initramfs via dracut:

```bash
# /etc/dracut.conf.d/qcom-adsp-firmware.conf
install_items+=" /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/qcadsp8380.mbn
  /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/adsp_dtbs.elf
  /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/adspr.jsn
  /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/adsps.jsn
  /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/adspua.jsn
  /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/battmgr.jsn "
```

**Result:** Battery sysfs at `/sys/class/power_supply/qcom-battmgr-bat/` fully functional — capacity, energy_now, power_now (µW), voltage, status.

**What Fedora could do:** Ship Qualcomm ADSP/GPU/CDSP firmware in initramfs by default for X1P platforms. A single dracut config adding `qcom/x1p42100/*` would fix this for all Snapdragon X devices.

---

### 5. Brightness — PMIC PWM signal not routed to display

**Problem:** Screen stuck at 100% brightness. No `/sys/class/backlight/` device.

**Root cause:** The Samsung ATANA33XC20 panel uses an external PWM signal for backlight control. The PMIC (PMK8550) has an LPG (Light Pulse Generator) channel pre-configured as 12-bit PWM at 19.2 MHz, but the DTB node is `status = "disabled"`. The PWM signal from LPG ch0 needs to be routed through the DTEST3 internal bus to GPIO5, which connects to the panel. This routing is not configured.

**How it was fixed:** DKMS module `vivobook_bl_fix`:
- Finds PMK8550 regmap via DT child platform device lookup
- Unlocks SEC_ACCESS on LPG TEST register (offset `0xE8E2`)
- Enables DTEST3 routing: writes `0x01` to the test register
- Writes 12-bit PWM value + PWM_SYNC (offset `0x47`) to latch into hardware
- Registers `/sys/class/backlight/vivobook-backlight` with 4096 brightness levels
- GNOME Quick Settings slider and Fn brightness keys work automatically

**Signal path:** `LPG ch0 PWM → DTEST3 bus → GPIO5 (DIG_OUT_SRC=0x04) → panel backlight`

> **WARNING:** Never change GPIO5 DIG_OUT_SOURCE_CTL to `0x00` or force GPIO output LOW — this kills the display and requires a forced reboot (power button 10s).

**What Fedora could do:** A proper DTB with LPG enabled and DTEST3 routing configured would eliminate this module.

---

### 6. Fn hotkeys — ASUS vendor HID not initialized

**Problem:** Fn+F5 (brightness down), Fn+F6 (brightness up), mic mute, camera toggle, airplane mode, keyboard backlight — all silently swallowed.

**Root cause:** The ASUS keyboard firmware requires a vendor-specific init sequence before it forwards hotkey events. The standard `hid-asus` driver is disabled in Fedora's aarch64 kernel (`CONFIG_HID_ASUS is not set`) and PID `0x4543` isn't in its device table anyway. Without the init, the keyboard only reports standard keycodes — vendor page `0xFF31` hotkeys are never sent.

**How it was fixed:** DKMS module `vivobook_hotkey_fix`:
- Registers as HID driver for `0x0B05:0x4543`, binding instead of `hid-generic`
- Sends ASUS init sequence: `SET_FEATURE` with payload `"ASUS Tech.Inc.\0"` to report ID `0x5A`
- Maps vendor page `0xFF31` usages to standard Linux input events:

| Hotkey | Vendor Usage | Mapped to |
|--------|-------------|-----------|
| Fn+F5 | `0xFF31:0x10` | `KEY_BRIGHTNESSDOWN` |
| Fn+F6 | `0xFF31:0x20` | `KEY_BRIGHTNESSUP` |
| Mic mute | `0xFF31:0x7c` | `KEY_MICMUTE` |
| Camera | `0xFF31:0x82` | `KEY_CAMERA` |
| Airplane | `0xFF31:0x88` | `KEY_RFKILL` |
| Kbd backlight | `0xFF31:0xc7` | `KEY_KBDILLUMTOGGLE` |

Must load **before** `vivobook_kbd_fix` so the HID driver is registered when the I2C device is created. Alphabetical order in `modules-load.d` handles this.

---

### 7. GPU — firmware not in initramfs (msm.ko has no MODULE_FIRMWARE declarations)

**Problem:** No 3D acceleration. `glxinfo` shows software renderer. GPU init fails with `gpu hw init failed: -2`.

**Root cause:** The Adreno X1-45 GPU driver probes at ~t=2.0s, ~375ms before `switchroot` — so when it calls `adreno_request_fw()` the rootfs is not yet mounted. `msm.ko` does not declare any `MODULE_FIRMWARE`, so dracut never pulls the GPU blobs automatically. And the device-specific ZAP shader (`qcdxkmsucpurwa.mbn`) is extracted from Windows and not present in any Linux firmware package at all.

**How it was fixed:** Three GPU firmware files forced into the initramfs via a dracut `install_items+=` drop-in:

| Firmware | Purpose |
|----------|---------|
| `gen71500_sqe.fw.xz` | Shader Queue Engine microcode (`qcom-firmware` package) |
| `gen71500_gmu.bin.xz` | Graphics Management Unit firmware (`qcom-firmware` package) |
| `qcdxkmsucpurwa.mbn` | ZAP shader (Windows-extracted; DTB `zap-shader.firmware-name`) |

**Result:** Full 3D acceleration — freedreno (OpenGL), turnip (Vulkan), Adreno X1-45.

**What Fedora could do:** Add `MODULE_FIRMWARE("qcom/gen71500_sqe.fw")` and friends to `msm.ko` so dracut pulls them via the standard firmware-resolution path. The device-specific ZAP shader problem is deeper — it needs either an upstream-signed replacement or a DTB that points at the upstream path (`qcom/x1p42100/gen71500_zap.mbn`), assuming the TrustZone accepts that signature.

---

### 8. Boot time 1min 47s → 7.301s — fixed

**Problem:** System takes almost 2 minutes to boot despite NVMe storage.

**Root cause:** The INSYDE firmware advertises TPM devices (`/dev/tpm0`, `/dev/tpmrm0`) that don't exist. A later regression also came from Fedora's zram generator waiting 45s for `/dev/zram0`, although the custom kernel has no zram module. Plymouth and two artificial camera waits added another ~9s.

**How it was fixed:**
1. Mask TPM devices in userspace: `systemctl mask dev-tpm0.device dev-tpmrm0.device`
2. Mask in initrd via kernel cmdline: `rd.systemd.mask=dev-tpm0.device rd.systemd.mask=dev-tpmrm0.device`
3. Remove TPM/NFS dracut modules (unnecessary on laptop): `omit_dracutmodules+=" tpm2-tss systemd-pcrphase nfs "`
4. Add `systemd.zram=0 plymouth.enable=0` only to installed-system boot entries; live entries retain `rd.live.ram`.
5. Remove the camera service's global `udevadm settle`, arbitrary three-second sleep and pre-login WirePlumber restart; synchronous camera initialization now completes in 112ms.

| Metric | Before | After |
|--------|--------|-------|
| Total boot | 1min 47s | **7.301s** |
| kernel | — | 733ms |
| initrd | 46s | 3.242s |
| userspace | 60s | 3.325s |
| graphical target | — | **3.278s** |

The roughly three-second target is desktop/userspace readiness. Kernel +
initrd already take 3.975s, so the validated total is 7.301s rather than an
unattainable three-second total.

**What Fedora could do:** Detect phantom TPM and avoid generating zram units when the running kernel cannot provide zram. This affects multiple vendors, not just ASUS.

---

### 9. Terminal flicker — GTK4 Vulkan descriptor pool exhaustion on turnip

**Problem:** Terminal (Ptyxis) starts flickering after ~30 minutes of use. Journal fills with hundreds of `VK_ERROR_OUT_OF_POOL_MEMORY` errors per minute.

**Root cause:** GTK4's Vulkan renderer (GSK) creates descriptor pools with `maxSets=100` and `VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT`. The freedreno turnip driver (`tu_descriptor_set.cc:649`) fragments these small pools under rapid alloc/free cycles from terminal text rendering. After sustained use, all pools are exhausted — the allocation loop iterates all fragmented pools, generating errors and causing visible flicker.

In GTK4 source (`gsk/gpu/gskvulkandevice.c`):
```c
.flags = VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT,  // enables fragmentation
.maxSets = 100,        // too small for sustained rendering on turnip
.descriptorCount = 100,
```

**How it was fixed:** LD_PRELOAD library (`vk_pool_fix.so`) that intercepts `vkCreateDescriptorPool` and increases pool sizes by 50x (100 → 5000 sets):

```bash
gcc -shared -fPIC -o vk_pool_fix.so vk_pool_fix.c -ldl
sudo cp vk_pool_fix.so /usr/local/lib64/
```

Since Ptyxis uses D-Bus activation (`DBusActivatable=true`), a simple `.desktop` override isn't enough — a D-Bus service file override is also required to inject `LD_PRELOAD` into the actual launch path.

**Result:** 952 errors → 0 errors. Vulkan renderer preserved (better performance than GL fallback with `GSK_RENDERER=ngl`).

**What Fedora could do:** Report upstream to GTK4 — the pool size is too small for drivers with linear allocators (turnip). Also relevant for any ARM/Adreno GPU running GNOME.

---

### 10. Battery time display — GNOME doesn't show time remaining

**Problem:** GNOME 50 shows battery percentage but not time remaining. UPower's estimate fluctuates wildly with power draw changes.

**Root cause:** The `qcom-battmgr` driver doesn't expose `POWER_SUPPLY_PROP_TIME_TO_EMPTY_NOW`, so UPower has to estimate from energy_now/power_now — which jumps with brightness changes, CPU load, etc.

**How it was fixed:** Custom GNOME Shell extension `battery-time@wifiteste`:
- Reads `/sys/class/power_supply/qcom-battmgr-bat/energy_now` and `power_now` directly
- Uses weighted rolling average (30 samples x 30s = 15min window) to smooth fluctuations
- Displays on hover over battery icon: e.g. `4:12` (hours:minutes)
- Handles both discharging (time remaining) and charging (time to full)

**What Fedora could do:** Patch `qcom-battmgr` upstream to expose `TIME_TO_EMPTY_NOW`. This would make UPower and GNOME show the time natively.

---

### 11. Touchpad right-click — clickpad only reports BTN_LEFT

**Problem:** Right-click doesn't work. Two-finger click doesn't register as right-click.

**Root cause:** The ELAN touchpad (`04F3:3313`) is a clickpad (`INPUT_PROP_BUTTONPAD`) — one physical button under the entire pad, always reports `BTN_LEFT`. GNOME defaults to `click-method: fingers` (2-finger = right-click), but area-based clicking (bottom-right corner = right-click) is the standard laptop behavior.

**How it was fixed:**
```bash
gsettings set org.gnome.desktop.peripherals.touchpad click-method 'areas'
```

Bottom-left = left click, bottom-right = right click.

---

### 12. Audio — UCM2 regex doesn't match "Vivobook 14"

**Problem:** PipeWire shows "Dummy Output" — no speakers, no headphones, no mic. But the hardware works: WCD938x codec, 2x WSA884x speakers, all LPASS macros, SoundWire bus, and Q6APM DSP are all loaded and running at kernel level.

**Root cause:** ALSA UCM2 (Use Case Manager) at `/usr/share/alsa/ucm2/conf.d/x1e80100/x1e80100.conf` matches machines by DMI string. The regex includes `Zenbook A14` and `Vivobook S 15` but **not** `Vivobook 14`:

```
# DMI string: "ASUSTeK COMPUTER INC.-ASUS Vivobook 14-X1407QA"
# Regex before: "...ASUS (Zenbook A14|Vivobook S 15)..."
# Regex after:  "...ASUS (Zenbook A14|Vivobook S 15|Vivobook 14)..."
```

Without the UCM2 profile match, WirePlumber can't configure ALSA mixer routing (`RX_CODEC_DMA_RX_0`, `WSA_CODEC_DMA_RX_0`, etc.) and falls back to dummy sink.

**How it was fixed:**
```bash
sudo sed -i 's/Vivobook S 15/Vivobook S 15|Vivobook 14/' \
    /usr/share/alsa/ucm2/conf.d/x1e80100/x1e80100.conf \
    /usr/share/alsa/ucm2/Qualcomm/x1e80100/x1e80100.conf
systemctl --user restart pipewire pipewire-pulse wireplumber
```

**Audio devices enabled:**

| Device | Type | Details |
|--------|------|---------|
| Speakers | Playback | 2ch, WSA884x x2, WSA_CODEC_DMA_RX_0 |
| Headphones | Playback | WCD938x, RX_CODEC_DMA_RX_0 |
| HDMI | Playback | DisplayPort audio (3 outputs) |
| Internal mic | Capture | DMIC0+DMIC1, VA_CODEC_DMA_TX_0 |
| Headset mic | Capture | WCD938x ADC2, TX_CODEC_DMA_TX_3 |

**What Fedora could do:** PR to [alsa-ucm-conf](https://github.com/alsa-project/alsa-ucm-conf) upstream adding `Vivobook 14` to the ASUS regex. One-line change fixes audio for this model (and likely others).

---

### 13. Lid close — S3 suspend crashes, requires cold reboot

**Problem:** Closing the lid triggers S3 suspend (`PM: suspend entry (deep)`), but the system never wakes — it cold reboots, losing all open work.

**Root cause:** Both S3 deep and s2idle crash. Detailed testing shows the problem is in the CPU idle phase — device suspend/resume works fine (`pm_test=devices` passes), but when CPUs enter the idle loop, no IRQ can wake them. Three interrelated causes:

1. **PDC wakeup mapping disabled** — `pinctrl-x1e80100.c` has `nwakeirq_map = 0` with a TODO comment. GPIO IRQs (lid, keyboard, touchpad) are not routed through the PDC for wakeup.
2. **PDC mode wrong** — PDC may be in "secondary controller" mode instead of "pass-through" mode.
3. **No system power domain idle state** — DTB lacks `domain-idle-states` for the system power domain, so PSCI firmware doesn't configure the wake path.

Qualcomm has posted a 5-patch series (Maulik Shah, March 2026) to fix all three issues — currently in review on LKML.

**How it was fixed:** Disable all suspend paths, configure lid close to lock screen only (display turns off via DPMS):

1. **logind:** `HandleLidSwitch=lock` (all power states)
2. **systemd:** mask `suspend.target`, `hibernate.target`, `hybrid-sleep.target`, `suspend-then-hibernate.target`, `sleep.target`
3. **GNOME:** disable idle suspend for AC and battery

**Behavior:** Lid close → screen off + session locks. Lid open → screen on, lock screen. No suspend, no data loss.

**What Fedora could do:** Default to disable suspend on Snapdragon X platforms until Qualcomm's PDC patches are merged (~6.21/7.0). Applies to all X1E/X1P devices.

---

### 14. CPU frequency scaling — `scmi_cpufreq` not auto-loaded

**Problem:** No CPU frequency scaling. CPU runs at whatever frequency the firmware sets. No `scaling_governor`, no `/sys/devices/system/cpu/cpufreq/` entries. Battery drains fast, thermals are uncontrolled.

**Root cause:** The `scmi_cpufreq` module exists in-tree and works perfectly, but it doesn't auto-load via device modalias matching. The SCMI firmware has a cosmetic bug (duplicate OPP entry at 2956800 for NCC1, `EEXIST`), but it's non-fatal.

**How it was fixed:**
```bash
echo "scmi_cpufreq" | sudo tee /etc/modules-load.d/scmi-cpufreq.conf
```

**Result:** Two cpufreq policies — efficiency cluster (CPUs 0-3) and performance cluster (CPUs 4-7), both 710MHz–2.96GHz, `schedutil` governor. CPU now scales with load.

**What Fedora could do:** Auto-load `scmi_cpufreq` on Qualcomm platforms. A udev rule or modules-load.d entry would fix this for all Snapdragon X devices. Without it, CPU frequency scaling simply doesn't work.

---

### 15. CDSP/NPU — firmware not in initramfs

**Problem:** Compute DSP (Hexagon NPU) stays offline. `remoteproc1` fails with error `-2` (ENOENT).

**Root cause:** Same as #4 (ADSP/battery). The `remoteproc` for CDSP probes during early boot when only the initramfs is available. The firmware `qccdsp8380.mbn` (3.1MB) exists on rootfs but isn't in initramfs.

```
remoteproc remoteproc1: Direct firmware load for qcom/x1p42100/ASUSTeK/zenbook-a14/qccdsp8380.mbn failed with error -2
```

**How it was fixed:** Added CDSP firmware to initramfs:
```bash
# /etc/dracut.conf.d/qcom-cdsp-firmware.conf
install_items+=" /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/qccdsp8380.mbn
  /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/cdsp_dtbs.elf
  /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/cdspr.jsn "
```

**Result:** `remoteproc1` state = `running`, 13 FastRPC compute callback
contexts available (cb@1 through cb@13). The non-secure
`/dev/fastrpc-cdsp` node is available to group `render`; secure and ADSP nodes
remain root-only.

CDSP `running` is not by itself NPU inference. Getting `onnxruntime-qnn 2.4.0` to
execute an operator on the HTP needed three more pieces, none of them a vendor
block:

1. **`libcdsprpc.so` is absent on Fedora.** `libQnnHtpV73Stub.so` lists it in
   `DT_NEEDED`, so the backend dies in `logCreate`. Building
   [`qualcomm/fastrpc`](https://github.com/qualcomm/fastrpc) supplies it — it is
   built with `-DENABLE_UPSTREAM_DRIVER_INTERFACE` and speaks the mainline
   `drivers/misc/fastrpc.c` ioctl ABI. Fedora aarch64 does not scan
   `/usr/local/lib`, so it also needs an `ld.so.conf.d` entry. **A packaged
   `libcdsprpc.so` would be the single highest-value thing Fedora could ship for
   Snapdragon X.**
2. **The Hexagon-side shell must be present and hash-paired.** The signed CDSP
   firmware embeds the SHA-256 of every ELF segment of each Hexagon binary it
   will load, so `fastrpc_shell_unsigned_3` has to come from the same build as
   the `.mbn` in use. The published
   [`linux-msm/hexagon-dsp-binaries`](https://github.com/linux-msm/hexagon-dsp-binaries)
   Hamoa sets (`CDSP.HT.2.9.c1-00069`, `-00082`) authorize only 1 of 4 segments
   against this machine's `CDSP.HT.2.9.c1-00046-HAMOA-1`, and substituting the
   generic `x1e80100/cdsp.mbn` fails earlier still — PAS rejects it with `-22`
   because it is not signed for the Purwa fuses.
3. **SoC ID `635` is not in the QNN table.** `libQnnHtp.so` reads
   `/sys/devices/soc0/soc_id` and aborts before touching the DSP. `555`
   (X1E80100, which QNN knows as `SC8380XP`) works; we apply it per process via
   `LD_PRELOAD`, never system-wide. A QNN release that recognises X1P42100 would
   remove the need for that shim entirely.

**Result:** `NPU devices: 1` and HTP inference with
`session.disable_cpu_ep_fallback=1`, returning `abs([[-1, 2, -3.5, 4.25]])` as
`[[1.0000001192092896, 2.000000238418579, 3.500000238418579, 4.250000476837158]]`
— the ~4.7e-07 delta is normal HTP precision. With fallback disabled, a CPU run
cannot be mistaken for acceleration.

---

### 16. Battery charge control — threshold not set by default

**Problem:** Battery always charges to 100%. `charge_control_end_threshold` reads as 0 (no limit). `technology` reports "Unknown" (firmware sends string `OOD`).

**Root cause:** The thresholds are simply unset — 0 means no limit. The `qcom_battmgr` driver supports `charge_control_end_threshold` writes, and the ADSP firmware honors them. The `OOD` technology string is a cosmetic firmware quirk.

**How it was fixed:** let `upower` (1.91) own the thresholds — it applies 75/80 and persists
the choice in `/var/lib/upower/charging-threshold-status`, so GNOME Settings → Power drives it:
```bash
sudo busctl call org.freedesktop.UPower \
    /org/freedesktop/UPower/devices/battery_qcom_battmgr_bat \
    org.freedesktop.UPower.Device EnableChargeThreshold b true
```

**Do NOT use a udev rule for this.** The obvious
`ATTR{charge_control_end_threshold}="80"` rule is self-triggering: writing the attribute
makes the kernel call `power_supply_changed()`, the resulting `change` uevent re-runs the
rule, and any later value the user picks is reverted to 80 within milliseconds. Both GNOME
charge modes then sit at 80% and look broken.

**Result:** *Preserve Battery Health* = start 75% / stop 80%; *Maximize Charge* = start 50% /
stop 100% (firmware defaults). Both modes verified on hardware.

---

### 17. RGB Camera — no CAMSS/CCI nodes in DTB

**Problem:** Camera doesn't work. The Zenbook A14 DTB has no CAMSS, CAMCC, CCI, or CSIPHY device tree nodes.

**Root cause:** 7 problems solved iteratively:
1. No DT nodes → runtime DT overlay via `of_overlay_fdt_apply()` in DKMS module
2. Overlay -22 (EINVAL) on CCI child nodes → two-phase overlay (CCI disabled in phase 1, enabled in phase 2)
3. CCI crash `list_add corruption` → added empty `i2c-bus@0` (master[0] was uninitialized)
4. RPMH regulator not registering → separate `regulators-9` block (parent already probed)
5. Sensor had no power → AVDD/DVDD from PM8550B `vreg_l7b_2p8` (2.8V), DOVDD from pm8010 `vreg_l3m_1p8` over RPMH
6. PLL8 enable timeout → `pm_runtime_get_sync(camcc_dev)` holds CAMCC awake (prevents MMCX power-off)
7. Image upside down → `rotation = <180>` in DT node

**How it was fixed:** DKMS module `vivobook_cam_fix` v2.0 with two-phase DT
overlay, Fedora libcamera with bundled OV02C10 IPA data, `system_heap`, and
PipeWire integration, loaded automatically after the core modules and display manager:
```bash
systemctl status vivobook-camera.service
vivobook-camera start   # manual fallback
vivobook-camera status  # checks if camera is active
```

**Why late graphical autostart:** CCI adapters create dynamic I2C buses that
shift Geni I2C numbering, so the module is never placed in `modules-load.d`.
The service waits for the core module loader and display manager. A clean boot
confirmed that touchpad and keyboard registered before the camera overlay. The
privacy shutter is purely mechanical (no GPIO/HID event — confirmed by
monitoring dmesg during open/close).

**Result:** OV02C10 RGB camera is functional — 1920×1080 XRGB8888 still,
1280×720 XRGB8888 video at ~30 fps, GNOME Snapshot and PipeWire apps.
Revalidated after an autostart reboot on 2026-08-24: service enabled/active,
still 1080p, 60/60 720p30 frames, and PipeWire `Built-in Front Camera`. The libcamera
metadata/helper and kernel CAMCC clock warnings are gone on the patched 7.2 build
(`kernel/linux-7.2-camera-warning-fix.patch` + `libcamera-0.7.1-ov02c10.patch`); there
was no Oops or soft lockup.

**What Fedora could do:** Upstream CAMSS patches (Bryan O'Donoghue, Linaro) would eliminate the overlay approach. A proper Vivobook DTB with camera nodes would make this work at boot.

---

### 18. Display colour control — msm_dpu exposes CTM but no GAMMA_LUT

**Problem:** No way to change saturation or contrast. `wl-gammarelay-rs` and any
`zwlr_gamma_control` client fail because `msm_dpu` exposes the CRTC `CTM` and `PCC`
properties but not `GAMMA_LUT`, and a Wayland client cannot become DRM master to
drive `CTM` directly.

**How it was fixed:** DKMS module `vivobook_color_ctrl` performs the DRM atomic commit
from kernel space, which is not subject to the DRM master restriction, and exposes
`/sys/kernel/vivobook_color/{saturation,contrast}` (0.000–2.000, 1.000 = identity).

**What Fedora could do:** nothing kernel-side — this is a `msm_dpu` feature gap. A
`GAMMA_LUT` implementation in `msm_dpu`, or compositor support for `CTM`, would make
the module unnecessary.

---

### 19. IR camera (HM1092) — the "pm8010 is absent" false negative

**Problem:** the Windows Hello IR sensor answered on no bus. Provisioning its AVDD rail
made `devm_regulator_register()` return `-ENOTRECOVERABLE` for pm8010 LDO7 and take the
whole regulator block down, which was read as "the camera PMIC is not on the board".

**Root cause:** five software bugs, no missing hardware.
1. **AVDD off the regulator step grid.** The generic `CAMI_RES_MTP.bin` asks for
   2,900,000 µV; `pmic5_pldo` steps in 8 mV, so with `min == max` off-grid the constraint
   is rejected and registration fails. The Purwa-specific `CAMI_RES_QRD.bin` that factory
   Windows loads asks for **2,912,000 µV**, which lands on an exact selector and registers.
   **This failure mode is worth knowing generally: an off-grid fixed voltage on a
   `pmic5_pldo` looks exactly like absent silicon.**
2. Sensor does not auto-increment the register pointer — every 16-bit register is two
   8-bit writes, low byte first. No `CCI_REG16`.
3. CSIPHY region size — csiphy0/1/2 need `0x2000`, not `0x1000`; `csiphy_reset()` writes at
   `base+0x1000` and Oopses otherwise. Only csiphy4 (RGB) was large enough to hide this.
4. Purwa has no IFE1/CSID1 (`cam_cc_ife_1_gdsc status stuck at 'off'`), so the only path is
   `csid0 → vfe0_rdi0` — shared with the RGB sensor.
5. One CSI lane at 180 MHz, not two — the init PLL yields `24 MHz ÷ 12 × 90`.

**How it was fixed:** a dedicated `hm1092` V4L2 driver (`himax,hm1092`) plus a sensor node
on CCI0 bus 0. Result: 560×360 Y10 at ~29.7 fps over
`hm1092 → csiphy0 → csid0 → vfe0_rdi0`. Still missing: an IR illuminator (a PMIC flash LED
at 700 mA per `qccamflash_ext8380`, with no DTB node), and libcamera capture — the sensor
enumerates but the soft-ISP rejects `R10_CSI2P` since its debayer does not handle
monochrome RAW10.

**What Fedora could do:** nothing packaging-side. This one is a device driver that belongs
upstream once the Purwa CAMSS DT lands.

---

## What Fedora could do upstream — summary

### High impact (fixes Snapdragon X out-of-the-box)

1. **Ship Qualcomm firmware in initramfs** — ADSP, GPU, CDSP all fail without it. One dracut config for `qcom/x1p42100/*` fixes #4, #7, #15 for all X1P devices.
2. **Auto-load `scmi_cpufreq`** — fixes #14, one line in modules-load.d.
3. **Fix `alsa-ucm-conf` regex** — fixes #12, one-line PR upstream.
4. **Add `clk_ignore_unused pd_ignore_unused`** — fixes #1, prevents Qualcomm clock/PD crash.

### Medium impact

5. **Skip phantom TPM and unsupported zram** on INSYDE Snapdragon X — fixes #8 and keeps userspace boot near 3s.
6. **Keep deep suspend disabled on Snapdragon X** — s2idle is working on this
   machine (~0.80W measured), but deep still crashes.
7. **GTK4 Vulkan pool size** — fixes #9, upstream GTK4/Mesa issue.

### Model-specific

8. **Vivobook X1407QA DTB** upstream — would eliminate need for DKMS modules #3, #5, #6.
9. **`qcom-battmgr` time-to-empty** — fixes #10, UPower/GNOME battery time.

## Full documentation and code

All fixes, 7 DKMS module sources, setup scripts, and detailed reverse-engineering notes:

**https://github.com/pir0c0pter0/fedora-vivobook-x1407q**

- `setup-vivobook.sh` — one-command setup applying all hardware fixes
- `build-vivobook-iso.sh` — builds pre-patched ISO with everything baked in

## System info

```
Fedora release 44 (Forty Four)
Kernel: 7.2.0-x1407qa
GNOME: 50
Mesa: 26.0.3
```

## Related upstream work

- **Camera RGB:** Functional via DKMS two-phase DT overlay, with a clean log on the
  patched 7.2 kernel and libcamera 0.7.1.
- **Camera IR:** Functional via the out-of-tree `hm1092` driver — 560×360 Y10 at
  ~29.7 fps. No IR illuminator yet, and libcamera's soft-ISP cannot consume monochrome
  RAW10, so capture goes through V4L2 directly.
- **Camera (upstream):** Bryan O'Donoghue (Linaro) v9 patches (7 patches, reduzido de v8's 18) in LKML review (Feb 2026). Expected merge ~6.21/6.22. **Note:** patches only cover x1e80100 (Hamoa) — not Purwa/x1p42100. Our DKMS overlay remains the only working path for this SoC.
- **Suspend:** s2idle is physically validated on `7.2.0-x1407qa` at ~0.80W;
  deep/S3 still crashes and remains disabled.
- **USB4 / Thunderbolt 3:** USB-C DP alt-mode works, but TB3 tunneling is still
  blocked. Non-PCI NHI preparation is upstream and a Hamoa/Purwa PHY v4 is in
  review; the Qualcomm host-router driver and final DT graph are still private.
  Reverse engineering recovered the MCU firmware embedded in the Windows
  lower-filter, so firmware is no longer the unknown. A custom kernel becomes
  useful only after the missing driver series is public.
- **PCIe race condition:** Upstream fix expected ~6.21, would eliminate WiFi DKMS module.
- **CDSP/NPU:** Working end to end — CDSP/FastRPC transport plus QNN/HTP
  inference with CPU fallback disabled. Two things would let this work without
  per-machine surgery: a packaged `libcdsprpc.so` (Fedora ships no FastRPC
  userspace, which is what actually blocked inference), and a QNN release that
  knows SoC ID `635`/X1P42100 so the `LD_PRELOAD` SoC ID shim can be dropped.
  The Hexagon shell stays a per-device concern — it is hash-pinned to the signed
  CDSP firmware and cannot be shipped generically. The proposed QDA driver uses a
  different interface from the current FastRPC stack.
- **DTB:** Vivobook X1407QA DTB not yet submitted — depends on camera/sensor patches.
