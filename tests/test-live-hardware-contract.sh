#!/usr/bin/env bash
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

require_file() {
    [[ -f $1 ]] || { echo "FAIL: missing $1" >&2; exit 1; }
}

require_token() {
    grep -qF -- "$2" "$1" || {
        echo "FAIL: $1 missing: $2" >&2
        exit 1
    }
}

for module in wcn-regulator-fix vivobook-kbd-fix vivobook-bl-fix vivobook-hotkey-fix; do
    dir="$repo/modules/$module-1.0"
    require_file "$dir/Makefile"
    require_file "$dir/dkms.conf"
done

wcn="$repo/modules/wcn-regulator-fix-1.0/wcn_regulator_fix.c"
kbd="$repo/modules/vivobook-kbd-fix-1.0/vivobook_kbd_fix.c"
bl="$repo/modules/vivobook-bl-fix-1.0/vivobook_bl_fix.c"
hotkey="$repo/modules/vivobook-hotkey-fix-1.0/vivobook_hotkey_fix.c"
for source in "$wcn" "$kbd" "$bl" "$hotkey"; do require_file "$source"; done

for token in 'vddaon' 'vddio' 'vddpcie1p3' 'vddpcie1p9' 'vddpmu' 'vddpmucx' 'vddpmumx' \
    'vddrfa0p95' 'vddrfa1p3' 'vddrfa1p9' \
    'regulator_bulk_enable' 'pci_rescan_bus' 'rescan_delay_ms'; do
    require_token "$wcn" "$token"
done
for token in '/soc@0/geniqup@bc0000/i2c@b94000' '/soc@0/pinctrl@f100000' '0x3a' '67' 'IRQ_TYPE_LEVEL_LOW' 'i2c_hid_core_probe' '0x0001' 'DECLARE_DELAYED_WORK' 'schedule_delayed_work'; do
    require_token "$kbd" "$token"
done
for token in '0x0b05' '0x4543' '0x5a' 'ASUS Tech.Inc.' 'KEY_BRIGHTNESSDOWN' 'KEY_BRIGHTNESSUP' 'KEY_MICMUTE' 'KEY_CAMERA' 'KEY_RFKILL' 'KEY_KBDILLUMTOGGLE'; do
    require_token "$hotkey" "$token"
done
for token in '0xe800' '0xe8d0' '0xe8e2' '0xe847' '0x0c' '4095' 'backlight_device_register'; do
    require_token "$bl" "$token"
done

kernel_builder="$repo/kernel/build-linux-7.2-x1407qa.sh"
iso_builder="$repo/tools/build-personal-maximal-iso.sh"
firmware_manifest="$repo/firmware/x1407qa-driverstore.sha256"
require_file "$firmware_manifest"
for token in 'wcn-regulator-fix-1.0' 'vivobook-kbd-fix-1.0' 'vivobook-bl-fix-1.0' 'vivobook-hotkey-fix-1.0' 'modules_install'; do
    require_token "$kernel_builder" "$token"
done
if error=$("$kernel_builder" /tmp/missing-linux.tar.xz /var /var/artifacts 2>&1); then
    echo 'FAIL: kernel builder accepted an unsafe destructive work root' >&2
    exit 1
fi
[[ $error == *'unsafe work root: /var'* ]] || {
    echo "FAIL: kernel builder rejected unsafe root for the wrong reason: $error" >&2
    exit 1
}
for token in 'FIRMWARE_SOURCE' 'DriverStore-Backup/FileRepository' 'x1407qa-driverstore.sha256' 'qcsubsys_ext_adsp8380.inf_arm64_dad10e5e4880caf9' 'qcnspmcdm_ext_cdsp8380.inf_arm64_a2e536ad01025a78' 'qcdx8380.inf_arm64_e13ac55ddce2b10f' 'firmware/ath11k/WCN6855/hw2.1' 'qcadsp8380.mbn' 'qccdsp8380.mbn' 'qcdxkmsucpurwa.mbn' 'amss.bin' '00756e19aee2b5e6725f5029b7e6abea748caca0f53af5a7662cd32086dde4bd' '/usr/src' '/run/initramfs/livedev' 'qemu-aarch64' 'ConditionKernelCommandLine=rd.live.ram' 'modprobe qcom_q6v5_pas' 'rd.live.ram' 'rd.minmem=4096' 'fallback USB' 'systemd.tpm2_wait=0' 'modprobe.blacklist=qcom_q6v5_pas'; do
    require_token "$iso_builder" "$token"
done
kernel_verifier="$repo/kernel/verify-linux-7.2-x1407qa.sh"
for token in 'CONFIG_I2C_QCOM_GENI=m' 'CONFIG_ATH11K_PCI=m' 'CONFIG_QCOM_Q6V5_PAS=m' 'CONFIG_QCOM_PMIC_GLINK=m' 'CONFIG_BATTERY_QCOM_BATTMGR=m'; do
    require_token "$kernel_verifier" "$token"
done
if grep -qF 'install_newest_firmware' "$iso_builder" || grep -Eq 'rsync .*REPO_ROOT/' "$iso_builder"; then
    echo 'FAIL: ISO builder contains nondeterministic firmware or repository payload copy' >&2
    exit 1
fi
if error=$(WORK_ROOT=/var "$iso_builder" 2>&1); then
    echo 'FAIL: ISO builder accepted an unsafe destructive work root' >&2
    exit 1
fi
[[ $error == *'unsafe work root: /var'* ]] || {
    echo "FAIL: ISO builder rejected unsafe root for the wrong reason: $error" >&2
    exit 1
}
if error=$(WORK_ROOT=/var/tmp/x1407qa-contract INPUT_ISO=/tmp/final.iso.sha256 \
    OUTPUT_ISO=/tmp/final.iso "$iso_builder" 2>&1); then
    echo 'FAIL: ISO builder accepted the output checksum as input' >&2
    exit 1
fi
[[ $error == *'input ISO conflicts with output checksum path'* ]] || {
    echo "FAIL: ISO builder rejected checksum collision for the wrong reason: $error" >&2
    exit 1
}
setup="$repo/setup-vivobook.sh"
require_file "$setup"
for token in 'snd_soc_wcd938x' 'HandleLidSwitch=suspend' 'vivobook-battery-freq-cap' \
    '99-battery-freq-cap.rules' '2380800' 'mem_sleep_default=s2idle' \
    '--remove-args="pd_ignore_unused mem_sleep_default"'; do
    require_token "$setup" "$token"
done
setup_grubby=$(grep -F 'grubby --update-kernel=ALL' "$setup")
[[ $setup_grubby == *'--args="clk_ignore_unused mem_sleep_default=s2idle '* ]] || {
    echo 'FAIL: installed-system setup does not preserve the required clock guard and s2idle' >&2
    exit 1
}

update_manager="$repo/vivobook-update.sh"
require_file "$update_manager"
for token in 'mem_sleep_default=s2idle' "! grep -q 'pd_ignore_unused'" \
    'for target in sleep.target suspend.target' \
    'for target in hibernate.target hybrid-sleep.target suspend-then-hibernate.target'; do
    require_token "$update_manager" "$token"
done
if grep -qF '/etc/grub.d/08_vivobook' "$update_manager" || \
    grep -qF 'rodar setup-all.sh' "$update_manager"; then
    echo 'FAIL: update manager still enforces the retired installed-system boot policy' >&2
    exit 1
fi

legacy_guard="$repo/post-install-protect.sh"
require_file "$legacy_guard"
if legacy_output=$(bash "$legacy_guard" 2>&1); then
    echo 'FAIL: retired post-install boot guard still mutates the installed system' >&2
    exit 1
fi
[[ $legacy_output == *'desativado'* ]] || {
    echo 'FAIL: retired post-install boot guard does not explain its replacement' >&2
    exit 1
}

fallback_linux=$(awk '/menuentry .*fallback USB/ { found=1 } found && /^[[:space:]]*linux / { print; exit }' "$iso_builder")
[[ $fallback_linux != *rd.live.ram* && $fallback_linux == *modprobe.blacklist=qcom_q6v5_pas* ]] || {
    echo 'FAIL: USB fallback RAM/ADSP policy is invalid' >&2
    exit 1
}

mapfile -t live_linux < <(grep -E '^[[:space:]]+linux .*root=live:' "$iso_builder")
[[ ${#live_linux[@]} -eq 3 ]] || {
    echo "FAIL: expected three live boot entries, found ${#live_linux[@]}" >&2
    exit 1
}
for linux_line in "${live_linux[@]}"; do
    [[ $linux_line == *clk_ignore_unused* && $linux_line == *pd_ignore_unused* ]] || {
        echo 'FAIL: a live boot entry lost the conservative clock/power-domain guards' >&2
        exit 1
    }
done

echo 'PASS: X1407QA live hardware source and ISO contracts are present'
