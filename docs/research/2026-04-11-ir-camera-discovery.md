# IR Camera (HM1092) Discovery — Findings

**Date:** 2026-04-11
**Hardware:** ASUS Vivobook X1407QA (Snapdragon X, Purwa/X1P42100)
**Kernel:** 6.19.10-300.fc44.aarch64
**Source material:** Qualcomm SOC Package `SOCPackage_forWebSite_Qualcomm_Z_V1.306.7800.0_45216.exe` (425 MiB) — published 2025-09-30, contains Windows drivers + config files for Snapdragon X platforms
**Related spec:** `docs/superpowers/specs/2026-04-11-ir-camera-hm1092-design.md`
**Plan:** `docs/superpowers/plans/2026-04-11-ir-camera-hm1092-discovery.md`

## Plan deviation notice

The original plan extracted an Asus BIOS `.cap` with UEFIExtract + parsed DSDT with iasl + parsed AeoB via custom scripts. In practice the user downloaded the **Qualcomm SOC driver package** (not the BIOS), which turned out to be a richer source for this investigation — it contains the Windows camera driver INFs, sensor module binaries, and platform resource files directly. The scripts 02-05 were not run; instead the SOC package was unpacked with `7z` directly into `/tmp/qcom-soc-pkg/extracted{,-aos,-front}/`.

The BIOS `.cap` path remains viable as a **future follow-up** if the SOC package analysis below turns out insufficient (notably, the Windows DSDT would have explicit ACPI `_PR0` power-resource mappings that the SOC package does not contain).

## Phase 0 pre-flight result

- RGB camera on 6.19.10: **WORKS** ✅ — `cam -c 1 --capture=1` produced a valid 8.38 MB ABGR8888 1920x1092 frame.
- Baseline kernel clock warnings: **REGRESSED** ⚠️ — three warnings reappeared on 6.19.10 that the March patched `qcom_camss` (for 6.19.8) had suppressed:
  - `Lucid PLL latch failed. Output may be unstable!`
  - `cam_cc_pll8 failed to enable!`
  - `cam_cc_slow_ahb_clk_src: rcg didn't update its configuration.`
- Frame capture **still succeeded** despite warnings — warnings are functionally benign on this kernel.
- Baseline log: `/tmp/rgb-6.19.10-baseline.log`.
- **Not blocking** IR work. Treat as separate follow-up: "rebuild the `cpas_ahb` `qcom_camss` patch for 6.19.10 and install in `/lib/modules/6.19.10-300.fc44.aarch64/updates/`."

## Phase 1 Discovery — Findings from SOC Package

### Hardware identity (confirmed)

| Field | Value | Source |
|-------|-------|--------|
| IR sensor model | **Hynix HM1092** | `com.qti.sensormodule.hm1092.bin`, `com.qti.tuned.hm1092_pw.bin` |
| ACPI Device ID | `ACPI\VEN_QCOM&DEV_0C99` | `qccamauxsensor_extension8380.inf` |
| ACPI HID (full name) | "Qualcomm(R) Spectra(TM) 695 ISP Camera Auxiliary Sensor Device" | INF strings section |
| Asus Purwa SubSys ID match | `SUBSYS_13041043&REV_0001` → `CameraAuxSensor_Device_QRD_Pw` | INF line 118 |
| Asus Purwa variant | **QRD_Pw** (not MTP, not Pw, not QRD) | INF binding table |

Four ASUS subsystem IDs are listed with `REV_0001` → `CameraAuxSensor_Device_QRD_Pw`:
- `13041043`, `32211043`, `13241043`, `32311043` (all 1043 = ASUS vendor)
- All ASUS Purwa variants use **QRD_Pw** binding

### Files bundled for Asus Purwa variant (QRD_Pw section)

From `[Binary_CopyFiles_QRD_Pw]` in `qccamauxsensor_extension8380.inf`:
- `com.qti.tuned.hm1092_pw.bin` — Purwa-specific HM1092 ISP tuning (1,051,746 bytes)
- `SCFG_AUX_8340_QRD.bin` — Purwa sensor config manifest (120 bytes)

From `[CameraAuxSensor_SysReg_QRD_Pw]` registry keys:
- `BinaryPath` → `CAMI_RES_QRD.bin` ← **NOT the `_MTP.bin` that Linux is currently using!**
- `ScfgBinaryPath` → `SCFG_AUX_8340_QRD.bin`

### AoS (Always-on Sensing) finding

INF lines 205-209:
```
[CameraAUXSensor_AOS_ShareResource_Pw]       AosShareResource = 1  (generic non-ASUS Purwa)
[CameraAUXSensor_AOS_ShareResource_QRD_Pw]   AosShareResource = 0  (ASUS Purwa)
```

**Asus Purwa does NOT use AOS resource sharing for the IR camera.** Earlier hypothesis that "Windows powers IR via Always-on Sensing sharing" is wrong for Asus. The IR camera uses the regular sensor driver power path on Asus.

Additionally, `qcAlwaysOnSensing_X1_0326_Signed/qcAlwaysOnSensing.inf` lists only `SUBSYS_13041043` and `SUBSYS_32211043` without `&REV_0001` — meaning the AOS driver does **not bind** to Asus Purwa devices at all.

### CAMI_RES_MTP.bin vs CAMI_RES_QRD.bin diff

Both files are 1906 bytes, same AeoB magic, same structure, same LDO names (`LDO4_M` + `LDO7_M`). They differ in exactly **two 4-byte fields** — voltage setpoints:

| Offset | MTP value | QRD value | Interpretation |
|--------|-----------|-----------|----------------|
| 0x238  | `0x001b7740` (1,800,000 µV = 1.800V) | `0x001b9680` (1,820,800 µV ≈ 1.821V) | LDO4_M (DOVDD) voltage |
| 0x2a8  | `0x002c4020` (2,900,000 µV = 2.900V) | `0x002c6f00` (2,912,000 µV ≈ 2.912V) | LDO7_M (AVDD) voltage |

Conclusion: MTP and QRD are **functionally equivalent** for the IR camera, with micro-tweaks to the setpoints. Both reference the same pm8010 rails.

**Live system check:** `/lib/firmware/qcom/CAMI_RES_MTP.bin` on this Vivobook is **BYTE-IDENTICAL** to the SOC package `CAMI_RES_MTP.bin`. Likewise `com.qti.sensormodule.hm1092.bin` is byte-identical. So Linux firmware-qualcomm package just ships the generic MTP reference; no Asus-specific IR config exists in the Linux firmware path.

### Power topology implied by CAMI_RES files

From AeoB string dump (identical structure in MTP and QRD for the IR sensor):

**Power-up sequence** (order in file):
1. `NPARESOURCE /arc/client/rail_mmcx` — MMCX rail vote
2. `CLOCK gcc_camera_xo_clk` — camera XO on
3. `CLOCK gcc_camera_ahb_clk` — camera AHB on
4. `CLOCK cam_cc_gdsc_clk` — GDSC clock on
5. `FOOTSWITCH cam_cc_titan_top_gdsc` — top GDSC on
6. `CLOCK cam_cc_cpas_ahb_clk` — CPAS AHB on
7. `PMICVREGVOTE PPP_RESOURCE_ID_LDO4_M` — **pm8010 LDO4_M (DOVDD, 1.8V)** ← enable
8. `PMICVREGVOTE PPP_RESOURCE_ID_LDO7_M` — **pm8010 LDO7_M (AVDD, 2.9V)** ← enable
9. `CLOCK cam_cc_mclk0_clk` — **MCLK0 (GPIO 96) on**
10. `TLMMGPIO ...` — reset gpio (GPIO 109 per CAMERA_STATUS.md)
11. `DELAY ...`
(power-down is reverse order)

### Comparison: RGB front sensor variants show the Purwa pattern

For the already-working RGB camera (OV02C10), the SOC package has THREE variants and they differ meaningfully:

| Variant | Size | Regulators used |
|---------|------|-----------------|
| `CAMF_RES_MTP.bin` (generic) | 3086 B | **LDO4_M + LDO1_M + LDO7_B + LDO6_M** (4 rails) |
| `CAMF_RES_MTP_Pw.bin` (Purwa generic) | 2275 B | **LDO7_B + LDO3_M** (2 rails) |
| `CAMF_RES_QRD.bin` (QRD ref) | 2275 B | **LDO7_B + LDO3_M** (identical to Pw) |

For Asus Purwa RGB:
- AVDD+DVDD: `vreg_l7b_2p8` (**PM8550B** LDO7, 2.8V) — physically present on this device
- DOVDD: `vreg_l3m_1p8` (pm8010 LDO3, 1.8V) — works fire-and-forget via RPMH despite pm8010 being marked disabled in DT
- This matches the working configuration in `modules/vivobook-cam-fix-2.0` (achievement #17)

**The IR files do NOT show this pattern** — there is no `CAMI_RES_MTP_Pw.bin` equivalent, and QRD/MTP for IR use identical LDO names (both reference pm8010 LDO4_M and LDO7_M, not pm8550B LDO7 like the RGB Purwa variant does).

### The central puzzle remains

- **Windows Hello IR worked on this exact hardware** (user confirmed).
- **Windows uses `CAMI_RES_QRD.bin`** (from the Asus Purwa INF binding path), which **explicitly references pm8010 LDO4_M + LDO7_M**.
- **pm8010 is physically absent from SPMI** per runtime scan (2026-04-11 verified):
  - SPMI bus has: `pm8550` × 5, `pmc8380` × 3, `smb2360` × 2
  - DT node `/soc@0/arbiter@c400000/spmi@c42d000/pmic@c` = `qcom,pm8010` with `status = "disabled"`
- **The DT status is `"disabled"`** — but the DT we boot is the Zenbook A14 DTB, not a Vivobook-specific DTB. Zenbook A14 may not use pm8010 even if Vivobook does.

**Two competing hypotheses:**

1. **pm8010 is physically present on Vivobook but dormant at boot.** Linux's SPMI driver doesn't probe it because the Zenbook A14 DT says "disabled". Windows enables it via a platform initialization step we're not replicating. The fix would be: override DT to mark pm8010 as `"okay"` and let the SPMI driver probe it.
2. **pm8010 is absent on Vivobook too** (same as Zenbook A14), but **Windows never actually enables LDO4_M/LDO7_M** — it relies on some alternative mechanism (physical pull-up on the rails, a GPIO power gate, or a shared regulator). The fix would require identifying that alternative mechanism, likely from the Windows DSDT we don't have.

### GPIO / I2C bus — still not definitively known

From `CAMERA_STATUS.md`:
- GPIO 96: MCLK0 (confirmed IR clock pin — matches sensormodule AeoB's `cam_cc_mclk0_clk`)
- GPIO 109: IR camera reset (confirmed)
- I2C bus: UNKNOWN — March tests tried CCI0 bus 0 (adapters 9, 10, 11) and got nothing

**New observation (2026-04-11):** In March tests, the scan did NOT explicitly include CCI1 bus 1 (the AON bus where RGB lives at addr 0x36). If the IR sensor shares CCI1 bus 1 at a different address, that could explain the failures. Neither CAMERA_STATUS.md nor the SOC package definitively assigns IR to CCI0 bus 0 — that was a best-guess assumption.

## Checkpoint A decision

**Mark ONE:**

- [ ] **GREEN** — Definitive mapping, proceed to write Phase 2-5 follow-up plan.
- [x] **YELLOW** — Partial data. Major progress but two key fields still unknown: (a) whether pm8010 is actually reachable, (b) which CCI/bus/address the IR sensor sits on.
- [ ] **RED** — BIOS/SOC-package revealed nothing new.

**YELLOW rationale:** The SOC package gave us the ASUS-Purwa binding path, the exact sensor model, the tuning files to use, confirmed power sequence, confirmed GPIOs 96 (MCLK0) and 109 (reset), confirmed AoS sharing is NOT used on Asus Purwa, and nailed down the voltage setpoints (1.82V / 2.91V). Still missing: I2C bus number and definitive answer on pm8010 reachability.

## Proposed next actions (for user decision)

Listed in order of effort / information yield. User picks one or more:

### Option 1 — Empirical: enable pm8010 in DT overlay, reboot, observe
**Cost:** 1 overlay edit + 1 reboot, maybe 15 minutes.
**What:** add to `vivobook_cam_fix` phase1 overlay:
```dts
&spmi_bus {
    pmic@c {
        status = "okay";
    };
};
```
**Success criteria:** after reboot, SPMI scan shows pm8010 at USID 0xc. If yes → hypothesis 1 confirmed, we can provision LDO4_M and LDO7_M. If no → hypothesis 2 confirmed, pm8010 really is absent.
**Risk:** very low — if SPMI driver fails to probe, it's a no-op (pm8010 already marked disabled, worst case we get probe timeouts in dmesg, nothing breaks).

### Option 2 — Download the actual Asus BIOS `.cap` and parse DSDT
**Cost:** one more download (~32-64 MB), run script 02 with the BIOS file, inspect DSDT `Device(CAMI)` and its `_PR0`.
**What:** gets the definitive power resource list from the Asus DSDT, which would settle the pm8010 question and reveal the real I2C bus.
**Blocker:** requires user to download the BIOS file (driver package doesn't contain DSDT).

### Option 3 — Scan ALL I2C adapters at runtime for HM1092 chip ID
**Cost:** small helper script + `i2cdetect` on each adapter, no reboot needed.
**What:** after loading the existing `vivobook_cam_fix` (RGB path — which brings CCI0 and CCI1 online), iterate every `i2c-N` adapter with `i2cdetect -y N` and look for any device at a plausible address. Test addresses 0x10, 0x20, 0x21, 0x36, 0x37 (HM1092 typical range).
**Success criteria:** any non-0x36-on-CCI1-bus1 response is the IR sensor. If nothing responds → IR is completely unpowered regardless of bus.

### Option 4 — Deeper binary parsing of `com.qti.sensormodule.hm1092.bin` (49 KB)
**Cost:** write a small parser for Qualcomm CAMX sensormodule format, 30-60 minutes.
**What:** extract I2C slaveAddr table, init register sequence, chip-ID register. Might reveal the default I2C address.
**Yield:** useful later for driver writing regardless of power path decision.

### Option 5 — Pause and commit findings, stop IR work
**Cost:** 0.
**What:** commit this findings doc, mark achievement #20 as "researched but unresolved", move to other tasks.

**My recommendation:** **Option 1 first** (cheap empirical test with clear outcome), then **Option 3** (no-reboot I2C scan), and if both hint that pm8010 is reachable or a bus is found, proceed to a follow-up plan. If both come up empty, **Option 2** (download BIOS).

## Open questions

1. Which option does the user pick next?
2. If Option 1 reveals pm8010 is reachable: are you OK with me writing an immediate DT overlay experiment before committing to a full Phase 2-5 plan?
3. Should the RGB `cpas_ahb` patch regression on 6.19.10 be handled as a parallel task, or deferred entirely until after IR work concludes?
