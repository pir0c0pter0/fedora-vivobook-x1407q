# Linux 7.3-rc6 X1407QA build and boot report

Date: **2026-10-07**

Machine: **ASUS VivoBook 14 X1407QA / Snapdragon X1-26-100 / AArch64**

Installed kernel: **`7.3.0-rc6-x1407qa-perf`**

Status: **validated after a physical cold boot on the notebook**

This report records the Fedora package refresh, the Linux 7.3-rc6 build,
model-specific runtime fixes, installation, recovery boundary, and post-boot
evidence. It supplements the Linux 7.2 ISO baseline; it does not claim that a
new 7.3 ISO has been published.

## Executive result

- Fedora 44 was updated successfully in DNF transaction 22: 825 packages were
  altered and the transaction finished with `Status: Ok`.
- The native AArch64 kernel toolchain was completed in transaction 23.
- Upstream Linux `v7.3-rc6` commit
  `a90ee4305c4a5df72c11b31dacfdc76e00fcf78a` was built locally on the
  X1407QA as `7.3.0-rc6-x1407qa-perf`.
- The final kernel, modules, config, `System.map`, and initramfs were installed
  as one consistent set; the eight existing X1407QA extra modules were
  preserved.
- A physical cold boot completed with zero failed systemd units. The graphical
  target was reached after 3.764 seconds.
- Landlock, RFCOMM, lithium-ion battery reporting, PipeWire audio, both camera
  sensors, FastRPC, CDSP, and QNN/HTP inference were validated.
- The repeatable first-client CDSP firmware crash was eliminated. The service
  completed one controlled remoteproc cycle, then remained active with
  `NRestarts=0`; the boot journal contained no `sleep_statsi` fatal error or
  CDSP crash recovery.

## Package refresh and build dependencies

The system refresh was performed before the build:

```text
Transaction 22: dnf upgrade --refresh -y
Result:         Ok
Packages:       825 altered
```

The kernel build dependencies were then installed explicitly:

```bash
sudo dnf install -y \
  dwarves ccache ncurses-devel elfutils-libelf-devel openssl-devel \
  bc bison flex rsync cpio xz tar perl make gcc git diffutils findutils
```

Transaction 23 installed the previously missing `ccache`, `dwarves`,
`libdwarves1`, `ncurses-devel`, and `ncurses-c++-libs` packages and also ended
with `Status: Ok`.

## Kernel source and performance configuration

The source baseline was the unmodified upstream release candidate before the
X1407QA patches:

```text
Tag:     v7.3-rc6
Commit:  a90ee4305c4a5df72c11b31dacfdc76e00fcf78a
Subject: Linux 7.3-rc6
```

Relevant final configuration:

```text
CONFIG_LOCALVERSION="-x1407qa-perf"
# CONFIG_LOCALVERSION_AUTO is not set
CONFIG_PREEMPT=y
CONFIG_HZ_250=y
CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE=y
CONFIG_ARM64_4K_PAGES=y
CONFIG_CPU_FREQ_DEFAULT_GOV_SCHEDUTIL=y
CONFIG_LTO_NONE=y
CONFIG_BT_RFCOMM=m
CONFIG_SECURITY_LANDLOCK=y
CONFIG_SECURITY_LANDLOCK_LOG=y
CONFIG_LSM="landlock,lockdown,yama,loadpin,safesetid,ipe,bpf"
```

The configuration favors predictable desktop latency and native build speed:
full preemption, the `schedutil` frequency governor, 250 Hz ticks, compiler
performance optimization, and no LTO. The 4 KiB page size matches the tested
Fedora userspace and existing X1407QA module stack.

Apply the versioned runtime patch and configuration changes with:

```bash
kernel/apply-linux-7.3-x1407qa-runtime-fixes.sh \
  /path/to/linux-7.3/source /path/to/linux-7.3/build
```

The helper rejects any source commit other than the recorded `v7.3-rc6`
commit. It requires an existing known-good X1407QA AArch64 `.config`, applies
both `linux-7.3-x1407qa-runtime-fixes.patch` and the compatible
`linux-7.2-camera-warning-fix.patch`, then normalizes and verifies every
performance, RFCOMM, and Landlock option shown above. It intentionally does
not claim that a generic `defconfig` contains all model-specific drivers. It
also rejects the result unless `make LOCALVERSION= kernelrelease` is exactly
`7.3.0-rc6-x1407qa-perf`, preventing a dirty-tree suffix from breaking module
vermagic.

Build the matching image and complete module set with an empty make-time
`LOCALVERSION`; otherwise a dirty source tree can append `-dirty` and break
module vermagic:

```bash
make -C /path/to/linux-7.3/source \
  O=/path/to/linux-7.3/build LOCALVERSION= -j"$(nproc)" Image modules
```

The installed kernel image SHA-256 was:

```text
dfc38d0d032a56bdf89f3ec5f8568eb5c3a5798c5718829fb3d54a83da9454db
```

The rebuilt `rfcomm`, `qcom_battmgr`, and `snd-soc-wcd938x` modules all report
the exact vermagic:

```text
7.3.0-rc6-x1407qa-perf SMP preempt mod_unload aarch64
```

Directory-scoped `M=<subdirectory>` builds were used for early module-only
validation. Asking Kbuild for an individual in-tree `.ko` target did not load
the full module symbol set and produced misleading modpost undefined-symbol
errors; the full `Image modules` build is the authoritative artifact set.

## Kernel runtime fixes

The versioned patch
[`kernel/linux-7.3-x1407qa-runtime-fixes.patch`](../kernel/linux-7.3-x1407qa-runtime-fixes.patch)
contains two source fixes. The accompanying apply script enables two required
configuration options.

| Component | Root cause | Change | Observed result |
|---|---|---|---|
| Qualcomm battery manager | ASUS firmware reports chemistry `OOD`, which mainline did not map | Treat `OOD` as `POWER_SUPPLY_TECHNOLOGY_LION` | Sysfs reports `Li-ion` |
| WCD938x codec | Headphone type and impedance are detected values, but controls were exposed with writable semantics | Use read-only, volatile ALSA controls | Codec loads cleanly; speaker and microphone nodes are available |
| Bluetooth RFCOMM | The custom config omitted `CONFIG_BT_RFCOMM` | Build RFCOMM as a module | `rfcomm` loads and BlueZ stays active with zero restarts |
| Landlock | `landlock` appeared in `CONFIG_LSM`, but `CONFIG_SECURITY_LANDLOCK` was disabled | Enable Landlock and its logging support | Active LSM list is `capability,landlock`; LocalSearch starts normally |

## FastRPC and CDSP boot hardening

### Root cause

Across multiple boots, the first `cdsprpcd` client consistently triggered a
firmware assertion in `sleep_statsi.c:537`. Delaying the client from about 6
seconds to about 15 seconds only delayed the same crash. The recovered second
remoteproc instance always worked, proving that the missing condition was a
clean warm CDSP initialization, not an arbitrary longer delay.

### Implemented boot sequence

The drop-in
[`systemd/cdsprpcd.service.d/10-x1407qa-stability.conf`](../systemd/cdsprpcd.service.d/10-x1407qa-stability.conf)
requires the separate, non-restarting
[`x1407qa-cdsp-prepare.service`](../systemd/x1407qa-cdsp-prepare.service),
which performs this sequence before `cdsprpcd`:

1. Find the remote processor named `cdsp`.
2. Atomically record that this boot has attempted the cycle.
3. Perform one controlled `stop`/`start` per boot.
4. Wait for the remoteproc state to return to `running` and for
   `/dev/fastrpc-cdsp` to reappear.
5. Use the udev `USEC_INITIALIZED` timestamp to wait until that exact device
   instance has remained stable for 10 seconds.
6. Start `cdsprpcd`.

The attempt marker is the atomic directory
`/run/x1407qa/remoteproc-cycle-cdsp.attempted`; successful preparation also
creates `/run/x1407qa/remoteproc-cycled-cdsp`. A manual daemon restart, or a
systemd retry after failed preparation, cannot cycle the hardware again in
the same boot. Both helpers have bounded waits and fail the service rather
than starting against a disappearing device.

The ADSP service also now uses the explicit invocation:

```text
/usr/local/sbin/adsprpcd audiopd adsp
```

`tools/setup-npu-runtime.sh` installs the two helpers, the corrected ADSP unit,
the CDSP preparation unit, and the daemon drop-in, then reloads systemd. The
implementation is covered by `tests/test-fastrpc-boot-hardening.sh`, including
the success and failure paths of the one-cycle-only contract and systemd unit
verification.

### Cold-boot evidence

The validating boot showed:

```text
 10.919306  systemd: Starting x1407qa-cdsp-prepare.service
 10.931780  helper: Clean-cycling cdsp before its first FastRPC client
 21.108188  systemd: Finished x1407qa-cdsp-prepare.service
 21.109795  systemd: Starting cdsprpcd.service
 21.131212  cdsprpcd: CDSP daemon starting
 21.131329  systemd: Started cdsprpcd.service
```

Final state:

```text
remoteproc cdsp state: running
x1407qa-cdsp-prepare ActiveState: active (exited)
x1407qa-cdsp-prepare NRestarts:   0
cdsprpcd ActiveState: active
cdsprpcd NRestarts:   0
CDSP crash matches:  0
```

QNN/HTP inference then passed with CPU fallback disabled:

```text
PASS: inferencia HTP/NPU com fallback de CPU desabilitado
ORT 1.26.0, NPU devices: 1, soc_id: 555, shim LD_PRELOAD ativo
result: [[1.0000001192092896, 2.000000238418579,
          3.500000238418579, 4.250000476837158]]
```

The per-process SoC ID override remains necessary because the current QNN
runtime does not recognize the X1P42100's real SoC ID `635`. The system sysfs
value is not changed.

## Power and graphical-service fixes included in this worktree

The battery frequency helper is now a standalone, testable program. It selects
2.3808 GHz on battery and restores 2.9568 GHz on AC or USB power. The setup
installs it for udev events and into the initramfs so coldplug can apply the
policy early. `tests/test-battery-freq-cap.sh` exercises battery and external
power with isolated fake sysfs trees.

The `vivobook_color_ctrl` module previously loaded too early through
`modules-load.d`, before the MSM DRM device existed. It now has a oneshot
systemd unit ordered after the display manager and camera service and wanted by
`graphical.target`. It deliberately does not unload at service stop; reboot is
the only safe teardown boundary for the display/camera stack.

## Installation and recovery boundary

Before replacing the same-release boot artifacts, the previous kernel image,
config, `System.map`, initramfs, and full module tree were copied to:

```text
/var/lib/x1407qa-kernel-7.3/runtime-fixes-backup/
  pre-full-rebuild-20261007-1040/
```

The complete module tree was installed first, preserving the existing
`extra/` modules. The new image, config, and `System.map` were then copied to
`/boot`, followed by `depmod` and a forced dracut rebuild. GRUB already pointed
to `/boot/vmlinuz-7.3.0-rc6-x1407qa-perf`, which remained the default entry.

Rollback is manual: restore the four `/boot` files and matching module tree
from that backup, run `depmod -a 7.3.0-rc6-x1407qa-perf`, and rebuild that
kernel's initramfs. Do not mix the backed-up image with the new module tree or
vice versa.

## Final physical validation

| Check | Result |
|---|---|
| Kernel release | `7.3.0-rc6-x1407qa-perf` |
| Kernel image/config/System.map | Byte-for-byte matched the completed build before reboot |
| systemd failed units | 0 |
| Kernel/initrd/userspace total | 21.131 s |
| Graphical target | 3.764 s in userspace |
| Active LSMs | `capability,landlock` |
| Battery technology | `Li-ion` |
| RFCOMM | Module loaded |
| WCD938x | Module loaded; PipeWire speaker and microphone nodes present |
| Cameras | `hm1092` and `ov02c10` published; PipeWire front-camera sources present |
| ADSP daemon | Active, zero restarts |
| CDSP daemon | Active, zero restarts, no cold-boot firmware crash |
| Bluetooth | Active, zero restarts |
| LocalSearch | Active under Landlock-enabled kernel |
| QNN/HTP | Real NPU inference passed with CPU fallback disabled |

Boot ID `25334202-039b-4474-90d6-28d80acd5987` validated the final separate
oneshot topology from firmware startup. The attempt and success markers were
created once, the device stability gate took the expected ten seconds, the
preparation unit completed before `cdsprpcd` started, and all FastRPC services
remained active with zero restarts. A journal-wide scan found no CDSP crash
signature, and real QNN/HTP inference passed afterward with CPU fallback
disabled.

Automated checks used for the final gate:

```bash
tests/test-battery-freq-cap.sh
tests/test-color-control-service.sh
tests/test-fastrpc-boot-hardening.sh
tests/test-linux73-runtime-fixes.sh
systemd-analyze verify x1407qa-cdsp-prepare.service cdsprpcd.service adsprpcd_audiopd.service
git diff --check
```

## Remaining work

1. Build and publish a refreshed Fedora image containing the validated 7.3
   kernel and runtime files, then repeat physical USB boot, installation,
   recovery, archive, and checksum tests.
2. Send the battery chemistry and WCD938x control fixes upstream.
3. Keep `s2idle`; `deep` suspend remains unsafe on this platform.
4. Continue tracking upstream Qualcomm USB4/Thunderbolt host-router support.
5. Remove the per-process QNN SoC-ID workaround only after the vendor runtime
   recognizes X1P42100 ID `635` natively.
6. Add native monochrome `R10_CSI2P` support to the libcamera soft ISP; the
   existing V4L2 IR capture path already works.
7. Keep the known non-fatal boot messages visible and documented: PMIC
   device-link retries, runtime device-tree overlay removal warnings, optional
   FastRPC `.farf` lookups, and the early PipeWire route probe.
