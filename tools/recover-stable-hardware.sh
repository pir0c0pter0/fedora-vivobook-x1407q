#!/usr/bin/env bash
# Transactional recovery of the stable X1407QA hardware path. This runner
# deliberately stops before reboot and never activates experimental hardware.
set -euo pipefail

RECOVERY_REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
EXPECTED_MODEL='ASUS Vivobook 14 X1407QA'
EXPECTED_KERNEL='7.2.0-x1407qa'
if [[ ${VIVOBOOK_RECOVERY_LIBRARY_ONLY:-0} == 1 ]]; then
    RECOVERY_ROOT=${RECOVERY_ROOT:-/var/lib/vivobook-recovery/2026-08-20}
    RECOVERY_OS_RELEASE_CANONICAL=${RECOVERY_OS_RELEASE_CANONICAL:-/usr/lib/os-release}
    RECOVERY_OS_RELEASE_PATH=${RECOVERY_OS_RELEASE_PATH:-$RECOVERY_OS_RELEASE_CANONICAL}
    RECOVERY_BUILD_STATE_ROOT=${RECOVERY_BUILD_STATE_ROOT:-/var/lib/x1407qa-kernel-7.2}
    RECOVERY_USR_SRC_ROOT=${RECOVERY_USR_SRC_ROOT:-/usr/src}
    RECOVERY_DKMS_STATE_ROOT=${RECOVERY_DKMS_STATE_ROOT:-/var/lib/dkms}
    RECOVERY_MODULES_ROOT=${RECOVERY_MODULES_ROOT:-/lib/modules}
    RECOVERY_BOOT_ROOT=${RECOVERY_BOOT_ROOT:-/boot}
else
    RECOVERY_ROOT=/var/lib/vivobook-recovery/2026-08-20
    RECOVERY_OS_RELEASE_CANONICAL=/usr/lib/os-release
    RECOVERY_OS_RELEASE_PATH=/etc/os-release
    RECOVERY_BUILD_STATE_ROOT=/var/lib/x1407qa-kernel-7.2
    RECOVERY_USR_SRC_ROOT=/usr/src
    RECOVERY_DKMS_STATE_ROOT=/var/lib/dkms
    RECOVERY_MODULES_ROOT=/lib/modules
    RECOVERY_BOOT_ROOT=/boot
    FIRMWARE_ROOT=/usr/lib/firmware
    DRACUT_CONFIG_DIR=/etc/dracut.conf.d
    unset INITRAMFS_BOOT_DIR MODULES_LOAD_CONFIG_DIR RECOVERY_MODEL_PATH
    VIVOBOOK_SETUP_TEST_MODE=0
fi
RECOVERY_MANIFEST="${RECOVERY_ROOT}/manifest.txt"
RECOVERY_AUDIT="${RECOVERY_REPO_ROOT}/tools/audit-stable-hardware.sh"
RECOVERY_BASELINE_STATUS=not-run
RECOVERY_LOCK_HELD=0
RECOVERY_LOCK_FD=

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

verify_operating_system() {
    local os_id version_id selected resolved

    if [[ ! -f $RECOVERY_OS_RELEASE_CANONICAL || -L $RECOVERY_OS_RELEASE_CANONICAL ]]; then
        recovery_error "os-release canônico ausente, não regular ou symlink: $RECOVERY_OS_RELEASE_CANONICAL"
        return 1
    fi
    selected=$RECOVERY_OS_RELEASE_PATH
    if [[ $selected == "$RECOVERY_OS_RELEASE_CANONICAL" ]]; then
        [[ -f $selected && ! -L $selected ]] || return 1
    else
        [[ -L $selected ]] || {
            recovery_error "os-release alternativo não é symlink para o canônico: $selected"
            return 1
        }
        resolved=$(readlink -f -- "$selected") || return 1
        [[ $resolved == "$RECOVERY_OS_RELEASE_CANONICAL" ]] || {
            recovery_error "os-release alternativo resolve fora do canônico: $selected -> $resolved"
            return 1
        }
    fi
    os_id=$(sed -n 's/^ID=//p' "$RECOVERY_OS_RELEASE_CANONICAL") || return 1
    version_id=$(sed -n 's/^VERSION_ID=//p' "$RECOVERY_OS_RELEASE_CANONICAL") || return 1
    os_id=${os_id#\"}
    os_id=${os_id%\"}
    version_id=${version_id#\"}
    version_id=${version_id%\"}
    if [[ $os_id != fedora || $version_id != 44 ]]; then
        recovery_error "sistema não suportado: ID=${os_id:-missing} VERSION_ID=${version_id:-missing}"
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

verify_recovery_base_commands() {
    local command_name

    for command_name in awk cp cut df du find flock grep install mktemp modinfo mv \
        readlink sed sha256sum sort stat sync tar; do
        command -v "$command_name" >/dev/null 2>&1 || {
            recovery_error "comando básico obrigatório ausente antes do lock/backup: $command_name"
            return 1
        }
    done
}

recovery_core_packages() {
    printf '%s\n' wcn-regulator-fix vivobook-kbd-fix vivobook-bl-fix \
        vivobook-hotkey-fix vivobook-cam-fix vivobook-color-ctrl
}

recovery_installed_modules() {
    printf '%s\n' wcn_regulator_fix vivobook_kbd_fix vivobook_bl_fix \
        vivobook_hotkey_fix vivobook_cam_fix
}

recovery_depmod_metadata_names() {
    printf '%s\n' modules.alias modules.alias.bin modules.builtin \
        modules.builtin.alias.bin modules.builtin.bin modules.builtin.modinfo \
        modules.builtin.ranges modules.dep modules.dep.bin modules.devname \
        modules.order modules.softdep modules.symbols modules.symbols.bin \
        modules.weakdep
}

write_expected_state_paths() {
    local kernel=$1 output=$2 package version name

    [[ -f $output && ! -L $output ]] || return 1
    {
        printf '%s\n' "$RECOVERY_BUILD_STATE_ROOT" \
            "${RECOVERY_MODULES_ROOT}/${kernel}/build" \
            "${RECOVERY_MODULES_ROOT}/${kernel}/extra" \
            "${RECOVERY_MODULES_ROOT}/${kernel}/updates"
        while IFS= read -r package; do
            version=1.0
            [[ $package == vivobook-cam-fix ]] && version=2.0
            printf '%s\n' "${RECOVERY_USR_SRC_ROOT}/${package}-${version}" \
                "${RECOVERY_DKMS_STATE_ROOT}/${package}"
        done < <(recovery_core_packages)
        while IFS= read -r name; do
            printf '%s\n' "${RECOVERY_MODULES_ROOT}/${kernel}/${name}"
        done < <(recovery_depmod_metadata_names)
    } | sort -u > "$output"
}

write_expected_managed_paths() {
    local kernel=$1 output=$2

    [[ -f $output && ! -L $output ]] || return 1
    printf '%s\n' \
        "${MODULES_LOAD_CONFIG_DIR:-/etc/modules-load.d}/vivobook-core.conf" \
        "${DRACUT_CONFIG_DIR}/vivobook-core.conf" \
        "${DRACUT_CONFIG_DIR}/qcom-remoteproc.conf" \
        "${DRACUT_CONFIG_DIR}/qcom-gpu-firmware.conf" \
        /etc/systemd/system/sleep.target \
        /etc/systemd/system/suspend.target \
        /etc/systemd/system/hibernate.target \
        /etc/systemd/system/hybrid-sleep.target \
        /etc/systemd/system/suspend-then-hibernate.target \
        "${RECOVERY_BOOT_ROOT}/initramfs-${kernel}.img" | sort -u > "$output"
}

require_no_follow_components() {
    local path=$1 final_kind=${2:-any} current= component index
    local -a components

    [[ $path == /* && $path != *'//'* && $path != */../* &&
       $path != */./* && $path != *$'\n'* && $path != *$'\t'* ]] || return 1
    IFS=/ read -r -a components <<< "${path#/}"
    for index in "${!components[@]}"; do
        component=${components[$index]}
        [[ -n $component && $component != . && $component != .. ]] || return 1
        current="${current}/${component}"
        if [[ -L $current ]]; then
            recovery_error "componente symlink proibido: $current"
            return 1
        fi
        if [[ -e $current && $index -lt $((${#components[@]} - 1)) && ! -d $current ]]; then
            recovery_error "componente ancestral não é diretório: $current"
            return 1
        fi
    done
    case "$final_kind" in
        dir) [[ ! -e $path || -d $path ]] ;;
        file) [[ ! -e $path || -f $path ]] ;;
        any) : ;;
        *) return 2 ;;
    esac
}

preflight_mutable_state_paths() {
    local kernel=$1 package version path resolved expected_build
    local module_root="${RECOVERY_MODULES_ROOT}/${kernel}"

    require_no_follow_components "$RECOVERY_BUILD_STATE_ROOT" dir || return 1
    require_no_follow_components "$RECOVERY_USR_SRC_ROOT" dir || return 1
    require_no_follow_components "$RECOVERY_DKMS_STATE_ROOT" dir || return 1
    require_no_follow_components "$module_root" dir || return 1
    for path in "$module_root/extra" "$module_root/updates"; do
        require_no_follow_components "$path" dir || return 1
    done
    while IFS= read -r package; do
        require_no_follow_components "$module_root/$package" file || return 1
    done < <(recovery_depmod_metadata_names)
    while IFS= read -r package; do
        version=1.0
        [[ $package == vivobook-cam-fix ]] && version=2.0
        require_no_follow_components "${RECOVERY_DKMS_STATE_ROOT}/${package}" dir || return 1
        require_no_follow_components "${RECOVERY_USR_SRC_ROOT}/${package}-${version}" dir || return 1
    done < <(recovery_core_packages)

    path="$module_root/build"
    if [[ -e $path || -L $path ]]; then
        [[ -L $path ]] || {
            recovery_error "build do kernel deve ser o symlink explicitamente gerenciado: $path"
            return 1
        }
        resolved=$(readlink -f -- "$path") || return 1
        expected_build="${RECOVERY_BUILD_STATE_ROOT}/module-build"
        [[ $resolved == "$expected_build" ]] || {
            recovery_error "build do kernel resolve fora do alvo esperado: $path -> $resolved"
            return 1
        }
        require_no_follow_components "$expected_build" dir || return 1
    fi

    while IFS= read -r package; do
        if path=$(modinfo -k "$kernel" -n "$package" 2>/dev/null); then
            [[ $path == "$module_root/extra/"* || $path == "$module_root/updates/"* ]] || {
                recovery_error "módulo instalado resolve fora de extra/updates: $package -> $path"
                return 1
            }
            require_no_follow_components "$path" file || return 1
            [[ -f $path && ! -L $path ]] || return 1
        fi
    done < <(recovery_installed_modules)
}

run_audit_command() {
    bash "$RECOVERY_AUDIT" --pre-reboot
}

run_pre_reboot_audit() {
    local status

    printf '%s\n' '=== PRE-REBOOT BASELINE (read-only) ==='
    if run_audit_command; then
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

acquire_recovery_lock() {
    local lock_path="${RECOVERY_ROOT}/runner.lock"

    if [[ -L $RECOVERY_ROOT ]] || [[ -e $RECOVERY_ROOT && ! -d $RECOVERY_ROOT ]]; then
        recovery_error "diretório de recovery inseguro: $RECOVERY_ROOT"
        return 1
    fi
    install -d -m 0700 "$RECOVERY_ROOT" || return 1
    if [[ -L $lock_path ]] || [[ -e $lock_path && ! -f $lock_path ]]; then
        recovery_error "arquivo de lock inseguro: $lock_path"
        return 1
    fi
    if [[ ! -e $lock_path ]]; then
        install -m 0600 /dev/null "$lock_path" || return 1
    fi
    exec {RECOVERY_LOCK_FD}<>"$lock_path" || return 1
    if ! flock -n "$RECOVERY_LOCK_FD"; then
        recovery_error 'outra recuperação já mantém o lock exclusivo'
        exec {RECOVERY_LOCK_FD}>&-
        RECOVERY_LOCK_FD=
        return 1
    fi
    RECOVERY_LOCK_HELD=1
}

validate_manifest_file() {
    local manifest=$1 type source relative expected actual artifact

    [[ -f $manifest && ! -L $manifest ]] || return 1
    awk -F '\t' '
        NR == 1 { if (NF != 2 || $1 != "FORMAT" || $2 != "2") exit 1; next }
        NR == 2 { if (NF != 2 || $1 != "DATE" || $2 != "2026-08-20") exit 1; next }
        NR > 2 {
            if ($1 == "BACKUP") { valid=(NF == 4); key="PATH" FS $2 }
            else if ($1 == "CREATED") { valid=(NF == 3 && $3 == "-"); key="PATH" FS $2 }
            else if ($1 == "SYMLINK") { valid=(NF == 4 && $4 == "-"); key="PATH" FS $2 }
            else if ($1 == "ARCHIVE") { valid=(NF == 3); key="ARCHIVE" FS $2 }
            else if ($1 == "STATE") { valid=(NF == 4 && (($2 == "ARCHIVED" && $4 == "backups/state-before.tar") || ($2 == "CREATED" && $4 == "-"))); key="STATE" FS $3 }
            else if ($1 == "INCIDENT") { valid=(NF == 3); key="INCIDENT" FS $2 }
            else if ($1 == "AUDIT") { valid=(NF == 3 && $2 == "pre-reboot" && ($3 == "0" || $3 == "1")); key="AUDIT" FS $2 }
            else exit 1
            if (!valid || $2 == "" || seen[key]++) exit 1
        }
        END { if (NR < 2) exit 1 }
    ' "$manifest" || return 1

    while IFS=$'\t' read -r type source relative expected; do
        case "$type" in
            BACKUP)
                [[ $relative == backups/* && $relative != *'..'* &&
                   $expected =~ ^[[:xdigit:]]{64}$ ]] || return 1
                artifact="${RECOVERY_ROOT}/${relative}"
                [[ -f $artifact && ! -L $artifact ]] || return 1
                actual=$(sha256sum "$artifact" | cut -d' ' -f1) || return 1
                [[ $actual == "$expected" ]] || return 1
                ;;
            ARCHIVE)
                [[ $source == backups/* && $source != *'..'* &&
                   $relative =~ ^[[:xdigit:]]{64}$ ]] || return 1
                artifact="${RECOVERY_ROOT}/${source}"
                [[ -f $artifact && ! -L $artifact ]] || return 1
                actual=$(sha256sum "$artifact" | cut -d' ' -f1) || return 1
                [[ $actual == "$relative" ]] || return 1
                ;;
        esac
    done < "$manifest"
}

validate_manifest_semantics_file() (
    local manifest=$1 kernel=${2:-$EXPECTED_KERNEL}
    local expected_file= archive_count state_count archive_relative archive list_file=

    expected_file=$(mktemp --tmpdir="$RECOVERY_ROOT" '.manifest-expected.XXXXXX') || return 1
    list_file=$(mktemp --tmpdir="$RECOVERY_ROOT" '.manifest-archive-list.XXXXXX') || return 1
    trap 'rm -f -- "$expected_file" "$list_file"' EXIT HUP INT TERM
    write_expected_state_paths "$kernel" "$expected_file" || return 1
    archive_count=$(awk -F '\t' '$1 == "ARCHIVE" { count++ } END { print count+0 }' "$manifest") || return 1
    state_count=$(awk -F '\t' '$1 == "STATE" { count++ } END { print count+0 }' "$manifest") || return 1
    if [[ $archive_count -eq 0 ]]; then
        [[ $state_count -eq 0 ]]
        return
    fi
    [[ $archive_count -eq 1 ]] || return 1
    awk -F '\t' '
        NR == FNR { expected[$0]++; next }
        $1 == "STATE" { actual[$3]++; status[$3]=$2 }
        END {
            for (path in expected)
                if (expected[path] != 1 || actual[path] != 1) exit 1
            for (path in actual)
                if (!(path in expected) || actual[path] != 1) exit 1
        }
    ' "$expected_file" "$manifest" || return 1

    archive_relative=$(awk -F '\t' '$1 == "ARCHIVE" { print $2 }' "$manifest") || return 1
    archive="${RECOVERY_ROOT}/${archive_relative}"
    tar -tf "$archive" > "$list_file" || return 1
    while IFS=$'\t' read -r type status path artifact; do
        [[ $type == STATE ]] || continue
        relative=${path#/}
        if [[ $status == ARCHIVED ]]; then
            awk -v wanted="$relative" '$0 == wanted || $0 == wanted "/" { found=1 } END { exit !found }' \
                "$list_file" || return 1
        else
            if awk -v wanted="$relative" '$0 == wanted || $0 == wanted "/" { found=1 } END { exit !found }' \
                "$list_file"; then
                return 1
            fi
        fi
    done < "$manifest"
)

validate_recovery_manifest() {
    validate_manifest_file "$RECOVERY_MANIFEST" &&
        validate_manifest_semantics_file "$RECOVERY_MANIFEST" "$EXPECTED_KERNEL" || {
        recovery_error "manifesto ausente, malformado, duplicado ou corrompido: $RECOVERY_MANIFEST"
        return 1
    }
}

initialize_recovery_manifest() {
    [[ $RECOVERY_LOCK_HELD == 1 ]] || {
        recovery_error 'manifesto não pode ser aberto sem lock exclusivo'
        return 1
    }
    if [[ -L $RECOVERY_ROOT || -L $RECOVERY_MANIFEST ]] ||
        [[ ! -d $RECOVERY_ROOT ]] ||
        [[ -e $RECOVERY_MANIFEST && ! -f $RECOVERY_MANIFEST ]]; then
        recovery_error "path de recovery inseguro: $RECOVERY_ROOT"
        return 1
    fi
    if [[ -L ${RECOVERY_ROOT}/backups || -L ${RECOVERY_ROOT}/backups/files ]] ||
        [[ -e ${RECOVERY_ROOT}/backups && ! -d ${RECOVERY_ROOT}/backups ]] ||
        [[ -e ${RECOVERY_ROOT}/backups/files && ! -d ${RECOVERY_ROOT}/backups/files ]]; then
        recovery_error 'árvore de backups contém path não real ou symlink'
        return 1
    fi
    install -d -m 0700 "${RECOVERY_ROOT}/backups/files" || return 1
    sync -f "${RECOVERY_ROOT}/backups/files" || return 1
    sync -f "${RECOVERY_ROOT}/backups" || return 1
    sync -f "$RECOVERY_ROOT" || return 1
    if [[ ! -e $RECOVERY_MANIFEST ]]; then
        printf 'FORMAT\t2\nDATE\t2026-08-20\n' > "$RECOVERY_MANIFEST" || return 1
        chmod 0600 "$RECOVERY_MANIFEST" || return 1
        sync -f "$RECOVERY_MANIFEST" || return 1
    fi
    validate_recovery_manifest
}

append_manifest_record() (
    local record=$1 candidate=

    [[ $RECOVERY_LOCK_HELD == 1 && $record != *$'\n'* ]] || return 1
    validate_recovery_manifest || return 1
    candidate=$(mktemp --tmpdir="$RECOVERY_ROOT" '.manifest.new.XXXXXX') || return 1
    cleanup_manifest_candidate() {
        [[ -z $candidate ]] || rm -f -- "$candidate"
    }
    trap cleanup_manifest_candidate EXIT HUP INT TERM
    cp --no-dereference --preserve=mode,ownership -- "$RECOVERY_MANIFEST" "$candidate" || return 1
    printf '%s\n' "$record" >> "$candidate" || return 1
    validate_manifest_file "$candidate" || return 1
    validate_manifest_semantics_file "$candidate" "$EXPECTED_KERNEL" || return 1
    sync -f "$candidate" || return 1
    mv -Tf -- "$candidate" "$RECOVERY_MANIFEST" || return 1
    candidate=
    sync -f "$RECOVERY_ROOT"
)

append_manifest_records_file() (
    local records_file=$1 candidate=

    [[ $RECOVERY_LOCK_HELD == 1 && -f $records_file && ! -L $records_file ]] || return 1
    validate_recovery_manifest || return 1
    candidate=$(mktemp --tmpdir="$RECOVERY_ROOT" '.manifest-batch.new.XXXXXX') || return 1
    cleanup_manifest_batch() {
        [[ -z $candidate ]] || rm -f -- "$candidate"
    }
    trap cleanup_manifest_batch EXIT HUP INT TERM
    cp --no-dereference --preserve=mode,ownership -- "$RECOVERY_MANIFEST" "$candidate" || return 1
    cat "$records_file" >> "$candidate" || return 1
    validate_manifest_file "$candidate" || return 1
    validate_manifest_semantics_file "$candidate" "$EXPECTED_KERNEL" || return 1
    sync -f "$candidate" || return 1
    mv -Tf -- "$candidate" "$RECOVERY_MANIFEST" || return 1
    candidate=
    sync -f "$RECOVERY_ROOT"
)

manifest_has_path() {
    local path=$1

    validate_recovery_manifest || return 2
    awk -F '\t' -v wanted="$path" \
        '($1 == "BACKUP" || $1 == "CREATED" || $1 == "SYMLINK") && $2 == wanted { found=1 } END { exit !found }' \
        "$RECOVERY_MANIFEST"
}

backup_managed_path() (
    local path=$1 backup_path relative_backup source_type checksum path_id candidate=

    cleanup_backup_candidate() {
        [[ -z $candidate ]] || rm -f -- "$candidate"
    }
    trap cleanup_backup_candidate EXIT HUP INT TERM

    if [[ $path != /* || $path == *$'\n'* || $path == *$'\t'* ]]; then
        recovery_error "path de backup inválido: $path"
        return 1
    fi
    if manifest_has_path "$path"; then
        return 0
    elif [[ $? -eq 2 ]]; then
        return 1
    fi

    if [[ -L $path ]]; then
        source_type=$(readlink -- "$path") || return 1
        [[ $source_type != *$'\n'* && $source_type != *$'\t'* ]] || return 1
        append_manifest_record $'SYMLINK\t'"$path"$'\t'"$source_type"$'\t-'
        return
    fi
    if [[ ! -e $path ]]; then
        append_manifest_record $'CREATED\t'"$path"$'\t-'
        return
    fi
    if [[ ! -f $path ]]; then
        recovery_error "backup individual exige arquivo regular ou symlink: $path"
        return 1
    fi

    path_id=$(printf '%s' "$path" | sha256sum | cut -d' ' -f1) || return 1
    relative_backup="backups/files/${path_id}.backup"
    backup_path="${RECOVERY_ROOT}/${relative_backup}"
    if [[ -e $backup_path || -L $backup_path ]]; then
        recovery_error "backup não manifestado já existe: $backup_path"
        return 1
    fi
    install -d -m 0700 "$(dirname "$backup_path")" || return 1
    candidate="${backup_path}.new.$$"
    [[ ! -e $candidate && ! -L $candidate ]] || return 1
    cp --no-dereference --preserve=all -- "$path" "$candidate" || return 1
    [[ -f $candidate && ! -L $candidate ]] || return 1
    sync -f "$candidate" || return 1
    mv -Tf -- "$candidate" "$backup_path" || return 1
    candidate=
    sync -f "$(dirname "$backup_path")" || return 1
    checksum=$(sha256sum "$backup_path" | cut -d' ' -f1) || return 1
    append_manifest_record $'BACKUP\t'"$path"$'\t'"$relative_backup"$'\t'"$checksum"
)

record_prior_incident() {
    local incident_id=task4-old-initramfs-dkms-hook

    validate_recovery_manifest || return 1
    if ! grep -qF $'INCIDENT\t'"$incident_id"$'\t' "$RECOVERY_MANIFEST"; then
        append_manifest_record $'INCIDENT\t'"$incident_id"$'\tretained /boot/initramfs-6.19.10-300.fc44.aarch64.img rewrite and /var/tmp/dracut.dRkFu6m; no automatic rollback or cleanup'
    fi
}

record_baseline_status() {
    validate_recovery_manifest || return 1
    if ! grep -qF $'AUDIT\tpre-reboot\t' "$RECOVERY_MANIFEST"; then
        append_manifest_record $'AUDIT\tpre-reboot\t'"$RECOVERY_BASELINE_STATUS"
    fi
}

recovery_archive_apparent_bytes() (
    local state_paths=$1 nul_list= path

    nul_list=$(mktemp --tmpdir="$RECOVERY_ROOT" '.disk-roots.XXXXXX') || return 1
    trap 'rm -f -- "$nul_list"' EXIT HUP INT TERM
    while IFS= read -r path; do
        [[ -e $path || -L $path ]] || continue
        printf '%s\0' "$path" >> "$nul_list" || return 1
    done < "$state_paths"
    if [[ ! -s $nul_list ]]; then
        printf '0\n'
        return
    fi
    du --apparent-size --bytes --summarize --files0-from="$nul_list" |
        awk '{ total += $1 } END { print total+0 }'
)

recovery_available_bytes() {
    df --output=avail --block-size=1 "$RECOVERY_ROOT" |
        awk 'NR == 2 { print $1+0 }'
}

preflight_recovery_disk_space() (
    local kernel=$1 state_paths=${2:-} generated_state= archive_bytes available needed
    local build_scratch=${RECOVERY_BUILD_SCRATCH_BYTES:-6442450944}
    local candidate_scratch=${RECOVERY_CANDIDATE_SCRATCH_BYTES:-1073741824}
    local margin=${RECOVERY_SPACE_MARGIN_BYTES:-2147483648}

    trap '[[ -z $generated_state ]] || rm -f -- "$generated_state"' EXIT HUP INT TERM

    if [[ -z $state_paths ]]; then
        state_paths=$(mktemp --tmpdir="$RECOVERY_ROOT" '.disk-state.XXXXXX') || return 1
        generated_state=$state_paths
        write_expected_state_paths "$kernel" "$state_paths" || return 1
    fi
    archive_bytes=$(recovery_archive_apparent_bytes "$state_paths") || return 1
    available=$(recovery_available_bytes) || return 1
    [[ $archive_bytes =~ ^[0-9]+$ && $available =~ ^[0-9]+$ &&
       $build_scratch =~ ^[0-9]+$ && $candidate_scratch =~ ^[0-9]+$ &&
       $margin =~ ^[0-9]+$ ]] || return 1
    needed=$((archive_bytes + build_scratch + candidate_scratch + margin))
    if (( available < needed )); then
        recovery_error "espaço insuficiente no filesystem de recovery: precisa ${needed}, disponível ${available} bytes"
        return 1
    fi
)

capture_recovery_state() (
    local kernel=$1 archive_relative=backups/state-before.tar
    local archive="${RECOVERY_ROOT}/${archive_relative}"
    local archive_tmp= state_paths= list_file= records_file= batch_file=
    local found_file= path relative checksum status

    validate_recovery_manifest || return 1
    if grep -qF $'ARCHIVE\t'"$archive_relative"$'\t' "$RECOVERY_MANIFEST"; then
        return 0
    fi
    if [[ -e $archive || -L $archive ]]; then
        recovery_error "archive de estado não manifestado já existe: $archive"
        return 1
    fi

    preflight_mutable_state_paths "$kernel" || return 1
    state_paths=$(mktemp --tmpdir="$RECOVERY_ROOT" '.state-expected.XXXXXX') || return 1
    list_file=$(mktemp --tmpdir="$RECOVERY_ROOT" '.state-list.XXXXXX') || return 1
    records_file=$(mktemp --tmpdir="$RECOVERY_ROOT" '.state-records.XXXXXX') || return 1
    batch_file=$(mktemp --tmpdir="$RECOVERY_ROOT" '.state-batch.XXXXXX') || return 1
    found_file=$(mktemp --tmpdir="$RECOVERY_ROOT" '.state-find.XXXXXX') || return 1
    archive_tmp=$(mktemp --tmpdir="${RECOVERY_ROOT}/backups" '.state-before.tar.new.XXXXXX') || return 1
    cleanup_state_capture() {
        [[ -z $state_paths ]] || rm -f -- "$state_paths"
        [[ -z $list_file ]] || rm -f -- "$list_file"
        [[ -z $records_file ]] || rm -f -- "$records_file"
        [[ -z $batch_file ]] || rm -f -- "$batch_file"
        [[ -z $found_file ]] || rm -f -- "$found_file"
        [[ -z $archive_tmp ]] || rm -f -- "$archive_tmp"
    }
    trap cleanup_state_capture EXIT HUP INT TERM

    write_expected_state_paths "$kernel" "$state_paths" || return 1
    if ! find "${RECOVERY_MODULES_ROOT}/${kernel}" -maxdepth 1 \
        \( -type f -o -type l \) -name 'modules.*' -print > "$found_file"; then
        recovery_error 'find falhou ao enumerar metadata depmod'
        return 1
    fi
    [[ -f $found_file && ! -L $found_file ]] || return 1
    while IFS= read -r path; do
        grep -Fxq -- "$path" "$state_paths" || {
            recovery_error "metadata depmod fora da allowlist: $path"
            return 1
        }
    done < "$found_file"

    while IFS= read -r path; do
        [[ $path == /* && $path != *$'\n'* && $path != *$'\t'* ]] || return 1
        if [[ -e $path || -L $path ]]; then
            status=ARCHIVED
            relative=${path#/}
            printf '%s\0' "$relative" >> "$list_file" || return 1
            printf 'STATE\tARCHIVED\t%s\t%s\n' "$path" "$archive_relative" >> "$records_file"
        else
            printf 'STATE\tCREATED\t%s\t-\n' "$path" >> "$records_file"
        fi
    done < "$state_paths"

    sort -zu "$list_file" -o "$list_file" || return 1
    if [[ -s $list_file ]]; then
        tar --create --file "$archive_tmp" --directory=/ --null \
            --acls --xattrs --selinux --numeric-owner \
            --files-from="$list_file" || return 1
    else
        tar --create --file "$archive_tmp" --files-from=/dev/null || return 1
    fi
    [[ -f $archive_tmp && ! -L $archive_tmp ]] || return 1
    sync -f "$archive_tmp" || return 1
    mv -Tf -- "$archive_tmp" "$archive" || return 1
    archive_tmp=
    sync -f "${RECOVERY_ROOT}/backups" || return 1
    checksum=$(sha256sum "$archive" | cut -d' ' -f1) || return 1
    printf 'ARCHIVE\t%s\t%s\n' "$archive_relative" "$checksum" > "$batch_file" || return 1
    cat "$records_file" >> "$batch_file" || return 1
    append_manifest_records_file "$batch_file" || return 1
    sync -f "$RECOVERY_ROOT"
)

preflight_recovery_mutation_paths() {
    local kernel=$1

    preflight_core_paths "$kernel" || return 1
    preflight_recovery_config_paths
}

backup_recovery_paths() {
    local kernel=$1 package_record module source_name artifact path target
    local -a paths=(
        "${MODULES_LOAD_CONFIG_DIR:-/etc/modules-load.d}/vivobook-core.conf"
        "${DRACUT_CONFIG_DIR}/vivobook-core.conf"
        "${DRACUT_CONFIG_DIR}/qcom-remoteproc.conf"
        "${DRACUT_CONFIG_DIR}/qcom-gpu-firmware.conf"
        /etc/systemd/system/sleep.target
        /etc/systemd/system/suspend.target
        /etc/systemd/system/hibernate.target
        /etc/systemd/system/hybrid-sleep.target
        /etc/systemd/system/suspend-then-hibernate.target
        "${RECOVERY_BOOT_ROOT}/initramfs-${kernel}.img"
    )
    for target in "${paths[@]}"; do
        backup_managed_path "$target" || return 1
    done
}

verify_installed_module() {
    local kernel=$1 module=$2 required=${3:-1} path module_root canonical_path vermagic release

    if ! path=$(modinfo -k "$kernel" -n "$module" 2>/dev/null); then
        if [[ $required == 0 ]]; then
            return 0
        fi
        recovery_error "módulo instalado não resolve para ${kernel}: $module"
        return 1
    fi
    module_root=$(readlink -f "${RECOVERY_MODULES_ROOT}/${kernel}") || return 1
    canonical_path=$(readlink -f "$path") || return 1
    if [[ $path != "${RECOVERY_MODULES_ROOT}/${kernel}/"* ||
          $canonical_path != "${module_root}/"* || ! -f $path || -L $path ]]; then
        recovery_error "path instalado fora da árvore segura de ${kernel}: $module -> $path"
        return 1
    fi
    vermagic=$(modinfo -F vermagic "$path") || return 1
    release=${vermagic%% *}
    if [[ $release != "$kernel" ]]; then
        recovery_error "vermagic instalado incorreto para $module: $vermagic"
        return 1
    fi
}

verify_recovery_checkpoint() {
    local kernel=$1 module target image
    local -a modules=(
        wcn_regulator_fix vivobook_kbd_fix vivobook_bl_fix vivobook_hotkey_fix
    )

    if [[ ! -d ${RECOVERY_MODULES_ROOT}/${kernel} ||
          -L ${RECOVERY_MODULES_ROOT}/${kernel} ]]; then
        recovery_error "árvore final de módulos insegura: ${RECOVERY_MODULES_ROOT}/${kernel}"
        return 1
    fi
    for module in "${modules[@]}"; do
        verify_installed_module "$kernel" "$module" 1 || return 1
    done
    verify_installed_module "$kernel" vivobook_cam_fix 0 || return 1
    image="${RECOVERY_BOOT_ROOT}/initramfs-${kernel}.img"
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
    run_gate 'Fedora 44 obrigatório para esta recuperação' \
        verify_operating_system || return 1
    run_gate 'assets de recuperação ausentes' \
        verify_repository_entrypoints || return 1
    run_gate 'ferramentas básicas de lock/backup ausentes' \
        verify_recovery_base_commands || return 1
    run_gate 'não foi possível adquirir o lock exclusivo' \
        acquire_recovery_lock || return 1
    run_gate 'espaço insuficiente para archive/build/candidato' \
        preflight_recovery_disk_space "$kernel" || return 1
    run_gate 'manifesto de recovery não pôde ser inicializado' \
        initialize_recovery_manifest || return 1
    run_gate 'auditoria pré-reboot não executável' \
        run_pre_reboot_audit || return 1
    record_baseline_status || return 1
    run_gate 'preflight de todos os paths de mutação falhou' \
        preflight_recovery_mutation_paths "$kernel" || return 1
    preflight_mutable_state_paths "$kernel" || return 1
    run_gate 'firmware obrigatório não pôde ser resolvido' \
        resolve_kernel_requested_firmware || return 1
    record_prior_incident || return 1
    run_gate 'backup anterior às mutações falhou' \
        backup_recovery_paths "$kernel" || return 1
    run_gate 'captura do estado DKMS/build/depmod falhou' \
        capture_recovery_state "$kernel" || return 1
    run_gate 'dependências exatas não puderam ser instaladas/verificadas' \
        install_exact_dependencies recovery || return 1
    run_gate 'namespace DKMS privado indisponível' \
        preflight_dkms_namespace || return 1
    preflight_mutable_state_paths "$kernel" || return 1

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
