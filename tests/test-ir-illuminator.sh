#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

cat >"$work_dir/sequence_test.c" <<'EOF'
#include <stdbool.h>
#include <stdio.h>
#include <string.h>

#include "hm1092_ir_sequence.h"

struct fake_hw {
	char events[16];
	size_t used;
	int sensor_on_error;
	int sensor_off_error;
	int ir_on_error;
	int ir_off_failures;
	int provider_off_error;
	int sensor_power_off_error;
	int sensor_power_restore_error;
};

static void record(struct fake_hw *hw, char event)
{
	hw->events[hw->used++] = event;
	hw->events[hw->used] = '\0';
}

static int sensor_set(void *context, bool on)
{
	struct fake_hw *hw = context;

	record(hw, on ? 'S' : 's');
	return on ? hw->sensor_on_error : hw->sensor_off_error;
}

static int illuminator_set(void *context, bool on)
{
	struct fake_hw *hw = context;

	record(hw, on ? 'I' : 'i');
	if (on)
		return hw->ir_on_error;
	if (hw->ir_off_failures > 0) {
		hw->ir_off_failures--;
		return -7;
	}
	return 0;
}

static int provider_force_off(void *context)
{
	struct fake_hw *hw = context;

	record(hw, 'P');
	return hw->provider_off_error;
}

static int sensor_power_off(void *context)
{
	struct fake_hw *hw = context;

	record(hw, 'X');
	return hw->sensor_power_off_error;
}

static int sensor_power_restore(void *context)
{
	struct fake_hw *hw = context;

	record(hw, 'R');
	return hw->sensor_power_restore_error;
}

static int expect(const char *name, const char *got, const char *want)
{
	if (!strcmp(got, want))
		return 0;

	fprintf(stderr, "%s: got event order '%s', expected '%s'\n",
		name, got, want);
	return 1;
}

int main(void)
{
	const struct hm1092_ir_ops ops = {
		.sensor_set = sensor_set,
		.illuminator_set = illuminator_set,
		.provider_force_off = provider_force_off,
		.sensor_power_off = sensor_power_off,
		.sensor_power_restore = sensor_power_restore,
	};
	struct fake_hw hw = { 0 };
	bool sensor_active;
	int failed = 0;

	if (hm1092_ir_start(&ops, &hw, &sensor_active) != 0 || !sensor_active)
		return 1;
	hm1092_ir_stop(&ops, &hw);
	failed |= expect("normal stop", hw.events, "SIis");

	hw = (struct fake_hw) { .sensor_on_error = -5 };
	if (hm1092_ir_start(&ops, &hw, &sensor_active) != -5 || sensor_active)
		return 1;
	failed |= expect("sensor start error", hw.events, "S");

	hw = (struct fake_hw) {
		.ir_on_error = -6,
		.ir_off_failures = 2,
	};
	if (hm1092_ir_start(&ops, &hw, &sensor_active) != -6 || sensor_active)
		return 1;
	failed |= expect("illuminator start error", hw.events, "SIiiis");

	hw = (struct fake_hw) {
		.ir_on_error = -6,
		.ir_off_failures = 3,
	};
	if (hm1092_ir_start(&ops, &hw, &sensor_active) != -7 || !sensor_active)
		return 1;
	failed |= expect("unresolved illuminator start error", hw.events,
			 "SIiii");

	hw = (struct fake_hw) { .ir_off_failures = 2 };
	if (hm1092_ir_stop(&ops, &hw) != 0)
		return 1;
	failed |= expect("transient illuminator stop error", hw.events, "iiis");

	hw = (struct fake_hw) { .ir_off_failures = 3 };
	if (hm1092_ir_stop(&ops, &hw) != -7)
		return 1;
	failed |= expect("persistent illuminator stop error", hw.events, "iii");

	hw = (struct fake_hw) { .sensor_off_error = -8 };
	if (hm1092_ir_stop(&ops, &hw) != -8)
		return 1;
	failed |= expect("sensor stop error", hw.events, "is");

	hw = (struct fake_hw) { .ir_off_failures = 3 };
	if (hm1092_ir_teardown_off(&ops, &hw) != 0)
		return 1;
	failed |= expect("provider teardown fallback", hw.events, "iiiP");

	hw = (struct fake_hw) {
		.ir_off_failures = 3,
		.provider_off_error = -9,
	};
	if (hm1092_ir_teardown_off(&ops, &hw) != -9)
		return 1;
	failed |= expect("unresolved provider teardown", hw.events, "iiiP");

	hw = (struct fake_hw) { .ir_off_failures = 3 };
	if (hm1092_ir_power_off(&ops, &hw) != 0)
		return 1;
	failed |= expect("provider fallback completes power off", hw.events,
			 "iiiPX");

	hw = (struct fake_hw) {
		.ir_off_failures = 3,
		.provider_off_error = -9,
	};
	if (hm1092_ir_power_off(&ops, &hw) != -9)
		return 1;
	failed |= expect("failed fallback blocks sensor power off", hw.events,
			 "iiiP");

	hw = (struct fake_hw) { .sensor_power_off_error = -10 };
	if (hm1092_ir_power_off(&ops, &hw) != -10)
		return 1;
	failed |= expect("failed power off restores active state", hw.events,
			 "iXR");

	hw = (struct fake_hw) {
		.sensor_power_off_error = -10,
		.sensor_power_restore_error = -11,
	};
	if (hm1092_ir_power_off(&ops, &hw) != -11)
		return 1;
	failed |= expect("power restore failure is reported", hw.events,
			 "iXR");

	return failed;
}
EOF

cc -std=c11 -Wall -Wextra -Werror \
    -I"$repo_root/modules/vivobook-ir-cam-1.0" \
    "$work_dir/sequence_test.c" -o "$work_dir/sequence_test"
"$work_dir/sequence_test"

driver="$repo_root/modules/vivobook-ir-cam-1.0/hm1092.c"
disable_function=$(sed -n '/^static int hm1092_disable_streams/,/^}/p' "$driver")
cleanup_function=$(sed -n '/^static void hm1092_ir_cleanup_worker/,/^}/p' "$driver")
remove_function=$(sed -n '/^static void hm1092_remove/,/^}/p' "$driver")

grep -qF 'if (!hm1092->streaming && !hm1092->cleanup_pending)' \
    <<<"$disable_function" || {
	echo 'stream stop is not idempotent after deferred cleanup' >&2
	exit 1
}

grep -qF 'hm1092_schedule_ir_cleanup(hm1092, true, true, false);' \
    <<<"$disable_function" || {
	echo 'failed stream stop does not schedule fail-safe IR cleanup' >&2
	exit 1
}

if grep -A1 -F 'hm1092_schedule_ir_cleanup(hm1092, true, true, false);' \
    <<<"$disable_function" | grep -qF 'return ret;'; then
	echo 'deferred stream stop leaves the V4L2 stream logically enabled' >&2
	exit 1
fi

grep -qF 'hm1092->streaming = false;' <<<"$cleanup_function" || {
	echo 'deferred stream cleanup does not clear streaming state' >&2
	exit 1
}

if grep -qF 'if (release_pm &&' <<<"$remove_function"; then
	echo 'remove leaks a retained runtime-PM reference after recovered errors' >&2
	exit 1
fi

cpp -nostdinc \
    -I"/lib/modules/$(uname -r)/build/include" \
    -I"/lib/modules/$(uname -r)/build/include/uapi" \
    -undef -x assembler-with-cpp \
    "$repo_root/modules/vivobook-cam-fix-2.0/vivobook_cam_phase1.dts" |
    dtc -@ -I dts -O dtb -o "$work_dir/camera.dtbo" -

ir_led_path=$(fdtget "$work_dir/camera.dtbo" /__symbols__ ir_illuminator)
camera_path=$(fdtget "$work_dir/camera.dtbo" /__symbols__ hm1092)

[[ $(fdtget -t u "$work_dir/camera.dtbo" "$ir_led_path" led-max-microamp) == 700000 ]] || {
	echo 'IR illuminator is not capped at the ASUS 700 mA factory value' >&2
	exit 1
}

[[ $(fdtget -t u "$work_dir/camera.dtbo" "$ir_led_path" led-sources) == '1 4' ]] || {
	echo 'IR illuminator is not routed to the validated PM8550 channels 1+4' >&2
	exit 1
}

[[ $(fdtget -t u "$work_dir/camera.dtbo" "$camera_path" leds) == \
   $(fdtget -t u "$work_dir/camera.dtbo" "$ir_led_path" phandle) ]] || {
	echo 'HM1092 does not reference the PM8550 IR illuminator' >&2
	exit 1
}

echo 'PASS: IR illuminator sequencing and electrical contract'
