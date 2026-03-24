# RGB Camera Progress - March 24, 2026

## Context

User request on March 24, 2026:

- make the RGB camera work fully
- remove warnings
- make both frame capture and video work
- undo all IR work for now

This document records what was changed, what is already persisted on disk, what was validated, and what is still blocked by the current boot state.

## Current Short Status

- IR experimental work is undone and out of the way.
- RGB camera persistent changes were applied to the repo, DKMS module, systemd unit, wrapper script, and libcamera userspace.
- The current boot is contaminated by camera-related kernel oops/soft-lockup events, so final frame/video validation from this boot is not trustworthy.
- A clean reboot is required before re-validating the RGB pipeline.

## What Was Completed

### 1. IR work was removed

The experimental IR probe directory created earlier was removed:

- `modules/vivobook-ir-probe-0.1/`

Intentional state after this cleanup:

- no IR probe module
- no IR-specific overlay experiments
- focus only on RGB camera bring-up

### 2. RGB overlay/runtime-PM logic was hardened

Repo source updated:

- `modules/vivobook-cam-fix-2.0/vivobook_cam_fix.c`

Main changes:

- removed the fixed `msleep(1000)` gap after phase1
- added immediate runtime-PM holding logic for camera blocks
- made `CAMCC` and `CAMSS` holds happen immediately after phase1
- made `CCI1` hold mandatory after phase2
- kept `CCI0` hold as best-effort
- improved failure handling so overlay init aborts more explicitly if a critical hold cannot be acquired

Why this matters:

- the old code left a large window between overlay application and PM hold
- on this platform, `CAMCC` runtime PM can drop PLL state in that window
- once PLL8 state is lost, first stream attempts fail with `cam_cc_pll8 failed to enable` and `clock enable failed: -110`

### 3. RGB service and wrapper were hardened

Repo files updated:

- `modules/vivobook-cam-fix-2.0/vivobook-camera.service`
- `modules/vivobook-cam-fix-2.0/vivobook-camera`

Main changes:

- wrapper now uses `systemctl restart` instead of `start` to avoid stale active oneshot state
- service pins camera blocks to `power/control=on`
- service now runs a short `udevadm settle` before touching runtime PM sysfs
- installed copies were synced to:
  - `/etc/systemd/system/vivobook-camera.service`
  - `/usr/local/bin/vivobook-camera`

Installed file timestamps after sync:

- `/etc/systemd/system/vivobook-camera.service` -> March 24, 2026 11:36
- `/usr/local/bin/vivobook-camera` -> March 24, 2026 11:36

### 4. DKMS module was rebuilt and reinstalled

The updated RGB overlay module was copied into:

- `/usr/src/vivobook-cam-fix-2.0/`

Then DKMS was rebuilt/reinstalled for the running kernel:

- module name: `vivobook-cam-fix`
- version: `2.0`
- kernel: `6.19.8-300.fc44.aarch64`

Installed module location:

- `/lib/modules/6.19.8-300.fc44.aarch64/extra/vivobook_cam_fix.ko.xz`

`dkms status` afterward showed:

- `vivobook-cam-fix/2.0, 6.19.8-300.fc44.aarch64, aarch64: installed`

### 5. libcamera was patched and installed system-wide

Source tree used:

- `/home/mariostjr/.cache/libcamera-v0.7.0-src`

Files changed:

- `include/libcamera/internal/camera_sensor_properties.h`
- `src/libcamera/sensor/camera_sensor_properties.cpp`
- `src/libcamera/sensor/camera_sensor_legacy.cpp`
- `src/libcamera/sensor/camera_sensor_raw.cpp`
- `src/ipa/libipa/camera_sensor_helper.cpp`
- `src/ipa/simple/data/meson.build`
- `src/ipa/simple/data/ov02c10.yaml`

Main userspace additions:

- `ov02c10` camera sensor helper
- static properties entry for `ov02c10`
- IPA simple YAML for `ov02c10`
- static fallback for `pixelArraySize` and `activeArea`

Important detail:

- this userspace fallback is meant to suppress the libcamera warnings that were previously emitted when the kernel sensor driver did not expose selection rectangles
- this means the remaining warning cleanup no longer depends on patching the running kernel's `ov02c10` module

Build/install details:

- build system: `meson` + `ninja`
- extra build dependencies installed:
  - `python3-jinja2`
  - `python3-ply`
- installed into `/usr`
- `cam` now resolves against the system-installed `libcamera 0.7.0` in `/lib64`/`/usr/lib64`

Installed data confirmation:

- `/usr/share/libcamera/ipa/simple/ov02c10.yaml`

## What Was Attempted But Not Persisted

### Kernel `ov02c10.ko` override

An attempt was made to build a patched `ov02c10.ko` from a full kernel tree under:

- `/home/mariostjr/rpmbuild/BUILD/kernel-6.19.8-build/kernel-6.19.8/linux-6.19.8-300.s2idle.fc44.aarch64`

This produced a module, but it was built for:

- `6.19.8-300.s2idle.fc44.aarch64`

The running kernel is:

- `6.19.8-300.fc44.aarch64`

Because of the `vermagic` mismatch, that override was intentionally not installed for live use.

Conclusion:

- there is no safe kernel `ov02c10` override installed right now
- warning suppression for selection rectangles is expected to come from the libcamera fallback instead

## What Failed In This Boot

### 1. This boot was already degraded before final validation

Before the final round of work, this boot had already seen:

- repeated failed camera stream attempts
- module unload/reload experiments
- camera clock/controller instability

Symptoms already observed earlier in this boot:

- `cam_cc_pll8 failed to enable!`
- `qcom-camss acb7000.isp: clock enable failed: -110`
- `qcom-camss acb7000.isp: Failed to power up pipeline: -110`
- `i2c-qcom-cci ... CCI halt timeout`

### 2. Service restart triggered a kernel oops on `modprobe camcc_x1e80100`

At March 24, 2026 11:37:50 -03:

- `systemctl restart vivobook-camera.service` failed
- `modprobe camcc_x1e80100` triggered a kernel oops in `idempotent_init_module()`

Systemd result:

- `vivobook-camera.service: Main process exited, code=killed, status=11/SEGV`

Kernel result:

- page fault/oops during module init path
- current kernel became tainted with `D`, `W`, `O`, `E`

### 3. Later manual `modprobe qcom_camss` and `modprobe ov02c10` attempts soft-locked

After the oops, manual attempts to load:

- `qcom_camss`
- `ov02c10`

did not complete cleanly.

Observed later:

- `watchdog: BUG: soft lockup`
- stuck `modprobe` processes spinning in kernel

Conclusion:

- this boot is no longer a trustworthy validation environment
- any further results from this session are not meaningful for proving RGB camera success/failure

## Current Persistent System State

Confirmed present on disk:

- `/etc/systemd/system/vivobook-camera.service`
- `/usr/local/bin/vivobook-camera`
- `/lib/modules/6.19.8-300.fc44.aarch64/extra/vivobook_cam_fix.ko.xz`
- `/usr/share/libcamera/ipa/simple/ov02c10.yaml`
- updated libcamera libraries in `/usr/lib64`

Repo status after this work:

- modified:
  - `modules/vivobook-cam-fix-2.0/vivobook-camera`
  - `modules/vivobook-cam-fix-2.0/vivobook-camera.service`
  - `modules/vivobook-cam-fix-2.0/vivobook_cam_fix.c`
- unrelated existing untracked files remain in the repo
- one generated untracked file also exists from the module build:
  - `modules/vivobook-cam-fix-2.0/vivobook_cam_phase1.dtbo`

## What Still Needs Validation After Reboot

After a clean reboot, the following must be re-checked in a fresh kernel state:

1. Start RGB camera cleanly:

   - `vivobook-camera start`

2. Confirm camera enumeration:

   - `cam -l`

Expected result:

- camera should enumerate
- previous libcamera warnings about missing static properties / helper / YAML should be gone
- previous warnings about missing selection rectangles should be suppressed by the new static fallback

3. Validate still capture:

   - `cam -c 1 --capture=1`

4. Validate short video stream:

   - `cam -c 1 --capture=5 --stream role=video,width=1280,height=720`

5. Watch kernel logs during those tests:

   - confirm that `cam_cc_pll8 failed to enable` does not return
   - confirm there is no `clock enable failed: -110`

## Best Current Assessment

Most of the persistent engineering work requested by the user is already in place:

- IR work is removed
- RGB bootstrapping logic is stronger than before
- stale oneshot service behavior is fixed
- libcamera now knows `ov02c10`
- warning suppression no longer depends solely on kernel-side `get_selection`

What is not yet proven:

- frame capture on a clean boot
- video streaming on a clean boot
- absence of PLL8/clock failures after reboot

Because the current boot suffered kernel oops and later soft lockups, the only correct next step is:

- reboot
- re-run validation immediately in the fresh session

## Reboot Validation: 2026-03-24 13:17 to 13:25

Fresh boot:

- boot time confirmed with `uptime -s`: `2026-03-24 13:17:05`
- kernel: `6.19.8-300.fc44.aarch64`
- `vivobook-camera.service` restarted cleanly and stayed `active`
- `/dev/media0` and `/dev/video*` nodes were present
- loaded modules included `vivobook_cam_fix`, `ov02c10`, `qcom_camss`, `i2c_qcom_cci`, `camcc_x1e80100`

Userspace validation after the latest `libcamera` rebuild:

1. Camera enumeration:

   - command: `cam -l`
   - result: success
   - output was clean for the previous `libcamera` warnings
   - no more:
     - `No static properties available for ''`
     - `PixelArraySize property has been defaulted`
     - `PixelArrayActiveAreas property has been defaulted`
     - `Failed to retrieve the sensor crop rectangle`
     - `The analogue crop rectangle has been defaulted to the active area size`

2. Still frame:

   - command: `cam -c 1 --capture=1`
   - result: success
   - configured stream: `1920x1092-ABGR8888/sRGB`
   - one frame captured successfully

3. Short video stream:

   - command: `cam -c 1 --capture=15 --stream role=video,width=1280,height=720 --file=/tmp/ov02c10-video-#.bin`
   - result: success
   - configured stream: `1280x720-ABGR8888/sRGB`
   - sustained roughly `30 fps`
   - 15 frame dumps were written under `/tmp/ov02c10-video-*.bin`

## Remaining Problem After Reboot

Even with clean `libcamera` userspace logs and successful capture/streaming, the kernel still emits a clock warning on `streamon`.

Observed during frame capture at `2026-03-24 13:25:00` and again during video start at `2026-03-24 13:25:08`:

- `Lucid PLL latch failed. Output may be unstable!`
- `cam_cc_slow_ahb_clk_src: rcg didn't update its configuration.`
- `WARNING: drivers/clk/qcom/clk-rcg2.c:136 at update_config+0xdc/0x100`

Call trace consistently passes through:

- `csid_set_clock_rates()`
- `csid_set_power()`
- `video_prepare_streaming()`
- `vb2_ioctl_streamon()`

What this means:

- RGB camera is now functionally working for enumeration, still frame, and video stream
- `libcamera` warning cleanup is done
- the system is not yet fully warning-free because kernel clock programming still warns at stream start

Current status:

- userspace: clean
- frame capture: working
- video stream: working
- kernel: residual `clk-rcg2` / PLL latch WARN still unresolved

## Kernel Warning Investigation: 2026-03-24 13:33+

Observed facts from source inspection and live tests:

- the residual warning comes from `drivers/clk/qcom/clk-rcg2.c:update_config()`
- the call trace always passes through `csid_set_clock_rates()` in `qcom_camss`
- on `x1e80100`, the CSID resource table asks for:
  - `cpas_ahb = 64000000`
  - `cpas_fast_ahb = 80000000`
- `cpas_ahb` is routed through `cam_cc_slow_ahb_clk_src`
- that is the exact RCG that warns during `streamon`

Failed hypothesis:

- a temporary helper module was built to pre-program and hold `cpas_ahb` and `cpas_fast_ahb`
- result: this did **not** solve the issue
- setting `cpas_ahb` directly reproduced the same `cam_cc_slow_ahb_clk_src: rcg didn't update its configuration` warning at helper load time
- conclusion: the problem is not only "cold clocks" or missing PM refs
- conclusion: the bug sits in the `qcom_camss` rate vote path itself for `cpas_ahb`

What was changed after that:

- reverted the experimental clock-priming changes from `vivobook_cam_fix.c`
- patched `qcom_camss` in:
  - `drivers/media/platform/qcom/camss/camss-csid.c`
- patch behavior:
  - on `qcom,x1e80100-camss` only
  - skip the explicit `clk_set_rate()` vote for `cpas_ahb`
  - keep all other clock handling unchanged

Build/install state:

- rebuilt patched `qcom-camss.ko`
- rebuilt clean `vivobook_cam_fix.ko`
- installed both as override modules in:
  - `/lib/modules/6.19.8-300.fc44.aarch64/updates/qcom-camss.ko`
  - `/lib/modules/6.19.8-300.fc44.aarch64/updates/vivobook_cam_fix.ko`
- `depmod -a` completed
- `modprobe --show-depends` now resolves:
  - `qcom_camss` -> `/lib/modules/6.19.8-300.fc44.aarch64/updates/qcom-camss.ko`
  - `vivobook_cam_fix` -> `/lib/modules/6.19.8-300.fc44.aarch64/updates/vivobook_cam_fix.ko`

Important limitation of the current boot:

- the old in-memory `qcom_camss` is still loaded in this session
- hot-swapping the live camera stack is intentionally avoided because earlier unload/reload attempts on this platform caused instability
- therefore the new kernel-side fix is installed and ready, but not yet validated in-memory

Next validation after reboot:

1. Start camera again:

   - `vivobook-camera start`

2. Re-test:

   - `cam -l`
   - `cam -c 1 --capture=1`
   - `cam -c 1 --capture=10 --stream role=video,width=1280,height=720`

3. Check kernel log:

   - confirm `cam_cc_slow_ahb_clk_src: rcg didn't update its configuration` is gone
   - confirm `Lucid PLL latch failed. Output may be unstable!` is gone

## Final Reboot Validation: 2026-03-24 13:42+

Fresh boot:

- boot time: `2026-03-24 13:42:41`
- kernel: `6.19.8-300.fc44.aarch64`
- `modprobe --show-depends` confirmed:
  - `qcom_camss` resolves to `/lib/modules/6.19.8-300.fc44.aarch64/updates/qcom-camss.ko`
  - `vivobook_cam_fix` resolves to `/lib/modules/6.19.8-300.fc44.aarch64/updates/vivobook_cam_fix.ko`

Functional validation:

1. Camera start:

   - command: `vivobook-camera start`
   - result: success
   - service state: `ActiveState=active`, `Result=success`

2. Enumeration:

   - command: `cam -l`
   - result: success
   - userspace log remained clean

3. Still frame:

   - command: `cam -c 1 --capture=1`
   - result: success
   - stream: `1920x1092-ABGR8888/sRGB`

4. Video:

   - command: `cam -c 1 --capture=10 --stream role=video,width=1280,height=720`
   - result: success
   - stream: `1280x720-ABGR8888/sRGB`
   - observed rate: about `29-31 fps`

Kernel validation:

- checked `journalctl -k -b` for:
  - `cam_cc_slow_ahb_clk_src`
  - `Lucid PLL latch failed`
  - `WARNING: drivers/clk/qcom/clk-rcg2.c:136`
  - `clock enable failed`
  - `cam_cc_pll8`
  - `Oops`
  - `soft lockup`
  - `BUG:`
- result: no matches after this reboot's camera bring-up and tests

Final assessment:

- RGB camera enumeration works
- still frame works
- video stream works
- `libcamera` userspace warnings are gone
- kernel camera warnings previously tied to `cam_cc_slow_ahb_clk_src` are gone
- IR remains disabled/untouched
