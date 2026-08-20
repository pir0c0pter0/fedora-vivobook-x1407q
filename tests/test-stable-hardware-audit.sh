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

expect 'lid safety does not require every sleep target to be masked' \
    grep -q 'for target in sleep.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target' "$audit"
for policy in HandleLidSwitch HandleLidSwitchExternalPower HandleLidSwitchDocked; do
    expect "lid safety does not validate effective ${policy}=lock" grep -q "$policy" "$audit"
done
expect 'lid safety does not inspect effective logind configuration' grep -q 'systemd-analyze cat-config' "$audit"

for function_name in check_wifi check_remoteproc check_gpu; do
    expect "${function_name} can pass without a readable current boot journal" \
        function_contains "$function_name" 'require_boot_journal'
done

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
printf '#!/usr/bin/env bash\nexit 1\n' > "$tmpdir/journalctl"
chmod +x "$tmpdir/journalctl"

post_output=$(PATH="$tmpdir:$PATH" bash "$audit" --post-reboot 2>&1 || true)
pre_output=$(PATH="$tmpdir:$PATH" bash "$audit" --pre-reboot 2>&1 || true)
expect 'post-reboot journal failure does not fail GPU' \
    grep -q '^FAIL gpu: current boot journal is unavailable$' <<<"$post_output"
expect 'pre-reboot journal failure does not skip GPU' \
    grep -q '^SKIP gpu: current boot journal is unavailable before reboot$' <<<"$pre_output"
expect 'GPU passes when the current boot journal is unavailable' \
    bash -c '! grep -q "^PASS gpu:" <<<"$1"' _ "$post_output"

printf '#!/usr/bin/env bash\nif [[ ! -e $JOURNAL_COUNTER ]]; then\n    : > "$JOURNAL_COUNTER"\n    exit 0\nfi\nexit 1\n' > "$tmpdir/journalctl"
chmod +x "$tmpdir/journalctl"
late_journal_output=$(JOURNAL_COUNTER="$tmpdir/journal-called" PATH="$tmpdir:$PATH" bash "$audit" --post-reboot 2>&1 || true)
expect 'a later journal failure lets GPU pass' \
    grep -q '^FAIL gpu: current boot journal is unavailable$' <<<"$late_journal_output"
expect 'GPU passes after a later journal failure' \
    bash -c '! grep -q "^PASS gpu:" <<<"$1"' _ "$late_journal_output"

mkdir -p "$tmpdir/drm/renderD128"
touch "$tmpdir/drm/renderD128/dev"
chmod 000 "$tmpdir/drm/renderD128/dev"
gpu_output=$(AUDIT_DRM_CLASS="$tmpdir/drm" bash "$audit" --post-reboot 2>&1 || true)
expect 'GPU accepts a render node whose dev attribute is unreadable' \
    grep -q '^FAIL gpu: no readable DRM render node is present$' <<<"$gpu_output"

if (( failures )); then
    exit 1
fi

echo 'PASS: stable hardware audit covers the approved scope and regression safety checks'
