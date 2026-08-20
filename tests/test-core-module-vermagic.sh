#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
kernel=$(uname -r)
kdir=${KDIR:-/lib/modules/${kernel}/build}
modules=(wcn-regulator-fix vivobook-kbd-fix vivobook-bl-fix vivobook-hotkey-fix)

cleanup() {
    local module
    for module in "${modules[@]}"; do
        make -s -C "$root/modules/${module}-1.0" KDIR="$kdir" clean >/dev/null 2>&1 || true
    done
}
trap cleanup EXIT

for module in "${modules[@]}"; do
    directory="$root/modules/${module}-1.0"
    make -s -C "$directory" KDIR="$kdir" clean all
    mapfile -t artifacts < <(find "$directory" -maxdepth 1 -type f -name '*.ko' -print)
    [[ ${#artifacts[@]} -eq 1 ]] || {
        echo "expected one artifact for $module, found ${#artifacts[@]}" >&2
        exit 1
    }
    vermagic=$(modinfo -F vermagic "${artifacts[0]}")
    [[ ${vermagic%% *} == "$kernel" ]] || {
        echo "wrong vermagic for $module: $vermagic" >&2
        exit 1
    }
    printf 'PASS build %s: %s\n' "$module" "$vermagic"
done
