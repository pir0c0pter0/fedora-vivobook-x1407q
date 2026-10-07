#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
helper="${repo_root}/tools/vivobook-battery-freq-cap"
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

mkdir -p \
    "$test_root/power/qcom-battmgr-ac" \
    "$test_root/power/qcom-battmgr-usb" \
    "$test_root/cpu/policy0" \
    "$test_root/cpu/policy4"
printf '0\n' > "$test_root/power/qcom-battmgr-ac/online"
printf '0\n' > "$test_root/power/qcom-battmgr-usb/online"
printf '2956800\n' > "$test_root/cpu/policy0/scaling_max_freq"
printf '2956800\n' > "$test_root/cpu/policy4/scaling_max_freq"

VIVOBOOK_POWER_SUPPLY_ROOT="$test_root/power" \
VIVOBOOK_CPUFREQ_ROOT="$test_root/cpu" \
    "$helper"

for policy in policy0 policy4; do
    [[ $(<"$test_root/cpu/$policy/scaling_max_freq") == 2380800 ]]
done

printf '1\n' > "$test_root/power/qcom-battmgr-usb/online"
VIVOBOOK_POWER_SUPPLY_ROOT="$test_root/power" \
VIVOBOOK_CPUFREQ_ROOT="$test_root/cpu" \
    "$helper"

for policy in policy0 policy4; do
    [[ $(<"$test_root/cpu/$policy/scaling_max_freq") == 2956800 ]]
done

echo 'PASS: battery frequency cap selects the expected battery and external-power limits'
