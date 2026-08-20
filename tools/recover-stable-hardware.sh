#!/usr/bin/env bash
# Transactional recovery of the stable X1407QA hardware path. This runner
# deliberately stops before reboot and never activates experimental hardware.
set -euo pipefail

RECOVERY_REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
EXPECTED_MODEL='ASUS Vivobook 14 X1407QA'
EXPECTED_KERNEL='7.2.0-x1407qa'
if [[ ${VIVOBOOK_RECOVERY_LIBRARY_ONLY:-0} == 1 ]]; then
    RECOVERY_ROOT=${RECOVERY_ROOT:-/var/lib/vivobook-recovery/2026-08-20}
else
    RECOVERY_ROOT=/var/lib/vivobook-recovery/2026-08-20
    FIRMWARE_ROOT=/usr/lib/firmware
    DRACUT_CONFIG_DIR=/etc/dracut.conf.d
    unset INITRAMFS_BOOT_DIR MODULES_LOAD_CONFIG_DIR RECOVERY_MODEL_PATH
    VIVOBOOK_SETUP_TEST_MODE=0
fi
RECOVERY_MANIFEST="${RECOVERY_ROOT}/manifest.txt"
RECOVERY_AUDIT="${RECOVERY_REPO_ROOT}/tools/audit-stable-hardware.sh"
RECOVERY_BASELINE_STATUS=not-run

export VIVOBOOK_SETUP_LIBRARY_ONLY=1
if [[ ! -f ${RECOVERY_REPO_ROOT}/setup-vivobook.sh ||
      -L ${RECOVERY_REPO_ROOT}/setup-vivobook.sh ]]; then
    printf '%s\n' 'ERROR: setup library ausente ou insegura' >&2
    return 1 2>/dev/null || exit 1
fi
# shellcheck source=../setup-vivobook.sh
source "${RECOVERY_REPO_ROOT}/setup-vivobook.sh"

recovery_error() {
    printf 'ERROR: %s\n' "$*" >&2
}

run_gate() {
    local description=$1
    shift

    if ! "$@"; then
        recovery_error "$description"
        return 1
    fi
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        recovery_error 'execute como root: sudo -n bash tools/recover-stable-hardware.sh'
        return 1
    fi
}

detected_model() {
    local model_path=/sys/devices/virtual/dmi/id/product_name

    if [[ ${VIVOBOOK_RECOVERY_LIBRARY_ONLY:-0} == 1 ]]; then
        model_path=${RECOVERY_MODEL_PATH:-$model_path}
    fi

    [[ -r $model_path && ! -L $model_path ]] || return 1
    tr -d '\0\n' < "$model_path"
}

verify_recovery_target() {
    local model kernel

    model=$(detected_model) || {
        recovery_error 'não foi possível ler o modelo DMI'
        return 1
    }
    kernel=$(uname -r) || return 1
    if [[ $model != *"$EXPECTED_MODEL"* ]]; then
        recovery_error "modelo não suportado: $model"
        return 1
    fi
    if [[ $kernel != "$EXPECTED_KERNEL" ]]; then
        recovery_error "kernel não suportado: $kernel (esperado $EXPECTED_KERNEL)"
        return 1
    fi
}

verify_repository_entrypoints() {
    local path

    for path in "$RECOVERY_AUDIT" "${RECOVERY_REPO_ROOT}/setup-vivobook.sh"; do
        if [[ ! -f $path || -L $path ]]; then
            recovery_error "entrypoint ausente ou inseguro: $path"
            return 1
        fi
    done
}

run_pre_reboot_audit() {
    local status

    printf '%s\n' '=== PRE-REBOOT BASELINE (read-only) ==='
    if bash "$RECOVERY_AUDIT" --pre-reboot; then
        status=0
    else
        status=$?
    fi
    # Status 1 is the audit's documented aggregate result and is expected when
    # this runner is repairing broken Wi-Fi/remoteproc. Invocation errors are
    # prerequisites and remain fatal.
    if [[ $status -gt 1 ]]; then
        recovery_error "auditoria pré-reboot não pôde ser executada (status $status)"
        return 1
    fi
    if [[ $status -eq 1 ]]; then
        printf '%s\n' 'INFO: baseline contém falhas que serão reavaliadas após o reboot.'
    fi
    RECOVERY_BASELINE_STATUS=$status
}

initialize_recovery_manifest() {
    if [[ -L $RECOVERY_ROOT || -L $RECOVERY_MANIFEST ]] ||
        [[ -e $RECOVERY_ROOT && ! -d $RECOVERY_ROOT ]] ||
        [[ -e $RECOVERY_MANIFEST && ! -f $RECOVERY_MANIFEST ]]; then
        recovery_error "path de recovery inseguro: $RECOVERY_ROOT"
        return 1
    fi
    install -d -m 0700 "$RECOVERY_ROOT" "${RECOVERY_ROOT}/backups" || return 1
    if [[ ! -e $RECOVERY_MANIFEST ]]; then
        printf '%s\n' \
            'FORMAT\t1' \
            'DATE\t2026-08-20' > "$RECOVERY_MANIFEST" || return 1
    fi
    chmod 0600 "$RECOVERY_MANIFEST"
}

manifest_has_path() {
    local path=$1

    awk -F '\t' -v wanted="$path" \
        '($1 == "BACKUP" || $1 == "ABSENT") && $2 == wanted { found=1 } END { exit !found }' \
        "$RECOVERY_MANIFEST"
}

backup_managed_path() {
    local path=$1 backup_path relative_backup

    if [[ $path != /* || $path == *$'\n'* || $path == *$'\t'* ]]; then
        recovery_error "path de backup inválido: $path"
        return 1
    fi
    manifest_has_path "$path" && return 0

    relative_backup="backups${path}"
    backup_path="${RECOVERY_ROOT}/${relative_backup}"
    if [[ -e $path || -L $path ]]; then
        if [[ -e $backup_path || -L $backup_path ]]; then
            recovery_error "backup não manifestado já existe: $backup_path"
            return 1
        fi
        install -d -m 0700 "$(dirname "$backup_path")" || return 1
        cp -a -- "$path" "$backup_path" || return 1
        printf 'BACKUP\t%s\t%s\n' "$path" "$relative_backup" >> "$RECOVERY_MANIFEST"
    else
        printf 'ABSENT\t%s\t-\n' "$path" >> "$RECOVERY_MANIFEST"
    fi
}

record_prior_incident() {
    local incident_id=task4-old-initramfs-dkms-hook

    if ! grep -qF $'INCIDENT\t'"$incident_id"$'\t' "$RECOVERY_MANIFEST"; then
        printf 'INCIDENT\t%s\t%s\n' "$incident_id" \
            'retained: old /boot/initramfs-6.19.10-300.fc44.aarch64.img rewrite and /var/tmp/dracut.dRkFu6m; no automatic rollback or cleanup' \
            >> "$RECOVERY_MANIFEST"
    fi
}

record_baseline_status() {
    if ! grep -qF $'AUDIT\tpre-reboot\t' "$RECOVERY_MANIFEST"; then
        printf 'AUDIT\tpre-reboot\t%s\n' "$RECOVERY_BASELINE_STATUS" \
            >> "$RECOVERY_MANIFEST"
    fi
}

backup_recovery_paths() {
    local kernel=$1 package_record module source_name artifact path target
    local -a paths=(
        /etc/modules-load.d/vivobook-core.conf
        /etc/dracut.conf.d/vivobook-core.conf
        /etc/dracut.conf.d/qcom-remoteproc.conf
        /etc/dracut.conf.d/qcom-gpu-firmware.conf
        /etc/systemd/system/sleep.target
        /etc/systemd/system/suspend.target
        /etc/systemd/system/hibernate.target
        /etc/systemd/system/hybrid-sleep.target
        /etc/systemd/system/suspend-then-hibernate.target
        "/lib/modules/${kernel}/build"
        "/boot/initramfs-${kernel}.img"
    )

    for package_record in "${CORE_DKMS_PACKAGES[@]}"; do
        IFS=: read -r module source_name artifact <<< "$package_record"
        for path in "$source_name" Makefile dkms.conf; do
            paths+=("/usr/src/${module}-1.0/${path}")
        done
    done
    for target in "${paths[@]}"; do
        backup_managed_path "$target" || return 1
    done
}

verify_recovery_checkpoint() {
    local kernel=$1 module target image
    local -a modules=(
        wcn_regulator_fix vivobook_kbd_fix vivobook_bl_fix vivobook_hotkey_fix
    )

    for module in "${modules[@]}"; do
        if ! modinfo -k "$kernel" -n "$module" >/dev/null 2>&1; then
            recovery_error "módulo instalado não resolve para ${kernel}: $module"
            return 1
        fi
    done
    image="/boot/initramfs-${kernel}.img"
    if [[ ! -f $image || -L $image || $(stat -c %a "$image") != 600 ]]; then
        recovery_error "initramfs final ausente, inseguro ou sem modo 0600: $image"
        return 1
    fi
    if ! lsinitrd "$image" >/dev/null; then
        recovery_error "lsinitrd rejeitou o initramfs instalado: $image"
        return 1
    fi
    for target in sleep.target suspend.target hibernate.target \
        hybrid-sleep.target suspend-then-hibernate.target; do
        if [[ $(systemctl is-enabled "$target" 2>&1 || true) != masked ]]; then
            recovery_error "target de sleep deixou de estar masked: $target"
            return 1
        fi
    done
}

run_recovery() {
    local kernel

    kernel=$(uname -r)
    run_gate 'privilégio root obrigatório' require_root || return 1
    run_gate 'modelo/kernel não correspondem ao alvo estável' \
        verify_recovery_target || return 1
    run_gate 'assets de recuperação ausentes' \
        verify_repository_entrypoints || return 1
    run_gate 'auditoria pré-reboot não executável' \
        run_pre_reboot_audit || return 1
    run_gate 'preflight de paths/provenance falhou' \
        preflight_core_paths "$kernel" || return 1
    run_gate 'dependências exatas não puderam ser instaladas/verificadas' \
        install_exact_dependencies recovery || return 1
    run_gate 'namespace DKMS privado indisponível' \
        preflight_dkms_namespace || return 1
    run_gate 'firmware obrigatório não pôde ser resolvido' \
        resolve_kernel_requested_firmware || return 1
    run_gate 'manifesto de recovery não pôde ser inicializado' \
        initialize_recovery_manifest || return 1
    record_prior_incident || return 1
    record_baseline_status || return 1
    run_gate 'backup anterior às mutações falhou' \
        backup_recovery_paths "$kernel" || return 1

    run_gate 'stage das fontes core falhou' stage_core_dkms_sources || return 1
    run_gate 'provenance do stage core falhou' \
        verify_staged_core_sources || return 1
    run_gate 'build tree do kernel não pôde ser preparado' \
        prepare_core_module_build_tree "$kernel" || return 1
    run_gate 'compilação de todos os módulos core falhou' \
        build_core_dkms_modules "$kernel" || return 1
    run_gate 'gate de vermagic dos módulos core falhou' \
        verify_core_dkms_vermagic "$kernel" || return 1
    run_gate 'instalação dos módulos core falhou' \
        install_built_core_dkms_modules "$kernel" || return 1

    run_gate 'configuração de boot dos módulos core falhou' \
        write_core_module_boot_configs || return 1
    run_gate 'configuração early-boot remoteproc falhou' \
        write_remoteproc_firmware_dracut_config || return 1
    run_gate 'configuração de firmware GPU/Bluetooth falhou' \
        write_gpu_bluetooth_firmware_dracut_config || return 1
    run_gate 'sleep/suspend/hibernate não permaneceram masked' \
        keep_sleep_targets_masked || return 1
    run_gate 'depmod falhou após todos os installs' \
        depmod "$kernel" || return 1
    run_gate 'candidato initramfs não foi validado/promovido' \
        publish_initramfs_candidate "$kernel" || return 1
    run_gate 'checkpoint final pré-reboot falhou' \
        verify_recovery_checkpoint "$kernel" || return 1

    printf '%s\n' 'READY FOR REBOOT'
    printf 'Manifest: %s\n' "$RECOVERY_MANIFEST"
    printf '%s\n' 'Reboot is a manual boundary; this runner did not reboot the machine.'
}

if [[ ${VIVOBOOK_RECOVERY_LIBRARY_ONLY:-0} == 1 ]]; then
    return 0 2>/dev/null || exit 0
fi

run_recovery
