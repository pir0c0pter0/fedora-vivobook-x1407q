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
    validate_recovery_manifest
    backup_file="$RECOVERY_ROOT/$(awk -F '\t' -v path="$source_file" \
        '$1 == "BACKUP" && $2 == path { print $3 }' "$RECOVERY_MANIFEST")"

    rm "$backup_file"
    expect_failure 'manifest accepted a missing backup artifact' \
        validate_recovery_manifest

    prepare_locked_manifest
    printf 'original\n' > "$source_file"
    backup_managed_path "$source_file"
    backup_file="$RECOVERY_ROOT/$(awk -F '\t' -v path="$source_file" \
        '$1 == "BACKUP" && $2 == path { print $3 }' "$RECOVERY_MANIFEST")"
    printf 'corrupt\n' > "$backup_file"
    expect_failure 'manifest accepted a checksum-mismatched backup' \
        validate_recovery_manifest

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
        *) echo "unknown case: $1" >&2; exit 2 ;;
    esac
}

if [[ $case_name == all ]]; then
    for name in symlink fedora audit bc manifest lock state vermagic; do
        run_case "$name"
    done
else
    run_case "$case_name"
fi

echo "PASS: stable recovery hardening (${case_name})"
