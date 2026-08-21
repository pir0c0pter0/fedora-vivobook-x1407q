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

## Strong current lead: PCI power-control change in Linux 7.2

A source comparison between upstream Linux 6.19 and 7.2 found a relevant
architectural change in `drivers/pci/pwrctrl/pci-pwrctrl-pwrseq.c`:

- Linux 6.19 calls `pwrseq_power_on()` directly during the pwrctrl probe and
  registers a managed power-off action.
- Linux 7.2 instead registers `power_on` and `power_off` callbacks on
  `struct pci_pwrctrl`; the PCI controller owns when they are invoked.

The WCN6855-specific sequence in `pwrseq-qcom-wcn.c` is otherwise materially
the same. Linux 7.2 adds support for other WCN families, but does not obviously
change the WCN6855 target data.

This change matches the historical boundary: the repository documented Wi-Fi
working on Fedora Linux 6.19 with regulator holding and delayed enumeration,
while Linux 7.2 consistently reaches PCI enumeration but times out at MHI.
This is a hypothesis, not yet a confirmed root cause.

The controller-level ordering is the narrower observable difference. Linux 7.2
calls `pci_pwrctrl_power_on_devices()` in `qcom_pcie_host_init()` while PERST#
is still asserted, and deasserts PERST# only later. The earlier lifecycle
released PERST# before the WCN pwrseq consumer powered the endpoint and queued
a PCI rescan. The next experiment therefore changes only this ordering in a
separately versioned Linux 7.2 build.

Kernel config difference worth retaining:

```text
6.19: CONFIG_POWER_SEQUENCING=m
7.2:  CONFIG_POWER_SEQUENCING=y
6.19: CONFIG_PCI_PWRCTRL_SLOT=y
7.2:  CONFIG_PCI_PWRCTRL_GENERIC=y
```

Both kernels enable `CONFIG_PCI_PWRCTRL`, `CONFIG_PCI_PWRCTRL_PWRSEQ`,
`CONFIG_POWER_SEQUENCING_QCOM_WCN`, `CONFIG_MHI_BUS` and `CONFIG_ATH11K_PCI`.

## Exact next step

Do not repeat the inconclusive old-kernel boot. Build and install the separately
versioned Linux 7.2 diagnostic candidate that moves WCN power-on after PERST#
deassertion while retaining the Linux 7.2 pwrctrl ownership model.

Build and verify without replacing the stable kernel:

```bash
sudo -n kernel/build-linux-7.2-wifi-pwrctrl-diagnostic.sh
sudo -n kernel/verify-linux-7.2-x1407qa.sh \
  /var/lib/x1407qa-kernel-7.2-wifi-pwrctrl-diag/artifacts \
  7.2.0-x1407qa-wifi-pwrctrl-diag
```

Install it under its own kernel release and BLS ID, keep
`saved_entry=x1407qa-7.2.0-x1407qa`, and set only
`next_entry=x1407qa-7.2-wifi-pwrctrl-diag`. After reboot, wait at least 60
seconds and inspect:

```bash
uname -r
ip -br link
lspci -nnk -s 0004:01:00.0
sudo journalctl -b -k --no-pager -o short-monotonic |
  rg -i 'X1407QA Wi-Fi diagnostic|pcie|17cb:1103|ath11k|mhi|pwrseq|wcn'
```

Interpretation:

- If the candidate reaches MHI Mission mode and exposes a Wi-Fi interface,
  PERST#/WCN power ordering is confirmed as the regression mechanism. Convert
  the diagnostic change into a narrowly reviewed correction; do not revive the
  legacy rail-hold module as a permanent fix.
- If the candidate still produces `failed to power up mhi: -110`, this ordering
  hypothesis is falsified. Restore the stable 7.2 boot and investigate the next
  endpoint reset/power boundary without stacking another change.
- A missing custom DKMS helper in the diagnostic release is not a Wi-Fi result.
  Judge only the diagnostic marker, PCI endpoint, MHI state, ath11k binding and
  network interface after at least 60 seconds.

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
sudo sed -n '1,120p' /boot/loader/entries/x1407qa-7.2-wifi-pwrctrl-diag.conf

# DTB identity
sha256sum x1p42100-asus-zenbook-a14-wifi-fix.dtb \
  /boot/dtb-x1407qa/qcom/x1p42100-asus-zenbook-a14.dtb
```

## Completion condition

Do not declare the recovery complete until `tools/audit-stable-hardware.sh
--post-reboot` reports all 16 required components as `PASS` on a stable boot and
the repository tests pass. Before committing a final Wi-Fi correction, follow
test-driven development and run the verification-before-completion workflow.
