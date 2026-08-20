# Stable Hardware Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore every daily-driver hardware feature documented for the ASUS Vivobook X1407QA on the installed Fedora 44 kernel `7.2.0-x1407qa`, excluding IR camera, USB4/TB3, and suspend.

**Architecture:** Add a read-only audit as the executable acceptance contract, then repair the dependency chain from early-boot remoteproc/firmware through Wi-Fi and desktop integration. Keep each system mutation in an idempotent installer helper, stop before reboot if compilation or initramfs verification fails, and validate again after one controlled reboot.

**Tech Stack:** Bash, Linux sysfs/debugfs, dracut, kmod/DKMS, C kernel modules, NetworkManager, UPower, GNOME Shell 50, and optional PowerShell repository tests when `pwsh` is installed.

**Spec:** `docs/superpowers/specs/2026-08-20-hardware-recovery-design.md`

## Global Constraints

- Target Fedora 44 aarch64 and the installed kernel `7.2.0-x1407qa`; do not update kernel, Mesa, or firmware packages globally.
- Do not enable the IR camera, USB4/TB3 experimental module, suspend, or hibernate.
- Never set GPIO5 `DIG_OUT_SOURCE_CTL` to `0x00` or force GPIO5 output LOW.
- Preserve a bootable kernel entry and stop before reboot if module compilation, `depmod`, `dracut`, or initramfs inspection fails.
- Back up overwritten non-RPM system files under `/var/lib/vivobook-recovery/2026-08-20/` and record them in `manifest.txt`.
- Use test-first changes and one root-cause hypothesis per correction.

---

### Task 1: Executable hardware audit

**Files:**
- Create: `tools/audit-stable-hardware.sh`
- Create: `tests/test-stable-hardware-audit.sh`

**Interfaces:**
- Consumes: standard commands and sysfs exposed by Fedora 44.
- Produces: `tools/audit-stable-hardware.sh [--pre-reboot|--post-reboot]`, one `PASS|FAIL|SKIP <component>: <detail>` line per component and a nonzero exit when a required stable component fails.

- [ ] **Step 1: Write the failing structural test**

```bash
#!/usr/bin/env bash
set -euo pipefail
audit=tools/audit-stable-hardware.sh
[[ -f $audit ]] || { echo 'hardware audit missing' >&2; exit 1; }
for token in wifi battery adsp cdsp gpu bluetooth keyboard touchpad backlight hotkeys audio cpufreq charge-limit camera-rgb color-control lid-safety; do
    grep -q "$token" "$audit" || { echo "audit missing component: $token" >&2; exit 1; }
done
for forbidden in vivobook_usb4_fix enable-hm1092 'systemctl unmask suspend.target'; do
    ! grep -q "$forbidden" "$audit" || { echo "unsafe audit behavior: $forbidden" >&2; exit 1; }
done
echo 'PASS: stable hardware audit covers the approved scope'
```

- [ ] **Step 2: Run the test and verify RED**

Run: `bash tests/test-stable-hardware-audit.sh`

Expected: FAIL with `hardware audit missing`.

- [ ] **Step 3: Implement the audit**

Create a strict Bash script with `pass`, `fail`, and `skip` helpers. Test real state with `lspci -k`, `ip link`, `/sys/class/remoteproc`, `/sys/class/power_supply`, `/sys/class/backlight`, `/sys/devices/system/cpu/cpufreq`, `upower`, `bluetoothctl`, `pactl`, `libinput`, `gnome-extensions`, `systemctl is-enabled`, `modinfo`, and the current boot journal. `--pre-reboot` may mark reboot-dependent checks `SKIP`; `--post-reboot` must fail them. Never write to sysfs.

- [ ] **Step 4: Verify GREEN and capture the baseline**

Run:

```bash
bash tests/test-stable-hardware-audit.sh
bash tools/audit-stable-hardware.sh --pre-reboot | tee /tmp/x1407qa-before.txt
```

Expected: the structural test passes; the audit reports current Wi-Fi, ADSP, CDSP, battery, GNOME battery UI, and any other observed failures individually.

- [ ] **Step 5: Commit**

```bash
git add tools/audit-stable-hardware.sh tests/test-stable-hardware-audit.sh
git commit -m "test: add stable hardware audit"
```

### Task 2: Early-boot remoteproc and firmware contract

**Files:**
- Modify: `setup-vivobook.sh`
- Modify: `kernel/verify-linux-7.2-x1407qa.sh`
- Create: `tests/test-remoteproc-initramfs.sh`

**Interfaces:**
- Consumes: installed `qcom_q6v5_pas`, `qcom_q6v5_adsp`, `qcom_glink_smem`, ADSP/CDSP firmware, and the current kernel image.
- Produces: `/etc/dracut.conf.d/qcom-remoteproc.conf` and an initramfs containing the drivers and exact firmware paths needed before rootfs.

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
set -euo pipefail
for token in qcom_q6v5_pas qcom_q6v5_adsp qcom_glink_smem qcadsp8380.mbn adsp_dtbs.elf qccdsp8380.mbn cdsp_dtbs.elf; do
    grep -q "$token" setup-vivobook.sh || { echo "setup missing early boot item: $token" >&2; exit 1; }
done
grep -q 'CONFIG_QCOM_Q6V5_PAS=m' kernel/verify-linux-7.2-x1407qa.sh || { echo 'kernel verifier does not enforce PAS module' >&2; exit 1; }
echo 'PASS: remoteproc initramfs contract is explicit'
```

- [ ] **Step 2: Run the test and verify RED**

Run: `bash tests/test-remoteproc-initramfs.sh`

Expected: FAIL because `setup-vivobook.sh` does not force all remoteproc modules and the verifier does not assert `CONFIG_QCOM_Q6V5_PAS=m`.

- [ ] **Step 3: Implement the minimal configuration**

Add an idempotent setup block that writes:

```bash
force_drivers+=" qcom_q6v5_pas qcom_q6v5_adsp qcom_glink_smem "
install_items+=" /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/qcadsp8380.mbn /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/adsp_dtbs.elf /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/qccdsp8380.mbn /usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/cdsp_dtbs.elf "
```

Make setup fail if any named source file or module is absent. Extend the kernel artifact verifier to require `CONFIG_QCOM_Q6V5_PAS=m`, `CONFIG_QCOM_Q6V5_ADSP=m`, `CONFIG_QCOM_PMIC_GLINK=m`, and `CONFIG_BATTERY_QCOM_BATTMGR=m`.

- [ ] **Step 4: Verify tests and the rebuilt initramfs in a temporary output**

Run:

```bash
bash tests/test-remoteproc-initramfs.sh
sudo dracut --force --kver "$(uname -r)" /tmp/initramfs-$(uname -r)-candidate.img
sudo lsinitrd /tmp/initramfs-$(uname -r)-candidate.img | rg 'qcom_q6v5_(pas|adsp)|qcom_glink_smem|qcadsp8380|qccdsp8380|adsp_dtbs|cdsp_dtbs'
```

Expected: test passes and every required module/blob appears in the candidate image.

- [ ] **Step 5: Commit**

```bash
git add setup-vivobook.sh kernel/verify-linux-7.2-x1407qa.sh tests/test-remoteproc-initramfs.sh
git commit -m "fix: include remoteproc stack in initramfs"
```

### Task 3: Wi-Fi regulator fix for the kernel 7.2 DT

**Files:**
- Create: `modules/wcn-regulator-fix-1.0/wcn_regulator_fix.c`
- Create: `modules/wcn-regulator-fix-1.0/Makefile`
- Create: `modules/wcn-regulator-fix-1.0/dkms.conf`
- Create: `tests/test-wcn-regulator-fix.sh`
- Modify: `setup-vivobook.sh`

**Interfaces:**
- Consumes: DT node `qcom,wcn6855-pmu`, its ten supply properties, `pwrseq_qcom_wcn`, and PCI ID `17cb:1103`/subsystem `105b:e130`.
- Produces: `wcn_regulator_fix.ko` that holds the PMU supplies, caps deferred retries, and performs one delayed PCI rescan only when the device is absent.

- [ ] **Step 1: Write the failing source-contract test**

```bash
#!/usr/bin/env bash
set -euo pipefail
source_file=modules/wcn-regulator-fix-1.0/wcn_regulator_fix.c
[[ -f $source_file ]] || { echo 'repository Wi-Fi DKMS source missing' >&2; exit 1; }
for token in qcom,wcn6855-pmu vddrfa0p95 vddrfa1p9 vddpcie1p9 vddpmucx vddpmumx vddio max_regulator_retries; do
    grep -q "$token" "$source_file" || { echo "Wi-Fi fix missing: $token" >&2; exit 1; }
done
echo 'PASS: Wi-Fi module follows the active PMU supply contract'
```

- [ ] **Step 2: Run the test and verify RED**

Run: `bash tests/test-wcn-regulator-fix.sh`

Expected: FAIL with `repository Wi-Fi DKMS source missing`.

- [ ] **Step 3: Implement the module from the installed known source**

Copy the existing module structure into the repository, but change the consumer node to `of_find_compatible_node(NULL, NULL, "qcom,wcn6855-pmu")`. Replace the obsolete Wi-Fi-node supply list with the PMU supplies `vddaon`, `vddio`, `vddpcie1p3`, `vddpcie1p9`, `vddpmu`, `vddpmucx`, `vddpmumx`, `vddrfa0p95`, `vddrfa1p3`, and `vddrfa1p9`. Add `max_regulator_retries=30`; after the cap, log one error and stop rescheduling. Keep cleanup balanced and the existing subsystem-specific PCI detection.

- [ ] **Step 4: Verify GREEN and compile without loading**

Run:

```bash
bash tests/test-wcn-regulator-fix.sh
make -C modules/wcn-regulator-fix-1.0 KDIR=/lib/modules/$(uname -r)/build
modinfo modules/wcn-regulator-fix-1.0/wcn_regulator_fix.ko
```

Expected: test passes, compilation exits 0, and vermagic names `7.2.0-x1407qa`.

- [ ] **Step 5: Commit**

```bash
git add modules/wcn-regulator-fix-1.0 tests/test-wcn-regulator-fix.sh setup-vivobook.sh
git commit -m "fix: align Wi-Fi power hold with kernel 7.2 DT"
```

### Task 4: Persistent core module installation

**Files:**
- Create: `modules/vivobook-kbd-fix-1.0/{vivobook_kbd_fix.c,Makefile,dkms.conf}`
- Create: `modules/vivobook-bl-fix-1.0/{vivobook_bl_fix.c,Makefile,dkms.conf}`
- Create: `modules/vivobook-hotkey-fix-1.0/{vivobook_hotkey_fix.c,Makefile,dkms.conf}`
- Modify: `setup-vivobook.sh`
- Modify: `tests/Test-CoreModuleGate.ps1`
- Create: `tests/test-core-module-build.sh`

**Interfaces:**
- Consumes: the installed, currently working `/usr/src` source revisions, the checksum-pinned Linux 7.2 source tarball, and `/boot/config-7.2.0-x1407qa`.
- Produces: four complete in-repository DKMS packages and a prepared build tree at `/var/lib/x1407qa-kernel-7.2/module-build` before registering them.

- [ ] **Step 1: Extend the failing gate test**

Extend `Test-CoreModuleGate.ps1` to require each core module directory to contain its `.c`, `Makefile`, and `dkms.conf`. Create `test-core-module-build.sh` that fails unless setup contains the pinned checksum `f9fef3d14c0df53819026f4be74459835c2a0b0dcbf5b5bbd9ea19f0829402b3`, `make modules_prepare`, `/lib/modules/${kernel}/build`, `dkms add`, `dkms build`, `dkms install`, and `depmod`.

- [ ] **Step 2: Run the test and verify RED**

Run: `bash tests/test-core-module-build.sh`

Expected: FAIL because the Bash test and three core module sources are absent from the repository.

- [ ] **Step 3: Import and harden the known sources**

Copy only the installed source packages matching SHA-256 `1148c3c615355bd67a689f453d4d4264f6529f9ee00b403e08ee08eda6581bed` (keyboard), `b8da1abc280585d11d093c462df4197ac62871d2bb8d324ba0e52b5cba2691f1` (backlight), and `b70a6204b5ee88ee8f2cadac2ed8864764cef051a2a526bf419867dbb3eac1ab` (hotkey). If the kernel build link is broken, download `https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.2.tar.xz`, verify the pinned checksum, extract under `/var/lib/x1407qa-kernel-7.2/`, copy `/boot/config-$(uname -r)` to `.config`, run `make olddefconfig modules_prepare`, and atomically replace `/lib/modules/$(uname -r)/build` with a link to that prepared tree. Then stage sources with `install -D`, install only `gcc make dkms perl elfutils-libelf-devel openssl-devel` if missing, register/build/install each exact `name/1.0`, and run `depmod $(uname -r)`. A failed source verification, preparation, or core build must exit before dracut.

- [ ] **Step 4: Verify GREEN and build all four modules**

Run:

```bash
bash tests/test-core-module-build.sh
if command -v pwsh >/dev/null; then pwsh -NoProfile -File tests/Test-CoreModuleGate.ps1; fi
for d in modules/{wcn-regulator-fix,vivobook-kbd-fix,vivobook-bl-fix,vivobook-hotkey-fix}-1.0; do make -C "$d" KDIR=/lib/modules/$(uname -r)/build clean all; done
```

Expected: test and all builds pass.

- [ ] **Step 5: Commit**

```bash
git add modules/vivobook-{kbd,bl,hotkey}-fix-1.0 setup-vivobook.sh tests/Test-CoreModuleGate.ps1 tests/test-core-module-build.sh
git commit -m "build: package core Vivobook DKMS sources"
```

### Task 5: Firmware paths and battery desktop UI

**Files:**
- Modify: `setup-vivobook.sh`
- Modify: `install-battery-time-ext.sh`
- Create: `tests/test-hardware-desktop-integration.sh`

**Interfaces:**
- Consumes: compressed Fedora GPU/Bluetooth firmware, ASUS ZAP firmware, qcom-battmgr sysfs, GNOME Shell 50.
- Produces: verified dracut firmware paths, compatible Bluetooth aliases if the kernel cannot request compressed firmware directly, visible GNOME percentage, and enabled `battery-time@wifiteste` for the real user.

- [ ] **Step 1: Write the failing integration-contract test**

Assert that setup uses `SUDO_USER`, sets `show-battery-percentage true`, invokes the extension installer as that user, enables the extension, checks both compressed and uncompressed firmware variants, and refuses to claim success when a required firmware path is absent.

- [ ] **Step 2: Run the test and verify RED**

Run: `bash tests/test-hardware-desktop-integration.sh`

Expected: FAIL because setup currently logs extension success without checking installation/enabling and does not reconcile all runtime firmware requests.

- [ ] **Step 3: Implement idempotent desktop and firmware handling**

Resolve each kernel-requested firmware basename to an existing `.xz` or plain file and place the chosen path in dracut. Only create an uncompressed compatibility copy using `xz -dc` when a controlled `modprobe` test proves the running kernel cannot load the compressed file. Set the GNOME percentage for the real user, install the extension, run `gnome-extensions enable battery-time@wifiteste`, and verify `gnome-extensions info` returns enabled after the next login; otherwise report reboot/login pending rather than success.

- [ ] **Step 4: Verify GREEN**

Run:

```bash
bash tests/test-hardware-desktop-integration.sh
bash -n setup-vivobook.sh install-battery-time-ext.sh
```

Expected: all checks pass.

- [ ] **Step 5: Commit**

```bash
git add setup-vivobook.sh install-battery-time-ext.sh tests/test-hardware-desktop-integration.sh
git commit -m "fix: restore firmware and battery desktop integration"
```

### Task 6: Safe stable-hardware recovery runner

**Files:**
- Create: `tools/recover-stable-hardware.sh`
- Create: `tests/test-stable-hardware-recovery.sh`
- Modify: `README.md`

**Interfaces:**
- Consumes: Tasks 1–5, existing camera/color/Vulkan/sync-render assets, and root privileges.
- Produces: one idempotent recovery command, dated backup manifest, candidate initramfs verification, and an explicit reboot checkpoint.

- [ ] **Step 1: Write the failing safety test**

Require the runner to use `set -euo pipefail`, verify model/kernel, call the pre-reboot audit, back up overwritten files, install only named packages, exclude IR/USB4/suspend enablement, build all core modules, run `depmod`, generate a candidate initramfs, inspect it, atomically install it, and stop with a clear error on any failed prerequisite.

- [ ] **Step 2: Run the test and verify RED**

Run: `bash tests/test-stable-hardware-recovery.sh`

Expected: FAIL with `stable hardware recovery runner missing`.

- [ ] **Step 3: Implement the runner**

Compose the tested helpers rather than duplicating setup logic. Use `/var/lib/vivobook-recovery/2026-08-20/manifest.txt`, `dnf install -y` only for exact missing build/runtime dependencies, and `dracut --force --kver "$kernel" "$candidate"`. Validate with `lsinitrd`, then install the image with mode `0600`. Ensure suspend/hibernate targets stay masked and do not load camera RGB or color-control modules during installation.

- [ ] **Step 4: Verify GREEN and all repository tests**

Run:

```bash
bash tests/test-stable-hardware-recovery.sh
bash -n tools/recover-stable-hardware.sh tools/audit-stable-hardware.sh setup-vivobook.sh
for test in tests/test-*.sh; do bash "$test"; done
if command -v pwsh >/dev/null; then for test in tests/Test-*.ps1; do pwsh -NoProfile -File "$test"; done; fi
git diff --check
```

Expected: every command exits 0.

- [ ] **Step 5: Commit**

```bash
git add tools/recover-stable-hardware.sh tests/test-stable-hardware-recovery.sh README.md
git commit -m "feat: add safe stable hardware recovery workflow"
```

### Task 7: Apply recovery and verify the pre-reboot checkpoint

**Files:**
- Modify system state only under the paths declared by the recovery runner.
- Record: `/var/lib/vivobook-recovery/2026-08-20/manifest.txt`

**Interfaces:**
- Consumes: verified repository state from Task 6.
- Produces: installed modules/configuration and a verified initramfs ready for reboot.

- [ ] **Step 1: Capture fresh baseline evidence**

Run: `bash tools/audit-stable-hardware.sh --pre-reboot | tee /tmp/x1407qa-before-apply.txt`

- [ ] **Step 2: Execute the recovery**

Run: `sudo -n bash tools/recover-stable-hardware.sh`

Expected: exit 0 with an explicit `READY FOR REBOOT` line; no general package update occurs.

- [ ] **Step 3: Verify installed artifacts before reboot**

Run:

```bash
sudo depmod -a "$(uname -r)"
for m in wcn_regulator_fix vivobook_kbd_fix vivobook_bl_fix vivobook_hotkey_fix; do modinfo -n "$m"; done
sudo lsinitrd /boot/initramfs-$(uname -r).img | rg 'qcom_q6v5_(pas|adsp)|qcom_glink_smem|qcadsp8380|qccdsp8380|wcn_regulator_fix'
systemctl is-enabled suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target
```

Expected: all modules resolve to the current kernel, required early-boot files appear, and every sleep target reports `masked`.

- [ ] **Step 4: Stop for the reboot boundary**

Tell the user that the machine must reboot. Do not run `sudo reboot` without an immediate warning because it terminates the active session.

### Task 8: Post-reboot acceptance and documentation

**Files:**
- Create: `docs/research/2026-08-20-hardware-recovery-results.md`
- Modify only if evidence demands it: `tools/audit-stable-hardware.sh`

**Interfaces:**
- Consumes: the first boot after Task 7.
- Produces: complete acceptance evidence and an exact list of any remaining upstream/physical limitations.

- [ ] **Step 1: Run the full post-reboot audit**

Run:

```bash
bash tools/audit-stable-hardware.sh --post-reboot | tee /tmp/x1407qa-after.txt
sudo journalctl -b -k --no-pager | rg -i 'wcn_regulator_fix|ath11k|remoteproc|adsp|cdsp|battmgr|firmware.*failed|error|fail'
```

Expected: stable components pass, Wi-Fi has no MHI timeout, ADSP/CDSP are running, and battery values are readable.

- [ ] **Step 2: Run functional checks**

Run NetworkManager Wi-Fi discovery, UPower percentage comparison with sysfs, hardware rendering inspection, Bluetooth controller inspection, PipeWire sink/source listing, cpufreq governor/range reads, backlight reads, input device enumeration, charge-threshold read, GNOME extension status, camera RGB enumeration through its on-demand command followed by stop, and color-control interface inspection. Do not suspend the machine or alter GPIO5.

- [ ] **Step 3: Run the complete repository test suite**

Run:

```bash
for test in tests/test-*.sh; do bash "$test"; done
if command -v pwsh >/dev/null; then for test in tests/Test-*.ps1; do pwsh -NoProfile -File "$test"; done; fi
git diff --check
```

Expected: zero failures.

- [ ] **Step 4: Write the evidence report**

Document before/after results for every acceptance criterion, kernel and package versions, installed module paths, initramfs evidence, relevant journal excerpts, backups, and the intentionally excluded IR camera, USB4/TB3, and suspend.

- [ ] **Step 5: Commit**

```bash
git add docs/research/2026-08-20-hardware-recovery-results.md
git commit -m "docs: record hardware recovery verification"
```
