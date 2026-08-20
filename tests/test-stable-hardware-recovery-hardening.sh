#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
runner="$root/tools/recover-stable-hardware.sh"
setup="$root/setup-vivobook.sh"
case_name=${1:-all}
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

export VIVOBOOK_RECOVERY_LIBRARY_ONLY=1
export RECOVERY_ROOT="$test_root/recovery"
# shellcheck source=../tools/recover-stable-hardware.sh
source "$runner"

DRACUT_CONFIG_DIR="$test_root/managed/dracut"
MODULES_LOAD_CONFIG_DIR="$test_root/managed/modules-load"
RECOVERY_SYSTEMD_DIR="$test_root/managed/systemd"
RECOVERY_BOOT_ROOT="$test_root/managed/boot"
mkdir -p "$DRACUT_CONFIG_DIR" "$MODULES_LOAD_CONFIG_DIR" \
    "$RECOVERY_SYSTEMD_DIR" "$RECOVERY_BOOT_ROOT"

reset_recovery_root() {
    rm -rf -- "$RECOVERY_ROOT"
    mkdir -p "$RECOVERY_ROOT"
    RECOVERY_LOCK_HELD=0
}

expect_failure() {
    local message=$1
    shift
    if "$@"; then
        echo "$message" >&2
        exit 1
    fi
}

case_symlink_and_atomic_writers() {
    local config_root="$test_root/config"
    local modules_root="$test_root/modules-load"
    local victim="$test_root/victim"

    mkdir -p "$config_root" "$modules_root"
    printf 'must-survive\n' > "$victim"
    DRACUT_CONFIG_DIR="$config_root"
    MODULES_LOAD_CONFIG_DIR="$modules_root"
    RESOLVED_REMOTEPROC_FIRMWARE=(/firmware/adsp.mbn)
    RESOLVED_GPU_FIRMWARE=(/firmware/gpu.bin)
    RESOLVED_BLUETOOTH_FIRMWARE=(/firmware/bt.tlv)

    ln -s "$victim" "$config_root/qcom-remoteproc.conf"
    expect_failure 'remoteproc writer followed a symlink target' \
        write_remoteproc_firmware_dracut_config
    [[ $(<"$victim") == must-survive ]] || {
        echo 'symlink target was overwritten' >&2
        exit 1
    }
    rm "$config_root/qcom-remoteproc.conf"

    write_remoteproc_firmware_dracut_config
    grep -qF '/firmware/adsp.mbn' "$config_root/qcom-remoteproc.conf" || {
        echo 'atomic remoteproc writer lost its content' >&2
        exit 1
    }
    if find "$config_root" -maxdepth 1 -name '*.new.*' -print -quit | grep -q .; then
        echo 'atomic writer leaked a temporary file' >&2
        exit 1
    fi

    printf 'old\n' > "$config_root/qcom-gpu-firmware.conf"
    sync() { return 1; }
    expect_failure 'GPU writer accepted a failed pre-rename sync' \
        write_gpu_bluetooth_firmware_dracut_config
    unset -f sync
    [[ $(<"$config_root/qcom-gpu-firmware.conf") == old ]] || {
        echo 'failed atomic GPU write changed the target' >&2
        exit 1
    }

    mv "$modules_root" "$test_root/modules-real"
    ln -s "$test_root/modules-real" "$modules_root"
    expect_failure 'core writer accepted a symlinked parent directory' \
        write_core_module_boot_configs
}

case_fedora_gate() {
    local os_release="$test_root/os-release" os_line lock_line

    RECOVERY_OS_RELEASE_PATH="$os_release"
    RECOVERY_OS_RELEASE_CANONICAL="$os_release"
    printf 'ID=fedora\nVERSION_ID=43\n' > "$os_release"
    expect_failure 'runner accepted Fedora other than version 44' \
        verify_operating_system
    printf 'ID=ubuntu\nVERSION_ID=44\n' > "$os_release"
    expect_failure 'runner accepted a non-Fedora operating system' \
        verify_operating_system
    printf 'ID=fedora\nVERSION_ID=44\n' > "$os_release"
    verify_operating_system
    os_line=$(grep -n "verify_operating_system.*return 1" "$runner" | tail -1 | cut -d: -f1)
    lock_line=$(grep -n "acquire_recovery_lock.*return 1" "$runner" | tail -1 | cut -d: -f1)
    [[ $os_line -lt $lock_line ]] || {
        echo 'Fedora gate does not precede the first recovery mutation/lock' >&2
        exit 1
    }
}

case_audit_exit_contract() {
    run_audit_command() { return 1; }
    run_pre_reboot_audit
    [[ $RECOVERY_BASELINE_STATUS == 1 ]] || {
        echo 'hardware audit status 1 was not accepted as baseline' >&2
        exit 1
    }
    run_audit_command() { return 2; }
    expect_failure 'audit infrastructure status 2 was accepted' run_pre_reboot_audit
}

case_bc_dependency_and_order() {
    local installed_bc=0 dnf_args="$test_root/dnf-args"

    rpm() {
        [[ $1 == -q ]] || return 2
        if [[ $2 == bc && $installed_bc -eq 0 ]]; then
            return 1
        fi
        return 0
    }
    dnf() {
        printf '%s\n' "$*" > "$dnf_args"
        installed_bc=1
    }
    install_exact_dependencies recovery
    [[ $(<"$dnf_args") == 'install -y bc' ]] || {
        echo "exact dependency argv did not contain only bc: $(<"$dnf_args")" >&2
        exit 1
    }
    unset -f rpm dnf

    local preflight_line stage_line build_line
    preflight_line=$(grep -n 'preflight_recovery_mutation_paths' "$runner" | tail -1 | cut -d: -f1)
    stage_line=$(grep -n "stage_core_dkms_sources.*return 1" "$runner" | tail -1 | cut -d: -f1)
    build_line=$(grep -n "build_core_dkms_modules.*kernel.*return 1" "$runner" | tail -1 | cut -d: -f1)
    [[ $preflight_line -lt $stage_line && $preflight_line -lt $build_line ]] || {
        echo 'recovery mutation preflight does not precede stage/build' >&2
        exit 1
    }
}

prepare_locked_manifest() {
    reset_recovery_root
    acquire_recovery_lock
    initialize_recovery_manifest
}

prepare_expected_managed_records() {
    local kernel=$1 list="$test_root/managed-paths" path

    : > "$list"
    write_expected_managed_paths "$kernel" "$list"
    while IFS= read -r path; do
        backup_managed_path "$path"
    done < "$list"
}

case_manifest_integrity() {
    local source_file="$test_root/source.conf" backup_file

    prepare_locked_manifest
    [[ $(sed -n '1p' "$RECOVERY_MANIFEST") == $'FORMAT\t2' &&
       $(sed -n '2p' "$RECOVERY_MANIFEST") == $'DATE\t2026-08-20' ]] || {
        echo 'manifest headers do not contain actual tabs and strict version/date' >&2
        exit 1
    }
    printf 'original\n' > "$source_file"
    backup_managed_path "$source_file"
    validate_manifest_file "$RECOVERY_MANIFEST"
    backup_file="$RECOVERY_ROOT/$(awk -F '\t' -v path="$source_file" \
        '$1 == "BACKUP" && $2 == path { print $3 }' "$RECOVERY_MANIFEST")"

    rm "$backup_file"
    expect_failure 'manifest accepted a missing backup artifact' \
        validate_manifest_file "$RECOVERY_MANIFEST"

    prepare_locked_manifest
    printf 'original\n' > "$source_file"
    backup_managed_path "$source_file"
    backup_file="$RECOVERY_ROOT/$(awk -F '\t' -v path="$source_file" \
        '$1 == "BACKUP" && $2 == path { print $3 }' "$RECOVERY_MANIFEST")"
    printf 'corrupt\n' > "$backup_file"
    expect_failure 'manifest accepted a checksum-mismatched backup' \
        validate_manifest_file "$RECOVERY_MANIFEST"

    prepare_locked_manifest
    append_manifest_record $'CREATED\t/tmp/duplicate\t-'
    expect_failure 'manifest accepted a duplicate path record' \
        append_manifest_record $'CREATED\t/tmp/duplicate\t-'

    prepare_locked_manifest
    expect_failure 'manifest accepted an unknown record type' \
        append_manifest_record $'UNKNOWN\tvalue'

    prepare_locked_manifest
    printf 'victim\n' > "$test_root/link-victim"
    ln -s "$test_root/link-victim" "$test_root/link-source"
    backup_managed_path "$test_root/link-source"
    grep -qF $'SYMLINK\t'"$test_root/link-source"$'\t'"$test_root/link-victim"$'\t-' \
        "$RECOVERY_MANIFEST" || {
        echo 'backup followed a source symlink instead of recording lstat state' >&2
        exit 1
    }
}

case_exclusive_lock() {
    reset_recovery_root
    acquire_recovery_lock
    (
        export VIVOBOOK_RECOVERY_LIBRARY_ONLY=1 RECOVERY_ROOT
        # shellcheck source=../tools/recover-stable-hardware.sh
        source "$runner"
        expect_failure 'second runner acquired the active recovery lock' \
            acquire_recovery_lock
    )
}

case_state_archive_coverage() {
    local kernel=7.2.0-x1407qa state_list

    prepare_locked_manifest
    RECOVERY_BUILD_STATE_ROOT="$test_root/state/build-root"
    RECOVERY_USR_SRC_ROOT="$test_root/state/usr-src"
    RECOVERY_DKMS_STATE_ROOT="$test_root/state/dkms"
    RECOVERY_MODULES_ROOT="$test_root/state/modules"
    mkdir -p "$RECOVERY_BUILD_STATE_ROOT/module-build" \
        "$RECOVERY_USR_SRC_ROOT/wcn-regulator-fix-1.0" \
        "$RECOVERY_DKMS_STATE_ROOT/wcn-regulator-fix" \
        "$RECOVERY_MODULES_ROOT/$kernel/extra"
    ln -s "$RECOVERY_BUILD_STATE_ROOT/module-build" \
        "$RECOVERY_MODULES_ROOT/$kernel/build"
    printf 'module\n' > "$RECOVERY_MODULES_ROOT/$kernel/extra/wcn_regulator_fix.ko"
    printf 'metadata\n' > "$RECOVERY_MODULES_ROOT/$kernel/modules.dep"
    RECOVERY_MODULES_CANONICAL_ROOT=$RECOVERY_MODULES_ROOT
    RECOVERY_MODULES_ALIAS_ROOT=$RECOVERY_MODULES_ROOT
    prepare_expected_managed_records "$kernel"

    modinfo() {
        if [[ $* == *'-n wcn_regulator_fix'* ]]; then
            printf '%s\n' "$RECOVERY_MODULES_ROOT/$kernel/extra/wcn_regulator_fix.ko"
            return 0
        fi
        return 1
    }
    capture_recovery_state "$kernel"
    unset -f modinfo
    validate_recovery_manifest
    state_list=$(tar -tf "$RECOVERY_ROOT/backups/state-before.tar")
    for expected in \
        "${RECOVERY_BUILD_STATE_ROOT#/}/module-build" \
        "${RECOVERY_USR_SRC_ROOT#/}/wcn-regulator-fix-1.0" \
        "${RECOVERY_DKMS_STATE_ROOT#/}/wcn-regulator-fix" \
        "${RECOVERY_MODULES_ROOT#/}/$kernel/extra" \
        "${RECOVERY_MODULES_ROOT#/}/$kernel/extra/wcn_regulator_fix.ko" \
        "${RECOVERY_MODULES_ROOT#/}/$kernel/modules.dep"; do
        grep -qF "$expected" <<<"$state_list" || {
            echo "state archive is missing: $expected" >&2
            exit 1
        }
    done
    grep -qF $'STATE\tARCHIVED\t' "$RECOVERY_MANIFEST" || {
        echo 'manifest lacks exact archive restore records' >&2
        exit 1
    }
}

case_installed_vermagic() {
    local kernel=7.2.0-x1407qa

    declare -F verify_installed_module >/dev/null || {
        echo 'installed-module path/vermagic verifier is missing' >&2
        exit 1
    }

    RECOVERY_MODULES_ROOT="$test_root/checkpoint/modules"
    RECOVERY_MODULES_CANONICAL_ROOT=$RECOVERY_MODULES_ROOT
    RECOVERY_MODULES_ALIAS_ROOT=$RECOVERY_MODULES_ROOT
    RECOVERY_BOOT_ROOT="$test_root/checkpoint/boot"
    mkdir -p "$RECOVERY_MODULES_ROOT/$kernel/extra" "$RECOVERY_BOOT_ROOT"
    printf 'image\n' > "$RECOVERY_BOOT_ROOT/initramfs-${kernel}.img"
    chmod 0600 "$RECOVERY_BOOT_ROOT/initramfs-${kernel}.img"
    for module in wcn_regulator_fix vivobook_kbd_fix vivobook_bl_fix vivobook_hotkey_fix vivobook_cam_fix; do
        printf '%s\n' "$module" > "$RECOVERY_MODULES_ROOT/$kernel/extra/${module}.ko"
    done
    modinfo() {
        local module path
        if [[ $1 == -k && $3 == -n ]]; then
            module=$4
            path="$RECOVERY_MODULES_ROOT/$2/extra/${module}.ko"
            [[ -f $path ]] || return 1
            printf '%s\n' "$path"
            return 0
        fi
        if [[ $1 == -F && $2 == vermagic ]]; then
            [[ $3 == *vivobook_hotkey_fix.ko ]] &&
                printf '%s SMP preempt mod_unload aarch64\n' wrong-kernel ||
                printf '%s SMP preempt mod_unload aarch64\n' "$kernel"
            return 0
        fi
        return 2
    }
    lsinitrd() { :; }
    systemctl() { printf 'masked\n'; }
    expect_failure 'checkpoint accepted an installed module vermagic mismatch' \
        verify_recovery_checkpoint "$kernel"
}

case_fedora_real_layout() {
    local os_root="$test_root/os-layout"

    mkdir -p "$os_root/usr/lib" "$os_root/etc"
    printf 'ID=fedora\nVERSION_ID=44\n' > "$os_root/usr/lib/os-release"
    ln -s ../usr/lib/os-release "$os_root/etc/os-release"
    RECOVERY_OS_RELEASE_CANONICAL="$os_root/usr/lib/os-release"
    RECOVERY_OS_RELEASE_PATH="$os_root/etc/os-release"
    verify_operating_system

    rm "$os_root/etc/os-release"
    printf 'ID=fedora\nVERSION_ID=44\n' > "$os_root/etc/os-release"
    expect_failure 'runner accepted a noncanonical regular /etc/os-release' \
        verify_operating_system
    rm "$os_root/etc/os-release"
    ln -s ../usr/lib/not-os-release "$os_root/etc/os-release"
    expect_failure 'runner accepted /etc/os-release resolving elsewhere' \
        verify_operating_system
}

case_mutable_root_no_follow() {
    local kernel=7.2.0-x1407qa state="$test_root/mutable" victim="$test_root/victim-dir"

    RECOVERY_BUILD_STATE_ROOT="$state/build-root"
    RECOVERY_USR_SRC_ROOT="$state/usr-src"
    RECOVERY_DKMS_STATE_ROOT="$state/dkms"
    RECOVERY_MODULES_ROOT="$state/modules"
    RECOVERY_MODULES_CANONICAL_ROOT=$RECOVERY_MODULES_ROOT
    RECOVERY_MODULES_ALIAS_ROOT=$RECOVERY_MODULES_ROOT
    mkdir -p "$RECOVERY_BUILD_STATE_ROOT/module-build" "$RECOVERY_USR_SRC_ROOT" \
        "$RECOVERY_DKMS_STATE_ROOT" "$RECOVERY_MODULES_ROOT/$kernel" "$victim"
    ln -s "$RECOVERY_BUILD_STATE_ROOT/module-build" "$RECOVERY_MODULES_ROOT/$kernel/build"

    ln -s "$victim" "$RECOVERY_DKMS_STATE_ROOT/wcn-regulator-fix"
    expect_failure 'archive preflight accepted a symlinked DKMS package root' \
        preflight_mutable_state_paths "$kernel"
    rm "$RECOVERY_DKMS_STATE_ROOT/wcn-regulator-fix"
    mkdir "$RECOVERY_DKMS_STATE_ROOT/wcn-regulator-fix"

    ln -s "$victim" "$RECOVERY_MODULES_ROOT/$kernel/extra"
    expect_failure 'archive preflight accepted a symlinked kernel extra root' \
        preflight_mutable_state_paths "$kernel"
    rm "$RECOVERY_MODULES_ROOT/$kernel/extra"
    mkdir "$RECOVERY_MODULES_ROOT/$kernel/extra"

    ln -s "$victim" "$RECOVERY_MODULES_ROOT/$kernel/updates"
    expect_failure 'archive preflight accepted a symlinked kernel updates root' \
        preflight_mutable_state_paths "$kernel"
    rm "$RECOVERY_MODULES_ROOT/$kernel/updates"

    rm "$RECOVERY_MODULES_ROOT/$kernel/build"
    ln -s "$victim" "$RECOVERY_MODULES_ROOT/$kernel/build"
    expect_failure 'archive preflight accepted the explicit build link with a wrong target' \
        preflight_mutable_state_paths "$kernel"
    rm "$RECOVERY_MODULES_ROOT/$kernel/build"
    ln -s "$RECOVERY_BUILD_STATE_ROOT/module-build" "$RECOVERY_MODULES_ROOT/$kernel/build"

    printf 'module\n' > "$victim/module.ko"
    ln -s "$victim/module.ko" "$RECOVERY_MODULES_ROOT/$kernel/extra/wcn_regulator_fix.ko"
    modinfo() {
        [[ $* == *'-n wcn_regulator_fix'* ]] || return 1
        printf '%s\n' "$RECOVERY_MODULES_ROOT/$kernel/extra/wcn_regulator_fix.ko"
    }
    expect_failure 'archive preflight accepted a symlinked installed module target' \
        preflight_mutable_state_paths "$kernel"
    unset -f modinfo

    local first_line second_line
    first_line=$(grep -n 'preflight_mutable_state_paths.*kernel.*return 1' "$runner" | head -1 | cut -d: -f1)
    second_line=$(grep -n 'preflight_mutable_state_paths.*kernel.*return 1' "$runner" | tail -1 | cut -d: -f1)
    [[ $first_line -ne $second_line ]] || {
        echo 'mutable roots are not revalidated before DKMS' >&2
        exit 1
    }
}

case_disk_preflight() {
    local disk_tree="$test_root/disk-tree" state_list="$test_root/disk-list" measured

    declare -F preflight_recovery_disk_space >/dev/null || {
        echo 'disk-space recovery preflight is missing' >&2
        exit 1
    }
    recovery_archive_apparent_bytes() { printf '1000\n'; }
    recovery_filesystem_info() { printf 'same-fs\t1500\n'; }
    RECOVERY_BUILD_SCRATCH_BYTES=1000
    RECOVERY_CANDIDATE_SCRATCH_BYTES=1000
    RECOVERY_SPACE_MARGIN_BYTES=1000
    expect_failure 'disk preflight accepted insufficient recovery filesystem space' \
        preflight_recovery_disk_space 7.2.0-x1407qa "$test_root/state-list"
    mkdir -p "$disk_tree"
    mkdir -p "$RECOVERY_ROOT"
    printf '1234567' > "$disk_tree/payload"
    printf '%s\n%s\n' "$disk_tree" "$disk_tree" > "$state_list"
    measured=$(VIVOBOOK_RECOVERY_LIBRARY_ONLY=1 RECOVERY_ROOT="$RECOVERY_ROOT" \
        bash -c 'source "$1"; recovery_archive_apparent_bytes "$2"' \
        _ "$runner" "$state_list")
    [[ $measured -eq 7 ]] || {
        echo "archive apparent size double-counted duplicate roots: $measured" >&2
        exit 1
    }
}

case_manifest_semantics() {
    local archive checksum

    prepare_locked_manifest
    archive="$RECOVERY_ROOT/backups/state-before.tar"
    tar -cf "$archive" --files-from=/dev/null
    checksum=$(sha256sum "$archive" | cut -d' ' -f1)
    expect_failure 'manifest accepted ARCHIVE without the exact STATE set' \
        append_manifest_record $'ARCHIVE\tbackups/state-before.tar\t'"$checksum"
}

prepare_capture_fixture() {
    local kernel=$1 state="$test_root/capture"

    prepare_locked_manifest
    RECOVERY_BUILD_STATE_ROOT="$state/build-root"
    RECOVERY_USR_SRC_ROOT="$state/usr-src"
    RECOVERY_DKMS_STATE_ROOT="$state/dkms"
    RECOVERY_MODULES_ROOT="$state/modules"
    RECOVERY_MODULES_CANONICAL_ROOT=$RECOVERY_MODULES_ROOT
    RECOVERY_MODULES_ALIAS_ROOT=$RECOVERY_MODULES_ROOT
    mkdir -p "$RECOVERY_BUILD_STATE_ROOT/module-build" "$RECOVERY_USR_SRC_ROOT" \
        "$RECOVERY_DKMS_STATE_ROOT" "$RECOVERY_MODULES_ROOT/$kernel/extra"
    ln -s "$RECOVERY_BUILD_STATE_ROOT/module-build" "$RECOVERY_MODULES_ROOT/$kernel/build"
    modinfo() { return 1; }
    prepare_expected_managed_records "$kernel"
}

case_find_failure() {
    local kernel=7.2.0-x1407qa

    prepare_capture_fixture "$kernel"
    find() { return 7; }
    expect_failure 'state capture ignored an injected find failure' \
        capture_recovery_state "$kernel"
    unset -f find modinfo
}

case_archive_durability() {
    local kernel=7.2.0-x1407qa events="$test_root/durability-events"

    prepare_capture_fixture "$kernel"
    sync() { printf 'sync:%s\n' "$*" >> "$events"; }
    append_manifest_records_file() {
        printf 'manifest\n' >> "$events"
    }
    capture_recovery_state "$kernel"
    unset -f sync append_manifest_records_file modinfo
    local backups_sync manifest_line
    backups_sync=$(grep -nFx "sync:-f $RECOVERY_ROOT/backups" "$events" | tail -1 | cut -d: -f1 || true)
    manifest_line=$(grep -n '^manifest$' "$events" | cut -d: -f1 || true)
    [[ -n $backups_sync && -n $manifest_line && $backups_sync -lt $manifest_line ]] || {
        echo 'archive directory was not synced after rename and before manifest publication' >&2
        exit 1
    }
}

case_atomic_temp_glob() {
    local config_root="$test_root/glob-config" stale

    mkdir -p "$config_root"
    stale="$config_root/.qcom-remoteproc.conf.new.attack"
    : > "$stale"
    expect_failure 'config preflight ignored its actual hidden mktemp glob' \
        preflight_atomic_config_target "$config_root/qcom-remoteproc.conf"
}

run_case() {
    case "$1" in
        symlink) case_symlink_and_atomic_writers ;;
        fedora) case_fedora_gate ;;
        audit) case_audit_exit_contract ;;
        bc) case_bc_dependency_and_order ;;
        manifest) case_manifest_integrity ;;
        lock) case_exclusive_lock ;;
        state) case_state_archive_coverage ;;
        vermagic) case_installed_vermagic ;;
        oslayout) case_fedora_real_layout ;;
        mutable) case_mutable_root_no_follow ;;
        disk) case_disk_preflight ;;
        semantic) case_manifest_semantics ;;
        findfail) case_find_failure ;;
        durability) case_archive_durability ;;
        tempglob) case_atomic_temp_glob ;;
        *) echo "unknown case: $1" >&2; exit 2 ;;
    esac
}

if [[ $case_name == all ]]; then
    for name in symlink fedora audit bc manifest lock state vermagic \
        oslayout mutable disk semantic findfail durability tempglob; do
        run_case "$name"
    done
else
    run_case "$case_name"
fi

echo "PASS: stable recovery hardening (${case_name})"
