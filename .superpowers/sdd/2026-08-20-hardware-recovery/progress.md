# SDD ledger — plan: docs/superpowers/plans/2026-08-20-hardware-recovery.md

Worktree: `/home/mariostjr/repositorios/fedora-vivobook-x1407q/.worktrees/hardware-recovery`
Branch: `hardware-recovery`
Baseline: `1826188`
Spec: `docs/superpowers/specs/2026-08-20-hardware-recovery-design.md`

## Pre-flight dependency scan

| Tasks | Producer → consumer/shared surface | Finding / ruling |
|---|---|---|
| 1 → 7 | audit CLI supplies pre-apply baseline | Clean; Task 7 uses the exact CLI modes from Task 1. |
| 1 → 8 | audit CLI supplies final acceptance | Clean; post-reboot changes to audit are evidence-driven only. |
| 2 ↔ 3 | both modify `setup-vivobook.sh` | Sequential; Task 3 must preserve Task 2's remoteproc block. |
| 2 ↔ 4 | both modify `setup-vivobook.sh` | Sequential; core DKMS preflight must run before final dracut. |
| 2 ↔ 5 | both modify firmware/setup behavior | Ruling: consolidate dracut configuration without dropping any Task 2 blobs; spec makes early boot authoritative. Cost if wrong: ADSP/CDSP stay deferred. |
| 3 ↔ 4 | Wi-Fi package is one of four core DKMS packages | Clean; Task 4 consumes the Task 3 repository module and must not overwrite its source from `/usr/src`. |
| 3 → 7 | installed Wi-Fi module needs reboot validation | Clean; no live unload/reload is required before reboot. |
| 4 → 6 | core packages/setup consumed by recovery runner | Clean; runner composes setup helpers and stops on build failure. |
| 5 → 6 | desktop/firmware helpers consumed by runner | Clean; real-user resolution remains `SUDO_USER`. |
| 1–5 → 6 | runner composes earlier deliverables | Ruling: no duplicated implementation blocks; call focused helpers where available. Cost if wrong: installer drift. |
| 6 → 7 | recovery runner mutates live system | Clean; exact command and pre-reboot gate specified. |
| 7 → 8 | prepared initramfs requires reboot | Clean; hard human-visible reboot boundary remains. |
| 1 | test names, CLI, outputs, files | Internally consistent; Bash tests replace unavailable PowerShell runtime. |
| 2 | test tokens match dracut implementation | Internally consistent. |
| 3 | DT node/supply contract matches source requirements | Internally consistent; runtime hypothesis still requires post-reboot proof. |
| 4 | sources, build-tree repair, DKMS output | Ruling: use verified Linux 7.2 source because custom build link is broken and no matching Fedora kernel-devel package exists. Cost if wrong: external module build stops safely. |
| 5 | firmware/UI test and implementation | Internally consistent; compressed compatibility copy is conditional on evidence. |
| 6 | runner safety test and implementation | Internally consistent; no global package update. |
| 7 | application steps and expected artifacts | Internally consistent; stop before reboot. |
| 8 | acceptance, report, commit | Internally consistent; IR/USB4/suspend remain excluded. |

Baseline verification: `git diff --check` passed; Bash syntax check returned no reported errors. PowerShell tests are not applicable at baseline because `pwsh` is absent.

Task 1 fix round 1: reviewer found incomplete lid safety (`sleep.target`, effective external/docked policies), journal read failures treated as clean, and a minor render-node readability check.

Task 1: complete — commits `a40bcaa`, `ca7075a`; re-review Approved with no remaining findings.

Task 2 fix round 1: reviewer found `vivobook-update.sh` still validating retired ADSP/CDSP dracut files instead of `qcom-remoteproc.conf`; minor test coverage gap also accepted for correction.

Task 2: complete — commits `944f1ab`, `d9632e6`; re-review Approved with no findings.

Ruling Task 3: do not modify `setup-vivobook.sh` merely to satisfy its Files list — `stage_bundled` already discovers `modules/*`; Task 4 owns persistent staging/install behavior. Cost if wrong: reviewer may require a concrete integration hunk, but a no-op comment would be worse and spec does not require it here.

Task 3: complete — commit `9c6d32f`; review Approved. Parked for Task 4: compilation/vermagic is blocking before persistence; extend the supply contract test to cover all ten current names and reject obsolete names.

Ruling Task 4: authorize exact additional build dependencies `flex bison` because the verified upstream tarball contains lexer/parser sources, not generated C. No general update. Audit the prior DNF transaction and stop if kernel, Mesa, linux-firmware, GNOME Shell, GTK4, ALSA UCM, systemd, or GRUB changed. Cost if wrong: dependency transaction may have touched a sensitive package; transaction evidence is mandatory.

Ruling Task 4 clarification: installs of `kernel-srpm-macros` and `kernel-headers` are accepted build dependencies, not a running `kernel-core`/`kernel-modules` update. Continue only if no sensitive runtime package was upgraded/replaced. Cost if wrong: header packages could influence future builds, but cannot replace the booted custom image.

Ruling Task 4 Module.symvers: choose full `make -j8 modules` in the checksum-pinned prepared tree to generate exact symbols; reject `KBUILD_MODPOST_WARN=1`. Do not install/load kernel modules. Cost if wrong: substantial build time/disk use, but no boot state mutation.

Ruling Task 4 vmlinux prerequisite: after `modules` proved `vmlinux.o` is required by modpost for this config, authorize `make -j8 vmlinux` then `make -j8 modules` in the same isolated tree. Still no install/load or `/boot`/dracut mutation. Cost if wrong: additional build time/disk only.

Task 4 fix round 1: review Needs fixes. Critical: raw DKMS autoinstall escapes namespace; direct dracut overwrites active initramfs; vermagic is not pre-install gate. Important: stale build-tree acceptance, incomplete provenance, symlink/ordering hazards, weak tests. Ruling: fix all Critical/Important now because setup main was modified and remains an executable full installer; Task 6 will compose these safe primitives rather than introduce them later.

Task 4 fix round 2: re-review found clean-baseline ordering bug (`preflight_dkms_namespace` before DKMS dependency), weak path type checks, post-promotion sync semantics, backup overwritten on second success, and redundant depmod.

Task 4 fix round 3: sole remaining Important finding — unique depmod precedes later camera DKMS install; move it after all installs and before candidate initramfs.

Task 4: complete — commits `db6d819`, `b50127e`, `bf4f315`, `f967827`; final re-review Approved. Material incident retained: first pre-freeze DKMS install rewrote only old `/boot/initramfs-6.19.10-300.fc44.aarch64.img`; current 7.2 image remained intact and both images passed `lsinitrd`. WCN DKMS registration remains installed; `/var/tmp/dracut.dRkFu6m` remains for later controlled cleanup decision.

Task 5 fix round 1: review Needs fixes. Critical: GNOME commands lack real XDG/DBus session and no post-login activation mechanism; candidate initramfs validates only four remoteproc blobs. Important: hard desktop failures still permit 16/16 success and tests are mostly textual.

Task 5 fix round 2: re-review found user bus socket can exist without active `org.gnome.Shell`; must classify absent Shell owner as pending-login and test it. Minor runtime ownership validation accepted.

Task 5: complete — commits `4779c17`, `9d43621`, `b6b917e`; final re-review Approved with no findings.

Task 6 fix round 1: review Needs fixes. Critical: config writers follow symlinks. Important: missing Fedora 44 gate, audit infra errors indistinguishable from hardware baseline, missing `bc`, incomplete recovery manifest/DKMS+depmod coverage, weak manifest validation, no installed vermagic final gate, weak tests. Minor actual-tab format and concurrency lock accepted.

Task 6 fix round 2: re-review found Fedora canonical `/etc/os-release` symlink rejection; mutable DKMS/module roots lack no-follow gates; no space reservation; archive restore overlays instead of exact round-trip; archive durability/manifest semantic/find-error/test gaps; temp glob mismatch.

Task 6 fix round 3: re-review found usrmerge `/lib` rejection; restore removes BACKUP/SYMLINK before replacement and may erase mountpoints; space checked only on recovery FS; restore lacks staged capacity/rollback; managed-path manifest completeness/test gaps; explicit restore error propagation.

Task 6 fix round 4: implementation commit `19a5c44` reports transactional staged restore, reverse rollback, mount gates, grouped filesystem capacity checks, canonical `/usr/lib/modules` handling, exact manifest validation, and 13/13 Bash tests passing. Independent re-review remains pending before Task 6 is marked complete.

Urgent live-power checkpoint (2026-08-20): user prioritized Wi-Fi, battery percentage, and CPU power states while running on battery. Diagnostics found SCMI `schedutil` on both CPU policies, but sustained high load with GNOME Shell/terminal CPU use and Mesa `llvmpipe`; kernel logs showed missing uncompressed `qcom/gen71500_sqe.fw` because the custom kernel has `CONFIG_FW_LOADER_COMPRESS` disabled. Verified `.xz` firmware was decompressed atomically to `/usr/lib/firmware/qcom/gen71500_sqe.fw` and `gen71500_gmu.bin`. ADSP/CDSP remoteprocs started after live module loading. A live `qcom_battmgr` reload temporarily exposed a discharging battery and UPower calculated approximately 43.7%, but the power-supply device later disappeared again, so live reload is not accepted as stable. GNOME `show-battery-percentage` is enabled for the active user session. Both CPU policies were temporarily capped; the kernel-selected maximum is 1,670,400 kHz, reversible by restoring 2,956,800 kHz or by rebooting.

Pre-reboot checkpoint: repository helpers wrote `/etc/dracut.conf.d/qcom-remoteproc.conf`, `/etc/dracut.conf.d/qcom-gpu-firmware.conf`, and `/etc/dracut.conf.d/vivobook-core.conf`, then built and atomically promoted `/boot/initramfs-7.2.0-x1407qa.img`. The prior image is preserved at `/boot/initramfs-7.2.0-x1407qa.img.vivobook-backup`. `lsinitrd` passed and confirmed WCN, Vivobook keyboard/backlight/hotkey modules, QCOM remoteproc/glink modules, all key ADSP/CDSP blobs, and both plain GPU firmware files. Current session remains wired-only and `llvmpipe`; Wi-Fi, persistent battery enumeration, and GPU acceleration require the explicitly warned post-save reboot boundary. No reboot has been performed yet.
