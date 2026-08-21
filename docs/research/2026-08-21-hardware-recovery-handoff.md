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
- Last implementation commit before this handoff: `e9bc4e1 fix: validate post-reboot stable hardware`
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
legacy wcn_regulator_fix: not loaded and omitted from the current initramfs
```

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

## Exact next step

Keep the laptop on `7.2.0-x1407qa` with working USB tethering. Do not repeat the
old-kernel boot and do not boot the rejected PERST-before-power candidate.

Continue the Wi-Fi investigation at the next endpoint reset/power boundary,
starting from pristine Linux 7.2 or newer and changing one WCN-specific
variable at a time. Do not stack another change on the falsified diagnostic
patch. Compile candidates on the user's stronger remote PC over SSH; transfer
only source, config, patch and verified artifacts. Never use USB storage or
alter USB configuration as part of that build workflow.

The current single-variable hypothesis is WCN6855 stabilization time. The
historical helper held the WCN rails and waited 6000 ms before rescanning PCI,
whereas native pwrseq uses short WCN6855 delays and reaches MHI in under one
second. First instrument the native 7.2+ timing and MHI state, then test one
WCN6855-only post-enable delay without changing PCI ordering, USB code or the
stable default boot entry. Do not apply a generic Qualcomm PCI reset patch:
the native ath11k probe already performs the endpoint global/MHI reset path.

Before any future candidate can be transferred or installed, require:

```bash
kernel/verify-linux-usb-config-preservation.sh \
  /boot/config-7.2.0-x1407qa \
  /path/to/candidate.config
X1407QA_REFERENCE_CONFIG=/boot/config-7.2.0-x1407qa \
  kernel/verify-linux-7.2-x1407qa.sh /path/to/artifacts candidate-release
```

The next research task is to compare the WCN6855 endpoint reset/power timing
and MHI state transition in current upstream Qualcomm PCIe/pwrseq code, then
propose one new Linux 7.2+ diagnostic. Obtain the remote SSH host/alias and
available build environment from the user before creating or transferring a
remote worktree.

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
