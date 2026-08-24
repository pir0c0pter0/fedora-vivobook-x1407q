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

failures=0

expect() {
    local message=$1
    shift
    if ! "$@"; then
        echo "$message" >&2
        failures=1
    fi
}

function_contains() {
    local function_name=$1 pattern=$2

    awk -v function_name="$function_name" -v pattern="$pattern" '
        $0 ~ "^" function_name "\\(\\)" { inside = 1 }
        inside && $0 ~ pattern { found = 1 }
        inside && /^}/ { exit(found ? 0 : 1) }
        END { exit(found ? 0 : 1) }
    ' "$audit"
}

expect 'lid safety does not require sleep/suspend targets to be unmasked' \
    grep -q 'for target in sleep.target suspend.target' "$audit"
expect 'lid safety does not keep hibernate-family targets masked' \
    grep -q 'for target in hibernate.target hybrid-sleep.target suspend-then-hibernate.target' "$audit"
for policy in HandleLidSwitch HandleLidSwitchExternalPower HandleLidSwitchDocked; do
    expect "lid safety does not validate effective ${policy}=suspend" grep -q "$policy" "$audit"
done
expect 'lid safety does not require the effective lid policy to be suspend' \
    grep -qF 'expected suspend' "$audit"
expect 'lid safety does not validate the selected s2idle mem_sleep mode' \
    grep -qF '/sys/power/mem_sleep' "$audit"
expect 'audio audit lacks the ALSA fallback for session-less runs' \
    grep -qF 'ALSA card present (no user session bus)' "$audit"
expect 'lid safety does not inspect effective logind configuration' grep -q 'systemd-analyze cat-config' "$audit"

for function_name in check_wifi check_remoteproc check_gpu; do
    expect "${function_name} can pass without a readable current boot journal" \
        function_contains "$function_name" 'require_boot_journal'
done

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
printf '#!/usr/bin/env bash\nexit 1\n' > "$tmpdir/journalctl"
chmod +x "$tmpdir/journalctl"

set +e
post_output=$(PATH="$tmpdir:$PATH" bash "$audit" --post-reboot 2>&1)
post_status=$?
pre_output=$(PATH="$tmpdir:$PATH" bash "$audit" --pre-reboot 2>&1)
pre_status=$?
set -e
expect 'post-reboot journal infrastructure failure does not exit 2' \
    test "$post_status" -eq 2
expect 'pre-reboot journal infrastructure failure does not exit 2' \
    test "$pre_status" -eq 2
expect 'post-reboot journal failure is not classified as infrastructure' \
    grep -q '^ERROR infrastructure: current boot journal is unavailable$' <<<"$post_output"
expect 'pre-reboot journal failure is not classified as infrastructure' \
    grep -q '^ERROR infrastructure: current boot journal is unavailable$' <<<"$pre_output"
expect 'GPU passes when the current boot journal is unavailable' \
    bash -c '! grep -q "^PASS gpu:" <<<"$1"' _ "$post_output"

printf '#!/usr/bin/env bash\nif [[ ! -e $JOURNAL_COUNTER ]]; then\n    : > "$JOURNAL_COUNTER"\n    exit 0\nfi\nexit 1\n' > "$tmpdir/journalctl"
chmod +x "$tmpdir/journalctl"
set +e
late_journal_output=$(JOURNAL_COUNTER="$tmpdir/journal-called" PATH="$tmpdir:$PATH" bash "$audit" --post-reboot 2>&1)
late_status=$?
set -e
expect 'a later journal failure is not infrastructure status 2' test "$late_status" -eq 2
expect 'a later journal failure is not classified as infrastructure' \
    grep -q '^ERROR infrastructure: current boot journal is unavailable$' <<<"$late_journal_output"
expect 'GPU passes after a later journal failure' \
    bash -c '! grep -q "^PASS gpu:" <<<"$1"' _ "$late_journal_output"

set +e
missing_tool_output=$(AUDIT_TEST_MODE=1 AUDIT_TEST_MISSING_COMMAND=nmcli \
    bash "$audit" --pre-reboot 2>&1)
missing_tool_status=$?
set -e
expect 'missing required audit tool does not exit 2' test "$missing_tool_status" -eq 2
expect 'missing required audit tool is not reported as infrastructure' \
    grep -q '^ERROR infrastructure: required command is unavailable: nmcli$' \
    <<<"$missing_tool_output"

mkdir -p "$tmpdir/drm/renderD128"
touch "$tmpdir/drm/renderD128/dev"
chmod 000 "$tmpdir/drm/renderD128/dev"
gpu_output=$(AUDIT_DRM_CLASS="$tmpdir/drm" bash "$audit" --post-reboot 2>&1 || true)
expect 'GPU accepts a render node whose dev attribute is unreadable' \
    grep -q '^FAIL gpu: no readable DRM render node is present$' <<<"$gpu_output"

expect 'remoteproc state helper discards the state instead of printing it' \
    grep -q 'cat "\$remoteproc/state"' "$audit"
expect 'battery audit still requires the optional capacity attribute' \
    bash -c '! grep -q '\''for attribute in capacity status energy_now power_now'\'' "$1"' _ "$audit"
expect 'battery audit rejects the decimal percentage emitted by UPower' \
    grep -qF '([.][0-9]+)?%' "$audit"
expect 'input audit has no privileged read-only fallback for /dev/input' \
    grep -q 'sudo -n libinput list-devices' "$audit"

if (( failures )); then
    exit 1
fi

echo 'PASS: stable hardware audit covers the approved scope and regression safety checks'
