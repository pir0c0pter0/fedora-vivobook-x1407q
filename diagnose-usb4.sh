#!/bin/bash
# =============================================================================
# diagnose-usb4.sh — Collect current USB-C / Type-C / USB4 state
# ASUS Vivobook X1407QA (Snapdragon X)
# =============================================================================

set -euo pipefail

shopt -s nullglob

section() {
    echo
    echo "=== $* ==="
}

show_file() {
    local path="$1"
    local label="${2:-$1}"

    printf -- "-- %s --\n" "$label"
    if [[ -r "$path" ]]; then
        cat "$path"
    else
        echo "<missing>"
    fi
    echo
}

ucsi_cmd() {
    local cmd="$1"
    local root="/sys/kernel/debug/usb/ucsi/pmic_glink.ucsi.0"

    sudo test -e "${root}/command" || return 1
    sudo sh -c "printf '%s\n' ${cmd} > ${root}/command" >/dev/null 2>&1 || return 1
    sudo cat "${root}/response"
}

show_ucsi_debug() {
    local root="/sys/kernel/debug/usb/ucsi/pmic_glink.ucsi.0"
    local cap_hex cap_hi cap_lo features num_connectors num_alt_modes pd_version typec_version
    local current1 current2 supported1 supported2

    section "UCSI DebugFS"
    if ! sudo test -d "${root}"; then
        echo "${root} not present"
        return
    fi

    cap_hex="$(ucsi_cmd 0x6 || true)"
    if [[ -z "${cap_hex}" ]]; then
        echo "GET_CAPABILITY failed"
        return
    fi

    echo "GET_CAPABILITY: ${cap_hex}"
    cap_hi="${cap_hex#0x}"
    cap_lo="${cap_hi:16:16}"
    cap_hi="${cap_hi:0:16}"

    num_connectors="0x${cap_lo:6:2}"
    features="0x${cap_lo:2:2}${cap_lo:4:2}"
    num_alt_modes="0x${cap_hi:14:2}"
    pd_version="0x${cap_hi:4:2}${cap_hi:6:2}"
    typec_version="0x${cap_hi:0:2}${cap_hi:2:2}"

    echo "Decoded capability:"
    echo "  num_connectors=${num_connectors}"
    echo "  features=${features}"
    echo "  num_alt_modes=${num_alt_modes}"
    echo "  pd_version=${pd_version}"
    echo "  typec_version=${typec_version}"

    if (( features & 0x0004 )); then
        echo "  feature ALT_MODE_DETAILS=yes"
    else
        echo "  feature ALT_MODE_DETAILS=no"
    fi

    if (( features & 0x0008 )); then
        echo "  feature ALT_MODE_OVERRIDE=yes"
    else
        echo "  feature ALT_MODE_OVERRIDE=no"
    fi

    current1="$(ucsi_cmd 0x1000e || true)"
    current2="$(ucsi_cmd 0x2000e || true)"
    supported1="$(ucsi_cmd 0x1000d || true)"
    supported2="$(ucsi_cmd 0x2000d || true)"

    [[ -n "${current1}" ]] && echo "Connector 1 current CAM: 0x${current1: -2}"
    [[ -n "${current2}" ]] && echo "Connector 2 current CAM: 0x${current2: -2}"
    [[ -n "${supported1}" ]] && echo "Connector 1 supported CAM bitmap: 0x${supported1: -2}"
    [[ -n "${supported2}" ]] && echo "Connector 2 supported CAM bitmap: 0x${supported2: -2}"
}

show_port() {
    local port="$1"
    local name
    name="$(basename "$port")"
    local partner="/sys/class/typec/${name}-partner"

    section "${name}"
    show_file "${port}/data_role"
    show_file "${port}/power_role"
    show_file "${port}/power_operation_mode"
    show_file "${port}/preferred_role"
    show_file "${port}/usb_capability"
    show_file "${port}/orientation"
    show_file "${port}/vconn_source"
    show_file "${port}/waiting_for_supplier"

    for alt in "${port}/${name}".*; do
        [[ -d "$alt" ]] || continue
        show_file "${alt}/active" "$(basename "$alt") active"
        show_file "${alt}/svid" "$(basename "$alt") svid"
        show_file "${alt}/vdo" "$(basename "$alt") vdo"
        show_file "${alt}/mode" "$(basename "$alt") mode"
    done

    if [[ -d "$partner" ]]; then
        section "${name} partner"
        show_file "${partner}/accessory_mode"
        show_file "${partner}/number_of_alternate_modes"
        show_file "${partner}/supports_usb_power_delivery"
        show_file "${partner}/usb_power_delivery_revision"
        show_file "${partner}/uevent"
    fi
}

section "System"
echo "Date:   $(date --iso-8601=seconds)"
echo "Kernel: $(uname -r)"
echo "Host:   $(hostname)"

section "Kernel Modules"
lsmod | rg 'ucsi|typec|ps883|thunderbolt|pmic_glink|phy_qcom_qmp_combo|usb4' || true

section "USB4 Bus"
if [[ -d /sys/bus/usb4 ]]; then
    ls -la /sys/bus/usb4
else
    echo "/sys/bus/usb4 not present"
fi

section "Type-C Class"
if [[ -d /sys/class/typec ]]; then
    ls -la /sys/class/typec
else
    echo "/sys/class/typec not present"
fi

for port in /sys/class/typec/port[0-9]*; do
    [[ -L "$port" ]] || continue
    [[ "$(basename "$port")" =~ ^port[0-9]+$ ]] || continue
    show_port "$port"
done

section "USB Topology"
lsusb -t || true

section "USB Devices"
lsusb || true

show_ucsi_debug

section "PMIC / Type-C Journal"
journalctl -b --no-pager 2>/dev/null | \
    rg 'pmic_glink|ucsi|typec|thunderbolt|usb4|ps883|billboard|altmode|a600000\.usb|a800000\.usb' || true
