#!/usr/bin/env bash
# Explicit, allowlisted restore of the checksum-pinned Task 6 recovery state.
# The recovery runner never calls this helper automatically.
set -euo pipefail

RESTORE_REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if [[ ${VIVOBOOK_RESTORE_LIBRARY_ONLY:-0} != 1 ]]; then
    RECOVERY_ROOT=/var/lib/vivobook-recovery/2026-08-20
    RECOVERY_OS_RELEASE_CANONICAL=/usr/lib/os-release
    RECOVERY_OS_RELEASE_PATH=/etc/os-release
    RECOVERY_BUILD_STATE_ROOT=/var/lib/x1407qa-kernel-7.2
    RECOVERY_USR_SRC_ROOT=/usr/src
    RECOVERY_DKMS_STATE_ROOT=/var/lib/dkms
    RECOVERY_MODULES_ROOT=/lib/modules
    RECOVERY_BOOT_ROOT=/boot
    DRACUT_CONFIG_DIR=/etc/dracut.conf.d
    MODULES_LOAD_CONFIG_DIR=/etc/modules-load.d
    unset RECOVERY_MODEL_PATH
    VIVOBOOK_SETUP_TEST_MODE=0
fi
export VIVOBOOK_RECOVERY_LIBRARY_ONLY=1
if ! declare -F validate_recovery_manifest >/dev/null; then
    # shellcheck source=recover-stable-hardware.sh
    source "${RESTORE_REPO_ROOT}/tools/recover-stable-hardware.sh"
fi

restore_error() {
    printf 'ERROR: %s\n' "$*" >&2
}

verify_restore_commands() {
    local command_name

    for command_name in basename chmod ln rm; do
        command -v "$command_name" >/dev/null 2>&1 || return 1
    done
}

validate_restore_record_allowlist() (
    local kernel=$1 expected_state= expected_managed= type field2 field3 field4 path

    expected_state=$(mktemp --tmpdir="$RECOVERY_ROOT" '.restore-state.XXXXXX') || return 1
    expected_managed=$(mktemp --tmpdir="$RECOVERY_ROOT" '.restore-managed.XXXXXX') || return 1
    trap 'rm -f -- "$expected_state" "$expected_managed"' EXIT HUP INT TERM
    write_expected_state_paths "$kernel" "$expected_state" || return 1
    write_expected_managed_paths "$kernel" "$expected_managed" || return 1
    while IFS=$'\t' read -r type field2 field3 field4; do
        case "$type" in
            FORMAT|DATE|ARCHIVE|INCIDENT|AUDIT) ;;
            STATE)
                path=$field3
                grep -Fxq -- "$path" "$expected_state" || return 1
                ;;
            BACKUP|CREATED|SYMLINK)
                path=$field2
                grep -Fxq -- "$path" "$expected_managed" || return 1
                ;;
            *) return 1 ;;
        esac
    done < "$RECOVERY_MANIFEST"
)

remove_allowlisted_path_no_follow() {
    local path=$1 allowlist=$2 parent

    grep -Fxq -- "$path" "$allowlist" || {
        restore_error "remoção fora da allowlist recusada: $path"
        return 1
    }
    [[ $path == /* && $path != / && $path != *$'\n'* && $path != *$'\t'* ]] || return 1
    parent=$(dirname -- "$path") || return 1
    require_no_follow_components "$parent" dir || return 1
    rm -rf --one-file-system -- "$path"
}

validate_restore_archive_members() (
    local archive=$1 roots= members= member root allowed

    roots=$(mktemp --tmpdir="$RECOVERY_ROOT" '.restore-roots.XXXXXX') || return 1
    members=$(mktemp --tmpdir="$RECOVERY_ROOT" '.restore-members.XXXXXX') || return 1
    trap 'rm -f -- "$roots" "$members"' EXIT HUP INT TERM
    awk -F '\t' '$1 == "STATE" && $2 == "ARCHIVED" { sub(/^\//, "", $3); print $3 }' \
        "$RECOVERY_MANIFEST" > "$roots" || return 1
    tar -tf "$archive" > "$members" || return 1
    while IFS= read -r member; do
        member=${member%/}
        [[ -n $member && $member != /* && $member != '..' &&
           $member != ../* && $member != */../* ]] || return 1
        allowed=0
        while IFS= read -r root; do
            if [[ $member == "$root" || $member == "$root/"* ]]; then
                allowed=1
                break
            fi
        done < "$roots"
        [[ $allowed == 1 ]] || return 1
    done < "$members"
)

restore_recovery_state() (
    local kernel=$1 archive_relative archive expected_state= expected_managed=
    local removal_order= type status path artifact target checksum candidate parent

    [[ $RECOVERY_LOCK_HELD == 1 ]] || {
        restore_error 'restore exige o lock exclusivo do recovery'
        return 1
    }
    validate_recovery_manifest || return 1
    validate_restore_record_allowlist "$kernel" || {
        restore_error 'manifesto contém path fora das allowlists de restore'
        return 1
    }
    archive_relative=$(awk -F '\t' '$1 == "ARCHIVE" { print $2 }' "$RECOVERY_MANIFEST") || return 1
    [[ -n $archive_relative ]] || return 1
    archive="${RECOVERY_ROOT}/${archive_relative}"
    validate_restore_archive_members "$archive" || {
        restore_error 'archive contém membro fora dos STATE ARCHIVED'
        return 1
    }

    expected_state=$(mktemp --tmpdir="$RECOVERY_ROOT" '.restore-state-allow.XXXXXX') || return 1
    expected_managed=$(mktemp --tmpdir="$RECOVERY_ROOT" '.restore-managed-allow.XXXXXX') || return 1
    removal_order=$(mktemp --tmpdir="$RECOVERY_ROOT" '.restore-order.XXXXXX') || return 1
    trap 'rm -f -- "$expected_state" "$expected_managed" "$removal_order"' EXIT HUP INT TERM
    write_expected_state_paths "$kernel" "$expected_state" || return 1
    write_expected_managed_paths "$kernel" "$expected_managed" || return 1

    awk -F '\t' '$1 == "STATE" { printf "%09d\t%s\n", length($3), $3 }' \
        "$RECOVERY_MANIFEST" | sort -rn > "$removal_order" || return 1
    while IFS=$'\t' read -r _ path; do
        remove_allowlisted_path_no_follow "$path" "$expected_state" || return 1
    done < "$removal_order"

    tar --extract --file "$archive" --directory=/ --same-owner --numeric-owner \
        --acls --xattrs --selinux || return 1

    while IFS=$'\t' read -r type path artifact checksum; do
        case "$type" in
            BACKUP|CREATED|SYMLINK)
                remove_allowlisted_path_no_follow "$path" "$expected_managed" || return 1
                ;;
            *) continue ;;
        esac
        case "$type" in
            BACKUP)
                target="${RECOVERY_ROOT}/${artifact}"
                [[ -f $target && ! -L $target ]] || return 1
                parent=$(dirname -- "$path") || return 1
                require_no_follow_components "$parent" dir || return 1
                candidate=$(mktemp --tmpdir="$parent" ".$(basename "$path").restore.XXXXXX") || return 1
                cp --no-dereference --preserve=all -- "$target" "$candidate" || return 1
                sync -f "$candidate" || return 1
                mv -Tf -- "$candidate" "$path" || return 1
                sync -f "$parent" || return 1
                ;;
            SYMLINK)
                parent=$(dirname -- "$path") || return 1
                require_no_follow_components "$parent" dir || return 1
                ln -s -- "$artifact" "$path" || return 1
                sync -f "$parent" || return 1
                ;;
        esac
    done < "$RECOVERY_MANIFEST"
)

run_restore() {
    local kernel

    [[ ${1:-} == --apply && $# -eq 1 ]] || {
        restore_error 'uso: sudo -n bash tools/restore-stable-hardware-backup.sh --apply'
        return 2
    }
    kernel=$(uname -r) || return 2
    require_root || return 2
    verify_recovery_target || return 2
    verify_operating_system || return 2
    verify_recovery_base_commands || return 2
    verify_restore_commands || return 2
    acquire_recovery_lock || return 2
    [[ -f $RECOVERY_MANIFEST && ! -L $RECOVERY_MANIFEST ]] || return 2
    restore_recovery_state "$kernel"
    printf '%s\n' 'RESTORE COMPLETE; no reboot was performed.'
}

if [[ ${VIVOBOOK_RESTORE_LIBRARY_ONLY:-0} == 1 ]]; then
    return 0 2>/dev/null || exit 0
fi

run_restore "$@"
