#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
runner="$root/tools/recover-stable-hardware.sh"
setup="$root/setup-vivobook.sh"

[[ -f $runner ]] || {
    echo 'stable hardware recovery runner missing' >&2
    exit 1
}

require() {
    local needle=$1 path=$2 message=$3

    grep -qF -- "$needle" "$path" || {
        echo "$message" >&2
        exit 1
    }
}

require 'set -euo pipefail' "$runner" 'runner is not fail-fast'
require '/var/lib/vivobook-recovery/2026-08-20' "$runner" \
    'runner does not use the dated recovery root'
require 'manifest.txt' "$runner" 'runner does not keep a recovery manifest'
require 'ASUS Vivobook 14 X1407QA' "$runner" 'runner does not gate the hardware model'
require '7.2.0-x1407qa' "$runner" 'runner does not gate the exact kernel'
require '--pre-reboot' "$runner" 'runner does not call the pre-reboot audit'
require 'install_exact_dependencies' "$runner" \
    'runner does not compose the exact dependency installer'
require 'dnf install -y "${missing_packages[@]}"' "$setup" \
    'shared dependency helper does not install only the exact missing list'

for helper in \
    preflight_core_paths preflight_dkms_namespace resolve_kernel_requested_firmware \
    stage_core_dkms_sources verify_staged_core_sources prepare_core_module_build_tree \
    build_core_dkms_modules verify_core_dkms_vermagic \
    install_built_core_dkms_modules write_core_module_boot_configs \
    write_remoteproc_firmware_dracut_config \
    write_gpu_bluetooth_firmware_dracut_config keep_sleep_targets_masked \
    publish_initramfs_candidate; do
    require "$helper" "$runner" "runner does not compose setup helper: $helper"
done
require 'depmod "$kernel"' "$runner" 'runner does not run depmod for the exact kernel'
require 'READY FOR REBOOT' "$runner" 'runner lacks an explicit reboot checkpoint'
require 'chmod 0600 "$candidate"' "$setup" \
    'authoritative initramfs primitive does not set candidate mode 0600'

if grep -Eq 'dnf[[:space:]]+(update|upgrade|distro-sync)|systemctl[[:space:]]+(enable|unmask).*\b(sleep|suspend|hibernate|hybrid-sleep|suspend-then-hibernate)\.target|modprobe[[:space:]]+(vivobook_cam_fix|vivobook_color_ctrl|vivobook_usb4_fix)|enable-hm1092|install-usb4-role-fix' "$runner"; then
    echo 'runner contains forbidden package, sleep, IR, USB4, camera, or color behavior' >&2
    exit 1
fi

# Exercise the backup/manifest contract only in a temporary sandbox. The first
# observed state is authoritative and reruns must not replace that backup.
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT
export VIVOBOOK_RECOVERY_LIBRARY_ONLY=1
export RECOVERY_ROOT="$test_root/recovery"
# shellcheck source=../tools/recover-stable-hardware.sh
source "$runner"

model_file="$test_root/product_name"
RECOVERY_MODEL_PATH="$model_file"
printf 'different laptop\n' > "$model_file"
if verify_recovery_target >/dev/null 2>&1; then
    echo 'runner accepted an unrelated hardware model' >&2
    exit 1
fi
printf 'ASUS Vivobook 14 X1407QA_X1407QA\n' > "$model_file"
verify_recovery_target

source_file="$test_root/system/example.conf"
mkdir -p "$(dirname "$source_file")"
printf 'original\n' > "$source_file"
acquire_recovery_lock
initialize_recovery_manifest
backup_managed_path "$source_file"
printf 'changed\n' > "$source_file"
backup_managed_path "$source_file"
backup_relative=$(awk -F '\t' -v path="$source_file" \
    '$1 == "BACKUP" && $2 == path { print $3 }' "$RECOVERY_MANIFEST")
backup_file="$RECOVERY_ROOT/$backup_relative"
[[ $(<"$backup_file") == original ]] || {
    echo 'recovery rerun replaced the original backup' >&2
    exit 1
}
[[ $(grep -cF $'BACKUP\t'"$source_file"$'\t' "$RECOVERY_MANIFEST") -eq 1 ]] || {
    echo 'manifest does not contain exactly one backup record' >&2
    exit 1
}

absent_file="$test_root/system/absent.conf"
backup_managed_path "$absent_file"
backup_managed_path "$absent_file"
[[ $(grep -cF $'CREATED\t'"$absent_file"$'\t-' "$RECOVERY_MANIFEST") -eq 1 ]] || {
    echo 'manifest does not retain exactly one created-path record' >&2
    exit 1
}

# Every failed gate must suppress the only success checkpoint.
require_root() { :; }
verify_recovery_target() { :; }
verify_operating_system() { :; }
verify_recovery_base_commands() { :; }
acquire_recovery_lock() { :; }
initialize_recovery_manifest() { :; }
run_pre_reboot_audit() { :; }
record_baseline_status() { :; }
record_prior_incident() { :; }
install_exact_dependencies() { :; }
preflight_core_paths() { :; }
preflight_recovery_mutation_paths() { :; }
preflight_mutable_state_paths() { :; }
preflight_recovery_disk_space() { :; }
preflight_dkms_namespace() { :; }
resolve_kernel_requested_firmware() { :; }
backup_recovery_paths() { :; }
capture_recovery_state() { :; }
stage_core_dkms_sources() { :; }
verify_staged_core_sources() { :; }
prepare_core_module_build_tree() { :; }
build_core_dkms_modules() { :; }
verify_core_dkms_vermagic() { :; }
install_built_core_dkms_modules() { :; }
write_core_module_boot_configs() { :; }
write_remoteproc_firmware_dracut_config() { :; }
write_gpu_bluetooth_firmware_dracut_config() { :; }
keep_sleep_targets_masked() { :; }
depmod() { :; }
publish_initramfs_candidate() { return 1; }
verify_recovery_checkpoint() { :; }

if failed_output=$(run_recovery 2>&1); then
    echo 'runner accepted a failed initramfs publication gate' >&2
    exit 1
fi
if grep -q 'READY FOR REBOOT' <<<"$failed_output"; then
    echo 'runner printed the reboot checkpoint after a failed gate' >&2
    exit 1
fi

publish_initramfs_candidate() { :; }
verify_recovery_checkpoint() { return 1; }
if checkpoint_output=$(run_recovery 2>&1); then
    echo 'runner accepted a failed final checkpoint' >&2
    exit 1
fi
if grep -q 'READY FOR REBOOT' <<<"$checkpoint_output"; then
    echo 'runner printed reboot readiness before the final checkpoint passed' >&2
    exit 1
fi

verify_recovery_checkpoint() { :; }
success_output=$(run_recovery 2>&1)
[[ $(grep -c '^READY FOR REBOOT$' <<<"$success_output") -eq 1 ]] || {
    echo 'runner did not print exactly one checkpoint after every gate passed' >&2
    exit 1
}

echo 'PASS: stable hardware recovery runner is gated, idempotent, and fail-fast'
