#!/usr/bin/env bash
set -euo pipefail

source_file=modules/wcn-regulator-fix-1.0/wcn_regulator_fix.c
[[ -f $source_file ]] || { echo 'repository Wi-Fi DKMS source missing' >&2; exit 1; }
for token in qcom,wcn6855-pmu vddrfa0p95 vddrfa1p9 vddpcie1p9 vddpmucx vddpmumx vddio max_regulator_retries; do
    grep -q "$token" "$source_file" || { echo "Wi-Fi fix missing: $token" >&2; exit 1; }
done
grep -q 'of_find_device_by_node' "$source_file" || {
    echo 'Wi-Fi fix does not reuse the active PMU platform device' >&2
    exit 1
}
if grep -q 'platform_device_alloc' "$source_file"; then
    echo 'Wi-Fi fix must not register a duplicate PMU platform device' >&2
    exit 1
fi
echo 'PASS: Wi-Fi module follows the active PMU supply contract'
