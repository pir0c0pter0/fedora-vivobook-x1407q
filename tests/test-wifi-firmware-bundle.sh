#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

export VIVOBOOK_SETUP_LIBRARY_ONLY=1
# shellcheck source=../setup-vivobook.sh
source "$repo_root/setup-vivobook.sh"

declare -F stage_bundled_firmware >/dev/null || {
    echo 'setup has no isolated bundled firmware staging function' >&2
    exit 1
}

FIRMWARE_ROOT="$test_root/firmware-root"
mkdir -p "$FIRMWARE_ROOT"
stage_bundled_firmware

wifi_dir="$FIRMWARE_ROOT/ath11k/WCN6855/hw2.1"
declare -A expected_hashes=(
    [amss.bin]=00756e19aee2b5e6725f5029b7e6abea748caca0f53af5a7662cd32086dde4bd
    [board.bin]=aea74372b997b7b55c76c786b02f4670922489353923ef7d4a48dc83780f2c86
    [m3.bin]=9be43a8d9dc9454a629d65368df7ccd532d8768a0ac1fd935f57bcd37cbefecd
    [regdb.bin]=f3930af4bb8d2e23737a1ba4c68fa297652fd9e256851245f72d0bc660074936
)

for filename in "${!expected_hashes[@]}"; do
    path="$wifi_dir/$filename"
    [[ -f $path && ! -L $path ]] || {
        echo "bundled Wi-Fi firmware missing or not a regular file: $filename" >&2
        exit 1
    }
    actual=$(sha256sum "$path")
    [[ $actual == "${expected_hashes[$filename]} "* ]] || {
        echo "bundled Wi-Fi firmware hash mismatch: $filename" >&2
        exit 1
    }
done

blocked_root="$test_root/not-a-directory"
touch "$blocked_root"
if FIRMWARE_ROOT="$blocked_root" stage_bundled_firmware >/dev/null 2>&1; then
    echo 'bundled firmware staging reported success for an invalid destination' >&2
    exit 1
fi

echo 'PASS: bundled Wi-Fi firmware stages the proven X1407QA WCN6855 set'
