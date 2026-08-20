#!/usr/bin/env bash
set -euo pipefail

setup=setup-vivobook.sh
installer=install-battery-time-ext.sh

require() {
    local needle=$1 path=$2 message=$3
    grep -qF "$needle" "$path" || {
        echo "$message" >&2
        exit 1
    }
}

# Desktop settings must target the account that invoked sudo, never root.
require 'REAL_USER="${SUDO_USER:-$USER}"' "$setup" \
    'setup does not resolve the real desktop user from SUDO_USER'
require 'show-battery-percentage true' "$setup" \
    'setup does not enable the visible battery percentage'
require 'sudo -u "${REAL_USER}"' "$setup" \
    'setup does not invoke desktop work as the real user'
require 'install-battery-time-ext.sh' "$setup" \
    'setup does not invoke the battery extension installer'
require 'gnome-extensions enable "$EXT_UUID"' "$installer" \
    'installer does not explicitly enable the extension'
require 'gnome-extensions info "$EXT_UUID"' "$installer" \
    'installer does not verify the extension state'
require 'pending-login' "$installer" \
    'installer claims success instead of an honest pending-login state'
require 'if ! resolve_kernel_requested_firmware; then' "$setup" \
    'setup does not gate publication on required firmware resolution'
require 'abortando sem publicar um initramfs' "$setup" \
    'setup can still claim success with missing required firmware'

# Firmware paths are selected from actual files, not hard-coded compression
# assumptions. Exercise both variants without touching host firmware.
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT
export VIVOBOOK_SETUP_LIBRARY_ONLY=1
# shellcheck source=../setup-vivobook.sh
source "$setup"
export FIRMWARE_ROOT="$test_root"

mkdir -p "$FIRMWARE_ROOT/qcom" "$FIRMWARE_ROOT/qca"
touch "$FIRMWARE_ROOT/qcom/compressed.bin.xz" "$FIRMWARE_ROOT/qca/plain.tlv"

[[ $(resolve_firmware_variant qcom/compressed.bin) == \
    "$FIRMWARE_ROOT/qcom/compressed.bin.xz" ]] || {
    echo 'resolver did not select the compressed firmware variant' >&2
    exit 1
}
[[ $(resolve_firmware_variant qca/plain.tlv) == \
    "$FIRMWARE_ROOT/qca/plain.tlv" ]] || {
    echo 'resolver did not select the plain firmware variant' >&2
    exit 1
}
DRACUT_CONFIG_DIR="$test_root/dracut"
RESOLVED_GPU_FIRMWARE=("$FIRMWARE_ROOT/qcom/compressed.bin.xz")
RESOLVED_BLUETOOTH_FIRMWARE=("$FIRMWARE_ROOT/qca/plain.tlv")
write_gpu_bluetooth_firmware_dracut_config
gpu_config="$DRACUT_CONFIG_DIR/qcom-gpu-firmware.conf"
require "$FIRMWARE_ROOT/qcom/compressed.bin.xz" "$gpu_config" \
    'dracut config did not receive the selected compressed path'
require "$FIRMWARE_ROOT/qca/plain.tlv" "$gpu_config" \
    'dracut config did not receive the selected plain path'

if resolve_firmware_variant qca/missing.tlv >/dev/null 2>&1; then
    echo 'resolver accepted a required firmware path that is absent' >&2
    exit 1
fi

require 'qcdxkmsucpurwa.mbn' "$setup" \
    'ASUS ZAP firmware is not part of the verified firmware contract'
require 'hpbtfw21.tlv' "$setup" \
    'Bluetooth firmware alias is not part of the verified firmware contract'
require 'hpnv21.bin' "$setup" \
    'Bluetooth NVM alias is not part of the verified firmware contract'
require 'xz -dc' "$setup" \
    'setup does not document the controlled compatibility-copy mechanism'
require 'controlled modprobe' "$setup" \
    'compressed Bluetooth fallback is not guarded by a controlled modprobe test'

echo 'PASS: firmware and battery desktop integration contract is explicit'
