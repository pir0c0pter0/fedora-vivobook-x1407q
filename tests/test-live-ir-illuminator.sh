#!/usr/bin/env bash
set -euo pipefail

flash_name='c42d000.spmi:pmic@1:led-controller@ee00'
flash_device="/sys/bus/platform/devices/$flash_name"
spmi_parent=/sys/bus/spmi/devices/0-01
ir_led='/sys/class/leds/ir:torch'

[[ -e $flash_device ]] || {
	echo 'PM8550 flash platform device is absent' >&2
	exit 1
}

[[ $(realpath "$flash_device/..") == $(realpath "$spmi_parent") ]] || {
	echo 'PM8550 flash device is not parented by SPMI USID 0-01' >&2
	exit 1
}

[[ -e $ir_led/brightness ]] || {
	echo 'PM8550 IR torch did not register in the LED class' >&2
	exit 1
}

[[ $(<"$ir_led/brightness") == 0 ]] || {
	echo 'IR torch is on while HM1092 is idle' >&2
	exit 1
}

[[ -e /sys/bus/i2c/drivers/hm1092/9-0024 ]] || {
	echo 'HM1092 did not bind to the IR illuminator consumer' >&2
	exit 1
}

echo 'PASS: live PM8550 IR illuminator topology and idle safety'
