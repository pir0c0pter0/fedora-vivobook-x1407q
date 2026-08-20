#!/usr/bin/env bash
set -euo pipefail

source_file=modules/wcn-regulator-fix-1.0/wcn_regulator_fix.c
[[ -f $source_file ]] || { echo 'repository Wi-Fi DKMS source missing' >&2; exit 1; }
for token in qcom,wcn6855-pmu vddaon vddio vddpcie1p3 vddpcie1p9 vddpmu vddpmucx vddpmumx vddrfa0p95 vddrfa1p3 vddrfa1p9 max_regulator_retries; do
    grep -q "$token" "$source_file" || { echo "Wi-Fi fix missing: $token" >&2; exit 1; }
done
for obsolete_supply in vddpcie0p9 vddpcie1p8 vddrfa0p8 vddrfa1p2 vddrfa1p8 vddrfacmn vddwlcx vddwlmx; do
    if grep -q "\.supply = \"${obsolete_supply}\"" "$source_file"; then
        echo "Wi-Fi fix retains obsolete supply: $obsolete_supply" >&2
        exit 1
    fi
done
[[ $(grep -c '\.supply = ' "$source_file") -eq 10 ]] || {
    echo 'Wi-Fi fix must request exactly the ten PMU supplies' >&2
    exit 1
}
grep -q 'of_find_device_by_node' "$source_file" || {
    echo 'Wi-Fi fix does not reuse the active PMU platform device' >&2
    exit 1
}
if grep -q 'platform_device_alloc' "$source_file"; then
    echo 'Wi-Fi fix must not register a duplicate PMU platform device' >&2
    exit 1
fi
echo 'PASS: Wi-Fi module follows the active PMU supply contract'
