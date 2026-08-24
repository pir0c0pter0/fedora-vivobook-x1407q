# Wi-Fi MHI -110 root cause and validated firmware fix (2026-08-21)

Continuation of `docs/research/2026-08-21-hardware-recovery-handoff.md`. Research
performed on the desktop (repo + Windows DriverStore dump + online sources +
independent Codex review), followed by controlled cold-boot tests on the
laptop.

## Validated result on the laptop

The root cause is confirmed: the Windows driver package contains two AMSS
images with the same visible WOS build string, but only `wlanfw20.mbn` is the
working hw2.1 runtime variant on this machine.

| Candidate installed as `amss.bin` | SHA-256 | Cold-boot result |
|---|---|---|
| Windows `wlanfw.mbn` | `27f3d81bc3715192cfc303d527112be0ae73152f367987470e887e166acb4679` | Silent full MHI timeout before SBL/Mission, then `-110` |
| Stock linux-firmware `SILICONZ_LITE` | `e12b23ddc4b8d2d2a10a651a5d6fdcd00f60fcae884d2cf5dad17627211fcdfd` | Reached Mission mode and reported `chip_id`, then entered `MHI_CB_EE_RDDM` during the board-data phase |
| Windows `wlanfw20.mbn` | `00756e19aee2b5e6725f5029b7e6abea748caca0f53af5a7662cd32086dde4bd` | Reached Mission mode, completed QMI initialization and created `wlP4p1s0` |

The successful boot (`4e9f7cb9-5017-4c68-ac3d-7268a3d1b223`) used Linux
`7.2.0-x1407qa`. MHI printed its wait marker at 8.600 s, the firmware reported
`WLAN.HSP.1.1.c5-00424-...SILICONZ_WOS-1` at 9.253 s, and the interface was
renamed to `wlP4p1s0` at 9.576 s. NetworkManager scanned visible 2.4/5 GHz
networks and connected to Wi-Fi. Two regulatory-setting warnings returned
`-22`, but they did not prevent interface creation, scanning or association.

The other files remained fixed across the AMSS tests and match the same
DriverStore package:

- `board.bin`: exact `bdwlan_wcn685x_2p1_nfa765a_AS_SA_X14QA.elf`, SHA-256
  `aea74372b997b7b55c76c786b02f4670922489353923ef7d4a48dc83780f2c86`;
- `m3.bin`: SHA-256
  `9be43a8d9dc9454a629d65368df7ccd532d8768a0ac1fd935f57bcd37cbefecd`
  (`m320.bin` in the package is byte-identical);
- `regdb.bin`: SHA-256
  `f3930af4bb8d2e23737a1ba4c68fa297652fd9e256851245f72d0bc660074936`.

Final validation: `tools/audit-stable-hardware.sh --post-reboot` passed all
16 hardware checks, and all 18 Linux shell tests passed. The validated
proprietary set is bundled under `firmware/ath11k/WCN6855/hw2.1/` so future
installs cannot silently restore the wrong AMSS variant.

## Correction to the handoff's stage model

The handoff states the failure is "before ath11k firmware/board-data loading"
and therefore rules firmware out. That is true for `board.bin`, `m3.bin` and
`regdb.bin` (all consumed post-Mission via QMI — verified in
`ath11k/qmi.c:2369/2413/2511/2614/2991-3012`), but **not for `amss.bin`**:

- `ath11k` registers MHI with `fbc_download=true`, `sbl_size=512K`,
  `fw_image=amss.bin`, `timeout_ms=20000` (`ath11k/mhi.c`).
- During `mhi_async_power_up`, the PBL-transition worker runs
  `mhi_fw_load_handler` (`mhi/host/boot.c:474`): `request_firmware(amss.bin)`,
  then pushes the **first 512 KiB of amss.bin via BHI while the device is in
  PBL**, then prints "Wait for device to enter SBL or Mission mode" and waits
  for an execution-environment change event.
- So the observed last line sits **exactly after the host handed amss.bin's SBL
  prefix to the device PBL**. The 21.3 s is ath11k's own 20 s host timeout,
  not device behavior.

Failure-signature table (source-verified):

| Cause | Log signature |
|---|---|
| amss.bin missing | explicit "Error loading firmware: -2", fast -110 |
| BHI transfer rejected | "Image transfer failed" + BHI error regs, fast -110 |
| Image delivered, device never runs it / host never sees EE event | **silent full 20 s wait, then -110 — the observed signature** |

## The untested variable: amss.bin provenance

Every Linux 7.2 test boot (stable, pwrctrl-diag, delay-diag) shared the same
rootfs firmware. Kernel-side variables were varied exhaustively and falsified;
firmware provenance was never varied.

Evidence chain (verified locally on the desktop):

1. The 6.19 system that had working Wi-Fi used the **stock linux-firmware
   `amss.bin`** (`WLAN.HSP.1.1-03125-…SILICONZ_LITE-3.6510.41`,
   sha256 `e12b23ddc4b8d2d2a10a651a5d6fcd…` on fc44 linux-firmware 20260410)
   plus only the custom Windows `board.bin`. Committed docs reference the
   `hw2.1` directory exclusively for board data.
2. The current system was installed from the locally built personal-maximal
   ISO, whose `install_x1407qa_firmware()` installs
   `qcwlanhsp8380.inf_arm64_417e5fdb5950602f/wlanfw.mbn` as `amss.bin`
   (sha256 `27f3d81bc3715192cfc303d527112be0ae73152f367987470e887e166acb4679`),
   plus Windows `m3.bin`, `regdb.bin`, and the bdwlan ELF as `board.bin`.
   This rename exists only in the local uncommitted script — it was never part
   of the 6.19 working configuration.
3. The same DriverStore directory also contains **`wlanfw20.mbn`**
   (sha256 `00756e19aee2b5e6725f5029b7e6abea748caca0f53af5a7662cd32086dde4bd`),
   same `WLAN.HSP.1.1.c5-00424-…SILICONZ_WOS-1` release, different content.
   The INF copies both files; its registry default is `wlanfw.mbn`. The
   Qualcomm Windows driver selects the fw file at runtime; which file Windows
   actually boots on hw2.1 silicon is not provable from the INF alone.
4. The proven-working Zenbook A14 recipe (same WCN6855 hw2.1 / QCNFA765, same
   platform family, native pwrseq+pwrctrl+ath11k stack) uses
   **`wlanfw20.mbn` as `amss.bin`** and reaches Mission mode
   (`fw_build_id WLAN.HSP.1.1.c5-00400-…SILICONZ_WOS-1`):
   https://github.com/alexVinarskis/linux-x1e80100-zenbook-a14 . His "does not
   work without newer firmware" failure log is a **post-Mission board-data
   fetch failure**, not an MHI -110 — no pre-SBL failure is documented on the
   A14 at all.

## Kernel-side findings (largely exonerating the 6.19→7.2 delta)

- The build tarball sha256
  `f9fef3d14c0df53819026f4be74459835c2a0b0dcbf5b5bbd9ea19f0829402b3` matches
  the **official kernel.org linux-7.2.tar.xz** — so the build already contains
  `0fe8010fc5b1` ("wifi: ath11k: Flush the posted write after writing to
  PCIE_SOC_GLOBAL_RESET", merged v7.2-rc5), the only 2026 upstream fix in the
  ath11k power-up path. Presence check on the tree:
  `grep -c "Flush the posted write" drivers/net/wireless/ath/ath11k/pci.c` → 2.
- `pwrseq-qcom-wcn.c`: no behavioral WCN6855 change in the window.
- pci/pwrctrl rework (v7.0) is exactly the lifecycle already falsified by the
  PERST diagnostic. `PCI_PWRCTRL_SLOT`→`GENERIC` is a pure rename.
- MHI host: no change affecting ath11k's path.
- No post-7.2 "MHI power-up retry" fix exists for ath11k upstream.
- X1E DTS "move PERST/PHY to port nodes" migration broke only *mixed* trees;
  the borrowed old-binding DTB is a supported configuration, and the link
  trains + enumerates, which clears that class entirely.
- Relevant operational fact: with v7.0+ pwrctrl, an ath11k probe failure does
  **not** cut power, removal does not power off (`2d8c5098b847`), and the
  DTB's `regulator-always-on` additions keep rails up — so a wedged chip
  **survives warm reboots**. Only a full poweroff drops the rails.

## Ranked hypotheses

1. **amss.bin content (Windows `wlanfw.mbn`) not executed by hw2.1 PBL** —
   prime. Only changed input consumed at the failing stage; never tested with
   the kernel held constant; sibling machine proves the stack works with a
   known-good amss.bin.
2. **Host never observes the EE-change event** (MHI control-event ring / MSI
   delivery / interrupt routing on the borrowed DTB). Identical log signature;
   not excluded by any test so far. "32 MSI vectors allocated" proves
   allocation, not delivery. Becomes top hypothesis if the firmware swap
   changes nothing.
3. Linux 7.2 MHI PM/state-machine regression (lost transition) — lower; would
   usually leave other traces.
4. PCIe REFCLK/CLKREQ#/ASPM sideband issues in the WLAN domain — BT working
   does not clear this (BT is UART-side), but link training + enumeration make
   it less likely.
5. Kconfig deltas (`POWER_SEQUENCING` m→y) — indirect timing factor at most.

## Next step on the laptop — single-variable amss.bin swap

Rules: change **exactly one file** (`amss.bin`). Keep the Windows `board.bin`,
`m3.bin`, `regdb.bin` in place. No USB changes, no live PCI reset, no GPIO
toggling. Use **full poweroff**, not reboot (always-on rails preserve wedged
chip state across warm reboots).

```bash
# 0. Confirm current state (read-only)
sha256sum /usr/lib/firmware/ath11k/WCN6855/hw2.1/amss.bin
#   expected 27f3d81bc3715192... = Windows wlanfw.mbn
strings -a /usr/lib/firmware/ath11k/WCN6855/hw2.1/amss.bin | grep -m1 QC_IMAGE_VERSION
#   expected ...SILICONZ_WOS-1
ls -la /usr/lib/firmware/updates/ath11k/WCN6855/hw2.1/ 2>/dev/null   # must not exist (higher priority)
lsinitrd /boot/initramfs-7.2.0-x1407qa.img | grep -i ath11k          # expect empty (no baked-in copy)
ls -la /usr/lib/firmware/ath11k/WCN6855/hw2.0/                        # stock .xz set must be present

# 1. Backup and swap ONLY amss.bin to the stock linux-firmware image
sudo mkdir -p /root/wifi-fw-backup-2026-08-21
sudo cp -a /usr/lib/firmware/ath11k/WCN6855/hw2.1/amss.bin \
    /root/wifi-fw-backup-2026-08-21/amss.bin.windows-wlanfw
xz -dc /usr/lib/firmware/ath11k/WCN6855/hw2.0/amss.bin.xz | \
    sudo tee /usr/lib/firmware/ath11k/WCN6855/hw2.1/amss.bin >/dev/null
sha256sum /usr/lib/firmware/ath11k/WCN6855/hw2.1/amss.bin   # record it
strings -a /usr/lib/firmware/ath11k/WCN6855/hw2.1/amss.bin | grep -m1 QC_IMAGE_VERSION
#   expected ...SILICONZ_LITE... (stock build)

# 2. FULL poweroff (drops the always-on rails), wait ~30 s, power on
sudo poweroff

# 3. After boot
sudo dmesg | grep -iE 'mhi|ath11k' | head -40
```

Outcome interpretation:

- **Win condition:** log proceeds past "Wait for device to enter SBL or
  Mission mode" to `chip_id`/`fw_version`/QMI lines — even if board data fails
  later, the -110 stage is solved (board issues are a separate, post-Mission
  problem; the custom `board.bin` worked on 6.19).
- **Identical -110:** NOT yet a refutation — a single failing boot after one
  swap can be a false negative. The amss hypothesis may only be declared
  refuted when the **refutation checklist** below is fully satisfied. Until
  then, an identical -110 means "continue the checklist", not "promote
  hypothesis 2".
- **Explicit BHI error:** the test itself picked a wrong/corrupt file — fix
  the test, no new information about the original blob.
- **Candidate B — `wlanfw20.mbn` (`00756e19...`) as `amss.bin`:** Codex's
  preferred first swap: it keeps the whole WOS `WLAN.HSP.1.1.c5-00424` set
  matched (the installed `m3.bin`/`regdb.bin` are from the same release) and
  is the A14-proven end-to-end recipe shape. Candidate A (stock) needs zero
  file transfer (the `.xz` is already on the laptop); candidate B must be
  extracted **on the laptop** from its own Windows partition or local
  DriverStore dump (`qcwlanhsp8380.inf_arm64_*/wlanfw20.mbn`). Either candidate
  discriminates the pre-SBL boundary; run one, and only move to the other if
  the first fails informatively.

### Refutation checklist — ALL required before discarding the amss hypothesis

1. **Effective file verified after the failed boot, not just before:**
   `sha256sum /usr/lib/firmware/ath11k/WCN6855/hw2.1/amss.bin` matches the
   candidate; `/usr/lib/firmware/updates/ath11k/` absent;
   `lsinitrd /boot/initramfs-7.2.0-x1407qa.img | grep -i ath11k` empty (no
   shadow copy served before switch-root); no `FIRMWARE_PATH` overrides in
   `/etc/` or kernel cmdline. If any of these fail, the boot did not test the
   candidate — fix and repeat.
2. **Clean power boundary, twice:** at least **two consecutive** full
   poweroff→cold-boot cycles per candidate, with ≥30 s powered off. The first
   boot after many failed attempts may inherit wedged endpoint/PBL state if
   the EC holds auxiliary power; `regulator-always-on` is Linux policy but the
   power-off boundary on this hardware is unproven. One failing boot proves
   nothing.
3. **BOTH candidates tested:** `wlanfw20.mbn` (`00756e19...`) AND stock
   linux-firmware (`SILICONZ_LITE` build). They are different builds; failure
   of one does not refute the other — the A14 proof is specifically about
   `wlanfw20.mbn`, and the 6.19 history is specifically about stock.
4. **No explicit BHI/firmware error in the failing log:** an explicit
   "Error loading firmware" / "Image transfer failed" means the test itself
   picked the wrong file or a corrupt copy — a test bug, not a refutation.

Only with 1–4 satisfied and the -110 unchanged does hypothesis 2 (MHI
event/MSI delivery) take the lead. Then instrument:
`/proc/interrupts | grep -i mhi` during the 20 s window (zero counts =
interrupt-delivery problem), scan dmesg for SMMU faults, read BHI_EXECENV at
timeout, and run the deferred-bind test (blacklist `ath11k_pci`, boot,
`modprobe ath11k_pci` after 60 s) to replicate 6.19's late-rescan condition.

The source fix is now the repository firmware bundle: `setup-vivobook.sh`
stages `firmware/ath11k/WCN6855/hw2.1/`, where `amss.bin` is the validated
`wlanfw20.mbn` and the other three files are the matching X1407QA set.

Per the handoff's completion condition: after Wi-Fi passes, rerun
`tools/audit-stable-hardware.sh --post-reboot` (expect every check to pass)
and the full repository test suite before committing a final fix.

## Independent review (Codex, GPT-5.2, two rounds)

Codex audited the evidence chain and converged: "this is no longer a
Windows-versus-linux-firmware theory — it is a specific variant-selection
error." Final ranking: (1) wrong AMSS silicon variant (`wlanfw.mbn` installed
where hw2.1 silicon needs the `wlanfw20.mbn`-class image) — overwhelmingly
first; (2) MHI event/MSI delivery failure — distant fallback, only pursued if
the swap fails with the effective-file hash verified; the Kconfig/pwrctrl
hypotheses are "no longer serious competitors".

Precision notes it insisted on (adopted here): the observed log proves only
that the initial BHI DMA handshake succeeded — not that the SBL prefix
executed; the 20 s figure is ath11k's host watchdog, not device timing; an
explicit PBL rejection would have logged BHI error codes, so the surviving
mechanism is "validly-signed image accepted by DMA but not executed on this
silicon revision"; the Windows INF's registry default for this device is
`wlanfw.mbn`, so the original file choice was not arbitrary — the runtime
driver, not the INF, selects the v2-silicon image; and MSI vector allocation
is not proof of event delivery. It endorsed full poweroff over warm reboot
(`regulator-always-on` is Linux policy, not a hardware strap — a warm reboot
can preserve wedged PBL/endpoint state).

## Sources

- MHI boot flow: `drivers/bus/mhi/host/boot.c` (fw_load_handler:474,
  BHI:258-303, "Wait for device":600), `pm.c` (SBL→BHIe:823-834,
  sync_power_up:1277-1293), `ath11k/mhi.c` (config:382-384, timeout, -110:448),
  `ath11k/qmi.c` (BDF/M3 post-Mission).
- Zenbook A14 recipe + logs: https://github.com/alexVinarskis/linux-x1e80100-zenbook-a14
- ath11k reset fix: https://github.com/torvalds/linux/commit/0fe8010fc5b1
- pwrctrl rework: https://github.com/torvalds/linux/commit/b921aa3f8dec ;
  removal keeps power: `2d8c5098b847`
- linux-firmware WHENCE (hw2.1→hw2.0 symlinks, build IDs):
  https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/WHENCE
- ath11k firmware installation:
  https://wireless.docs.kernel.org/en/latest/en/users/drivers/ath11k/installation.html
- -110 case law: Debian #1026028/#1032140 (missing amss, fast -2+-110),
  Ubuntu LP#1930637 (host MHI regression stranding device pre-SBL),
  MHI 20 s timeout patch: https://lkml.iu.edu/hypermail/linux/kernel/2304.1/04692.html
