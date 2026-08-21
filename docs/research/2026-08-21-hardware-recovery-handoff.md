# Hardware recovery handoff — 2026-08-21

This is the authoritative continuation note for the stable-hardware recovery
work on the ASUS Vivobook X1407QA. Read it together with:

- `docs/superpowers/plans/2026-08-20-hardware-recovery.md`
- `docs/superpowers/specs/2026-08-20-hardware-recovery-design.md`
- `docs/BUILD-REPORT-2026-08-19.md`

## Repository state

- Repository: `/home/mariostjr/repositorios/fedora-vivobook-x1407q`
- Worktree: `/home/mariostjr/repositorios/fedora-vivobook-x1407q/.worktrees/hardware-recovery`
- Branch: `hardware-recovery`
- Baseline commit before the WCN6855-delay candidate: `05b12f5 fix: preserve USB tethering in kernel diagnostics`
- WCN6855-delay candidate implementation: `f6f4427 feat: add WCN6855 delay diagnostic`
- Earlier checkpoint: `5945ee9 docs: checkpoint live hardware recovery`
- Tasks 1 through 6 of the recovery plan have been implemented and committed.
- The repository worktree was clean before this handoff was written.

Do not continue this work on `main`. Continue in the worktree above.

## Safety boundary

- USB ports and USB tethering are survival infrastructure for this recovery.
  Never change, reset, unload, rebind or experimentally configure USB,
  Type-C, UCSI or USB networking on the live laptop while investigating Wi-Fi.
- Every experimental kernel must inherit `/boot/config-7.2.0-x1407qa` and pass
  `kernel/verify-linux-usb-config-preservation.sh`. In particular,
  `CONFIG_USB_NET_RNDIS_HOST=m` and the `rndis_host.ko` artifact are mandatory.
  A candidate with any USB/Type-C config drift must not be installed or booted.
  The trusted reference SHA-256 is
  `35763b73052b88433a942b93555a1ce931d81abc67f9e465821c10683ac26199`;
  a transferred or overridden reference must match it exactly.
- Do not enable or test the IR camera.
- Do not enable or test USB4/TB3.
- Do not enable suspend or hibernate.
- Never set GPIO5 `DIG_OUT_SOURCE_CTL` to `0x00` and never force GPIO5 low;
  GPIO5 controls the display backlight path.
- Do not toggle the WCN WLAN GPIO low after PCI enumeration and do not issue a
  live PCI reset. The upstream Qualcomm power-sequencing driver warns that the
  PCI controller cannot safely handle link-down after enumeration.
- Keep the Linux 7.2 entry bootable while testing alternatives.

## Stable hardware result

The post-reboot audit currently reports 15 of 16 required components passing.
The only failure is Wi-Fi.

Passing components:

- battery reporting, UPower, GNOME percentage and battery-time extension
- ADSP and CDSP remote processors
- GPU/render node and required firmware
- Bluetooth controller
- built-in keyboard and touchpad
- backlight and Fn hotkeys
- audio
- SCMI CPU frequency scaling
- 80% charge limit
- RGB camera module availability (on demand, not loaded continuously)
- display saturation/contrast controls
- safe lid policy with suspend and hibernate targets masked

Current audit command:

```bash
cd /home/mariostjr/repositorios/fedora-vivobook-x1407q/.worktrees/hardware-recovery
bash tools/audit-stable-hardware.sh --post-reboot
```

Expected current result: 15 `PASS` lines and one Wi-Fi `FAIL` because WCN6855
is not bound to `ath11k_pci` after probe failure.

## Relevant installed system state

Current normal boot:

```text
kernel: 7.2.0-x1407qa
saved GRUB entry: x1407qa-7.2.0-x1407qa
kernel argument: rd.driver.pre=pwrseq_qcom_wcn
legacy wcn_regulator_fix: DKMS version 1.0 installed; not loaded and omitted from the current initramfs
```

### Installed legacy DKMS package

The installed package is `wcn-regulator-fix/1.0` for AArch64. Its source is
`/usr/src/wcn-regulator-fix-1.0`, whose `dkms.conf` declares
`PACKAGE_VERSION="1.0"`. A fresh `dkms status wcn-regulator-fix/1.0` and
`modinfo -k <release> wcn_regulator_fix` check found these installed artifacts:

| Kernel release | Installed module SHA-256 | Vermagic matches release |
|---|---|---|
| `7.2.0-x1407qa` | `27f7ab8cea440d4d52f88ec4020d7a1109d6596a5e6e9b748d23a5971c7802ee` | yes |
| `7.2.0-x1407qa-wifi-pwrctrl-diag` | `2fd539f834a8f7556e4ba1f34166d1b1ab210cd6f93b61ea660816fbfc1b5b0f` | yes |
| `7.2.0-x1407qa-wifi-wcn6855-delay-diag` | `7a6c6df3aac976da2ca2854036d5337bee8bb85a4deebe51209ab1c024a13831` | yes |

For the running kernel, the artifact resolves to
`/lib/modules/7.2.0-x1407qa/extra/wcn_regulator_fix.ko`. `lsmod` confirms that
it is not loaded, and the installed initramfs for all three releases does not
contain it. The normal boot uses `pwrseq_qcom_wcn`. Installed therefore means
the legacy module is available on disk, not active in the current boot.

The three kernel releases have all been boot-tested, with these distinct
results:

| Kernel release | What the boot proved | Result |
|---|---|---|
| `7.2.0-x1407qa` | Native WCN sequencing, stable USB tethering and the approved hardware baseline | Current audit: 15 of 16 components pass; Wi-Fi alone fails because MHI never reaches SBL or Mission mode and returns `-110` |
| `7.2.0-x1407qa-wifi-pwrctrl-diag` | The PERST-before-WCN-power ordering change ran, trained Gen3 x1 and enumerated `17cb:1103` | Wi-Fi still failed at MHI with `-110`; this build also lost `CONFIG_USB_NET_RNDIS_HOST=m` and must not be reused |
| `7.2.0-x1407qa-wifi-wcn6855-delay-diag` | The 6000 ms WCN6855 delay marker ran; PCIe enumeration and USB tethering succeeded | Wi-Fi still failed at the same MHI boundary with `-110`; audit reported 14 passes because the optional RGB camera module was unavailable and intentionally not tested |

Repository validation was repeated on the stable `7.2.0-x1407qa` boot after
returning from the diagnostic kernel:

- all 17 Linux shell tests passed, including the WCN supply contract, DKMS
  namespace preflight, core-module build and matching vermagic checks;
- all 50 tracked shell scripts passed `bash -n` syntax validation;
- the live post-reboot hardware audit reported 15 passes and one Wi-Fi failure;
- the nine Windows PowerShell tests were not executed on this Fedora system
  because `pwsh` is not installed.

These results validate the installed package, build contracts and tested boot
boundaries. They do not claim that `wcn_regulator_fix` fixed Wi-Fi on Linux 7.2.

The installed custom DTB is:

```text
/boot/dtb-x1407qa/qcom/x1p42100-asus-zenbook-a14.dtb
SHA-256: 95f7bb2840c7ce831661056c116f8cd9b692cd94b035f8cdde775cc4a976d90a
```

It is byte-identical to the repository Wi-Fi-fixed DTB and adds
`regulator-always-on` to the three fixed WCN rails. The active DT was already
verified to use this image, so loading the wrong DTB is not the current cause.

Current system configuration intentionally uses native WCN sequencing:

- `/etc/modules-load.d/30-wcn-regulator.conf`: `pwrseq_qcom_wcn`
- `/etc/modules-load.d/vivobook-core.conf`: keyboard, backlight, hotkey and
  color modules
- `/etc/dracut.conf.d/omit-legacy-wcn.conf`: omits `wcn_regulator_fix`
- `/etc/dracut.conf.d/90-x1407qa-hardware.conf`: forces native pwrseq and the
  required core modules
- `/boot/initramfs-7.2.0-x1407qa.img.before-native-wcn`: pre-experiment backup
- `/etc/dracut.conf.d/90-x1407qa-hardware.conf.before-native-wcn`: config backup

The native-only candidate and installed initramfs were inspected before boot:
required stable-hardware modules and firmware were present and the legacy WCN
module was absent.

## Wi-Fi failure — exact boundary

Hardware identity:

```text
endpoint: 0004:01:00.0
PCI ID: 17cb:1103
subsystem: 105b:e130
device: Qualcomm WCN6855 hw2.1 / QCNFA765
```

On every completed Linux 7.2 test boot:

1. Native `pwrseq_qcom_wcn` binds to the WCN PMU.
2. All required regulator consumer links exist and the rails are enabled.
3. BT-enable GPIO 116 and WLAN-enable GPIO 117 are high.
4. The PCIe controller establishes a Gen3 x1 link.
5. Endpoint `17cb:1103` enumerates correctly.
6. `ath11k_pci` enables the endpoint, assigns BAR0 and 32 MSI vectors.
7. MHI reports `Power on setup success`.
8. The endpoint never enters SBL or Mission mode.
9. About 21 seconds later, `ath11k_pci` fails with `-110`.

Representative Linux 7.2 timeline from boot
`8eb67bee-fdb6-4c8f-aed4-72ec130286f2`:

```text
8.016  qcom-pcie: PCIe Gen.3 x1 link up
8.019  pci 0004:01:00.0: [17cb:1103]
8.124  ath11k_pci: enabling device
8.128  ath11k_pci: wcn6855 hw2.1
8.284  mhi mhi0: Requested to power ON
8.284  mhi mhi0: Power on setup success
8.376  mhi mhi0: Wait for device to enter SBL or Mission mode
29.670 ath11k_pci: failed to power up mhi: -110
```

This locates the failure after rail enable, WLAN GPIO assertion, PCIe link
training and enumeration, but before ath11k firmware/board-data loading.
Consequently `board.bin`, calibration variant and NetworkManager cannot explain
this timeout stage.

Bluetooth remains functional even though the journal contains failed optional
lookups for `qca/wcnhpbtfw21.tlv` and `qca/hpbtfw21.tlv`. Those messages are not
the current Wi-Fi failure.

## Hypotheses already tested or ruled out

### Cold-boot residual state

Multiple cold/reboot cycles produced the same MHI timeout. Not supported.

### Legacy regulator module conflicts with native pwrseq

The system was changed from early-loading both `wcn_regulator_fix` and
`pwrseq_qcom_wcn` to native pwrseq only. After reboot, the legacy module was
absent, but the exact same MHI timeout occurred. Not supported.

### Wrong DTB or missing `regulator-always-on`

The installed boot DTB hash matches the repository fixed DTB. Runtime rails,
GPIOs, PCIe link and endpoint enumeration also pass. Not supported.

### Missing board data

The failure is before the driver requests ath11k firmware or board data. Board
data may matter later, but cannot cause this specific MHI transition timeout.

### Incorrect calibration variant

The inherited Zenbook node uses `qcom,calibration-variant = "UX3407Q"`. Like
board data, this is consumed after the failing MHI stage and is not the current
root cause.

## Falsified lead: PERST# before WCN power-on

A source comparison between upstream Linux 6.19 and 7.2 found a relevant
architectural change in `drivers/pci/pwrctrl/pci-pwrctrl-pwrseq.c`:

- Linux 6.19 calls `pwrseq_power_on()` directly during the pwrctrl probe and
  registers a managed power-off action.
- Linux 7.2 instead registers `power_on` and `power_off` callbacks on
  `struct pci_pwrctrl`; the PCI controller owns when they are invoked.

The WCN6855-specific sequence in `pwrseq-qcom-wcn.c` is otherwise materially
the same. Linux 7.2 adds support for other WCN families, but does not obviously
change the WCN6855 target data.

This change matched the historical boundary: the repository documented Wi-Fi
working on Fedora Linux 6.19 with regulator holding and delayed enumeration,
while Linux 7.2 consistently reaches PCI enumeration but times out at MHI.

The controller-level ordering is the narrower observable difference. Linux 7.2
calls `pci_pwrctrl_power_on_devices()` in `qcom_pcie_host_init()` while PERST#
is still asserted, and deasserts PERST# only later. The earlier lifecycle
released PERST# before the WCN pwrseq consumer powered the endpoint and queued
a PCI rescan. The diagnostic changed only this ordering in a separately
versioned Linux 7.2 build. It did not fix the MHI timeout and is now falsified.

Kernel config difference worth retaining:

```text
6.19: CONFIG_POWER_SEQUENCING=m
7.2:  CONFIG_POWER_SEQUENCING=y
6.19: CONFIG_PCI_PWRCTRL_SLOT=y
7.2:  CONFIG_PCI_PWRCTRL_GENERIC=y
```

Both kernels enable `CONFIG_PCI_PWRCTRL`, `CONFIG_PCI_PWRCTRL_PWRSEQ`,
`CONFIG_POWER_SEQUENCING_QCOM_WCN`, `CONFIG_MHI_BUS` and `CONFIG_ATH11K_PCI`.

## Linux 7.2 diagnostic result and USB regression

Boot `1f2aab1e3b084d66b0ad8b0ea0073275` ran
`7.2.0-x1407qa-wifi-pwrctrl-diag`. The WCN controller emitted the diagnostic
marker, trained the Gen3 x1 link and enumerated `17cb:1103`, but MHI still
timed out:

```text
15.628 qcom-pcie 1c08000.pci: X1407QA Wi-Fi diagnostic: PERST# deasserted before WCN power-on
15.828 qcom-pcie 1c08000.pci: PCIe Gen.3 x1 link up
15.834 pci 0004:01:00.0: [17cb:1103]
16.172 mhi mhi0: Power on setup success
16.272 mhi mhi0: Wait for device to enter SBL or Mission mode
37.856 ath11k_pci 0004:01:00.0: failed to power up mhi: -110
```

The same boot also exposed a build-process regression: the phone enumerated at
USB `2d95:600a`, but no tethering interface appeared. The diagnostic config had
lost `CONFIG_USB_NET_RNDIS_HOST=m`; NetworkManager therefore saw only `lo`.
The next stable boot loaded `rndis_host` and `cdc_ether`, created `enu1` and
restored connectivity. The stable and diagnostic DTBs were byte-identical, so
the USB regression came from starting the diagnostic build with `defconfig`
instead of preserving the stable kernel config.

This incident is now a permanent fail-closed constraint. The builder inherits
the stable config, and both the build and artifact verifier reject USB/Type-C
drift, a changed Qualcomm USB3/DP combo PHY, or a missing, corrupt,
wrong-release or unmanifested RNDIS module. Do not reuse the already-built
diagnostic artifacts.

## Falsified lead: WCN6855 6000 ms stabilization delay

Commit `f6f4427888f51c387e5eb748fb661c3746456aeb` added and documented a
second Linux 7.2 diagnostic. It was built locally because Wi-Fi was unavailable
for SSH to the stronger PC. The source patch starts from the protected pristine
Linux 7.2 tarball and changes only
`drivers/power/sequencing/pwrseq-qcom-wcn.c`: WCN6855 `pwup_delay_ms` from
50 ms to 6000 ms plus a runtime marker. It does not contain the rejected PERST
change and does not alter PCI, ath11k, DTB or USB source.

```text
release: 7.2.0-x1407qa-wifi-wcn6855-delay-diag
BLS id: x1407qa-7.2-wifi-wcn6855-delay-diag
patch SHA-256: 3b33bf00c951a340b0c1d85f6839f42d343dc23372c8052541304d8445e5f769
runtime marker: X1407QA Wi-Fi diagnostic: WCN6855 stabilization delay 6000 ms
```

Pre-boot validation completed:

- the patch applied to pristine Linux 7.2 with `--fuzz=0` and its embedded blob
  hashes were canonicalized against that source;
- the builder inherited `/boot/config-7.2.0-x1407qa`; both USB fail-closed
  guards and the complete artifact-manifest verifier passed;
- `rndis_host.ko` was valid, manifested and had the candidate vermagic;
- the candidate DTB was byte-identical to the stable DTB;
- the initramfs contained `pwrseq_qcom_wcn`, `rndis_host`, `cdc_ether`,
  `usbnet`, keyboard/backlight/hotkey modules and required remoteproc firmware;
- the initramfs WCN module was byte-identical to the installed candidate module,
  contained the marker and did not contain `wcn_regulator_fix`;
- all 17 repository tests and all 50 shell syntax checks passed;
- an independent review found no critical or important issue.

Important build confounder: the candidate inherited the stable Kconfig input,
but `olddefconfig` ran with the local Fedora GCC 16.1/binutils 2.46 toolchain.
The stable kernel had been built with Ubuntu GCC 13.3/binutils 2.42. The final
configs therefore differ by 22 compiler/tool capability lines, including RELR,
LSUI and compiler-version metadata. The protected USB/Type-C config did not
drift, but this was not a perfectly toolchain-identical binary A/B test. Future
A/B diagnostics must pin one toolchain for both baseline and candidate.

Installed artifact identities:

```text
vmlinuz:  4b519fc417da4bce8a709ba388c13e4a2192e3f5399f496613c6f8eec072bf77
config:   d845bf5b0f47b9e073ed91bf3a7f5126e68e2470e4130125c35898242e2aa2c9
initramfs: 76a68212cd725a469e1b85784cba3345a8561042561fcbab70a95925821ff73a
DTB:      95f7bb2840c7ce831661056c116f8cd9b692cd94b035f8cdde775cc4a976d90a
pwrseq:   95b7b4a2e87f38d13e28bbf45d7548e31806a13b7962bf4469d475ab37043eee
rndis:    cdf55fd9fa94d444eca955b20dcbb764054c058099794359e35ccbebbf597663
```

The one-shot boot succeeded as boot ID
`79383b4c-e180-4bac-a78f-fca53a5923ba`. The marker proves that the intended
delay ran before PCI enumeration. Wi-Fi still failed at exactly the established
MHI boundary:

```text
 7.680 X1407QA Wi-Fi diagnostic: WCN6855 stabilization delay 6000 ms
14.100 PCIe Gen.3 x1 link up
14.102 endpoint 17cb:1103 enumerated
14.260 ath11k_pci: enabling device; 32 MSI vectors; wcn6855 hw2.1
14.424 mhi mhi0: Requested to power ON
14.424 mhi mhi0: Power on setup success
14.502 mhi mhi0: Wait for device to enter SBL or Mission mode
35.812 ath11k_pci: failed to power up mhi: -110
36.004 ath11k_pci probe failed with error -110
```

Compared with the immediately preceding stable boot, the delay shifted PCIe
link-up and all later events by about 6.3 seconds but did not change the MHI
transition or failure duration:

| Boundary | Stable 7.2 | 6000 ms candidate |
|---|---:|---:|
| PCIe Gen3 x1 link | 7.770 s | 14.100 s |
| MHI setup success | 8.012 s | 14.424 s |
| wait for SBL/Mission | 8.112 s | 14.502 s |
| MHI `-110` | 29.672 s | 35.812 s |

The endpoint remains present in D0 but is unbound, `enable=0`; NetworkManager
reports Wi-Fi hardware as missing and `/sys/class/net` contains only `lo` and
USB tethering `enu1`. This strongly rejects stabilization time as the missing
condition: the endpoint still never enters SBL or Mission mode. Do not increase
the delay, stack another patch on this candidate or boot it again.

USB preservation succeeded. In the candidate boot the phone re-enumerated,
`rndis_host` registered normally at 109.016 seconds, renamed `usb0` to `enu1`,
and NetworkManager activated it at `10.202.21.72/24`. The loaded `rndis_host`,
`cdc_ether` and `usbnet` modules all match the candidate release. Never reset,
unload, rebind or reconfigure any of them during Wi-Fi work.

The candidate audit reports Wi-Fi failed and 14 passes. RGB camera also reports
failed only because the optional `vivobook_cam_fix.ko` could not be compiled for
this diagnostic output tree; camera was intentionally not enabled or tested.
The stable release still owns its camera module. This packaging limitation is
not evidence about the Wi-Fi failure.

At 52 seconds, after the Wi-Fi probe had already failed, `dkms.service`
automatically built and installed `wcn_regulator_fix.ko` into the candidate's
`extra/` directory. It is not loaded and is absent from the published initramfs,
so it could not cause this boot's timeout. Do not load it. Future diagnostic
installations should prevent this DKMS autoinstall to keep the installed module
tree as clean as the initramfs.

## Exact next step

The laptop is currently running the rejected delay candidate only to preserve
this diagnostic session. GRUB state is already safe:

```text
saved_entry=x1407qa-7.2.0-x1407qa
next_entry=
```

Reboot once normally. It will return to stable Linux `7.2.0-x1407qa`; do not
select either Wi-Fi diagnostic manually. After the stable boot, verify only
read-only state:

```bash
uname -r
ip -brief address show enu1
sudo grub2-editenv - list
bash tools/audit-stable-hardware.sh --post-reboot
```

Expected stable result is USB tethering restored/working, RGB camera module
available and 15 of 16 audit items passing, with Wi-Fi as the only failure.
Do not test an older kernel: all further work is Linux 7.2 or newer.

The full repository test suite passed before this diagnostic boot. While the
candidate is active, 16 tests pass and
`tests/test-stable-hardware-recovery.sh` intentionally fails because the
recovery runner accepts only the stable release. This is an environment gate,
not a newly observed source failure. Rerun all 17 tests after returning to the
stable kernel.

The next research boundary is inside the WCN6855/MHI device transition after
host power-on succeeds, not PCI enumeration, PERST ordering, regulator hold
time, NetworkManager, board data or calibration selection. Start the next clean
session by instrumenting the MHI execution-environment/state transition and
endpoint reset state at the existing timeout, without issuing a live reset.
Compare a baseline and one diagnostic built with the same pinned toolchain.
Change only one WCN6855/MHI variable at a time and preserve the stable config,
DTB, default entry and USB fail-closed checks.

Before any later candidate is installed, require:

```bash
kernel/verify-linux-usb-config-preservation.sh \
  /boot/config-7.2.0-x1407qa \
  /path/to/candidate.config
X1407QA_REFERENCE_CONFIG=/boot/config-7.2.0-x1407qa \
  kernel/verify-linux-7.2-x1407qa.sh /path/to/artifacts candidate-release
```

Wi-Fi is still unavailable, so SSH to the stronger PC cannot yet be the build
path. Do not use USB storage or modify USB networking to transfer a build.

## Useful evidence commands

```bash
# Current and previous boots
sudo journalctl --list-boots --no-pager
sudo journalctl -b -1 -k --no-pager -o short-monotonic

# Current WCN device and driver state
lspci -nnk -s 0004:01:00.0
readlink -f /sys/bus/pci/devices/0004:01:00.0/driver 2>/dev/null

# Native and legacy module state
lsmod | rg 'pwrseq|wcn_regulator|ath11k|mhi'
modinfo pwrseq_qcom_wcn
modinfo wcn_regulator_fix 2>/dev/null

# Boot configuration
sudo grub2-editenv - list
sudo sed -n '1,120p' /boot/loader/entries/x1407qa-7.2.0-x1407qa.conf
sudo sed -n '1,120p' /boot/loader/entries-disabled/x1407qa-7.2-wifi-pwrctrl-diag.conf

# DTB identity
sha256sum x1p42100-asus-zenbook-a14-wifi-fix.dtb \
  /boot/dtb-x1407qa/qcom/x1p42100-asus-zenbook-a14.dtb
```

## Completion condition

Do not declare the recovery complete until `tools/audit-stable-hardware.sh
--post-reboot` reports all 16 required components as `PASS` on a stable boot and
the repository tests pass. Before committing a final Wi-Fi correction, follow
test-driven development and run the verification-before-completion workflow.
