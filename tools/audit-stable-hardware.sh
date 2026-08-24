#!/usr/bin/env bash
# Read-only acceptance audit for stable ASUS Vivobook X1407QA hardware.
set -euo pipefail

mode=${1:---post-reboot}
case "$mode" in
    --pre-reboot|--post-reboot) ;;
    *)
        echo "usage: $0 [--pre-reboot|--post-reboot]" >&2
        exit 2
        ;;
esac

failures=0
infrastructure_failures=0

pass() {
    printf 'PASS %s: %s\n' "$1" "$2"
}

fail() {
    printf 'FAIL %s: %s\n' "$1" "$2"
    failures=1
}

infra_fail() {
    printf 'ERROR infrastructure: %s\n' "$1" >&2
    infrastructure_failures=1
}

audit_internal_error() {
    local status=$1 line=$2

    printf 'ERROR infrastructure: internal audit failure at line %s (status %s)\n' \
        "$line" "$status" >&2
    exit 2
}

trap 'audit_internal_error "$?" "$LINENO"' ERR

skip() {
    printf 'SKIP %s: %s\n' "$1" "$2"
}

have() {
    if [[ ${AUDIT_TEST_MODE:-0} == 1 &&
          ${AUDIT_TEST_MISSING_COMMAND:-} == "$1" ]]; then
        return 1
    fi
    command -v "$1" >/dev/null 2>&1
}

require_audit_tools() {
    local command_name
    local -a required_commands=(
        awk bluetoothctl find gnome-extensions grep gsettings ip journalctl
        libinput lsmod lspci modinfo nmcli pactl systemctl systemd-analyze upower
    )

    for command_name in "${required_commands[@]}"; do
        if ! have "$command_name"; then
            infra_fail "required command is unavailable: $command_name"
        fi
    done
    [[ $infrastructure_failures -eq 0 ]]
}

boot_journal_has() {
    local journal

    journal=$(journalctl -b --no-pager 2>/dev/null) || return 2
    grep -Eqi -- "$1" <<<"$journal"
}

report_unavailable_boot_journal() {
    local component=$1

    infra_fail 'current boot journal is unavailable'
}

require_boot_journal() {
    local component=$1

    if have journalctl && journalctl -b --no-pager >/dev/null 2>&1; then
        return 0
    fi
    report_unavailable_boot_journal "$component"
    return 1
}

remoteproc_state() {
    local wanted=$1 remoteproc name

    for remoteproc in /sys/class/remoteproc/remoteproc*; do
        [[ -r "$remoteproc/name" && -r "$remoteproc/state" ]] || continue
        name=$(<"$remoteproc/name")
        if [[ $name =~ $wanted ]]; then
            cat "$remoteproc/state"
            return 0
        fi
    done
    return 1
}

first_battery() {
    local supply

    for supply in /sys/class/power_supply/*; do
        [[ -r "$supply/type" ]] || continue
        [[ $(<"$supply/type") == Battery ]] || continue
        printf '%s\n' "$supply"
        return 0
    done
    return 1
}

check_wifi() {
    local pci_driver

    if ! have lspci || ! have ip || ! have nmcli; then
        fail wifi 'lspci, ip, or nmcli is unavailable'
        return
    fi
    if ! lspci -k -d 17cb:1103 2>/dev/null | grep -q .; then
        fail wifi 'WCN6855 PCI device 17cb:1103 is absent'
        return
    fi
    pci_driver=$(lspci -k -d 17cb:1103 2>/dev/null || true)
    if ! grep -Eq 'Kernel driver in use: ath11k_pci' <<<"$pci_driver"; then
        fail wifi 'WCN6855 is not bound to ath11k_pci'
        return
    fi
    if ! nmcli -t -f TYPE device status 2>/dev/null | grep -qx wifi; then
        fail wifi 'NetworkManager has no Wi-Fi device'
        return
    fi
    if ! ip -o link show | grep -Eq '^[0-9]+: (wl|wlan)'; then
        fail wifi 'no Wi-Fi network interface is present'
        return
    fi
    if ! require_boot_journal wifi; then
        return
    fi
    if boot_journal_has 'failed to power up mhi|mhi.*-110'; then
        fail wifi 'current boot journal reports an MHI power-up timeout'
        return
    elif [[ $? -eq 2 ]]; then
        report_unavailable_boot_journal wifi
        return
    fi
    pass wifi 'ath11k_pci, NetworkManager, interface, and current boot journal are healthy'
}

check_battery() {
    local battery upower_device percentage

    if ! have upower || ! have gnome-extensions || ! have gsettings; then
        fail battery 'upower, gnome-extensions, or gsettings is unavailable'
        return
    fi
    if ! battery=$(first_battery); then
        fail battery 'no battery power-supply device is present'
        return
    fi
    for attribute in status energy_now energy_full power_now; do
        if [[ ! -r "$battery/$attribute" || -z $(<"$battery/$attribute") ]]; then
            fail battery "${attribute} is not readable at ${battery}"
            return
        fi
    done
    upower_device=$(upower -e 2>/dev/null | grep -m1 battery || true)
    if [[ -z $upower_device ]]; then
        fail battery 'UPower has no battery device'
        return
    fi
    percentage=$(upower -i "$upower_device" 2>/dev/null | awk '/^[[:space:]]*percentage:/ { print $2; exit }')
    if [[ ! $percentage =~ ^[0-9]+([.][0-9]+)?%$ ]]; then
        fail battery 'UPower does not report a numeric battery percentage'
        return
    fi
    if ! gnome-extensions list >/dev/null 2>&1; then
        # The probe covers sudo/SSH/headless runs where the Shell is not
        # reachable on the caller's bus: skip the GNOME checks.
        pass battery "sysfs energy and power are readable; UPower reports ${percentage} (no reachable GNOME session)"
        return
    fi
    if [[ $(gsettings get org.gnome.desktop.interface show-battery-percentage 2>/dev/null || true) != true ]]; then
        fail battery 'GNOME battery percentage is disabled'
        return
    fi
    if ! gnome-extensions list --enabled 2>/dev/null | grep -qx 'battery-time@wifiteste'; then
        fail battery 'GNOME battery-time extension is not enabled'
        return
    fi
    pass battery "sysfs energy and power are readable; UPower reports ${percentage}; GNOME battery UI is enabled"
}

check_remoteproc() {
    local component=$1 name_pattern=$2 module=$3 state

    if ! have modinfo; then
        fail "$component" 'modinfo is unavailable'
        return
    fi
    if ! modinfo "$module" >/dev/null 2>&1; then
        fail "$component" "required module ${module} is unavailable"
        return
    fi
    if ! state=$(remoteproc_state "$name_pattern"); then
        fail "$component" 'no matching remoteproc is exposed in sysfs'
        return
    fi
    if [[ $state != running ]]; then
        fail "$component" "remoteproc state is ${state}"
        return
    fi
    if ! require_boot_journal "$component"; then
        return
    fi
    if boot_journal_has "${name_pattern}.*(defer|deferred)|((defer|deferred).*)${name_pattern}"; then
        fail "$component" 'current boot journal has a deferred probe'
        return
    elif [[ $? -eq 2 ]]; then
        report_unavailable_boot_journal "$component"
        return
    fi
    pass "$component" "${module} is available and remoteproc is running"
}

check_gpu() {
    local render_node='' drm_class=${AUDIT_DRM_CLASS:-/sys/class/drm}

    if ! have modinfo; then
        fail gpu 'modinfo is unavailable'
        return
    fi
    if ! modinfo msm >/dev/null 2>&1; then
        fail gpu 'msm DRM module is unavailable'
        return
    fi
    for render_node in "$drm_class"/renderD*; do
        if [[ -e $render_node && -r $render_node/dev ]]; then
            break
        fi
        render_node=''
    done
    if [[ -z $render_node ]]; then
        fail gpu 'no readable DRM render node is present'
        return
    fi
    if ! require_boot_journal gpu; then
        return
    fi
    if boot_journal_has '(msm|adreno|gpu).*(failed to load firmware|firmware.*(not found|failed))'; then
        fail gpu 'current boot journal reports missing GPU firmware'
        return
    elif [[ $? -eq 2 ]]; then
        report_unavailable_boot_journal gpu
        return
    fi
    pass gpu 'msm DRM module and render node are present without a firmware failure in this boot'
}

check_bluetooth() {
    if ! have bluetoothctl; then
        fail bluetooth 'bluetoothctl is unavailable'
        return
    fi
    if ! find /sys/class/bluetooth -maxdepth 1 -name 'hci*' -type l -print -quit 2>/dev/null | grep -q .; then
        fail bluetooth 'no Bluetooth HCI controller is present'
        return
    fi
    if ! bluetoothctl show >/dev/null 2>&1; then
        fail bluetooth 'the Bluetooth controller is not usable through bluetoothctl'
        return
    fi
    pass bluetooth 'HCI controller is present and bluetoothctl can query it'
}

check_input() {
    local component=$1 pattern=$2 devices

    if ! have libinput; then
        fail "$component" 'libinput is unavailable'
        return
    fi
    devices=$(libinput list-devices 2>/dev/null || true)
    if [[ -z $devices ]] && have sudo && sudo -n true >/dev/null 2>&1; then
        devices=$(sudo -n libinput list-devices 2>/dev/null || true)
    fi
    if [[ -z $devices ]]; then
        fail "$component" 'libinput cannot enumerate input devices'
        return
    fi
    if ! grep -Eqi -- "$pattern" <<<"$devices"; then
        fail "$component" 'libinput does not expose the expected device capability'
        return
    fi
    pass "$component" 'libinput exposes the expected input capability'
}

check_backlight() {
    local device

    for device in /sys/class/backlight/*; do
        [[ -r "$device/brightness" && -r "$device/max_brightness" ]] || continue
        if [[ -n $(<"$device/brightness") && -n $(<"$device/max_brightness") ]]; then
            pass backlight "brightness controls are readable at ${device}"
            return
        fi
    done
    fail backlight 'no readable backlight brightness controls are present'
}

check_hotkeys() {
    if ! have modinfo || ! modinfo vivobook_hotkey_fix >/dev/null 2>&1; then
        fail hotkeys 'vivobook_hotkey_fix module is unavailable'
        return
    fi
    if ! lsmod | awk '{print $1}' | grep -qx vivobook_hotkey_fix; then
        fail hotkeys 'vivobook_hotkey_fix is not loaded'
        return
    fi
    pass hotkeys 'vivobook_hotkey_fix is installed and loaded'
}

check_audio() {
    if ! have pactl || ! pactl info >/dev/null 2>&1; then
        # Typical under sudo/SSH without a session bus: fall back to raw ALSA.
        if grep -q '^[[:space:]]*[0-9]' /proc/asound/cards 2>/dev/null; then
            pass audio 'ALSA card present (no user session bus)'
        else
            fail audio 'no audio server is reachable and no ALSA soundcard is registered'
        fi
        return
    fi
    if ! pactl list short sinks 2>/dev/null | grep -q .; then
        fail audio 'no audio sink is available'
        return
    fi
    pass audio 'pactl reports an active audio server and sink'
}

check_cpufreq() {
    local policy driver governor

    if ! have modinfo || ! modinfo scmi_cpufreq >/dev/null 2>&1; then
        fail cpufreq 'scmi_cpufreq module is unavailable'
        return
    fi
    for policy in /sys/devices/system/cpu/cpufreq/policy*; do
        [[ -r "$policy/scaling_driver" && -r "$policy/scaling_governor" ]] || continue
        driver=$(<"$policy/scaling_driver")
        governor=$(<"$policy/scaling_governor")
        if [[ $driver == *scmi* && -n $governor ]]; then
            pass cpufreq "${policy##*/} uses ${driver} with governor ${governor}"
            return
        fi
    done
    fail cpufreq 'no CPU policy uses a readable SCMI cpufreq driver and governor'
}

check_charge_limit() {
    local threshold=/sys/class/power_supply/qcom-battmgr-bat/charge_control_end_threshold

    if [[ ! -r $threshold ]]; then
        fail charge-limit 'qcom-battmgr charge-control threshold is unavailable'
        return
    fi
    if [[ $(<$threshold) != 80 ]]; then
        fail charge-limit "charge-control threshold is $(<$threshold), expected 80"
        return
    fi
    pass charge-limit 'qcom-battmgr charge-control threshold is 80'
}

check_camera_rgb() {
    local state enabled

    if ! have modinfo || ! have systemctl; then
        fail camera-rgb 'modinfo or systemctl is unavailable'
        return
    fi
    if ! modinfo ov02c10 >/dev/null 2>&1 || ! modinfo vivobook_cam_fix >/dev/null 2>&1; then
        fail camera-rgb 'RGB camera modules are unavailable'
        return
    fi
    enabled=$(systemctl is-enabled vivobook-camera.service 2>&1 || true)
    state=$(systemctl is-active vivobook-camera.service 2>/dev/null || true)
    if [[ $enabled != enabled ]]; then
        fail camera-rgb "camera service is ${enabled:-not-found}, expected enabled"
        return
    fi
    if [[ $state != active || ! -d /sys/module/vivobook_cam_fix ]]; then
        fail camera-rgb "camera autostart is ${state:-unknown} or its module is not loaded"
        return
    fi
    if ! compgen -G '/sys/bus/i2c/drivers/ov02c10/*-0036' >/dev/null ||
       ! compgen -G '/dev/media*' >/dev/null ||
       ! compgen -G '/dev/video*' >/dev/null; then
        fail camera-rgb 'OV02C10 is not bound or its media nodes are unavailable'
        return
    fi
    pass camera-rgb 'RGB camera autostart is active and OV02C10 is available'
}

check_color_control() {
    local color_dir=/sys/kernel/vivobook_color

    if ! have modinfo || ! modinfo vivobook_color_ctrl >/dev/null 2>&1; then
        fail color-control 'vivobook_color_ctrl module is unavailable'
        return
    fi
    if [[ ! -r $color_dir/saturation || ! -r $color_dir/contrast ]]; then
        fail color-control 'saturation and contrast controls are unavailable'
        return
    fi
    pass color-control 'saturation and contrast controls are readable'
}

effective_logind_policy() {
    local policy=$1 configuration

    configuration=$(systemd-analyze cat-config systemd/logind.conf 2>/dev/null) || return 1
    awk -F= -v policy="$policy" '
        $0 ~ "^[[:space:]]*" policy "=" {
            value = $2
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
        }
        END {
            if (value != "") {
                print value
            } else {
                exit 1
            }
        }
    ' <<<"$configuration"
}

check_lid_safety() {
    local target status policy value mem_sleep

    if ! have systemctl || ! have systemd-analyze; then
        fail lid-safety 'systemctl or systemd-analyze is unavailable'
        return
    fi
    for target in sleep.target suspend.target; do
        status=$(systemctl is-enabled "$target" 2>&1 || true)
        if [[ $status == masked ]]; then
            fail lid-safety "${target} is masked, expected unmasked for s2idle suspend"
            return
        fi
    done
    for target in hibernate.target hybrid-sleep.target suspend-then-hibernate.target; do
        status=$(systemctl is-enabled "$target" 2>&1 || true)
        if [[ $status != masked ]]; then
            fail lid-safety "${target} is ${status:-not-found}, expected masked"
            return
        fi
    done
    for policy in HandleLidSwitch HandleLidSwitchExternalPower HandleLidSwitchDocked; do
        if ! value=$(effective_logind_policy "$policy"); then
            fail lid-safety "cannot determine effective ${policy} policy"
            return
        fi
        if [[ $value != suspend ]]; then
            fail lid-safety "effective ${policy} policy is ${value}, expected suspend"
            return
        fi
    done
    if [[ -r /sys/power/mem_sleep ]]; then
        mem_sleep=$(</sys/power/mem_sleep)
        if [[ $mem_sleep != *'[s2idle]'* ]]; then
            fail lid-safety "selected mem_sleep mode is ${mem_sleep}, expected [s2idle]"
            return
        fi
    fi
    pass lid-safety 'lid suspends via s2idle; hibernate-family targets remain masked'
}

# The audit usually runs under sudo, so the real user's HOME comes from
# SUDO_USER (logname/USER when it is invoked directly). A plain root run falls
# back to the first /home entry with a passwd record instead of /root.
audit_real_home() {
    local user home candidate

    user=${SUDO_USER:-}
    [[ -n $user ]] || user=$(logname 2>/dev/null || true)
    [[ -n $user ]] || user=${USER:-}
    if [[ -z $user || $user == root ]]; then
        for candidate in /home/*; do
            [[ -d $candidate ]] || continue
            if getent passwd "${candidate##*/}" >/dev/null 2>&1; then
                user=${candidate##*/}
                break
            fi
        done
    fi
    home=$(getent passwd "$user" 2>/dev/null | cut -d: -f6 || true)
    [[ -n $home ]] || home=${HOME:-}
    [[ -n $home && -d $home ]] || return 1
    printf '%s\n' "$home"
}

# ld.so never fails a bad LD_PRELOAD: it warns on stderr and ignores the
# library, so the loader probe has to inspect stderr instead of the exit code.
preload_rejects() {
    local message

    message=$(LD_PRELOAD=$1 /bin/true 2>&1 >/dev/null || true)
    [[ -n $message ]]
}

check_vulkan_pool_fix() {
    local library=/usr/local/lib64/vk_pool_fix.so
    local wrapper=/usr/local/bin/ptyxis-fixed
    local home icd_conf service desktop

    if ! have getent; then
        fail vulkan-pool-fix 'getent is unavailable'
        return
    fi
    if [[ ! -f $library ]]; then
        fail vulkan-pool-fix "${library} is absent"
        return
    fi
    if preload_rejects "$library"; then
        fail vulkan-pool-fix "${library} is present but the dynamic loader rejects it"
        return
    fi
    # nm ships with binutils, which is optional: without it the loader probe
    # above still rejects a broken library, only the symbol proof is skipped.
    if have nm && ! nm -D --defined-only "$library" 2>/dev/null |
        grep -q ' vkCreateDescriptorPool$'; then
        fail vulkan-pool-fix "${library} does not export vkCreateDescriptorPool"
        return
    fi
    if ! home=$(audit_real_home); then
        fail vulkan-pool-fix 'the home directory of the real user is unresolvable'
        return
    fi
    icd_conf=$home/.config/environment.d/vulkan-hardware.conf
    if [[ ! -r $icd_conf ]] || ! grep -q '^VK_DRIVER_FILES=' "$icd_conf"; then
        fail vulkan-pool-fix "${icd_conf} does not set VK_DRIVER_FILES"
        return
    fi
    # Ptyxis absent: the library and the ICD override above are still required,
    # but the terminal wrapper and its overrides have nothing to launch.
    if ! have ptyxis; then
        pass vulkan-pool-fix "${library} loads and exports the pool fix; VK_DRIVER_FILES is set (Ptyxis is not installed)"
        return
    fi
    if [[ ! -x $wrapper ]]; then
        fail vulkan-pool-fix "${wrapper} is absent or not executable"
        return
    fi
    # Anchored to a real assignment: a plain substring match also accepts the
    # line commented out, which silently drops the fix the wrapper exists for.
    if ! grep -qE '^[[:space:]]*(export[[:space:]]+)?LD_PRELOAD=[^#]*vk_pool_fix\.so' "$wrapper" ||
       ! grep -qE '^[[:space:]]*(export[[:space:]]+)?VK_DRIVER_FILES=' "$wrapper"; then
        fail vulkan-pool-fix "${wrapper} does not set both LD_PRELOAD and VK_DRIVER_FILES"
        return
    fi
    # Ptyxis is D-Bus activated: without the service override the wrapper is
    # bypassed whenever the shell activates the terminal on the bus.
    service=$home/.local/share/dbus-1/services/org.gnome.Ptyxis.service
    if [[ ! -r $service ]] || ! grep -q "^Exec=${wrapper}" "$service"; then
        fail vulkan-pool-fix "D-Bus activation in ${service} does not run ${wrapper}"
        return
    fi
    desktop=$home/.local/share/applications/org.gnome.Ptyxis.desktop
    if [[ ! -r $desktop ]] || ! grep -q "^Exec=${wrapper}" "$desktop" ||
       grep '^Exec=' "$desktop" | grep -qv "^Exec=${wrapper}"; then
        fail vulkan-pool-fix "${desktop} does not route every Exec line through ${wrapper}"
        return
    fi
    pass vulkan-pool-fix 'vk_pool_fix.so loads and Ptyxis is launched through the wrapper with VK_DRIVER_FILES'
}

check_npu_runtime() {
    local dsp_dir=/usr/share/qcom/x1p42100/Qualcomm/Purwa-IoT-EVK/dsp/cdsp
    local conf_dir=/usr/share/qcom/conf.d
    local shim=/usr/local/lib64/qnn_soc_id_fix.so
    local mbn=/usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/qccdsp8380.mbn
    local binary model soc_id authcheck

    authcheck=$(dirname "${BASH_SOURCE[0]}")/lib/hexagon-authcheck.py

    if ! have ldconfig || ! ldconfig -p 2>/dev/null | grep -q 'libcdsprpc\.so'; then
        fail npu-runtime 'libcdsprpc.so does not resolve through ldconfig'
        return
    fi
    for binary in fastrpc_shell_3 fastrpc_shell_unsigned_3 libc++.so.1 libc++abi.so.1; do
        if [[ ! -f "$dsp_dir/$binary" ]]; then
            fail npu-runtime "Hexagon binary ${binary} is missing from ${dsp_dir}"
            return
        fi
    done
    model=$(tr -d '\0' </sys/firmware/devicetree/base/model 2>/dev/null || true)
    if [[ -z $model ]]; then
        fail npu-runtime 'the device-tree model is unreadable'
        return
    fi
    if ! grep -rqF -- "$model" "$conf_dir" 2>/dev/null; then
        fail npu-runtime "no ${conf_dir} YAML maps the device-tree model ${model}"
        return
    fi
    if [[ ! -f $shim ]]; then
        fail npu-runtime "${shim} is absent"
        return
    fi
    if preload_rejects "$shim"; then
        fail npu-runtime "${shim} is present but the dynamic loader rejects it"
        return
    fi
    soc_id=$(cat /sys/devices/soc0/soc_id 2>/dev/null || true)
    if [[ $soc_id == 555 ]]; then
        fail npu-runtime 'soc_id reads 555 without the shim, so a global SoC ID spoof is installed'
        return
    fi
    if [[ $soc_id != 635 ]]; then
        fail npu-runtime "soc_id is ${soc_id:-unreadable}, expected the real 635"
        return
    fi
    # The signed CDSP firmware whitelists the SHA-256 of every ELF segment it
    # will run; the helper is only present for in-tree runs, never a failure.
    if [[ -r $authcheck ]] && have python3 && [[ -r $mbn ]]; then
        if ! python3 "$authcheck" --mbn "$mbn" "$dsp_dir" >/dev/null 2>&1; then
            fail npu-runtime "the signed CDSP firmware does not authorize the binaries in ${dsp_dir}"
            return
        fi
        pass npu-runtime 'FastRPC library, Hexagon binaries authorized by the signed CDSP firmware, conf.d mapping, and the SoC ID shim are installed'
        return
    fi
    pass npu-runtime 'FastRPC library, Hexagon binaries, conf.d mapping, and the SoC ID shim are installed'
}

if ! require_audit_tools; then
    exit 2
fi

check_wifi
check_battery
check_remoteproc adsp adsp qcom_q6v5_adsp
check_remoteproc cdsp cdsp qcom_q6v5_pas
check_gpu
check_bluetooth
check_input keyboard '^[[:space:]]*Capabilities:.*keyboard'
check_input touchpad '^Device:.*[Tt]ouchpad'
check_backlight
check_hotkeys
check_audio
check_cpufreq
check_charge_limit
check_camera_rgb
check_color_control
check_lid_safety
check_vulkan_pool_fix
check_npu_runtime

if [[ $infrastructure_failures -ne 0 ]]; then
    exit 2
fi
exit "$failures"
