#!/usr/bin/env bash
set -euo pipefail

out="${1:-$PWD/hm1092-evidence-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$out"

run_capture() {
    local name="$1"; shift
    { printf '$'; printf ' %q' "$@"; printf '\n'; "$@"; } >"$out/$name.txt" 2>&1 || true
}

run_capture dmi sh -c 'for f in /sys/class/dmi/id/{sys_vendor,product_name,board_name,bios_version}; do printf "%s: " "$f"; cat "$f" 2>/dev/null; done'
run_capture uname uname -a
run_capture dmesg dmesg
run_capture modules lsmod
run_capture media media-ctl -p
run_capture video v4l2-ctl --list-devices
run_capture i2c i2cdetect -l
run_capture remoteproc sh -c 'find /sys/class/remoteproc -maxdepth 3 -type f -print -exec sed -n "1,20p" {} \;'
run_capture firmware sh -c 'find /usr/lib/firmware /lib/firmware -type f \( -iname "*hm1092*" -o -iname "*camera*" -o -iname "*qcom0c99*" \) -print 2>/dev/null'
run_capture devicetree sh -c 'find /sys/firmware/devicetree/base -type f -print0 2>/dev/null | xargs -0 strings 2>/dev/null | grep -iE "HM1092|QCOM0C99|CameraAuxSensor|13041043|Spectra"'

grep -RaiE 'HM1092|QCOM0C99|CameraAuxSensor|13041043|Spectra' "$out" >"$out/matches.txt" 2>/dev/null || true
tar -C "$(dirname "$out")" -czf "$out.tar.gz" "$(basename "$out")"
printf 'Evidence saved to %s and %s.tar.gz\n' "$out" "$out"
