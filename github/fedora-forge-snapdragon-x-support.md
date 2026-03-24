# [RFE] Improve Snapdragon X (X1P) support in Fedora — ASUS Vivobook X1407QA fully working with runtime fixes

## Summary

The **ASUS Vivobook 14 X1407QA** with **Qualcomm Snapdragon X (X1-26-100)** is now fully functional as a Linux daily driver on **Fedora 44 aarch64** — **17 out of 17 hardware features working** (IR camera blocked by absent PMIC hardware). Every fix was reverse-engineered from scratch with **zero kernel patches** — all done via DKMS modules, initramfs firmware injection, and userspace fixes.

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
| **Camera IR** | 1× IR sensor — pm8010 PMIC physically absent, not functional |
| **Battery** | 50Wh Li-ion X321-42, driver `qcom_battmgr` via `pmic_glink` |

---

## Detailed breakdown — 17 issues found and fixed

### 1. Boot — no DTB for this laptop in the kernel

**Problem:** Fedora 44 aarch64 doesn't boot — there is no Device Tree Blob for the Vivobook X1407QA in kernel 6.19. The INSYDE UEFI firmware provides its own DTB and **blocks all override attempts** (7 methods tested: GRUB `devicetree`, BLS, `dtbloader.efi`, EFI stub — all fail on INSYDE aarch64).

**How it was fixed:** Boot using the **Zenbook A14 DTB** (`x1p42100-asus-zenbook-a14.dtb`) — same Qualcomm "Purwa" die (x1p42100). All hardware differences between the two laptops are corrected at runtime via DKMS kernel modules. Required kernel parameters:

```
clk_ignore_unused pd_ignore_unused
```

Without these, the kernel disables Qualcomm clocks and power domains it thinks are unused, crashing the system immediately.

**What Fedora could do:** Add `clk_ignore_unused pd_ignore_unused` to default kernel cmdline on Qualcomm aarch64 platforms. Submit a proper DTB for the Vivobook X1407QA upstream.

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

### 7. GPU — firmware not in initramfs, MDT loader doesn't retry

**Problem:** No 3D acceleration. `glxinfo` shows software renderer. GPU init fails with `gpu hw init failed: -2`.

**Root cause:** The Adreno X1-45 requires four firmware files. The ZAP shader (`qcdxkmsucpurwa.mbn`) uses the MDT (Meta Data Table) loader which does **not retry** — if the firmware isn't available at the first probe attempt, GPU init fails permanently. The generic firmware files are compressed (`.xz`) and the kernel's direct loader fails during early boot when only the initramfs is available.

**How it was fixed:** All four GPU firmware files added to initramfs via dracut:

| Firmware | Purpose |
|----------|---------|
| `gen71500_sqe.fw.xz` | Shader Queue Engine microcode |
| `gen71500_gmu.bin.xz` | Graphics Management Unit firmware |
| `gen71500_zap.mbn` | ZAP shader (generic, TrustZone authenticated) |
| `qcdxkmsucpurwa.mbn` | ZAP shader (device-specific, MDT format) |

**Result:** Full 3D acceleration — freedreno (OpenGL), turnip (Vulkan), Adreno X1-45.

**What Fedora could do:** Same as #4 — ship Qualcomm firmware in initramfs. The GPU firmware is the most critical because the MDT loader has zero retry logic.

---

### 8. Boot time 1min 47s → 8s — phantom TPM timeout

**Problem:** System takes almost 2 minutes to boot despite NVMe storage.

**Root cause:** The INSYDE firmware advertises TPM devices (`/dev/tpm0`, `/dev/tpmrm0`) that don't exist. The kernel itself detects this: `ima: No TPM chip found, activating TPM-bypass!`. But systemd waits for the device nodes — **twice**: once in initrd (~45s timeout) and again in userspace (~45s timeout). Total: ~90s wasted waiting for hardware that will never appear.

**How it was fixed:**
1. Mask TPM devices in userspace: `systemctl mask dev-tpm0.device dev-tpmrm0.device`
2. Mask in initrd via kernel cmdline: `rd.systemd.mask=dev-tpm0.device rd.systemd.mask=dev-tpmrm0.device`
3. Remove TPM/NFS dracut modules (unnecessary on laptop): `omit_dracutmodules+=" tpm2-tss systemd-pcrphase nfs "`

| Metric | Before | After |
|--------|--------|-------|
| Total boot | 1min 47s | **7.8s** |
| initrd | 46s | 2.3s |
| userspace | 60s | 5s |

**What Fedora could do:** Detect phantom TPM on Snapdragon X platforms (INSYDE firmware) and skip the wait. This affects multiple vendors, not just ASUS.

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

**Result:** `remoteproc1` state = `running`, 13 FastRPC compute callback contexts available (cb@1 through cb@13).

---

### 16. Battery charge control — threshold not set by default

**Problem:** Battery always charges to 100%. `charge_control_end_threshold` reads as 0 (no limit). `technology` reports "Unknown" (firmware sends string `OOD`).

**Root cause:** The thresholds are simply unset — 0 means no limit. The `qcom_battmgr` driver supports `charge_control_end_threshold` writes, and the ADSP firmware honors them. The `OOD` technology string is a cosmetic firmware quirk.

**How it was fixed:** udev rule to set charge limit when battery device appears:
```bash
# /etc/udev/rules.d/99-battery-charge-limit.rules
SUBSYSTEM=="power_supply", KERNEL=="qcom-battmgr-bat", ATTR{charge_control_end_threshold}="80"
```

**Result:** Charge stops at 80%, firmware auto-sets start threshold to 50%. Extends battery lifespan.

---

### 17. RGB Camera — no CAMSS/CCI nodes in DTB, pm8010 PMIC absent

**Problem:** Camera doesn't work. The Zenbook A14 DTB has no CAMSS, CAMCC, CCI, or CSIPHY device tree nodes. The dedicated camera PMIC (pm8010) is not physically present on the board.

**Root cause:** 7 problems solved iteratively:
1. No DT nodes → runtime DT overlay via `of_overlay_fdt_apply()` in DKMS module
2. Overlay -22 (EINVAL) on CCI child nodes → two-phase overlay (CCI disabled in phase 1, enabled in phase 2)
3. CCI crash `list_add corruption` → added empty `i2c-bus@0` (master[0] was uninitialized)
4. RPMH regulator not registering → separate `regulators-9` block (parent already probed)
5. pm8010 absent → power from PM8550B: AVDD/DVDD `vreg_l7b_2p8` (2.8V), DOVDD `vreg_l3m_1p8` (RPMH fire-and-forget)
6. PLL8 enable timeout → `pm_runtime_get_sync(camcc_dev)` holds CAMCC awake (prevents MMCX power-off)
7. Image upside down → `rotation = <180>` in DT node

**How it was fixed:** DKMS module `vivobook_cam_fix` v2.0 with two-phase DT overlay, loaded on-demand:
```bash
vivobook-camera start   # loads module + restarts wireplumber
vivobook-camera status  # checks if camera is active
```

**Why on-demand:** CCI adapters create dynamic I2C buses that shift Geni I2C numbering. Auto-loading at boot breaks keyboard and touchpad. The privacy shutter is purely mechanical (no GPIO/HID event — confirmed by monitoring dmesg during open/close).

**Result:** OV02C10 RGB camera fully working — libcamera, GNOME Snapshot, any PipeWire camera app. IR camera blocked (pm8010 absent, no one upstream has IR working on Snapdragon X Linux).

**What Fedora could do:** Upstream CAMSS patches (Bryan O'Donoghue, Linaro) would eliminate the overlay approach. A proper Vivobook DTB with camera nodes would make this work at boot.

---

## What Fedora could do upstream — summary

### High impact (fixes Snapdragon X out-of-the-box)

1. **Ship Qualcomm firmware in initramfs** — ADSP, GPU, CDSP all fail without it. One dracut config for `qcom/x1p42100/*` fixes #4, #7, #15 for all X1P devices.
2. **Auto-load `scmi_cpufreq`** — fixes #14, one line in modules-load.d.
3. **Fix `alsa-ucm-conf` regex** — fixes #12, one-line PR upstream.
4. **Add `clk_ignore_unused pd_ignore_unused`** — fixes #1, prevents Qualcomm clock/PD crash.

### Medium impact

5. **Mask phantom TPM** on INSYDE Snapdragon X — fixes #8, saves 90s boot time.
6. **Disable suspend on Snapdragon X** — fixes #13, prevents data-loss crash (s2idle also broken until PDC patches merge).
7. **GTK4 Vulkan pool size** — fixes #9, upstream GTK4/Mesa issue.

### Model-specific

8. **Vivobook X1407QA DTB** upstream — would eliminate need for DKMS modules #3, #5, #6.
9. **`qcom-battmgr` time-to-empty** — fixes #10, UPower/GNOME battery time.

## Full documentation and code

All fixes, 6 DKMS module source code, setup scripts, and detailed reverse-engineering notes:

**https://github.com/pir0c0pter0/fedora-vivobook-x1407q**

- `setup-vivobook.sh` — one-command setup applying all 17 fixes
- `build-vivobook-iso.sh` — builds pre-patched ISO with everything baked in

## System info

```
Fedora release 44 (Forty Four)
Kernel: 6.19.6-300.fc44.aarch64
GNOME: 50
Mesa: 25.3.6
```

## Related upstream work

- **Camera RGB:** Working via DKMS two-phase DT overlay. IR camera blocked (pm8010 absent).
- **Camera (upstream):** Bryan O'Donoghue (Linaro) v8 patches in LKML review (Feb 2026). Expected merge ~6.21/6.22.
- **Suspend (s2idle):** Both S3 and s2idle crash — PDC wakeup disabled in kernel. Qualcomm 5-patch series (Maulik Shah, March 2026) in LKML review. Custom kernel with fix prepared but not built yet.
- **USB4 / Thunderbolt 3:** USB-C DP alt-mode works, but TB3 tunneling is still blocked. UCSI exposes no `ALT_MODE_OVERRIDE`, the firmware never sends `USBC_NOTIFY` for the dock path, and current kernels still lack Qualcomm `x1e80100` USB4 host/router support. This is the first feature on this machine that looks likely to require a real custom-kernel path.
- **PCIe race condition:** Upstream fix expected ~6.21, would eliminate WiFi DKMS module.
- **DTB:** Vivobook X1407QA DTB not yet submitted — depends on camera/sensor patches.
