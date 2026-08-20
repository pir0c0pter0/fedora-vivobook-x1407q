#!/usr/bin/env bash
set -euo pipefail

setup=setup-vivobook.sh
installer=install-battery-time-ext.sh

require() {
    local needle=$1 path=$2 message=$3
    grep -qF -- "$needle" "$path" || {
        echo "$message" >&2
        exit 1
    }
}

# Desktop settings must target the account that invoked sudo, never root.
require 'REAL_USER="${SUDO_USER:-$USER}"' "$setup" \
    'setup does not resolve the real desktop user from SUDO_USER'
require 'show-battery-percentage true' "$installer" \
    'battery installer does not enable the visible percentage'
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
require 'SETUP PENDENTE — ATIVAÇÃO GNOME NO PRÓXIMO LOGIN' "$setup" \
    'setup does not expose its final pending-login state'
if grep -qF 'SETUP COMPLETO — 16/16 MELHORIAS' "$setup"; then
    echo 'setup retains an unconditional 16/16 success claim' >&2
    exit 1
fi

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

# A desktop command is valid only against the real user's session bus.  The
# installer must queue a retry when no bus exists and verify each setting when
# one does exist.  These are deliberately behavioural tests using fake commands
# and a temporary UNIX socket; no host gsettings or GNOME state is touched.
require 'run_as_real_user_session()' "$setup" \
    'setup does not encapsulate real-user GNOME session execution'
require 'DBUS_SESSION_BUS_ADDRESS' "$setup" \
    'setup does not set the real-user D-Bus session address'
require '--activate-only' "$installer" \
    'installer has no next-login activation mode'
require 'install_pending_autostart()' "$installer" \
    'installer does not arrange an autostart retry'
require 'gsettings get org.gnome.desktop.interface show-battery-percentage' "$installer" \
    'installer does not verify the battery percentage'

fake_bin="$test_root/fake-bin"
runtime_dir="$test_root/runtime"
fake_home="$test_root/home"
mkdir -p "$fake_bin" "$runtime_dir" "$fake_home"
cat > "$fake_bin/gsettings" <<'EOF'
#!/usr/bin/env bash
[[ ${XDG_RUNTIME_DIR:-} == "${FAKE_RUNTIME_DIR:-}" ]] || exit 90
[[ ${DBUS_SESSION_BUS_ADDRESS:-} == "unix:path=${FAKE_RUNTIME_DIR:-}/bus" ]] || exit 91
case "$1" in
    set) exit "${FAKE_GSETTINGS_SET_RC:-0}" ;;
    get) printf '%s\n' "${FAKE_GSETTINGS_GET_VALUE:-true}"; exit 0 ;;
esac
exit 2
EOF
cat > "$fake_bin/gnome-extensions" <<'EOF'
#!/usr/bin/env bash
[[ ${XDG_RUNTIME_DIR:-} == "${FAKE_RUNTIME_DIR:-}" ]] || exit 90
[[ ${DBUS_SESSION_BUS_ADDRESS:-} == "unix:path=${FAKE_RUNTIME_DIR:-}/bus" ]] || exit 91
case "$1" in
    enable) exit "${FAKE_EXTENSION_ENABLE_RC:-0}" ;;
    info) printf 'State: %s\n' "${FAKE_EXTENSION_INFO_STATE:-ENABLED}"; exit 0 ;;
esac
exit 2
EOF
cat > "$fake_bin/sudo" <<'EOF'
#!/usr/bin/env bash
[[ $1 == -u ]] || exit 2
shift 2
exec "$@"
EOF
chmod +x "$fake_bin/gsettings" "$fake_bin/gnome-extensions" "$fake_bin/sudo"

run_installer() {
    PATH="$fake_bin:$PATH" \
        BATTERY_TIME_TEST_MODE=1 BATTERY_TIME_TEST_HOME="$fake_home" \
        BATTERY_TIME_RUNTIME_DIR="$runtime_dir" FAKE_RUNTIME_DIR="$runtime_dir" \
        SUDO_USER="$USER" \
        bash "$installer" "$@"
}

# No bus means no desktop command runs: queue the real user autostart and
# report the explicit pending status.
if run_installer; then
    echo 'installer claimed verified activation without a session bus' >&2
    exit 1
else
    status=$?
    [[ $status -eq 3 ]] || { echo "expected pending status 3, got $status" >&2; exit 1; }
fi
autostart="$fake_home/.config/autostart/battery-time-extension-activation.desktop"
status_file="$fake_home/.local/state/battery-time-extension/status"
[[ -f $autostart && $(<"$status_file") == pending-login ]] || {
    echo 'pending activation did not persist autostart/status state' >&2
    exit 1
}
require '--activate-only' "$autostart" 'autostart does not invoke activation-only mode'

REAL_RUNTIME_DIR="$runtime_dir"
REAL_DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime_dir/bus"
if run_as_real_user_session env >/dev/null; then
    echo 'session wrapper accepted a missing session bus' >&2
    exit 1
else
    status=$?
    [[ $status -eq 3 ]] || { echo "expected wrapper status 3, got $status" >&2; exit 1; }
fi

# A real UNIX socket allows setup's session wrapper and the installer to use
# the derived runtime/D-Bus values.  The fake commands then confirm success.
ncat -l -U "$runtime_dir/bus" >/dev/null 2>&1 &
bus_pid=$!
trap 'kill "$bus_pid" 2>/dev/null || true; rm -rf -- "$test_root"' EXIT
for _ in $(seq 1 30); do
    [[ -S "$runtime_dir/bus" ]] && break
    sleep 0.05
done
[[ -S "$runtime_dir/bus" ]] || { echo 'failed to create fake session bus' >&2; exit 1; }
session_env=$(PATH="$fake_bin:$PATH" run_as_real_user_session env)
grep -qxF "XDG_RUNTIME_DIR=$runtime_dir" <<<"$session_env" || {
    echo 'session wrapper did not export XDG_RUNTIME_DIR' >&2
    exit 1
}
grep -qxF "DBUS_SESSION_BUS_ADDRESS=unix:path=$runtime_dir/bus" <<<"$session_env" || {
    echo 'session wrapper did not export DBUS_SESSION_BUS_ADDRESS' >&2
    exit 1
}
run_installer --activate-only --user "$USER"
[[ ! -e $autostart && $(<"$status_file") == enabled ]] || {
    echo 'verified activation did not remove autostart and mark enabled' >&2
    exit 1
}

# With a bus, a percentage verification failure is fatal and leaves the retry
# autostart in place instead of reporting pending/success.
if FAKE_GSETTINGS_SET_RC=1 run_installer --activate-only --user "$USER"; then
    echo 'installer accepted a percentage failure in a live session' >&2
    exit 1
else
    status=$?
    [[ $status -ne 0 && $status -ne 3 ]] || {
        echo "expected fatal status, got $status" >&2
        exit 1
    }
fi
[[ -f $autostart && $(<"$status_file") == fatal ]] || {
    echo 'fatal activation did not retain autostart/fatal marker' >&2
    exit 1
}

echo 'PASS: firmware and battery desktop integration contract is explicit'
