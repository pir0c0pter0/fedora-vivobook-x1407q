#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
parameter=/sys/module/hm1092/parameters/ir_led_brightness
led=/sys/class/leds/ir:torch/brightness
pmic_registers=${PMIC_REGISTERS:-/sys/kernel/debug/regmap/0-01/registers}
capture_frames=${IR_CAPTURE_FRAMES:-30}
dark_png=$(mktemp /tmp/ir-dark-XXXXXX.png)
lit_png=$(mktemp /tmp/ir-lit-XXXXXX.png)
dark_after_png=$(mktemp /tmp/ir-dark-after-XXXXXX.png)
capture_pid=
capture_log=
capture_output=

[[ $EUID -eq 0 ]] || {
	echo 'live IR illumination comparison must run as root' >&2
	exit 1
}
[[ -w $parameter && -w $led && -r $pmic_registers ]] || {
	echo 'HM1092 brightness controls are unavailable' >&2
	exit 1
}

original_brightness=$(<"$parameter")
cleanup()
{
	local status=$? attempt off_confirmed=0

	trap - EXIT HUP INT TERM
	if [[ -n $capture_pid ]]; then
		kill -TERM "$capture_pid" 2>/dev/null || true
		wait "$capture_pid" 2>/dev/null || true
	fi
	for attempt in 1 2 3; do
		printf '0\n' > "$led" 2>/dev/null || true
		sleep 0.05
		if assert_pmic_off >/dev/null 2>&1; then
			off_confirmed=1
			break
		fi
	done
	if ((off_confirmed == 0)); then
		echo 'CRITICAL: failed to prove PM8550 IR hardware off during cleanup' >&2
		assert_pmic_off >&2 || true
		status=1
	fi
	printf '%s\n' "$original_brightness" > "$parameter" 2>/dev/null || true
	[[ -z $capture_log ]] || rm -f "$capture_log"
	rm -f "$dark_png" "$lit_png" "$dark_after_png"
	exit "$status"
}

read_pmic_enable()
{
	awk '
		$1 == "ee46:" { module = $2 }
		$1 == "ee4e:" { channels = $2 }
		END { print module, channels }
	' "$pmic_registers"
}

assert_pmic_off()
{
	local module_hex channel_hex module_value channel_value

	read -r module_hex channel_hex < <(read_pmic_enable)
	[[ $module_hex =~ ^[0-9a-fA-F]{2}$ &&
	   $channel_hex =~ ^[0-9a-fA-F]{2}$ ]] || {
		echo "PM8550 enable readback unavailable: module=$module_hex channels=$channel_hex" >&2
		return 1
	}
	module_value=$((16#$module_hex))
	channel_value=$((16#$channel_hex))
	(( (module_value & 0x80) == 0 && (channel_value & 0x09) == 0 )) || {
		echo "PM8550 IR hardware remained enabled: module=$module_hex channels=$channel_hex" >&2
		return 1
	}
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

capture_at_brightness()
{
	local brightness=$1 output_png=$2
	local module_hex channel_hex module_value channel_value
	local saw_on=0 saw_valid=0

	printf '%s\n' "$brightness" > "$parameter"
	capture_log=$(mktemp /tmp/ir-capture-log-XXXXXX)
	"$repo_root/tools/ir-camera-capture.sh" "$capture_frames" "$output_png" \
		>"$capture_log" 2>&1 &
	capture_pid=$!
	while kill -0 "$capture_pid" 2>/dev/null; do
		read -r module_hex channel_hex < <(read_pmic_enable)
		if [[ $module_hex =~ ^[0-9a-fA-F]{2}$ &&
		      $channel_hex =~ ^[0-9a-fA-F]{2}$ ]]; then
			saw_valid=1
			module_value=$((16#$module_hex))
			channel_value=$((16#$channel_hex))
			if ((brightness == 0 &&
			      ((module_value & 0x80) != 0 ||
			       (channel_value & 0x09) != 0))); then
				kill -TERM "$capture_pid" 2>/dev/null || true
				wait "$capture_pid" 2>/dev/null || true
				capture_pid=
				rm -f "$capture_log"
				capture_log=
				echo "PM8550 IR enable bit active during brightness-0 capture: module=$module_hex channels=$channel_hex" >&2
				return 1
			fi
			if (( (module_value & 0x80) != 0 &&
			      (channel_value & 0x09) == 0x09 )); then
				saw_on=1
			fi
		fi
		sleep 0.01
	done
	if ! wait "$capture_pid"; then
		capture_pid=
		cat "$capture_log" >&2
		rm -f "$capture_log"
		capture_log=
		return 1
	fi
	capture_pid=
	capture_output=$(<"$capture_log")
	rm -f "$capture_log"
	capture_log=
	[[ $(<"$led") == 0 ]] || {
		echo "IR torch remained on after brightness-$brightness capture" >&2
		return 1
	}
	assert_pmic_off
	if ((saw_valid == 0)); then
		echo 'PM8550 enable readback was unavailable throughout capture' >&2
		return 1
	fi
	if ((brightness > 0 && saw_on == 0)); then
		echo 'PM8550 enable bits were never observed during illuminated capture' >&2
		return 1
	fi
}

stat_value()
{
	local output=$1 key=$2

	awk -v key="$key" '
		/^IR_STATS / {
			for (field = 2; field <= NF; field++) {
				split($field, pair, "=")
				if (pair[1] == key) print pair[2]
			}
		}
	' <<< "$output"
}

capture_at_brightness 0 "$dark_png"
dark_output=$capture_output
capture_at_brightness 255 "$lit_png"
lit_output=$capture_output
capture_at_brightness 0 "$dark_after_png"
dark_after_output=$capture_output
printf '%s\n' 'IR brightness 0:' "$dark_output"
printf '%s\n' 'IR brightness 255:' "$lit_output"
printf '%s\n' 'IR brightness 0 after illumination:' "$dark_after_output"

dark_mean=$(stat_value "$dark_output" mean)
dark_p95=$(stat_value "$dark_output" p95)
lit_mean=$(stat_value "$lit_output" mean)
lit_p95=$(stat_value "$lit_output" p95)
dark_after_mean=$(stat_value "$dark_after_output" mean)
dark_after_p95=$(stat_value "$dark_after_output" p95)
[[ -n $dark_mean && -n $dark_p95 && -n $lit_mean && -n $lit_p95 &&
   -n $dark_after_mean && -n $dark_after_p95 ]] || {
	echo 'IR frame statistics are incomplete' >&2
	exit 1
}

awk -v dark_mean="$dark_mean" -v lit_mean="$lit_mean" \
	-v dark_p95="$dark_p95" -v lit_p95="$lit_p95" \
	-v dark_after_mean="$dark_after_mean" -v dark_after_p95="$dark_after_p95" '
	BEGIN {
		if (lit_mean < dark_mean * 1.25 || lit_mean < dark_mean + 3 ||
		    lit_p95 < dark_p95 + 10 ||
		    dark_after_mean > dark_mean * 1.5 + 2 ||
		    dark_after_mean > lit_mean / 1.25 ||
		    dark_after_p95 > dark_p95 + 10 ||
		    dark_after_p95 > lit_p95 - 10)
			exit 1
	}
' || {
	echo "IR optical transition invalid: mean ${dark_mean}->${lit_mean}->${dark_after_mean}, p95 ${dark_p95}->${lit_p95}->${dark_after_p95}" >&2
	exit 1
}

echo "PASS: IR optical gain reversed after off (mean ${dark_mean}->${lit_mean}->${dark_after_mean}, p95 ${dark_p95}->${lit_p95}->${dark_after_p95})"
