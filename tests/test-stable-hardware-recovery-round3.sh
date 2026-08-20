#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
runner="$root/tools/recover-stable-hardware.sh"
restore="$root/tools/restore-stable-hardware-backup.sh"
case_name=${1:-all}
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

export VIVOBOOK_RECOVERY_LIBRARY_ONLY=1 VIVOBOOK_RESTORE_LIBRARY_ONLY=1
export RECOVERY_ROOT="$test_root/recovery"
source "$runner"
source "$restore"

expect_failure() {
    local message=$1
    shift
    if "$@"; then
        echo "$message" >&2
        exit 1
    fi
}

case_usrmerge() {
    declare -F verify_modules_root_layout >/dev/null || {
        echo 'canonical modules-root verifier missing' >&2
        exit 1
    }
    local layout="$test_root/usrmerge" kernel=7.2.0-x1407qa expected="$test_root/expected"
    mkdir -p "$layout/usr/lib/modules/$kernel/extra" "$layout/lib"
    ln -s ../usr/lib/modules "$layout/lib/modules"
    RECOVERY_MODULES_CANONICAL_ROOT="$layout/usr/lib/modules"
    RECOVERY_MODULES_ALIAS_ROOT="$layout/lib/modules"
    RECOVERY_MODULES_ROOT=$RECOVERY_MODULES_CANONICAL_ROOT
    verify_modules_root_layout
    : > "$expected"
    write_expected_state_paths "$kernel" "$expected"
    grep -Fq "$RECOVERY_MODULES_CANONICAL_ROOT/$kernel/extra" "$expected"
    if grep -Fq "$RECOVERY_MODULES_ALIAS_ROOT/$kernel" "$expected"; then
        echo 'state paths retained the lexical /lib alias' >&2
        exit 1
    fi
    printf 'module\n' > "$RECOVERY_MODULES_CANONICAL_ROOT/$kernel/extra/wcn_regulator_fix.ko"
    [[ $(canonicalize_installed_module_path \
        "$RECOVERY_MODULES_ALIAS_ROOT/$kernel/extra/wcn_regulator_fix.ko") == \
        "$RECOVERY_MODULES_CANONICAL_ROOT/$kernel/extra/wcn_regulator_fix.ko" ]]
    rm "$RECOVERY_MODULES_ALIAS_ROOT"
    ln -s ../wrong/modules "$RECOVERY_MODULES_ALIAS_ROOT"
    expect_failure 'modules alias resolving outside canonical was accepted' verify_modules_root_layout
}

case_mounts() {
    declare -F preflight_restore_mounts >/dev/null || {
        echo 'restore mount-boundary verifier missing' >&2
        exit 1
    }
    local target="$test_root/mount-root" allowlist="$test_root/mount-allowlist"
    mkdir -p "$RECOVERY_ROOT" "$target"
    printf '%s\n' "$target" > "$allowlist"
    findmnt() { printf '/\n%s/nested-bind\n' "$target"; }
    expect_failure 'nested bind mount was accepted' preflight_restore_mounts "$allowlist"
    findmnt() { printf '/\n%s\n' "$target"; }
    expect_failure 'exact mountpoint was accepted' preflight_restore_mounts "$allowlist"
    findmnt() { printf '/\n'; }
    preflight_restore_mounts "$allowlist"
    unset -f findmnt
}

case_grouped_space() {
    declare -F recovery_filesystem_info >/dev/null || {
        echo 'grouped filesystem accounting missing' >&2
        exit 1
    }
    local list="$test_root/space-list"
    mkdir -p "$RECOVERY_ROOT"
    : > "$list"
    RECOVERY_BUILD_STATE_ROOT="$test_root/build-fs/root"
    RECOVERY_BOOT_ROOT="$test_root/boot-fs"
    RECOVERY_BUILD_SCRATCH_BYTES=200
    RECOVERY_CANDIDATE_SCRATCH_BYTES=300
    RECOVERY_SPACE_MARGIN_BYTES=50
    recovery_archive_apparent_bytes() { printf '100\n'; }
    recovery_filesystem_info() {
        case "$1" in
            "$RECOVERY_ROOT") printf 'recovery\t149\n' ;;
            "$RECOVERY_BUILD_STATE_ROOT") printf 'build\t250\n' ;;
            "$RECOVERY_BOOT_ROOT") printf 'boot\t350\n' ;;
            *) return 1 ;;
        esac
    }
    expect_failure 'separate recovery filesystem shortage was accepted' \
        preflight_recovery_disk_space 7.2.0-x1407qa "$list"
    recovery_filesystem_info() {
        case "$1" in
            "$RECOVERY_ROOT") printf 'recovery\t150\n' ;;
            "$RECOVERY_BUILD_STATE_ROOT") printf 'build\t250\n' ;;
            "$RECOVERY_BOOT_ROOT") printf 'boot\t350\n' ;;
            *) return 1 ;;
        esac
    }
    preflight_recovery_disk_space 7.2.0-x1407qa "$list"

    (
        printf 'placeholder\n' > "$RECOVERY_MANIFEST"
        validate_recovery_manifest() { :; }
        recovery_archive_apparent_bytes() { return 88; }
        recovery_filesystem_info() {
            case "$1" in
                "$RECOVERY_BUILD_STATE_ROOT") printf 'build\t250\n' ;;
                "$RECOVERY_BOOT_ROOT") printf 'boot\t350\n' ;;
                *) return 89 ;;
            esac
        }
        preflight_recovery_disk_space 7.2.0-x1407qa "$list"
    )
}

case_complete_manifest() {
    mkdir -p "$RECOVERY_ROOT"
    rm -f -- "$RECOVERY_MANIFEST"
    RECOVERY_LOCK_HELD=1
    initialize_recovery_manifest
    expect_failure 'an incomplete manifest was accepted as complete' \
        validate_recovery_manifest
}

case_transaction() {
    declare -F build_restore_transaction_plan >/dev/null || {
        echo 'transactional staged restore planner missing' >&2
        exit 1
    }
}

case_explicit_success() {
    grep -qF 'restore_recovery_state "$kernel" || return' "$restore" || {
        echo 'restore success is not explicitly gated' >&2
        exit 1
    }
}

run_case() {
    case "$1" in
        usrmerge) case_usrmerge ;;
        mounts) case_mounts ;;
        space) case_grouped_space ;;
        semantic) case_complete_manifest ;;
        transaction) case_transaction ;;
        success) case_explicit_success ;;
        *) echo "unknown case: $1" >&2; exit 2 ;;
    esac
}

if [[ $case_name == all ]]; then
    for name in usrmerge mounts space semantic transaction success; do
        run_case "$name"
    done
else
    run_case "$case_name"
fi

echo "PASS: stable recovery round 3 ($case_name)"
