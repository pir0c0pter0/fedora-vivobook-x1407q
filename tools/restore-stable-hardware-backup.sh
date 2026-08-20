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
    RECOVERY_MODULES_CANONICAL_ROOT=/usr/lib/modules
    RECOVERY_MODULES_ALIAS_ROOT=/lib/modules
    RECOVERY_MODULES_ROOT=$RECOVERY_MODULES_CANONICAL_ROOT
    RECOVERY_BOOT_ROOT=/boot
    RECOVERY_SYSTEMD_DIR=/etc/systemd/system
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

    for command_name in basename chmod dirname findmnt ln rm; do
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

preflight_restore_mounts() (
    local allowlist=$1 mounts= path mount

    mounts=$(mktemp --tmpdir="$RECOVERY_ROOT" '.restore-mounts.XXXXXX') || return 1
    trap 'rm -f -- "$mounts"' EXIT HUP INT TERM
    findmnt -rn --raw -o TARGET > "$mounts" || return 1
    [[ -f $mounts && ! -L $mounts ]] || return 1
    while IFS= read -r path; do
        [[ $path == /* && $path != / && $path != *$'\n'* && $path != *$'\t'* ]] || return 1
        while IFS= read -r mount; do
            if [[ $mount == "$path" || $mount == "$path/"* ]]; then
                restore_error "mountpoint exato ou aninhado impede restore: $mount"
                return 1
            fi
        done < "$mounts"
    done < "$allowlist"
)

preflight_restore_space() (
    local archive=$1 state_allowlist=$2 managed_allowlist=$3 path parent key available bytes type artifact
    local archive_bytes margin=${RECOVERY_RESTORE_MARGIN_BYTES:-1073741824}
    local -A needed=()
    local -A free=()
    local -A archive_charged=()

    archive_bytes=$(stat -c %s -- "$archive") || return 1
    add_restore_need() {
        local need_path=$1 need_bytes=$2
        parent=$(dirname -- "$need_path") || return 1
        IFS=$'\t' read -r key available < <(recovery_filesystem_info "$parent") || return 1
        needed[$key]=$(( ${needed[$key]:-0} + need_bytes ))
        if [[ -z ${free[$key]:-} || $available -lt ${free[$key]} ]]; then
            free[$key]=$available
        fi
    }
    while IFS=$'\t' read -r type artifact path _; do
        [[ $type == STATE && $artifact == ARCHIVED ]] || continue
        parent=$(dirname -- "$path") || return 1
        IFS=$'\t' read -r key available < <(recovery_filesystem_info "$parent") || return 1
        if [[ -z ${archive_charged[$key]:-} ]]; then
            needed[$key]=$(( ${needed[$key]:-0} + archive_bytes ))
            archive_charged[$key]=1
        fi
        if [[ -z ${free[$key]:-} || $available -lt ${free[$key]} ]]; then
            free[$key]=$available
        fi
    done < "$RECOVERY_MANIFEST"
    while IFS=$'\t' read -r type path artifact _; do
        [[ $type == BACKUP ]] || continue
        bytes=$(stat -c %s -- "${RECOVERY_ROOT}/${artifact}") || return 1
        add_restore_need "$path" "$bytes" || return 1
    done < "$RECOVERY_MANIFEST"
    for key in "${!needed[@]}"; do
        bytes=$((needed[$key] + margin))
        (( free[$key] >= bytes )) || {
            restore_error "espaço insuficiente para staging no filesystem $key"
            return 1
        }
    done
)

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

build_restore_transaction_plan() {
    local archive=$1 plan=$2 type status path artifact checksum parent base workspace relative candidate holder

    [[ -f $plan && ! -L $plan ]] || return 1
    while IFS=$'\t' read -r type status path artifact; do
        [[ $type == STATE ]] || continue
        parent=$(dirname -- "$path") || return 1
        base=$(basename -- "$path") || return 1
        holder=$(mktemp -d --tmpdir="$parent" ".${base}.restore-rollback.XXXXXX") || return 1
        printf 'TEMP\t%s\n' "$holder" >> "$plan" || return 1
        if [[ $status == ARCHIVED ]]; then
            workspace=$(mktemp -d --tmpdir="$parent" ".${base}.restore-stage.XXXXXX") || return 1
            printf 'TEMP\t%s\n' "$workspace" >> "$plan" || return 1
            relative=${path#/}
            tar --extract --file "$archive" --directory="$workspace" --same-owner --numeric-owner \
                --acls --xattrs --selinux -- "$relative" || return 1
            candidate="${workspace}/${relative}"
            [[ -e $candidate || -L $candidate ]] || return 1
            if [[ -f $candidate && ! -L $candidate ]]; then sync -f "$candidate" || return 1; fi
            if [[ -d $candidate && ! -L $candidate ]]; then sync -f "$candidate" || return 1; fi
            sync -f "$workspace" || return 1
            sync -f "$parent" || return 1
            printf 'ACTION\tREPLACE\t%s\t%s\t%s\n' "$path" "$candidate" "$holder" >> "$plan" || return 1
        else
            printf 'ACTION\tREMOVE\t%s\t-\t%s\n' "$path" "$holder" >> "$plan" || return 1
        fi
    done < "$RECOVERY_MANIFEST"

    while IFS=$'\t' read -r type path artifact checksum; do
        case "$type" in BACKUP|CREATED|SYMLINK) ;; *) continue ;; esac
        parent=$(dirname -- "$path") || return 1
        base=$(basename -- "$path") || return 1
        holder=$(mktemp -d --tmpdir="$parent" ".${base}.restore-rollback.XXXXXX") || return 1
        printf 'TEMP\t%s\n' "$holder" >> "$plan" || return 1
        case "$type" in
            BACKUP)
                candidate=$(mktemp --tmpdir="$parent" ".${base}.restore-stage.XXXXXX") || return 1
                printf 'TEMP\t%s\n' "$candidate" >> "$plan" || return 1
                cp --no-dereference --preserve=all -- "${RECOVERY_ROOT}/${artifact}" "$candidate" || return 1
                sync -f "$candidate" || return 1
                sync -f "$parent" || return 1
                printf 'ACTION\tREPLACE\t%s\t%s\t%s\n' "$path" "$candidate" "$holder" >> "$plan" || return 1
                ;;
            SYMLINK)
                candidate=$(mktemp --tmpdir="$parent" ".${base}.restore-stage.XXXXXX") || return 1
                rm -f -- "$candidate" || return 1
                ln -s -- "$artifact" "$candidate" || return 1
                printf 'TEMP\t%s\n' "$candidate" >> "$plan" || return 1
                sync -f "$parent" || return 1
                printf 'ACTION\tREPLACE\t%s\t%s\t%s\n' "$path" "$candidate" "$holder" >> "$plan" || return 1
                ;;
            CREATED)
                printf 'ACTION\tREMOVE\t%s\t-\t%s\n' "$path" "$holder" >> "$plan" || return 1
                ;;
        esac
    done < "$RECOVERY_MANIFEST"
}

cleanup_restore_plan() {
    local plan=$1 type path

    [[ -f $plan && ! -L $plan ]] || return 1
    while IFS=$'\t' read -r type path _; do
        [[ $type == TEMP ]] || continue
        [[ $path == /* && $path != / ]] || continue
        rm -rf --one-file-system -- "$path" || return 1
    done < "$plan"
}

rollback_restore_transaction() {
    local applied=$1 index action path holder had parent failed
    local -a records=()

    mapfile -t records < "$applied" || return 1
    for ((index=${#records[@]}-1; index>=0; index--)); do
        IFS=$'\t' read -r action path holder had <<< "${records[$index]}"
        parent=$(dirname -- "$path") || return 1
        if [[ -e $path || -L $path ]]; then
            failed="${holder}/failed"
            mv -T -- "$path" "$failed" || return 1
        fi
        if [[ $had == 1 ]]; then
            mv -T -- "${holder}/original" "$path" || return 1
        fi
        sync -f "$parent" || return 1
    done
}

publish_restore_transaction() {
    local plan=$1 applied=$2 type action path candidate holder parent had

    while IFS=$'\t' read -r type action path candidate holder; do
        [[ $type == ACTION ]] || continue
        parent=$(dirname -- "$path") || return 1
        had=0
        if [[ -e $path || -L $path ]]; then
            mv -T -- "$path" "${holder}/original" || return 1
            had=1
        fi
        printf '%s\t%s\t%s\t%s\n' "$action" "$path" "$holder" "$had" >> "$applied" || return 1
        if [[ $action == REPLACE ]]; then
            mv -T -- "$candidate" "$path" || return 1
        fi
        sync -f "$parent" || return 1
    done < "$plan"
}

restore_recovery_state() (
    local kernel=$1 archive_relative archive expected_state= expected_managed= all_paths=
    local plan= applied= restore_ok=0 rollback_ok=1

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
    all_paths=$(mktemp --tmpdir="$RECOVERY_ROOT" '.restore-all-paths.XXXXXX') || return 1
    plan=$(mktemp --tmpdir="$RECOVERY_ROOT" '.restore-plan.XXXXXX') || return 1
    applied=$(mktemp --tmpdir="$RECOVERY_ROOT" '.restore-applied.XXXXXX') || return 1
    cleanup_restore_transaction() {
        if [[ $restore_ok != 1 && -s $applied ]]; then
            if ! rollback_restore_transaction "$applied"; then
                rollback_ok=0
                restore_error "rollback transacional incompleto; preservando plan e rollback dirs: $plan"
            fi
        fi
        if [[ $rollback_ok == 1 ]]; then
            cleanup_restore_plan "$plan" || true
            rm -f -- "$expected_state" "$expected_managed" "$all_paths" "$plan" "$applied"
        fi
    }
    trap cleanup_restore_transaction EXIT HUP INT TERM
    write_expected_state_paths "$kernel" "$expected_state" || return 1
    write_expected_managed_paths "$kernel" "$expected_managed" || return 1
    sort -u "$expected_state" "$expected_managed" > "$all_paths" || return 1
    preflight_restore_mounts "$all_paths" || return 1
    preflight_restore_space "$archive" "$expected_state" "$expected_managed" || return 1
    while IFS= read -r path; do
        require_no_follow_components "$(dirname -- "$path")" dir || return 1
    done < "$all_paths"
    build_restore_transaction_plan "$archive" "$plan" || return 1
    preflight_restore_mounts "$all_paths" || return 1
    while IFS= read -r path; do
        require_no_follow_components "$(dirname -- "$path")" dir || return 1
    done < "$all_paths"
    if ! publish_restore_transaction "$plan" "$applied"; then
        return 1
    fi
    restore_ok=1
    cleanup_restore_plan "$plan" || return 1
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
    verify_modules_root_layout || return 2
    verify_recovery_base_commands || return 2
    verify_restore_commands || return 2
    acquire_recovery_lock || return 2
    [[ -f $RECOVERY_MANIFEST && ! -L $RECOVERY_MANIFEST ]] || return 2
    restore_recovery_state "$kernel" || return 1
    printf '%s\n' 'RESTORE COMPLETE; no reboot was performed.'
}

if [[ ${VIVOBOOK_RESTORE_LIBRARY_ONLY:-0} == 1 ]]; then
    return 0 2>/dev/null || exit 0
fi

run_restore "$@"
