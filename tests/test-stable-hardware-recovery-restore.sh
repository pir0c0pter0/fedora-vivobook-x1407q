#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
runner="$root/tools/recover-stable-hardware.sh"
restore="$root/tools/restore-stable-hardware-backup.sh"
[[ -f $restore ]] || {
    echo 'stable hardware recovery restore helper missing' >&2
    exit 1
}

test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT
kernel=7.2.0-x1407qa
expect_failure() {
    local message=$1
    shift
    if "$@"; then
        echo "$message" >&2
        exit 1
    fi
}
export VIVOBOOK_RECOVERY_LIBRARY_ONLY=1
export VIVOBOOK_RESTORE_LIBRARY_ONLY=1
export RECOVERY_ROOT="$test_root/recovery"
export RECOVERY_BUILD_STATE_ROOT="$test_root/system/build-root"
export RECOVERY_USR_SRC_ROOT="$test_root/system/usr-src"
export RECOVERY_DKMS_STATE_ROOT="$test_root/system/dkms"
export RECOVERY_MODULES_ROOT="$test_root/system/modules"
export RECOVERY_BOOT_ROOT="$test_root/system/boot"
export DRACUT_CONFIG_DIR="$test_root/system/dracut"
export MODULES_LOAD_CONFIG_DIR="$test_root/system/modules-load"

# shellcheck source=../tools/recover-stable-hardware.sh
source "$runner"
mkdir -p "$RECOVERY_BUILD_STATE_ROOT/module-build" \
    "$RECOVERY_USR_SRC_ROOT/wcn-regulator-fix-1.0" \
    "$RECOVERY_DKMS_STATE_ROOT/wcn-regulator-fix" \
    "$RECOVERY_MODULES_ROOT/$kernel/extra" "$RECOVERY_BOOT_ROOT" \
    "$DRACUT_CONFIG_DIR" "$MODULES_LOAD_CONFIG_DIR"
ln -s "$RECOVERY_BUILD_STATE_ROOT/module-build" "$RECOVERY_MODULES_ROOT/$kernel/build"
printf 'build-original\n' > "$RECOVERY_BUILD_STATE_ROOT/module-build/original"
printf 'source-original\n' > "$RECOVERY_USR_SRC_ROOT/wcn-regulator-fix-1.0/original"
printf 'dkms-original\n' > "$RECOVERY_DKMS_STATE_ROOT/wcn-regulator-fix/original"
printf 'module-original\n' > "$RECOVERY_MODULES_ROOT/$kernel/extra/original.ko"
printf 'metadata-original\n' > "$RECOVERY_MODULES_ROOT/$kernel/modules.dep"

acquire_recovery_lock
initialize_recovery_manifest
printf 'config-original\n' > "$DRACUT_CONFIG_DIR/qcom-remoteproc.conf"
backup_managed_path "$DRACUT_CONFIG_DIR/qcom-remoteproc.conf"
backup_managed_path "$DRACUT_CONFIG_DIR/qcom-gpu-firmware.conf"
ln -s target-before "$MODULES_LOAD_CONFIG_DIR/vivobook-core.conf"
backup_managed_path "$MODULES_LOAD_CONFIG_DIR/vivobook-core.conf"
modinfo() { return 1; }
capture_recovery_state "$kernel"
unset -f modinfo

printf 'changed\n' > "$RECOVERY_BUILD_STATE_ROOT/module-build/original"
printf 'new descendant\n' > "$RECOVERY_BUILD_STATE_ROOT/module-build/new-file"
printf 'changed\n' > "$RECOVERY_USR_SRC_ROOT/wcn-regulator-fix-1.0/original"
printf 'new descendant\n' > "$RECOVERY_DKMS_STATE_ROOT/wcn-regulator-fix/new-file"
mkdir -p "$RECOVERY_MODULES_ROOT/$kernel/updates"
printf 'must-disappear\n' > "$RECOVERY_MODULES_ROOT/$kernel/updates/new.ko"
printf 'config-changed\n' > "$DRACUT_CONFIG_DIR/qcom-remoteproc.conf"
printf 'created-after-backup\n' > "$DRACUT_CONFIG_DIR/qcom-gpu-firmware.conf"
rm "$MODULES_LOAD_CONFIG_DIR/vivobook-core.conf"
printf 'not-a-link\n' > "$MODULES_LOAD_CONFIG_DIR/vivobook-core.conf"

# shellcheck source=../tools/restore-stable-hardware-backup.sh
source "$restore"
restore_recovery_state "$kernel"

[[ $(<"$RECOVERY_BUILD_STATE_ROOT/module-build/original") == build-original &&
   ! -e $RECOVERY_BUILD_STATE_ROOT/module-build/new-file ]] || {
    echo 'round-trip did not exactly restore the build tree' >&2
    exit 1
}
[[ $(<"$RECOVERY_USR_SRC_ROOT/wcn-regulator-fix-1.0/original") == source-original &&
   ! -e $RECOVERY_DKMS_STATE_ROOT/wcn-regulator-fix/new-file ]] || {
    echo 'round-trip did not exactly restore source/DKMS roots' >&2
    exit 1
}
[[ ! -e $RECOVERY_MODULES_ROOT/$kernel/updates ]] || {
    echo 'round-trip did not remove a STATE CREATED root' >&2
    exit 1
}
[[ $(<"$DRACUT_CONFIG_DIR/qcom-remoteproc.conf") == config-original &&
   ! -e $DRACUT_CONFIG_DIR/qcom-gpu-firmware.conf ]] || {
    echo 'round-trip did not restore BACKUP/CREATED files' >&2
    exit 1
}
[[ -L $MODULES_LOAD_CONFIG_DIR/vivobook-core.conf &&
   $(readlink "$MODULES_LOAD_CONFIG_DIR/vivobook-core.conf") == target-before ]] || {
    echo 'round-trip did not recreate the recorded symlink' >&2
    exit 1
}

state_allowlist="$test_root/state-allowlist"
printf '%s\n' "$RECOVERY_DKMS_STATE_ROOT/wcn-regulator-fix" > "$state_allowlist"
mv "$RECOVERY_DKMS_STATE_ROOT" "$test_root/system/dkms-real"
ln -s "$test_root/system/dkms-real" "$RECOVERY_DKMS_STATE_ROOT"
expect_failure 'restore removal followed a symlinked mutable parent' \
    remove_allowlisted_path_no_follow "$RECOVERY_DKMS_STATE_ROOT/wcn-regulator-fix" "$state_allowlist"

printf 'corruption\n' >> "$RECOVERY_ROOT/backups/state-before.tar"
expect_failure 'restore accepted a checksum-corrupt state archive' \
    restore_recovery_state "$kernel"

echo 'PASS: recovery restore is allowlisted, no-follow, and exact round-trip'
