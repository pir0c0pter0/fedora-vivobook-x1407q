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
export RECOVERY_MODULES_CANONICAL_ROOT="$RECOVERY_MODULES_ROOT"
export RECOVERY_MODULES_ALIAS_ROOT="$RECOVERY_MODULES_ROOT"
export RECOVERY_BOOT_ROOT="$test_root/system/boot"
export DRACUT_CONFIG_DIR="$test_root/system/dracut"
export MODULES_LOAD_CONFIG_DIR="$test_root/system/modules-load"
export RECOVERY_SYSTEMD_DIR="$test_root/system/systemd"

# shellcheck source=../tools/recover-stable-hardware.sh
source "$runner"
mkdir -p "$RECOVERY_BUILD_STATE_ROOT/module-build" \
    "$RECOVERY_USR_SRC_ROOT/wcn-regulator-fix-1.0" \
    "$RECOVERY_DKMS_STATE_ROOT/wcn-regulator-fix" \
    "$RECOVERY_MODULES_ROOT/$kernel/extra" "$RECOVERY_BOOT_ROOT" \
    "$DRACUT_CONFIG_DIR" "$MODULES_LOAD_CONFIG_DIR" "$RECOVERY_SYSTEMD_DIR"
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
managed_list="$test_root/managed-paths"
: > "$managed_list"
write_expected_managed_paths "$kernel" "$managed_list"
while IFS= read -r managed_path; do
    backup_managed_path "$managed_path"
done < "$managed_list"
modinfo() { return 1; }
capture_recovery_state "$kernel"
unset -f modinfo

manifest_saved="$test_root/manifest-complete"
manifest_candidate="$test_root/manifest-candidate"
cp "$RECOVERY_MANIFEST" "$manifest_saved"
awk -F '\t' -v missing="$DRACUT_CONFIG_DIR/vivobook-core.conf" \
    '!(($1 == "BACKUP" || $1 == "CREATED" || $1 == "SYMLINK") && $2 == missing)' \
    "$manifest_saved" > "$manifest_candidate"
mv -Tf -- "$manifest_candidate" "$RECOVERY_MANIFEST"
expect_failure 'complete manifest accepted a missing managed-path record' validate_recovery_manifest
cp "$manifest_saved" "$RECOVERY_MANIFEST"
printf 'CREATED\t%s\t-\n' "$test_root/not-allowlisted" >> "$RECOVERY_MANIFEST"
expect_failure 'complete manifest accepted an extra managed-path record' validate_recovery_manifest
cp "$manifest_saved" "$RECOVERY_MANIFEST"

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

assert_original_state() {
    [[ $(<"$RECOVERY_BUILD_STATE_ROOT/module-build/original") == build-original &&
       ! -e $RECOVERY_BUILD_STATE_ROOT/module-build/new-file &&
       $(<"$RECOVERY_USR_SRC_ROOT/wcn-regulator-fix-1.0/original") == source-original &&
       $(<"$RECOVERY_DKMS_STATE_ROOT/wcn-regulator-fix/original") == dkms-original &&
       $(<"$DRACUT_CONFIG_DIR/qcom-remoteproc.conf") == config-original &&
       -L $MODULES_LOAD_CONFIG_DIR/vivobook-core.conf &&
       $(readlink "$MODULES_LOAD_CONFIG_DIR/vivobook-core.conf") == target-before ]] || return 1
    if find "$test_root/system" -name '*.restore-stage.*' -o -name '*.restore-rollback.*' | grep -q .; then
        return 1
    fi
}

(
    tar() {
        [[ $* == *'--extract'* ]] && return 73
        command tar "$@"
    }
    expect_failure 'injected archive extraction failure was accepted' restore_recovery_state "$kernel"
)
assert_original_state || { echo 'tar failure changed originals' >&2; exit 1; }

(
    cp() { return 74; }
    expect_failure 'injected backup copy failure was accepted' restore_recovery_state "$kernel"
)
assert_original_state || { echo 'cp failure changed originals' >&2; exit 1; }

(
    mktemp() { return 75; }
    expect_failure 'injected staging allocation failure was accepted' restore_recovery_state "$kernel"
)
assert_original_state || { echo 'mktemp failure changed originals' >&2; exit 1; }

(
    mutation_started=0
    sync_failed=0
    mv() { command mv "$@"; mutation_started=1; }
    sync() {
        if [[ $mutation_started == 1 && $sync_failed == 0 ]]; then
            sync_failed=1
            return 76
        fi
        command sync "$@"
    }
    expect_failure 'injected post-rename sync failure was accepted' restore_recovery_state "$kernel"
)
assert_original_state || { echo 'sync failure did not roll back originals' >&2; exit 1; }

(
    rename_count=0
    mv() {
        rename_count=$((rename_count + 1))
        [[ $rename_count -eq 4 ]] && return 77
        command mv "$@"
    }
    expect_failure 'injected atomic rename failure was accepted' restore_recovery_state "$kernel"
)
assert_original_state || { echo 'rename failure did not roll back originals' >&2; exit 1; }

printf 'corruption\n' >> "$RECOVERY_ROOT/backups/state-before.tar"
expect_failure 'restore accepted a checksum-corrupt state archive' \
    restore_recovery_state "$kernel"

echo 'PASS: recovery restore is allowlisted, no-follow, and exact round-trip'
