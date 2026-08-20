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
