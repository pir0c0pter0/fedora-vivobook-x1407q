#!/bin/bash
# =============================================================================
# setup-vivobook.sh — PARTE 2: aplica todos os fixes no Vivobook já bootado
# ASUS Vivobook X1407QA (Snapdragon X) — Fedora 44 aarch64
#
# Empacotado no ISO pela Parte 1 (build-vivobook-iso.sh) em /opt/vivobook-fixes/.
# Faz stage automático dos módulos DKMS (modules/ -> /usr/src) e do firmware
# bundled (firmware/ -> /usr/lib/firmware) quando rodado de /opt/vivobook-fixes/.
#
# Pré-requisitos:
#   - Fedora 44 aarch64 instalado e bootado no Vivobook
#   - Firmware: bundled no ISO (auto-staged) OU extraído do Windows antes:
#       sudo /opt/vivobook-fixes/extract-qcom-firmware.sh
#
# Usage: sudo bash /opt/vivobook-fixes/setup-vivobook.sh
# =============================================================================

set -uo pipefail

VERSION="2.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~${REAL_USER}")
FIRMWARE_ROOT="${FIRMWARE_ROOT:-/usr/lib/firmware}"
DRACUT_CONFIG_DIR="${DRACUT_CONFIG_DIR:-/etc/dracut.conf.d}"
KERNEL_MODULES_ROOT="${KERNEL_MODULES_ROOT:-/usr/lib/modules}"
VULKAN_CONFIG_DIR="${VULKAN_CONFIG_DIR:-${REAL_HOME}/.config/environment.d}"
UDEV_RULES_DIR="${UDEV_RULES_DIR:-/etc/udev/rules.d}"
LIBCAMERA_IPA_SIMPLE_DIR="${LIBCAMERA_IPA_SIMPLE_DIR:-/usr/share/libcamera/ipa/simple}"
REAL_USER_UID=$(id -u "$REAL_USER" 2>/dev/null || true)
REAL_RUNTIME_DIR="/run/user/${REAL_USER_UID}"
# Test-only override: production always derives /run/user/<uid> above.
if [[ ${VIVOBOOK_SETUP_TEST_MODE:-0} == 1 ]]; then
    REAL_RUNTIME_DIR=${VIVOBOOK_TEST_RUNTIME_DIR:?VIVOBOOK_TEST_RUNTIME_DIR is required in test mode}
fi
REAL_DBUS_SESSION_BUS_ADDRESS="unix:path=${REAL_RUNTIME_DIR}/bus"

# ─── Colors & logging ────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()    { echo -e "${GREEN}[+]${NC} $*"; }
warn()   { echo -e "${YELLOW}[!]${NC} $*"; }
err()    { echo -e "${RED}[x]${NC} $*"; }
info()   { echo -e "${CYAN}[i]${NC} $*"; }
step()   { echo -e "${GREEN}[${1}/${2}]${NC} ${3}"; }

CORE_DKMS_PACKAGES=(
    "wcn-regulator-fix:wcn_regulator_fix.c:wcn_regulator_fix"
    "vivobook-kbd-fix:vivobook_kbd_fix.c:vivobook_kbd_fix"
    "vivobook-bl-fix:vivobook_bl_fix.c:vivobook_bl_fix"
    "vivobook-hotkey-fix:vivobook_hotkey_fix.c:vivobook_hotkey_fix"
)
CAMERA_DKMS_PACKAGES=(
    "vivobook-cam-fix:2.0:vivobook_cam_fix"
    "vivobook-ir-cam:1.0:hm1092"
)
CAMERA_DKMS_FILES=(
    "vivobook-cam-fix-2.0/Makefile"
    "vivobook-cam-fix-2.0/dkms.conf"
    "vivobook-cam-fix-2.0/vivobook_cam_fix.c"
    "vivobook-cam-fix-2.0/vivobook_cam_phase1.dts"
    "vivobook-cam-fix-2.0/vivobook_cam_phase2.dts"
    "vivobook-ir-cam-1.0/Makefile"
    "vivobook-ir-cam-1.0/dkms.conf"
    "vivobook-ir-cam-1.0/hm1092.c"
    "vivobook-ir-cam-1.0/hm1092_ir_sequence.h"
    "vivobook-ir-cam-1.0/hm1092_regs.h"
)
CORE_SOURCE_MANIFEST=(
    "modules/wcn-regulator-fix-1.0/wcn_regulator_fix.c:471793ec12df3785b652857aec4800c957fe3518bc33bae229daf1f326ce4180"
    "modules/wcn-regulator-fix-1.0/Makefile:2c73bfe02197b0fc21d9fe3e3a430cdc679374754425bb16e4036b72accb945e"
    "modules/wcn-regulator-fix-1.0/dkms.conf:197fa6ebbfcae133677ee673cbcfd4a8eccb5049594b63211cfcb4f691accd32"
    "modules/vivobook-kbd-fix-1.0/vivobook_kbd_fix.c:1148c3c615355bd67a689f453d4d4264f6529f9ee00b403e08ee08eda6581bed"
    "modules/vivobook-kbd-fix-1.0/Makefile:3949986b88aa04977031137720e58263bcdfe4dfb0dafba8b0ad016568f58967"
    "modules/vivobook-kbd-fix-1.0/dkms.conf:8a9f059d3b7028026b42582212257e1d0131fbe8f72b50c2dbf8c18664097a7c"
    "modules/vivobook-bl-fix-1.0/vivobook_bl_fix.c:b8da1abc280585d11d093c462df4197ac62871d2bb8d324ba0e52b5cba2691f1"
    "modules/vivobook-bl-fix-1.0/Makefile:129514b245ff3532e8a6db91f9e811893799f82868fb72d35f1f4adb8718f0b3"
    "modules/vivobook-bl-fix-1.0/dkms.conf:c2ffc9c6003dea39bbd55ef60dff1f2986b447d6f15333448518c7a8355e2ed4"
    "modules/vivobook-hotkey-fix-1.0/vivobook_hotkey_fix.c:b70a6204b5ee88ee8f2cadac2ed8864764cef051a2a526bf419867dbb3eac1ab"
    "modules/vivobook-hotkey-fix-1.0/Makefile:d93e53b7385906b9e8e9dce967dc542af2682e84ab5426ce7ca7fa791bbda1da"
    "modules/vivobook-hotkey-fix-1.0/dkms.conf:4eca02cf4a530456e6173cd0409692a05ef9c37bd63c95987224caebfe4df72b"
)

# ─── Root check ──────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 && ${VIVOBOOK_SETUP_LIBRARY_ONLY:-0} != 1 ]]; then
    err "Execute como root: sudo bash setup-vivobook.sh"
    exit 1
fi

# ─── Dependencies ────────────────────────────────────────────────────────────
install_exact_dependencies() {
    local scope=${1:-setup} package command_name
    local -a build_packages=(gcc cpp make dkms perl elfutils-libelf-devel openssl-devel flex bison bc dtc xxd)
    local -a runtime_packages=(curl tar xz dracut kmod util-linux)
    if [[ $scope == setup ]]; then
        runtime_packages+=(
            grubby libcamera-gstreamer libcamera-tools pipewire-plugin-libcamera
            python3-pip vulkan-tools
        )
    elif [[ $scope != recovery ]]; then
        err "Escopo de dependências desconhecido: $scope"
        return 1
    fi
    local -a approved_packages=("${build_packages[@]}" "${runtime_packages[@]}")
    local -a missing_packages=()

    for package in "${approved_packages[@]}"; do
        rpm -q "$package" &>/dev/null || missing_packages+=("$package")
    done
    if [[ ${#missing_packages[@]} -gt 0 ]]; then
        warn "Dependências aprovadas faltando: ${missing_packages[*]}"
        info "Instalando somente as dependências nomeadas que estão ausentes..."
        if ! dnf install -y "${missing_packages[@]}"; then
            err "Falha ao instalar dependências aprovadas"
            return 1
        fi
    fi
    for package in "${approved_packages[@]}"; do
        if ! rpm -q "$package" &>/dev/null; then
            err "Dependência obrigatória ausente: $package"
            return 1
        fi
    done
    for command_name in \
        awk bc cpp curl depmod dkms dnf dracut dtc fdtget flock grep install lsinitrd make \
        modinfo mount mv rpm sha256sum systemctl tar unshare xz xxd; do
        if ! command -v "$command_name" &>/dev/null; then
            err "Comando obrigatório ausente: $command_name"
            return 1
        fi
    done
    if [[ $scope == setup ]]; then
        for command_name in grubby grub2-mkconfig modprobe; do
            if ! command -v "$command_name" &>/dev/null; then
                err "Comando obrigatório do setup ausente: $command_name"
                return 1
            fi
        done
    fi
}

check_deps() {
    install_exact_dependencies
}

# ─── Prompt ───────────────────────────────────────────────────────────────────
prompt_yn() {
    local msg="$1" default="${2:-s}"
    local choice
    if [[ "$default" == "s" ]]; then
        read -rp "$(echo -e "${msg} [${BOLD}S${NC}/n]: ")" choice </dev/tty || choice=""
        [[ -z "$choice" || "$choice" =~ ^[Ss]$ ]]
    else
        read -rp "$(echo -e "${msg} [s/${BOLD}N${NC}]: ")" choice </dev/tty || choice=""
        [[ "$choice" =~ ^[Ss]$ ]]
    fi
}

# GNOME settings must be sent to the invoking user's live session, never to a
# root/default dconf database.  A missing bus is an explicit pending state.
real_user_session_available() {
    local owner_reply

    [[ -n "$REAL_USER_UID" && -d "$REAL_RUNTIME_DIR" && ! -L "$REAL_RUNTIME_DIR" &&
        -S "${REAL_RUNTIME_DIR}/bus" && ! -L "${REAL_RUNTIME_DIR}/bus" ]] || return 3
    [[ $(stat -c %u "$REAL_RUNTIME_DIR") == "$REAL_USER_UID" &&
        $(stat -c %u "${REAL_RUNTIME_DIR}/bus") == "$REAL_USER_UID" ]] || return 3
    if command -v gdbus >/dev/null 2>&1; then
        owner_reply=$(run_as_real_user env XDG_RUNTIME_DIR="$REAL_RUNTIME_DIR" \
            DBUS_SESSION_BUS_ADDRESS="$REAL_DBUS_SESSION_BUS_ADDRESS" \
            gdbus call --session --dest org.freedesktop.DBus \
            --object-path /org/freedesktop/DBus \
            --method org.freedesktop.DBus.NameHasOwner org.gnome.Shell 2>/dev/null) || return 3
        [[ $owner_reply == *true* ]] || return 3
    elif command -v busctl >/dev/null 2>&1; then
        owner_reply=$(run_as_real_user env XDG_RUNTIME_DIR="$REAL_RUNTIME_DIR" \
            DBUS_SESSION_BUS_ADDRESS="$REAL_DBUS_SESSION_BUS_ADDRESS" \
            busctl --user call org.freedesktop.DBus /org/freedesktop/DBus \
            org.freedesktop.DBus NameHasOwner s org.gnome.Shell 2>/dev/null) || return 3
        [[ $owner_reply == *true* ]] || return 3
    else
        return 3
    fi
}

run_as_real_user() {
    sudo -u "$REAL_USER" env HOME="$REAL_HOME" SUDO_USER="$REAL_USER" "$@"
}

run_as_real_user_session() {
    real_user_session_available || return 3
    run_as_real_user env \
        XDG_RUNTIME_DIR="$REAL_RUNTIME_DIR" \
        DBUS_SESSION_BUS_ADDRESS="$REAL_DBUS_SESSION_BUS_ADDRESS" "$@"
}

# ─── DKMS helper ─────────────────────────────────────────────────────────────
run_dkms_without_runtime_hooks() (
    local override_root result

    override_root=$(mktemp -d /run/vivobook-dkms.XXXXXX) || return 1
    cleanup_dkms_namespace() {
        rm -rf -- "$override_root"
    }
    trap cleanup_dkms_namespace EXIT HUP INT TERM
    mkdir -p "$override_root/etc-dkms" || {
        return 1
    }
    if ! printf '%s\n' \
        'post_transaction=""' \
        'modprobe_on_install=""' > "$override_root/etc-dkms/framework.conf"; then
        return 1
    fi

    unshare --mount --propagation private -- bash -c '
        set -euo pipefail
        override_root=$1
        shift
        mount --bind "$override_root/etc-dkms" /etc/dkms
        exec "$@"
    ' vivobook-dkms "$override_root" "$@"
    result=$?
    return "$result"
)

preflight_dkms_namespace() {
    if [[ ! -d /etc/dkms ]] || [[ -L /etc/dkms ]]; then
        err "Layout de configuração DKMS não suportado"
        return 1
    fi
    if ! run_dkms_without_runtime_hooks bash -c '
        set -euo pipefail
        source /etc/dkms/framework.conf
        [[ ${post_transaction+x} && -z $post_transaction ]]
        [[ ${modprobe_on_install+x} && -z $modprobe_on_install ]]
        [[ -z $(find /etc/dkms -mindepth 1 ! -name framework.conf -print -quit) ]]
    '; then
        err "Namespace DKMS privado não suprimiu hooks de runtime"
        return 1
    fi
}

install_dkms_module() {
    local mod_name="$1"  # e.g. wcn-regulator-fix
    local mod_src="/usr/src/${mod_name}-1.0"

    if [[ ! -d "$mod_src" ]]; then
        warn "  ${mod_src} não encontrado — pulando"
        return 1
    fi

    if dkms status 2>/dev/null | grep -q "${mod_name}.*installed"; then
        log "  ${mod_name} já instalado"
        return 0
    fi

    err "  ${mod_name} não foi instalado pela fase core transacional"
    return 1
}

verify_repository_core_sources() {
    local source_record relative_path expected_hash source_path

    for source_record in "${CORE_SOURCE_MANIFEST[@]}"; do
        relative_path=${source_record%%:*}
        expected_hash=${source_record##*:}
        source_path="${SCRIPT_DIR}/${relative_path}"
        if [[ ! -f "$source_path" || -L "$source_path" ]] ||
            ! printf '%s  %s\n' "$expected_hash" "$source_path" |
            sha256sum --check --status; then
            err "Artefato core ausente, symlink ou com SHA-256 inesperado: $relative_path"
            return 1
        fi
    done
}

preflight_core_paths() {
    local kernel=$1 package_record module source_name artifact path destination
    local work_root=/var/lib/x1407qa-kernel-7.2
    local build_tree="${work_root}/module-build"
    local tarball="${work_root}/linux-7.2.tar.xz"
    local build_link="${KERNEL_MODULES_ROOT}/${kernel}/build"
    local build_link_tmp="${build_link}.x1407qa-new"
    local initramfs_dir=${INITRAMFS_BOOT_DIR:-/boot}
    local initramfs_target="${initramfs_dir}/initramfs-${kernel}.img"
    local initramfs_backup="${initramfs_target}.vivobook-backup"

    if [[ "$kernel" != 7.2.0-x1407qa ]]; then
        err "Kernel ativo inesperado para os módulos core: $kernel"
        return 1
    fi
    if [[ ! -f "/boot/config-${kernel}" || -L "/boot/config-${kernel}" ]]; then
        err "Config do kernel ausente, não regular ou symlink: /boot/config-${kernel}"
        return 1
    fi
    if [[ ! -d "${KERNEL_MODULES_ROOT}/${kernel}" || -L "${KERNEL_MODULES_ROOT}/${kernel}" ]]; then
        err "Diretório de módulos ausente, não diretório ou symlink: ${KERNEL_MODULES_ROOT}/${kernel}"
        return 1
    fi
    if [[ ! -d /usr/src || -L /usr/src ]]; then
        err "Diretório de fontes ausente, não diretório ou symlink: /usr/src"
        return 1
    fi
    for path in "$work_root" "$build_tree"; do
        if [[ -L "$path" ]] || [[ -e "$path" && ! -d "$path" ]]; then
            err "Diretório de build inseguro: $path"
            return 1
        fi
    done
    if [[ -L "$tarball" ]] || [[ -e "$tarball" && ! -f "$tarball" ]]; then
        err "Tarball path inseguro: $tarball"
        return 1
    fi
    if [[ -e "$build_link" && ! -L "$build_link" ]]; then
        err "Build link existente não é symlink: $build_link"
        return 1
    fi
    if [[ -e "$build_link_tmp" || -L "$build_link_tmp" ]]; then
        err "Link temporário preexistente: $build_link_tmp"
        return 1
    fi
    if [[ ! -d "$initramfs_dir" || -L "$initramfs_dir" ]]; then
        err "Diretório initramfs inseguro: $initramfs_dir"
        return 1
    fi
    for path in "$initramfs_target" "$initramfs_backup"; do
        if [[ -L "$path" ]] || [[ -e "$path" && ! -f "$path" ]]; then
            err "Destino initramfs inseguro: $path"
            return 1
        fi
    done
    verify_repository_core_sources || return 1

    for package_record in "${CORE_DKMS_PACKAGES[@]}"; do
        IFS=: read -r module source_name artifact <<< "$package_record"
        path="${SCRIPT_DIR}/modules/${module}-1.0"
        if [[ ! -d "$path" || -L "$path" ]]; then
            err "Pacote core inseguro: $path"
            return 1
        fi
        destination="/usr/src/${module}-1.0"
        if [[ -L "$destination" ]] ||
            [[ -e "$destination" && ! -d "$destination" ]]; then
            err "Destino DKMS inseguro: $destination"
            return 1
        fi
        for path in "$destination/$source_name" "$destination/Makefile" \
            "$destination/dkms.conf"; do
            if [[ -L "$path" ]]; then
                err "Destino DKMS contém symlink: $path"
                return 1
            fi
            if compgen -G "${path}.new.*" >/dev/null; then
                err "Stage DKMS temporário preexistente: ${path}.new.*"
                return 1
            fi
        done
    done
}

verify_staged_core_sources() {
    local source_record relative_path expected_hash staged_path

    for source_record in "${CORE_SOURCE_MANIFEST[@]}"; do
        relative_path=${source_record%%:*}
        expected_hash=${source_record##*:}
        staged_path="/usr/src/${relative_path#modules/}"
        if [[ ! -f "$staged_path" || -L "$staged_path" ]] ||
            ! printf '%s  %s\n' "$expected_hash" "$staged_path" |
                sha256sum --check --status; then
            err "Stage DKMS não preservou provenance: $staged_path"
            return 1
        fi
    done
}

stage_core_dkms_sources() (
    local package_record module source_name artifact source_path destination stage_tmp=

    cleanup_core_stage() {
        [[ -z "$stage_tmp" ]] || rm -f -- "$stage_tmp"
    }
    trap cleanup_core_stage EXIT HUP INT TERM

    for package_record in "${CORE_DKMS_PACKAGES[@]}"; do
        IFS=: read -r module source_name artifact <<< "$package_record"
        if [[ -L "/usr/src/${module}-1.0" ]] ||
            [[ -e "/usr/src/${module}-1.0" && ! -d "/usr/src/${module}-1.0" ]]; then
            err "Destino DKMS tornou-se inseguro: /usr/src/${module}-1.0"
            return 1
        fi
        for source_path in "$source_name" Makefile dkms.conf; do
            destination="/usr/src/${module}-1.0/${source_path}"
            if [[ -L "$destination" ]]; then
                err "Recusando sobrescrever symlink DKMS: $destination"
                return 1
            fi
            stage_tmp="${destination}.new.$$"
            if [[ -e "$stage_tmp" || -L "$stage_tmp" ]]; then
                err "Stage temporário preexistente: $stage_tmp"
                return 1
            fi
            if ! install -D -m 0644 \
                "${SCRIPT_DIR}/modules/${module}-1.0/${source_path}" "$stage_tmp" ||
                ! mv -Tf -- "$stage_tmp" "$destination"; then
                err "Falha ao instalar fonte DKMS do repositório: ${module}/${source_path}"
                return 1
            fi
            stage_tmp=
        done
        log "  DKMS source verificado e staged: ${module}-1.0"
    done
)

validate_core_module_symvers() {
    local symvers=$1

    [[ -f "$symvers" && ! -L "$symvers" ]] || return 1
    awk -F '\t' '
        NF < 4 || $1 !~ /^0x[[:xdigit:]]{8}$/ { invalid=1 }
        { records++ }
        END { exit(!(records >= 10000 && !invalid)) }
    ' "$symvers"
}

build_marker_value() {
    local marker=$1 key=$2

    [[ $(grep -c "^${key}=" "$marker") -eq 1 ]] || return 1
    sed -n "s/^${key}=//p" "$marker"
}

validate_core_module_build_tree() {
    local build_tree=$1 kernel=$2 source_sha256=$3 config_input_sha256=$4
    local marker="${build_tree}/.x1407qa-build-complete"
    local config_final_sha256 module_symvers_sha256 records

    [[ -d "$build_tree" && ! -L "$build_tree" ]] || return 1
    [[ -f "$marker" && ! -L "$marker" ]] || return 1
    [[ $(build_marker_value "$marker" kernel) == "$kernel" ]] || return 1
    [[ $(build_marker_value "$marker" source_archive_sha256) == "$source_sha256" ]] || return 1
    [[ $(build_marker_value "$marker" config_input_sha256) == "$config_input_sha256" ]] || return 1
    [[ -f "$build_tree/include/generated/utsrelease.h" &&
       ! -L "$build_tree/include/generated/utsrelease.h" ]] || return 1
    grep -qxF "#define UTS_RELEASE \"${kernel}\"" \
        "$build_tree/include/generated/utsrelease.h" || return 1
    [[ -f "$build_tree/.config" && ! -L "$build_tree/.config" ]] || return 1
    config_final_sha256=$(sha256sum "$build_tree/.config" | cut -d' ' -f1)
    [[ $(build_marker_value "$marker" config_final_sha256) == "$config_final_sha256" ]] || return 1
    validate_core_module_symvers "$build_tree/Module.symvers" || return 1
    module_symvers_sha256=$(sha256sum "$build_tree/Module.symvers" | cut -d' ' -f1)
    records=$(wc -l < "$build_tree/Module.symvers")
    [[ $(build_marker_value "$marker" module_symvers_sha256) == "$module_symvers_sha256" ]] || return 1
    [[ $(build_marker_value "$marker" module_symvers_records) == "$records" ]] || return 1
    [[ -s "$build_tree/vmlinux" && ! -L "$build_tree/vmlinux" &&
       -s "$build_tree/vmlinux.o" && ! -L "$build_tree/vmlinux.o" ]] || return 1
}

prepare_core_module_build_tree() (
    local kernel=$1
    local expected_sha256=f9fef3d14c0df53819026f4be74459835c2a0b0dcbf5b5bbd9ea19f0829402b3
    local source_url=https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.2.tar.xz
    local work_root=/var/lib/x1407qa-kernel-7.2
    local tarball="${work_root}/linux-7.2.tar.xz"
    local build_tree=/var/lib/x1407qa-kernel-7.2/module-build
    local build_link="${KERNEL_MODULES_ROOT}/${kernel}/build"
    local kernel_suffix=${kernel#7.2.0}
    local download_tmp= prepare_root= prepared_source= link_tmp=
    local previous_tree= marker_tmp= config_input_sha256 config_final_sha256
    local module_symvers_sha256 module_symvers_records

    cleanup_core_build_prepare() {
        [[ -z "$download_tmp" ]] || rm -f -- "$download_tmp"
        [[ -z "$link_tmp" ]] || rm -f -- "$link_tmp"
        [[ -z "$prepare_root" ]] || rm -rf -- "$prepare_root"
        if [[ -n "$previous_tree" && -d "$previous_tree" && ! -e "$build_tree" ]]; then
            mv -T -- "$previous_tree" "$build_tree" || true
        fi
    }
    trap cleanup_core_build_prepare EXIT HUP INT TERM

    if [[ -L "$work_root" ]] || [[ -e "$work_root" && ! -d "$work_root" ]] ||
        [[ -L "$build_tree" ]] || [[ -e "$build_tree" && ! -d "$build_tree" ]] ||
        [[ -L "$tarball" ]] || [[ -e "$tarball" && ! -f "$tarball" ]] ||
        [[ -e "${build_link}.x1407qa-new" || -L "${build_link}.x1407qa-new" ]]; then
        err "Paths do build tree mudaram após o preflight"
        return 1
    fi

    if [[ "$kernel" != 7.2.0-x1407qa ]]; then
        err "Kernel ativo inesperado para os módulos core: $kernel"
        return 1
    fi
    if [[ ! -f "/boot/config-${kernel}" || -L "/boot/config-${kernel}" ]]; then
        err "Config do kernel ativo ausente: /boot/config-${kernel}"
        return 1
    fi
    config_input_sha256=$(sha256sum "/boot/config-${kernel}" | cut -d' ' -f1) || return 1
    mkdir -p "$work_root" || return 1

    if [[ ! -f "$tarball" ]]; then
        download_tmp="${tarball}.part.$$"
        if ! curl --fail --location --proto '=https' --tlsv1.2 \
            --output "$download_tmp" "$source_url"; then
            rm -f -- "$download_tmp"
            err "Falha ao baixar Linux 7.2"
            return 1
        fi
        if ! printf '%s  %s\n' "$expected_sha256" "$download_tmp" |
            sha256sum --check --status; then
            rm -f -- "$download_tmp"
            err "SHA-256 do tarball Linux 7.2 não confere"
            return 1
        fi
        mv -Tf -- "$download_tmp" "$tarball" || return 1
        download_tmp=
    fi
    if ! printf '%s  %s\n' "$expected_sha256" "$tarball" |
        sha256sum --check --status; then
        err "SHA-256 do tarball Linux 7.2 não confere"
        return 1
    fi

    if ! validate_core_module_build_tree "$build_tree" "$kernel" \
        "$expected_sha256" "$config_input_sha256"; then
        warn "Build tree ausente, parcial ou stale; reconstruindo de fonte verificada"
        prepare_root=$(mktemp -d "${work_root}/.module-build.XXXXXX") || return 1
        if ! tar -xJf "$tarball" -C "$prepare_root"; then
            rm -rf -- "$prepare_root"
            err "Falha ao extrair o tarball Linux 7.2 verificado"
            return 1
        fi
        prepared_source="${prepare_root}/linux-7.2"
        if ! install -m 0644 "/boot/config-${kernel}" "${prepared_source}/.config"; then
            rm -rf -- "$prepare_root"
            return 1
        fi
        if ! (
            cd "$prepared_source" || exit 1
            export LOCALVERSION="$kernel_suffix"
            make olddefconfig modules_prepare
        ); then
            rm -rf -- "$prepare_root"
            err "Falha em make olddefconfig modules_prepare"
            return 1
        fi
        if ! grep -qxF "#define UTS_RELEASE \"${kernel}\"" \
            "$prepared_source/include/generated/utsrelease.h"; then
            rm -rf -- "$prepare_root"
            err "Build tree preparado não corresponde a ${kernel}"
            return 1
        fi
        if ! (
            cd "$prepared_source" || exit 1
            export LOCALVERSION="$kernel_suffix"
            make -j"$(nproc)" vmlinux
            make -j"$(nproc)" modules
        ); then
            err "Falha ao gerar Module.symvers no build tree verificado"
            return 1
        fi
        if ! validate_core_module_symvers "$prepared_source/Module.symvers"; then
            err "Module.symvers ausente, pequeno ou malformado"
            return 1
        fi
        config_final_sha256=$(sha256sum "$prepared_source/.config" | cut -d' ' -f1) || return 1
        module_symvers_sha256=$(sha256sum "$prepared_source/Module.symvers" | cut -d' ' -f1) || return 1
        module_symvers_records=$(wc -l < "$prepared_source/Module.symvers") || return 1
        marker_tmp="${prepared_source}/.x1407qa-build-complete.tmp"
        if ! printf '%s\n' \
            "kernel=${kernel}" \
            "source_archive_sha256=${expected_sha256}" \
            "config_input_sha256=${config_input_sha256}" \
            "config_final_sha256=${config_final_sha256}" \
            "module_symvers_sha256=${module_symvers_sha256}" \
            "module_symvers_records=${module_symvers_records}" > "$marker_tmp"; then
            return 1
        fi
        mv -Tf -- "$marker_tmp" "${prepared_source}/.x1407qa-build-complete" || return 1
        marker_tmp=
        validate_core_module_build_tree "$prepared_source" "$kernel" \
            "$expected_sha256" "$config_input_sha256" || return 1

        if [[ -e "$build_tree" ]]; then
            previous_tree="${work_root}/.module-build.previous.$$"
            mv -T -- "$build_tree" "$previous_tree" || return 1
        fi
        if ! mv -T -- "$prepared_source" "$build_tree"; then
            err "Falha ao promover build tree validado"
            return 1
        fi
        prepared_source=
        rmdir "$prepare_root" || return 1
        prepare_root=
        if [[ -n "$previous_tree" ]]; then
            rm -rf -- "$previous_tree"
            previous_tree=
        fi
    fi

    if ! validate_core_module_build_tree "$build_tree" "$kernel" \
        "$expected_sha256" "$config_input_sha256"; then
        err "Module.symvers ausente ou inválido no build tree verificado"
        return 1
    fi

    if [[ -e "$build_link" && ! -L "$build_link" ]]; then
        err "Recusando substituir build path que não é symlink: $build_link"
        return 1
    fi
    link_tmp="${build_link}.x1407qa-new"
    ln -sfn "$build_tree" "$link_tmp" || return 1
    mv -Tf -- "$link_tmp" "$build_link" || return 1
    if [[ $(readlink -f "$build_link") != "$build_tree" ]]; then
        err "Build link não aponta para o tree verificado"
        return 1
    fi
    log "  Build tree verificado: $build_tree"
)

build_core_dkms_modules() {
    local kernel=$1 package_record module source_name artifact mod_src

    preflight_dkms_namespace || return 1
    verify_staged_core_sources || return 1
    for package_record in "${CORE_DKMS_PACKAGES[@]}"; do
        IFS=: read -r module source_name artifact <<< "$package_record"
        mod_src="/usr/src/${module}-1.0"
        if ! dkms status "${module}/1.0" -k "$kernel" 2>/dev/null |
            grep -qE 'added|built|installed'; then
            run_dkms_without_runtime_hooks dkms add "$mod_src" || return 1
        fi
        run_dkms_without_runtime_hooks dkms build --force \
            "${module}/1.0" -k "$kernel" || return 1
        log "  ${module}/1.0 compilado para ${kernel}"
    done
}

verify_core_dkms_vermagic() {
    local kernel=$1 package_record module source_name artifact vermagic release
    local -a artifacts

    for package_record in "${CORE_DKMS_PACKAGES[@]}"; do
        IFS=: read -r module source_name artifact <<< "$package_record"
        mapfile -t artifacts < <(find "/var/lib/dkms/${module}/1.0/${kernel}" \
            -type f -path '*/module/*.ko*' -name "${artifact}.ko*" -print 2>/dev/null)
        if [[ ${#artifacts[@]} -ne 1 ]]; then
            err "Artefato DKMS único não encontrado para ${module}: ${#artifacts[@]}"
            return 1
        fi
        vermagic=$(modinfo -F vermagic "${artifacts[0]}") || return 1
        release=${vermagic%% *}
        if [[ "$release" != "$kernel" ]]; then
            err "Vermagic incorreto para ${module}: ${vermagic}"
            return 1
        fi
        log "  ${module}/1.0 vermagic validado: ${vermagic}"
    done
}

install_built_core_dkms_modules() {
    local kernel=$1 package_record module source_name artifact

    preflight_dkms_namespace || return 1
    verify_core_dkms_vermagic "$kernel" || return 1
    for package_record in "${CORE_DKMS_PACKAGES[@]}"; do
        IFS=: read -r module source_name artifact <<< "$package_record"
        run_dkms_without_runtime_hooks dkms install --no-depmod --force \
            "${module}/1.0" -k "$kernel" || return 1
        log "  ${module}/1.0 compilado e instalado para ${kernel}"
    done
}

check_core_dkms_sources() {
    CORE_DKMS_MISSING=()
    local module
    for module in wcn-regulator-fix vivobook-kbd-fix vivobook-bl-fix vivobook-hotkey-fix; do
        [[ -d "/usr/src/${module}-1.0" ]] || CORE_DKMS_MISSING+=("$module")
    done
    if [[ ${#CORE_DKMS_MISSING[@]} -gt 0 ]]; then
        err "Fontes DKMS essenciais ausentes: ${CORE_DKMS_MISSING[*]}"
        err "WiFi, teclado, brilho e hotkeys não serão declarados como funcionais."
        if [[ "${ALLOW_MISSING_CORE_DKMS:-0}" != "1" ]]; then
            err "Abortando com segurança. Use ALLOW_MISSING_CORE_DKMS=1 somente para diagnóstico experimental."
            exit 2
        fi
    fi
}

# ─── Stage do payload bundled (vindo do ISO, em /opt/vivobook-fixes/) ─────────
# Copia módulos DKMS -> /usr/src e firmware bundled -> /usr/lib/firmware, para o
# setup ser self-contained quando rodado de /opt/vivobook-fixes/ (Parte 2).
stage_bundled_firmware() {
    if [[ -d "${SCRIPT_DIR}/firmware" ]]; then
        mkdir -p "$FIRMWARE_ROOT" || {
            err "Falha ao preparar destino do firmware bundled: $FIRMWARE_ROOT"
            return 1
        }
        cp -a "${SCRIPT_DIR}/firmware/." "$FIRMWARE_ROOT/" || {
            err "Falha ao instalar firmware bundled em: $FIRMWARE_ROOT"
            return 1
        }
        log "  Firmware bundled instalado em ${FIRMWARE_ROOT}/"
    fi
}

stage_bundled() {
    if [[ -d "${SCRIPT_DIR}/modules" ]]; then
        local moddir name
        for moddir in "${SCRIPT_DIR}/modules"/*/; do
            [[ -d "$moddir" ]] || continue
            name=$(basename "$moddir")
            if [[ ! -d "/usr/src/${name}" ]]; then
                cp -a "$moddir" "/usr/src/${name}" && log "  DKMS source staged: ${name}"
            fi
        done
    fi
    stage_bundled_firmware
}

stage_camera_dkms_sources() (
    local source_root=${CAMERA_DKMS_SOURCE_ROOT:-/usr/src}
    local keep_backups=${CAMERA_DKMS_KEEP_BACKUPS:-0}
    local transaction_id=${CAMERA_DKMS_TRANSACTION_ID:-$$}
    local stage_marker=${CAMERA_DKMS_STAGE_MARKER:-}
    local package_record module version package_dir relative source
    local destination stage_dir backup_dir index published=0
    local committed=0 publication_active=0 publication_had_destination=0
    local publication_index=-1
    local -a destinations=() stage_dirs=() backup_dirs=()

    cleanup_camera_stage() {
        local path

        for path in "${stage_dirs[@]}"; do
            [[ -z $path || (! -e $path && ! -L $path) ]] || rm -rf -- "$path"
        done
    }
    cleanup_camera_backups() {
        local path

        for path in "${backup_dirs[@]}"; do
            if [[ -n $path && (-e $path || -L $path) ]] &&
                ! rm -rf -- "$path"; then
                warn "Backup DKMS recuperável não removido: $path"
            fi
        done
    }
    rollback_camera_publication() {
        local rollback_destination rollback_backup

        if ((publication_active && publication_index >= published)); then
            rollback_destination=${destinations[publication_index]}
            rollback_backup=${backup_dirs[publication_index]}
            if ((publication_had_destination)); then
                if [[ -d $rollback_backup ]]; then
                    rm -rf -- "$rollback_destination"
                    mv -T -- "$rollback_backup" "$rollback_destination" ||
                        err "Falha crítica ao restaurar DKMS: $rollback_destination"
                fi
            elif [[ ! -e ${stage_dirs[publication_index]} &&
                    ! -L ${stage_dirs[publication_index]} ]]; then
                rm -rf -- "$rollback_destination"
            fi
            publication_active=0
        fi

        while ((published > 0)); do
            published=$((published - 1))
            rollback_destination=${destinations[published]}
            rollback_backup=${backup_dirs[published]}
            rm -rf -- "$rollback_destination"
            if [[ -d $rollback_backup ]]; then
                mv -T -- "$rollback_backup" "$rollback_destination" ||
                    err "Falha crítica ao restaurar DKMS: $rollback_destination"
            fi
        done
    }
    finish_camera_stage() {
        local status=$?

        trap - EXIT HUP INT TERM
        if ((committed && (status == 0 || !keep_backups))); then
            ((keep_backups)) || cleanup_camera_backups
        else
            rollback_camera_publication
            [[ -z $stage_marker || (! -e $stage_marker && ! -L $stage_marker) ]] ||
                rm -f -- "$stage_marker"
        fi
        cleanup_camera_stage
        exit "$status"
    }
    trap finish_camera_stage EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    if [[ $source_root != /* || $source_root == / ]]; then
        err "Raiz DKMS da câmera insegura: $source_root"
        return 1
    fi
    mkdir -p "$source_root" || return 1

    for package_record in "${CAMERA_DKMS_PACKAGES[@]}"; do
        IFS=: read -r module version _ <<< "$package_record"
        package_dir="${module}-${version}"
        destination="${source_root}/${package_dir}"
        stage_dir="${destination}.new.${transaction_id}"
        backup_dir="${destination}.old.${transaction_id}"

        if [[ -L $destination ]] ||
            [[ -e $destination && ! -d $destination ]] ||
            [[ -e $stage_dir || -L $stage_dir || -e $backup_dir || -L $backup_dir ]]; then
            err "Destino DKMS da câmera inseguro: $destination"
            return 1
        fi
        mkdir "$stage_dir" || return 1
        destinations+=("$destination")
        stage_dirs+=("$stage_dir")
        backup_dirs+=("$backup_dir")

        for relative in "${CAMERA_DKMS_FILES[@]}"; do
            [[ $relative == "$package_dir/"* ]] || continue
            source="${SCRIPT_DIR}/modules/${relative}"
            if [[ ! -f $source || -L $source ]]; then
                err "Fonte DKMS da câmera ausente ou insegura: $source"
                return 1
            fi
            install -m 0644 "$source" \
                "$stage_dir/${relative#*/}" || return 1
        done
    done

    for index in "${!destinations[@]}"; do
        destination=${destinations[index]}
        stage_dir=${stage_dirs[index]}
        backup_dir=${backup_dirs[index]}
        publication_index=$index
        publication_had_destination=0
        [[ ! -d $destination ]] || publication_had_destination=1
        publication_active=1

        if [[ -d $destination ]]; then
            if ! mv -T -- "$destination" "$backup_dir"; then
                return 1
            fi
        fi
        if ! mv -T -- "$stage_dir" "$destination"; then
            return 1
        fi
        stage_dirs[index]=
        ((++published))
        publication_active=0
    done

    if [[ -n $stage_marker ]]; then
        if [[ $stage_marker != "${source_root}/"* ||
              -e $stage_marker || -L $stage_marker ]]; then
            err "Marcador inseguro da transação DKMS: $stage_marker"
            return 1
        fi
        (set -o noclobber; : > "$stage_marker") || return 1
    fi
    committed=1
    ((keep_backups)) || cleanup_camera_backups
    log "  Fontes DKMS de câmera atualizadas"
)

verify_camera_dkms_vermagic() {
    local kernel=$1 state_root=${CAMERA_DKMS_STATE_ROOT:-/var/lib/dkms}
    local package_record module version artifact path vermagic release
    local -a artifacts

    for package_record in "${CAMERA_DKMS_PACKAGES[@]}"; do
        IFS=: read -r module version artifact <<< "$package_record"
        mapfile -t artifacts < <(find \
            "${state_root}/${module}/${version}/${kernel}" -type f \
            -path '*/module/*.ko*' -name "${artifact}.ko*" -print 2>/dev/null)
        if [[ ${#artifacts[@]} -ne 1 ]]; then
            err "Artefato DKMS único não encontrado para ${module}: ${#artifacts[@]}"
            return 1
        fi
        path=${artifacts[0]}
        vermagic=$(modinfo -F vermagic "$path") || return 1
        release=${vermagic%% *}
        if [[ $release != "$kernel" ]]; then
            err "Vermagic incorreto para ${module}: $vermagic"
            return 1
        fi
    done
}

install_camera_dkms_modules() {
    local kernel=$1 source_root=${CAMERA_DKMS_SOURCE_ROOT:-/usr/src}
    local config_dir=${MODPROBE_CONFIG_DIR:-/etc/modprobe.d}
    local package_record module version artifact package source config_content

    for package_record in "${CAMERA_DKMS_PACKAGES[@]}"; do
        IFS=: read -r module version artifact <<< "$package_record"
        source="${source_root}/${module}-${version}"
        if [[ ! -d $source || -L $source ]]; then
            err "Fonte DKMS da câmera ausente ou insegura: $source"
            return 1
        fi
    done

    for package_record in "${CAMERA_DKMS_PACKAGES[@]}"; do
        IFS=: read -r module version artifact <<< "$package_record"
        package="${module}/${version}"
        source="${source_root}/${module}-${version}"

        if ! dkms status "$package" -k "$kernel" 2>/dev/null |
            grep -qE 'added|built|installed'; then
            run_dkms_without_runtime_hooks dkms add "$source" || return 1
        fi
        run_dkms_without_runtime_hooks dkms build --force \
            "$package" -k "$kernel" || return 1
    done

    verify_camera_dkms_vermagic "$kernel" || return 1

    for package_record in "${CAMERA_DKMS_PACKAGES[@]}"; do
        IFS=: read -r module version artifact <<< "$package_record"
        package="${module}/${version}"
        run_dkms_without_runtime_hooks dkms install --no-depmod --force \
            "$package" -k "$kernel" || return 1
        log "  ${package} atualizado para ${kernel}"
    done

    config_content=$(<"${SCRIPT_DIR}/modules/vivobook-ir-cam-1.0/hm1092-ir.conf") ||
        return 1
    mkdir -p "$config_dir" || return 1
    atomic_write_config "${config_dir}/hm1092-ir.conf" 0644 \
        "${config_content}"$'\n' || return 1
    log "  Configuração do iluminador IR instalada"
}

update_camera_dkms_transaction() (
    local kernel=$1 source_root=${CAMERA_DKMS_SOURCE_ROOT:-/usr/src}
    local config_dir=${MODPROBE_CONFIG_DIR:-/etc/modprobe.d}
    local transaction_id=$BASHPID config_path config_backup stage_marker
    local package_record module version package source destination backup index
    local committed=0 rollback_status=0 config_had_file=0 dkms_status
    local -a packages=() sources=() destinations=() backups=()
    local -a source_existed=() dkms_state_before=()

    config_path="${config_dir}/hm1092-ir.conf"
    config_backup="${config_path}.old.${transaction_id}"
    stage_marker="${source_root}/.vivobook-camera-dkms-staged.${transaction_id}"

    if [[ $source_root != /* || $source_root == / ||
          $config_dir != /* || $config_dir == / ]]; then
        err "Raiz insegura na transação DKMS das câmeras"
        return 1
    fi

    for package_record in "${CAMERA_DKMS_PACKAGES[@]}"; do
        IFS=: read -r module version _ <<< "$package_record"
        package="${module}/${version}"
        source="${source_root}/${module}-${version}"
        destination=$source
        backup="${destination}.old.${transaction_id}"
        packages+=("$package")
        sources+=("$source")
        destinations+=("$destination")
        backups+=("$backup")
        if [[ -d $destination && ! -L $destination ]]; then
            source_existed+=(1)
        else
            source_existed+=(0)
        fi
        dkms_status=$(dkms status "$package" -k "$kernel" 2>/dev/null || true)
        if grep -q 'installed' <<< "$dkms_status"; then
            dkms_state_before+=(installed)
        elif grep -q 'built' <<< "$dkms_status"; then
            dkms_state_before+=(built)
        elif grep -q 'added' <<< "$dkms_status"; then
            dkms_state_before+=(added)
        else
            dkms_state_before+=(absent)
        fi
    done

    mkdir -p "$config_dir" || return 1
    if [[ -e $config_path || -L $config_path ]]; then
        if [[ ! -f $config_path || -L $config_path ||
              -e $config_backup || -L $config_backup ]]; then
            err "Configuração HM1092 insegura para backup: $config_path"
            return 1
        fi
        cp -a -- "$config_path" "$config_backup" || return 1
        config_had_file=1
    fi

    rollback_camera_transaction() {
        local rollback_package rollback_source rollback_destination
        local rollback_backup

        for index in "${!destinations[@]}"; do
            rollback_destination=${destinations[index]}
            rollback_backup=${backups[index]}
            rm -rf -- "$rollback_destination"
            if [[ ${source_existed[index]} == 1 ]]; then
                if ! mv -T -- "$rollback_backup" "$rollback_destination"; then
                    err "Falha crítica ao restaurar fonte DKMS: $rollback_destination"
                    rollback_status=1
                fi
            fi
        done

        for index in "${!packages[@]}"; do
            rollback_package=${packages[index]}
            run_dkms_without_runtime_hooks dkms remove \
                "$rollback_package" -k "$kernel" >/dev/null 2>&1 || true
        done
        for index in "${!packages[@]}"; do
            [[ ${dkms_state_before[index]} != absent ]] || continue
            rollback_package=${packages[index]}
            rollback_source=${sources[index]}
            if ! dkms status "$rollback_package" -k "$kernel" 2>/dev/null |
                grep -qE 'added|built|installed'; then
                run_dkms_without_runtime_hooks dkms add "$rollback_source" ||
                    rollback_status=1
            fi
            if [[ ${dkms_state_before[index]} == built ||
                  ${dkms_state_before[index]} == installed ]]; then
                run_dkms_without_runtime_hooks dkms build --force \
                    "$rollback_package" -k "$kernel" || rollback_status=1
            fi
        done
        for index in "${!packages[@]}"; do
            [[ ${dkms_state_before[index]} == installed ]] || continue
            rollback_package=${packages[index]}
            run_dkms_without_runtime_hooks dkms install --no-depmod --force \
                "$rollback_package" -k "$kernel" || rollback_status=1
        done

        if ((config_had_file)); then
            if ! mv -T -- "$config_backup" "$config_path"; then
                err "Falha crítica ao restaurar configuração HM1092"
                rollback_status=1
            fi
        else
            rm -f -- "$config_path"
        fi
        rm -f -- "$stage_marker"
    }

    finish_camera_transaction() {
        local status=$? cleanup_path

        trap - EXIT HUP INT TERM
        if ((committed)); then
            for cleanup_path in "${backups[@]}" "$config_backup" \
                "$stage_marker"; do
                [[ ! -e $cleanup_path && ! -L $cleanup_path ]] ||
                    rm -rf -- "$cleanup_path"
            done
        elif [[ -f $stage_marker && ! -L $stage_marker ]]; then
            rollback_camera_transaction
            ((rollback_status == 0)) ||
                err "Rollback da transação DKMS das câmeras ficou incompleto"
        else
            [[ ! -e $config_backup && ! -L $config_backup ]] ||
                rm -f -- "$config_backup"
        fi
        exit "$status"
    }
    trap finish_camera_transaction EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    CAMERA_DKMS_KEEP_BACKUPS=1 \
    CAMERA_DKMS_TRANSACTION_ID=$transaction_id \
    CAMERA_DKMS_STAGE_MARKER=$stage_marker \
        stage_camera_dkms_sources || return 1
    install_camera_dkms_modules "$kernel" || return 1
    committed=1
)

# ─── Firmware runtime / initramfs contract ──────────────────────────────────
# Fedora packages may store firmware compressed, while vendor extracts usually
# provide a plain file.  Keep the basename requested by the kernel and select
# the file that actually exists; dracut must receive that selected path.
REMOTEPROC_FIRMWARE_BASENAMES=(
    qcom/x1p42100/ASUSTeK/zenbook-a14/qcadsp8380.mbn
    qcom/x1p42100/ASUSTeK/zenbook-a14/adsp_dtbs.elf
    qcom/x1p42100/ASUSTeK/zenbook-a14/qccdsp8380.mbn
    qcom/x1p42100/ASUSTeK/zenbook-a14/cdsp_dtbs.elf
    qcom/x1p42100/ASUSTeK/zenbook-a14/adspr.jsn
    qcom/x1p42100/ASUSTeK/zenbook-a14/adsps.jsn
    qcom/x1p42100/ASUSTeK/zenbook-a14/adspua.jsn
    qcom/x1p42100/ASUSTeK/zenbook-a14/battmgr.jsn
    qcom/x1p42100/ASUSTeK/zenbook-a14/cdspr.jsn
)
GPU_FIRMWARE_BASENAMES=(
    qcom/gen71500_sqe.fw
    qcom/gen71500_gmu.bin
    qcom/x1p42100/ASUSTeK/zenbook-a14/qcdxkmsucpurwa.mbn
)
BLUETOOTH_FIRMWARE_BASENAMES=(
    qca/hpbtfw21.tlv
    qca/hpnv21.bin
)
RESOLVED_REMOTEPROC_FIRMWARE=()
RESOLVED_GPU_FIRMWARE=()
RESOLVED_BLUETOOTH_FIRMWARE=()

resolve_firmware_variant() {
    local basename=$1 candidate

    case "$basename" in
        /*|*'..'*|"")
            err "Basename de firmware inseguro: $basename" >&2
            return 1
            ;;
    esac
    for candidate in "${FIRMWARE_ROOT}/${basename}.xz" \
        "${FIRMWARE_ROOT}/${basename}"; do
        if [[ -f "$candidate" && ! -L "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    err "Firmware obrigatório ausente (testados .xz e plano): $basename" >&2
    return 1
}

resolve_firmware_group() {
    local group_name=$1 basename selected
    local -n group="$group_name"

    group=()
    shift
    for basename in "$@"; do
        selected=$(resolve_firmware_variant "$basename") || return 1
        group+=("$selected")
    done
}

resolve_kernel_requested_firmware() {
    resolve_firmware_group RESOLVED_REMOTEPROC_FIRMWARE \
        "${REMOTEPROC_FIRMWARE_BASENAMES[@]}" || return 1
    resolve_firmware_group RESOLVED_GPU_FIRMWARE \
        "${GPU_FIRMWARE_BASENAMES[@]}" || return 1
    resolve_firmware_group RESOLVED_BLUETOOTH_FIRMWARE \
        "${BLUETOOTH_FIRMWARE_BASENAMES[@]}"
}

# Do not create a plain Bluetooth alias merely because Fedora supplied .xz.
# A future recovery must use `xz -dc` only after a controlled modprobe test
# proves that this running kernel cannot request the compressed firmware.

write_remoteproc_firmware_dracut_config() {
    local target="${DRACUT_CONFIG_DIR}/qcom-remoteproc.conf" content

    content=$(cat <<EOF
force_drivers+=" qcom_q6v5_pas qcom_q6v5_adsp qcom_glink_smem "
# Required basenames: qcadsp8380.mbn adsp_dtbs.elf qccdsp8380.mbn cdsp_dtbs.elf
# Required basenames: adspr.jsn adsps.jsn adspua.jsn battmgr.jsn cdspr.jsn
install_items+=" ${RESOLVED_REMOTEPROC_FIRMWARE[*]} "
EOF
    ) || return 1
    atomic_write_config "$target" 0644 "${content}"$'\n'
}

write_gpu_bluetooth_firmware_dracut_config() {
    local target="${DRACUT_CONFIG_DIR}/qcom-gpu-firmware.conf" content

    content=$(cat <<EOF
# Selected existing paths for GPU/ZAP and Bluetooth firmware.
install_items+=" ${RESOLVED_GPU_FIRMWARE[*]} ${RESOLVED_BLUETOOTH_FIRMWARE[*]} "
EOF
    ) || return 1
    atomic_write_config "$target" 0644 "${content}"$'\n'
}

preflight_atomic_config_target() {
    local target=$1 allowed_temp=${2:-} target_dir temp_glob temp_path
    local -a temp_paths=()

    target_dir=$(dirname "$target") || return 1
    if [[ ! -d $target_dir || -L $target_dir ]]; then
        err "Diretório de configuração ausente, não real ou symlink: $target_dir"
        return 1
    fi
    if [[ -e $target || -L $target ]]; then
        if [[ ! -f $target || -L $target ]]; then
            err "Target de configuração não é arquivo regular seguro: $target"
            return 1
        fi
    fi
    temp_glob="${target_dir}/.$(basename "$target").new.*"
    shopt -s nullglob
    temp_paths=("${target_dir}/.$(basename "$target").new."*)
    shopt -u nullglob
    for temp_path in "${temp_paths[@]}"; do
        [[ -n $allowed_temp && $temp_path == "$allowed_temp" ]] && continue
        err "Temporário de configuração preexistente: $temp_glob"
        return 1
    done
}

atomic_write_config() (
    local target=$1 mode=$2 content=$3 target_dir candidate=

    target_dir=$(dirname "$target") || return 1
    cleanup_atomic_config() {
        [[ -z $candidate ]] || rm -f -- "$candidate"
    }
    trap cleanup_atomic_config EXIT HUP INT TERM

    preflight_atomic_config_target "$target" || return 1
    candidate=$(mktemp --tmpdir="$target_dir" ".$(basename "$target").new.XXXXXX") || return 1
    printf '%s' "$content" > "$candidate" || return 1
    chmod "$mode" "$candidate" || return 1
    [[ -f $candidate && ! -L $candidate ]] || return 1
    sync -f "$candidate" || return 1
    sync -f "$target_dir" || return 1
    preflight_atomic_config_target "$target" "$candidate" || return 1
    mv -Tf -- "$candidate" "$target" || return 1
    candidate=
    sync -f "$target_dir"
)

write_vulkan_hardware_config() {
    local target="${VULKAN_CONFIG_DIR}/vulkan-hardware.conf"

    mkdir -p "$VULKAN_CONFIG_DIR" || return 1
    atomic_write_config "$target" 0644 \
        $'VK_DRIVER_FILES=/usr/share/vulkan/icd.d/freedreno_icd.aarch64.json\n' || return 1
    chown "$REAL_USER:$REAL_USER" "$target" 2>/dev/null || true
}

write_fastrpc_access_rule() {
    local target="${UDEV_RULES_DIR}/99-x1407qa-fastrpc.rules"

    mkdir -p "$UDEV_RULES_DIR" || return 1
    atomic_write_config "$target" 0644 \
        $'SUBSYSTEM=="misc", KERNEL=="fastrpc-cdsp", GROUP="render", MODE="0660"\n'
}

write_camera_dma_heap_rule() {
    local target="${UDEV_RULES_DIR}/71-vivobook-camera-dma-heap.rules"

    mkdir -p "$UDEV_RULES_DIR" || return 1
    atomic_write_config "$target" 0644 \
        $'SUBSYSTEM=="dma_heap", KERNEL=="system", TAG+="uaccess"\n'
}

install_ov02c10_ipa_data() {
    local source="${SCRIPT_DIR}/modules/vivobook-cam-fix-2.0/ov02c10.yaml"
    local target="${LIBCAMERA_IPA_SIMPLE_DIR}/ov02c10.yaml"
    local content

    [[ -f $source && ! -L $source ]] || return 1
    content=$(<"$source") || return 1
    mkdir -p "$LIBCAMERA_IPA_SIMPLE_DIR" || return 1
    atomic_write_config "$target" 0644 "${content}"$'\n'
}

preflight_recovery_config_paths() {
    local modules_load_dir=${MODULES_LOAD_CONFIG_DIR:-/etc/modules-load.d}
    local target

    for target in \
        "${modules_load_dir}/vivobook-core.conf" \
        "${DRACUT_CONFIG_DIR}/vivobook-core.conf" \
        "${DRACUT_CONFIG_DIR}/qcom-remoteproc.conf" \
        "${DRACUT_CONFIG_DIR}/qcom-gpu-firmware.conf"; do
        preflight_atomic_config_target "$target" || return 1
    done
}

write_core_module_boot_configs() {
    local modules_load_dir=${MODULES_LOAD_CONFIG_DIR:-/etc/modules-load.d}
    local modules_target="${modules_load_dir}/vivobook-core.conf"
    local dracut_target="${DRACUT_CONFIG_DIR}/vivobook-core.conf"
    local modules_content dracut_content

    modules_content=$'wcn_regulator_fix\nvivobook_kbd_fix\nvivobook_bl_fix\nvivobook_hotkey_fix\n'
    dracut_content=$'force_drivers+=" wcn_regulator_fix vivobook_kbd_fix vivobook_bl_fix vivobook_hotkey_fix "\n'
    atomic_write_config "$modules_target" 0644 "$modules_content" || return 1
    atomic_write_config "$dracut_target" 0644 "$dracut_content"
}

configure_sleep_targets() {
    local target

    # s2idle validado em 2026-08-24 (~0.8W suspenso) — suspend liberado;
    # hibernate segue masked (sem swap) e deep/S3 continua proibido.
    for target in sleep.target suspend.target; do
        systemctl unmask "$target" >/dev/null || return 1
        [[ $(systemctl is-enabled "$target" 2>&1 || true) != masked ]] || {
            err "Target de sleep permaneceu masked: $target"
            return 1
        }
    done
    for target in hibernate.target hybrid-sleep.target \
        suspend-then-hibernate.target; do
        systemctl mask "$target" >/dev/null || return 1
        [[ $(systemctl is-enabled "$target" 2>&1 || true) == masked ]] || {
            err "Target de sleep não permaneceu masked: $target"
            return 1
        }
    done
}

# ponytail: alias de compat — tools/recover-stable-hardware.sh chama o nome antigo
keep_sleep_targets_masked() { configure_sleep_targets; }

# ─── Early boot remoteproc contract ──────────────────────────────────────────
require_remoteproc_early_boot_assets() {
    local module
    local -a modules=(qcom_q6v5_pas qcom_q6v5_adsp qcom_glink_smem)
    for module in "${modules[@]}"; do
        if ! modinfo -n "$module" &>/dev/null; then
            err "Módulo remoteproc obrigatório ausente: $module"
            exit 1
        fi
    done
    resolve_firmware_group RESOLVED_REMOTEPROC_FIRMWARE \
        "${REMOTEPROC_FIRMWARE_BASENAMES[@]}" || exit 1
}

run_dracut_candidate() {
    local kernel=$1 candidate=$2

    dracut --force --kver "$kernel" "$candidate"
}

inspect_initramfs_candidate() {
    local candidate=$1

    lsinitrd "$candidate"
}

sync_initramfs_path() {
    sync -f "$1"
}

publish_initramfs_candidate() (
    local kernel=$1
    local target_dir=${INITRAMFS_BOOT_DIR:-/boot}
    local target="${target_dir}/initramfs-${kernel}.img"
    local backup="${target}.vivobook-backup"
    local candidate= listing= backup_tmp= required
    local -a required_items=(
        qcom_q6v5_pas.ko qcom_q6v5_adsp.ko qcom_glink_smem.ko
        wcn_regulator_fix.ko vivobook_kbd_fix.ko
        vivobook_bl_fix.ko vivobook_hotkey_fix.ko
    )
    local -a resolved_firmware=(
        "${RESOLVED_REMOTEPROC_FIRMWARE[@]}"
        "${RESOLVED_GPU_FIRMWARE[@]}"
        "${RESOLVED_BLUETOOTH_FIRMWARE[@]}"
    )
    local firmware_path

    if [[ ${#resolved_firmware[@]} -eq 0 ]]; then
        err "Nenhum firmware resolvido para validar no candidato initramfs"
        return 1
    fi
    for firmware_path in "${resolved_firmware[@]}"; do
        if [[ -z "$firmware_path" || "$firmware_path" != "${FIRMWARE_ROOT}/"* ]]; then
            err "Path de firmware resolvido inválido: $firmware_path"
            return 1
        fi
        required_items+=("${firmware_path#/}")
    done

    cleanup_initramfs_candidate() {
        [[ -z "$candidate" ]] || rm -f -- "$candidate"
        [[ -z "$listing" ]] || rm -f -- "$listing"
        [[ -z "$backup_tmp" ]] || rm -f -- "$backup_tmp"
    }
    trap cleanup_initramfs_candidate EXIT HUP INT TERM

    if [[ ! -d "$target_dir" || -L "$target_dir" ]]; then
        err "Diretório do initramfs ausente ou symlink: $target_dir"
        return 1
    fi
    if [[ -L "$target" ]] || [[ -e "$target" && ! -f "$target" ]] ||
        [[ -L "$backup" ]] || [[ -e "$backup" && ! -f "$backup" ]]; then
        err "Target ou backup initramfs inseguro"
        return 1
    fi
    candidate=$(mktemp --tmpdir="$target_dir" \
        ".initramfs-${kernel}.candidate.XXXXXX") || return 1
    listing=$(mktemp --tmpdir="$target_dir" \
        ".initramfs-${kernel}.listing.XXXXXX") || return 1
    if ! run_dracut_candidate "$kernel" "$candidate"; then
        err "Falha ao gerar candidato initramfs para ${kernel}"
        return 1
    fi
    if [[ ! -f "$candidate" || -L "$candidate" ]] ||
        [[ $(stat -c %s "$candidate") -lt 1048576 ]]; then
        err "Candidato initramfs ausente, symlink ou pequeno"
        return 1
    fi
    if ! inspect_initramfs_candidate "$candidate" > "$listing"; then
        err "lsinitrd rejeitou o candidato"
        return 1
    fi
    for required in "${required_items[@]}"; do
        if ! grep -qF "$required" "$listing"; then
            err "Candidato initramfs não contém: $required"
            return 1
        fi
    done

    chmod 0600 "$candidate" || return 1
    [[ $(stat -c %a "$candidate") == 600 ]] || {
        err "Modo inesperado no candidato initramfs"
        return 1
    }

    sync_initramfs_path "$candidate" || return 1
    if [[ -L "$target" ]] || [[ -e "$target" && ! -f "$target" ]] ||
        [[ -L "$backup" ]] || [[ -e "$backup" && ! -f "$backup" ]]; then
        err "Target ou backup initramfs mudou durante a geração"
        return 1
    fi
    if [[ -e "$target" && ! -e "$backup" ]]; then
        backup_tmp="${backup}.new.$$"
        if [[ -e "$backup_tmp" || -L "$backup_tmp" ]]; then
            err "Backup initramfs temporário preexistente"
            return 1
        fi
        cp --reflink=auto --sparse=always --preserve=mode,ownership,timestamps \
            -- "$target" "$backup_tmp" || return 1
        sync_initramfs_path "$backup_tmp" || return 1
        mv -Tf -- "$backup_tmp" "$backup" || return 1
        backup_tmp=
    fi
    # Complete every fallible durability operation before the atomic promotion.
    # The rename below is the last fallible operation, so an error can never be
    # reported after the active target has already changed.
    sync_initramfs_path "$target_dir" || return 1
    rm -f -- "$listing"
    listing=
    log "Initramfs candidato validado; promovendo atomicamente: $target"
    if mv -Tf -- "$candidate" "$target"; then
        candidate=
        return 0
    fi
    return 1
)

write_installed_boot_params() {
    local root=${1%/}
    local params='clk_ignore_unused mem_sleep_default=s2idle systemd.zram=0 plymouth.enable=0 systemd.tpm2_wait=0 rd.driver.pre=pwrseq_qcom_wcn rd.driver.pre=wcn_regulator_fix rd.systemd.mask=dev-tpm0.device rd.systemd.mask=dev-tpmrm0.device'
    local grub=$root/etc/default/grub
    local kernel_cmdline=$root/etc/kernel/cmdline
    local custom=$root/boot/grub2/custom.cfg
    local clean='s/(^|[ "])rd\.live\.ram\>/\1/g; s/(^|[ "])clk_ignore_unused\>/\1/g; s/(^|[ "])pd_ignore_unused\>/\1/g; s/(^|[ "])mem_sleep_default=[^ "]+/\1/g; s/(^|[ "])systemd\.zram=[^ "]+/\1/g; s/(^|[ "])plymouth\.enable=[^ "]+/\1/g; s/(^|[ "])systemd\.tpm2_wait=[^ "]+/\1/g; s/(^|[ "])rd\.driver\.pre=(pwrseq_qcom_wcn|wcn_regulator_fix)\>/\1/g; s/(^|[ "])rd\.systemd\.mask=dev-tpm(0|rm0)\.device\>/\1/g'

    if [[ -f $grub ]]; then
        if grep -q '^GRUB_CMDLINE_LINUX=' "$grub"; then
            sed -Ei "/^GRUB_CMDLINE_LINUX=/ { $clean; s/ *\"$/ $params\"/; }" "$grub" || return
        else
            printf 'GRUB_CMDLINE_LINUX="%s"\n' "$params" >> "$grub" || return
        fi
    fi
    if [[ -f $kernel_cmdline ]]; then
        sed -Ei "1 { $clean; s/ *$/ $params/; }" "$kernel_cmdline" || return
    fi
    if [[ -f $custom ]]; then
        sed -Ei "/^[[:space:]]*linux / { $clean; s/ *$/ $params/; }" "$custom" || return
    fi
}

if [[ ${VIVOBOOK_SETUP_LIBRARY_ONLY:-0} == 1 ]]; then
    return 0 2>/dev/null || exit 0
fi

# =============================================================================
#  MAIN
# =============================================================================

echo ""
echo -e "${BOLD}════════════════════════════════════════════${NC}"
echo -e "${BOLD}  ASUS Vivobook X1407QA — Setup v${VERSION}${NC}"
echo -e "${BOLD}  Todas as 16 melhorias — Fedora 44 aarch64${NC}"
echo -e "${BOLD}════════════════════════════════════════════${NC}"
echo ""

ACTIVE_KERNEL=$(uname -r)
if ! preflight_core_paths "$ACTIVE_KERNEL"; then
    err "Preflight de paths/hashes falhou antes de qualquer mutação"
    exit 1
fi
check_deps
dependency_status=$?
if [[ $dependency_status -ne 0 ]]; then
    err "Dependências exatas não puderam ser satisfeitas"
    exit 1
fi
if ! preflight_dkms_namespace; then
    err "Preflight do namespace DKMS falhou antes de qualquer ação DKMS"
    exit 1
fi
stage_bundled
if ! resolve_kernel_requested_firmware; then
    err "Firmware obrigatório ausente; abortando sem publicar um initramfs ou declarar sucesso"
    exit 1
fi
if ! stage_core_dkms_sources; then
    err "Falha no stage das fontes core; abortando antes do dracut"
    exit 1
fi
if ! verify_staged_core_sources; then
    err "Falha de provenance após stage; abortando antes do DKMS"
    exit 1
fi
check_core_dkms_sources
if ! prepare_core_module_build_tree "$ACTIVE_KERNEL"; then
    err "Falha ao preparar build tree; abortando antes do dracut"
    exit 1
fi
if ! build_core_dkms_modules "$ACTIVE_KERNEL"; then
    err "Falha ao compilar todos os módulos core; nenhum install iniciado"
    exit 1
fi
if ! verify_core_dkms_vermagic "$ACTIVE_KERNEL"; then
    err "Vermagic core inválido; nenhum install iniciado"
    exit 1
fi
if ! install_built_core_dkms_modules "$ACTIVE_KERNEL"; then
    err "Falha ao instalar módulos core; abortando antes do dracut"
    exit 1
fi

TOTAL=16
dkms_ok=0
dkms_fail=0
desktop_extension_status=0

# ─── 1. GRUB kernel parameters ──────────────────────────────────────────────
step 1 $TOTAL "Parâmetros de kernel (GRUB)..."
# O blacklist só protege o boot do Live USB; no NVMe o ADSP é necessário.
rm -f /etc/modprobe.d/anaconda-denylist.conf
write_installed_boot_params / || { err "Não foi possível persistir o cmdline instalado"; exit 1; }
grubby --update-kernel=ALL --remove-args="rd.live.ram pd_ignore_unused mem_sleep_default systemd.zram plymouth.enable" 2>/dev/null \
    || { err "Não foi possível limpar o cmdline instalado"; exit 1; }
grubby --update-kernel=ALL --args="clk_ignore_unused mem_sleep_default=s2idle systemd.zram=0 plymouth.enable=0 systemd.tpm2_wait=0 rd.driver.pre=pwrseq_qcom_wcn rd.driver.pre=wcn_regulator_fix rd.systemd.mask=dev-tpm0.device rd.systemd.mask=dev-tpmrm0.device" 2>/dev/null \
    || { err "Não foi possível atualizar o cmdline instalado"; exit 1; }
write_installed_boot_params / || { err "Não foi possível validar o cmdline instalado"; exit 1; }
log "  GRUB configurado"

# ─── 2. WiFi — DKMS wcn_regulator_fix ───────────────────────────────────────
step 2 $TOTAL "WiFi (wcn_regulator_fix)..."
if install_dkms_module "wcn-regulator-fix"; then
    ((dkms_ok++))
else
    ((dkms_fail++))
fi
echo "wcn_regulator_fix" > /etc/modules-load.d/wcn-regulator-fix.conf
echo 'force_drivers+=" wcn_regulator_fix "' > /etc/dracut.conf.d/wcn-regulator-fix.conf

# ─── 3. Teclado — DKMS vivobook_kbd_fix ─────────────────────────────────────
step 3 $TOTAL "Teclado (vivobook_kbd_fix)..."
if install_dkms_module "vivobook-kbd-fix"; then
    ((dkms_ok++))
else
    ((dkms_fail++))
fi
echo "vivobook_kbd_fix" > /etc/modules-load.d/vivobook-kbd-fix.conf
echo 'force_drivers+=" vivobook_kbd_fix "' > /etc/dracut.conf.d/vivobook-kbd-fix.conf

# ─── 4. ADSP/CDSP — remoteproc e firmware no initramfs ──────────────────────
step 4 $TOTAL "ADSP/CDSP (remoteproc initramfs)..."
require_remoteproc_early_boot_assets
if ! write_remoteproc_firmware_dracut_config; then
    err "Não foi possível gravar a configuração dracut do remoteproc"
    exit 1
fi
log "  dracut remoteproc ADSP/CDSP config"

# ─── 5. Brilho — DKMS vivobook_bl_fix ───────────────────────────────────────
step 5 $TOTAL "Brilho (vivobook_bl_fix)..."
if install_dkms_module "vivobook-bl-fix"; then
    ((dkms_ok++))
else
    ((dkms_fail++))
fi
echo "vivobook_bl_fix" > /etc/modules-load.d/vivobook-bl-fix.conf

# ─── 6. Hotkeys Fn — DKMS vivobook_hotkey_fix ───────────────────────────────
step 6 $TOTAL "Hotkeys Fn (vivobook_hotkey_fix)..."
if install_dkms_module "vivobook-hotkey-fix"; then
    ((dkms_ok++))
else
    ((dkms_fail++))
fi
echo "vivobook_hotkey_fix" > /etc/modules-load.d/vivobook-hotkey-fix.conf

if ! write_core_module_boot_configs; then
    err "Não foi possível gravar o contrato de boot dos módulos core"
    exit 1
fi

# ─── 7. GPU — Firmware no initramfs ─────────────────────────────────────────
step 7 $TOTAL "GPU (firmware initramfs)..."
if ! write_gpu_bluetooth_firmware_dracut_config; then
    err "Não foi possível gravar a configuração dracut de GPU/Bluetooth"
    exit 1
fi
log "  dracut GPU, ZAP e Bluetooth config"

# ─── 8. Boot time — Mask TPM fantasma ───────────────────────────────────────
step 8 $TOTAL "Boot time (mask TPM fantasma)..."
systemctl mask dev-tpm0.device dev-tpmrm0.device 2>/dev/null || true
echo 'omit_dracutmodules+=" tpm2-tss systemd-pcrphase "' > /etc/dracut.conf.d/no-tpm.conf
echo 'omit_dracutmodules+=" nfs "' > /etc/dracut.conf.d/no-nfs.conf
log "  TPM masked, NFS omitido"

# ─── 9. Terminal flicker — Vulkan pool fix ───────────────────────────────────
step 9 $TOTAL "Terminal flicker (vk_pool_fix.so + .desktop)..."
mkdir -p /usr/local/lib64 /usr/local/bin

local_vk_installed=false
if [[ -f "${SCRIPT_DIR}/vk_pool_fix.c" ]] && command -v gcc &>/dev/null; then
    if gcc -shared -fPIC -o /usr/local/lib64/vk_pool_fix.so "${SCRIPT_DIR}/vk_pool_fix.c" -ldl 2>/dev/null; then
        local_vk_installed=true
        log "  vk_pool_fix.so compilado"
    fi
fi
if [[ "$local_vk_installed" == false && -f "${SCRIPT_DIR}/vk_pool_fix.so" ]]; then
    cp "${SCRIPT_DIR}/vk_pool_fix.so" /usr/local/lib64/vk_pool_fix.so
    local_vk_installed=true
    log "  vk_pool_fix.so pre-built copiado"
fi
if [[ "$local_vk_installed" == false ]]; then
    warn "  vk_pool_fix.so não disponível — terminal pode ter flicker"
fi

# Wrapper script — forces hardware Vulkan + pool fix
# VK_DRIVER_FILES needed even on Mesa 25.3.6: MR 37622 fixes device select but
# LVP still gets loaded without this override, degrading GTK4 rendering.
cat > /usr/local/bin/ptyxis-fixed << 'WRAPPER'
#!/bin/sh
export VK_DRIVER_FILES=/usr/share/vulkan/icd.d/freedreno_icd.aarch64.json
export LD_PRELOAD=/usr/local/lib64/vk_pool_fix.so
exec /usr/bin/ptyxis "$@"
WRAPPER
chmod +x /usr/local/bin/ptyxis-fixed

# Global hardware Vulkan for ALL apps (environment.d)
write_vulkan_hardware_config || warn "  Não foi possível fixar o ICD Freedreno"

# D-Bus service override (Ptyxis usa D-Bus activation)
mkdir -p "${REAL_HOME}/.local/share/dbus-1/services"
cat > "${REAL_HOME}/.local/share/dbus-1/services/org.gnome.Ptyxis.service" << 'DBUS'
[D-BUS Service]
Name=org.gnome.Ptyxis
Exec=/usr/local/bin/ptyxis-fixed --gapplication-service
DBUS

# Desktop entry override
mkdir -p "${REAL_HOME}/.local/share/applications"
if [[ -f /usr/share/applications/org.gnome.Ptyxis.desktop ]]; then
    cp /usr/share/applications/org.gnome.Ptyxis.desktop "${REAL_HOME}/.local/share/applications/"
    sed -i 's|^Exec=ptyxis|Exec=/usr/local/bin/ptyxis-fixed|g' \
        "${REAL_HOME}/.local/share/applications/org.gnome.Ptyxis.desktop"
    log "  .desktop override criado"
else
    warn "  Ptyxis .desktop não encontrado — criar manualmente após instalar"
fi
chown -R "${REAL_USER}:${REAL_USER}" "${REAL_HOME}/.local/share/dbus-1" "${REAL_HOME}/.local/share/applications"

# ─── 10. Tempo bateria — Extensão GNOME ─────────────────────────────────────
step 10 $TOTAL "Tempo bateria (extensão GNOME)..."
if [[ -f "${SCRIPT_DIR}/install-battery-time-ext.sh" ]]; then
    if real_user_session_available; then
        run_as_real_user_session bash "${SCRIPT_DIR}/install-battery-time-ext.sh"
        desktop_extension_status=$?
    else
        run_as_real_user bash "${SCRIPT_DIR}/install-battery-time-ext.sh"
        desktop_extension_status=$?
    fi
    case "$desktop_extension_status" in
        0)
            log "  Percentual e extensão battery-time verificados na sessão de ${REAL_USER}"
            ;;
        3)
            warn "  Extensão instalada; ativação e verificação pendentes no próximo login"
            ;;
        *)
            err "  Falha ao configurar/verificar extensão battery-time (status ${desktop_extension_status})"
            exit "$desktop_extension_status"
            ;;
    esac
else
    err "  install-battery-time-ext.sh não encontrado"
    exit 1
fi

# A pending desktop activation intentionally prevents the final setup-success
# banner.  The remaining non-desktop steps may still make their safe changes.
if [[ $desktop_extension_status -eq 3 ]]; then
    info "  Estado desktop: pending-login (autostart do usuário instalado)"
fi

# ─── 11. Touchpad — click-method areas ──────────────────────────────────────
step 11 $TOTAL "Touchpad (click-method: areas)..."
sudo -u "${REAL_USER}" gsettings set org.gnome.desktop.peripherals.touchpad click-method 'areas' 2>/dev/null || true
# dconf system-wide fallback
mkdir -p /etc/dconf/db/local.d /etc/dconf/profile
cat > /etc/dconf/db/local.d/01-vivobook << 'EOF'
[org/gnome/desktop/peripherals/touchpad]
click-method='areas'

[org/gnome/software]
download-updates=false
download-updates-notify=false
EOF
cat > /etc/dconf/profile/user << 'EOF'
user-db:user
system-db:local
EOF
dconf update 2>/dev/null || true
log "  Touchpad + dconf defaults"

# ─── 12. Áudio — UCM2 regex fix ─────────────────────────────────────────────
step 12 $TOTAL "Áudio (UCM2 regex — Vivobook 14)..."
UCM_CONF="/usr/share/alsa/ucm2/conf.d/x1e80100/x1e80100.conf"
if [[ -f "$UCM_CONF" ]]; then
    if ! grep -qi "vivobook" "$UCM_CONF"; then
        if grep -q "Zenbook A14" "$UCM_CONF"; then
            sed -i 's/Zenbook A14/Zenbook A14|Vivobook 14/' "$UCM_CONF"
            log "  Vivobook 14 adicionado ao regex UCM2"
        else
            warn "  Regex UCM2 não reconhecido — patch manual necessário"
            info "  Arquivo: ${UCM_CONF}"
        fi
    else
        log "  Vivobook já presente no UCM2"
    fi
else
    warn "  UCM2 x1e80100.conf não encontrado — instalar alsa-ucm-conf"
fi
# Topologia de áudio: kernel custom sem CONFIG_FW_LOADER_COMPRESS_XZ não lê
# o .xz do linux-firmware — descomprimir (no-op se .bin já existe)
AUDIO_TPLG="${FIRMWARE_ROOT}/qcom/x1e80100/X1E80100-ASUS-Zenbook-A14-tplg.bin"
if [[ ! -f "$AUDIO_TPLG" && -f "${AUDIO_TPLG}.xz" ]]; then
    if xz -dk "${AUDIO_TPLG}.xz"; then
        log "  Topologia de áudio descomprimida (${AUDIO_TPLG##*/})"
    else
        warn "  Falha ao descomprimir ${AUDIO_TPLG}.xz"
    fi
fi
echo "snd_soc_wcd938x" > /etc/modules-load.d/vivobook-audio.conf
log "  Autoload snd_soc_wcd938x (race no boot)"

# ─── 13. Lid close — suspend via s2idle ─────────────────────────────────────
step 13 $TOTAL "Lid close (suspend s2idle)..."
mkdir -p /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/no-suspend.conf << 'EOF'
# s2idle validado em 2026-08-24: ~0.8W suspenso (vs 2.85W idle) — deep/S3 continua proibido
[Login]
HandleLidSwitch=suspend
HandleLidSwitchExternalPower=suspend
HandleLidSwitchDocked=suspend
IdleAction=ignore
EOF
if ! configure_sleep_targets; then
    err "Targets de sleep não ficaram no estado esperado"
    exit 1
fi
systemctl mask dev-tpm0.device dev-tpmrm0.device 2>/dev/null || true
log "  Lid = suspend (s2idle); hibernate continua masked"

# ─── 14. cpufreq — scmi_cpufreq autoload ────────────────────────────────────
step 14 $TOTAL "CPU frequency scaling (scmi_cpufreq)..."
echo "scmi_cpufreq" > /etc/modules-load.d/scmi-cpufreq.conf
modprobe scmi_cpufreq 2>/dev/null || true
log "  cpufreq autoload"

# ─── 15. CDSP/NPU — contrato early boot + runtime QNN/HTP ───────────────────
step 15 $TOTAL "CDSP/NPU (firmware early boot + runtime QNN/HTP)..."
write_fastrpc_access_rule || warn "  Não foi possível configurar acesso ao FastRPC CDSP"
usermod -aG render "$REAL_USER" 2>/dev/null || true
udevadm control --reload-rules 2>/dev/null || true
udevadm trigger --action=change /sys/class/misc/fastrpc-cdsp 2>/dev/null || true
log "  firmware CDSP + acesso ao FastRPC não seguro configurados"

# Shim de SoC ID do QNN: libQnnHtp.so lê /sys/devices/soc0/soc_id, não conhece
# 635 (X1P42100) e aborta em logCreate. Só é aplicado por processo via npu-run —
# nunca globalmente. Não fatal: sem ele a NPU some, o resto do setup fica de pé.
qnn_shim_src="${SCRIPT_DIR}/modules/qnn-soc-id-fix"
if [[ -f "${qnn_shim_src}/Makefile" ]] && command -v gcc &>/dev/null && command -v make &>/dev/null; then
    if make -C "$qnn_shim_src" install >/dev/null 2>&1; then
        log "  qnn_soc_id_fix.so instalado em /usr/local/lib64/"
    else
        warn "  qnn_soc_id_fix.so não compilou — inferência QNN/HTP indisponível"
    fi
    make -C "$qnn_shim_src" clean >/dev/null 2>&1 || true
else
    warn "  modules/qnn-soc-id-fix ou toolchain ausente — shim de SoC ID não instalado"
fi
if [[ -f "${SCRIPT_DIR}/tools/npu-run" ]]; then
    install -m 0755 "${SCRIPT_DIR}/tools/npu-run" /usr/local/bin/npu-run &&
        log "  npu-run instalado em /usr/local/bin/" ||
        warn "  npu-run não instalado"
fi

# Runtime da NPU: libcdsprpc.so + binários Hexagon do CDSP + DSP_LIBRARY_PATH.
# Idempotente e verboso por conta própria. Não fatal: sem rede para clonar o
# fastrpc, ou com binários Hexagon não autorizados pelo firmware desta máquina,
# só a NPU fica de fora — as outras conquistas continuam sendo instaladas.
if [[ -f "${SCRIPT_DIR}/tools/setup-npu-runtime.sh" ]]; then
    if bash "${SCRIPT_DIR}/tools/setup-npu-runtime.sh"; then
        log "  runtime da NPU pronto"
    else
        warn "  runtime da NPU não ficou pronto — NPU indisponível, setup segue"
    fi
else
    warn "  tools/setup-npu-runtime.sh ausente — runtime da NPU não configurado"
fi

# ─── 16. Charge control — limite 80% via upower + freq cap na bateria ───────
step 16 $TOTAL "Charge control (limite 80%)..."
# ponytail: quem manda no limite é o upower (1.91 aplica 75/80 e persiste em
# /var/lib/upower/charging-threshold-status). A udev rule antiga reescrevia 80 a
# cada uevent — e escrever o threshold gera uevent — então trocar o modo de carga
# em Ajustes → Energia voltava para 80 em milissegundos.
rm -f /etc/udev/rules.d/99-battery-charge-limit.rules
if ! busctl call org.freedesktop.UPower \
        /org/freedesktop/UPower/devices/battery_qcom_battmgr_bat \
        org.freedesktop.UPower.Device EnableChargeThreshold b true >/dev/null 2>&1; then
    warn "  upower não aceitou EnableChargeThreshold — limite de carga fica em Ajustes → Energia"
fi

# Freq cap na bateria (plano de bateria Fase 3): 2.38GHz na bateria, 2.96GHz no AC/USB
cat > /usr/local/bin/vivobook-battery-freq-cap << 'EOF'
#!/bin/sh
# vivobook-battery-freq-cap: cap CPU max freq on battery, restore on AC/USB power.
# 2380800 = highest OPP <= 2.4GHz on X1-26-100; 2956800 = cpuinfo_max_freq.
ac=$(cat /sys/class/power_supply/qcom-battmgr-ac/online 2>/dev/null)
usb=$(cat /sys/class/power_supply/qcom-battmgr-usb/online 2>/dev/null)
if [ "$ac" = 1 ] || [ "$usb" = 1 ]; then
    freq=2956800
else
    freq=2380800
fi
for p in /sys/devices/system/cpu/cpufreq/policy*/scaling_max_freq; do
    echo "$freq" > "$p" 2>/dev/null || true
done
EOF
chmod 755 /usr/local/bin/vivobook-battery-freq-cap
echo 'SUBSYSTEM=="power_supply", KERNEL=="qcom-battmgr-*", RUN+="/usr/local/bin/vivobook-battery-freq-cap"' > /etc/udev/rules.d/99-battery-freq-cap.rules
udevadm control --reload-rules 2>/dev/null || true
/usr/local/bin/vivobook-battery-freq-cap || true
log "  Charge limit 80% + freq cap 2.38GHz na bateria"

# ─── 17. Câmera RGB — DKMS + systemd no boot gráfico ────────────────────────
log "Câmeras RGB/IR (DKMS + autostart gráfico)..."
if ! update_camera_dkms_transaction "$ACTIVE_KERNEL"; then
    err "Falha na transação de atualização DKMS das câmeras"
    exit 1
fi

# Install and enable the service for the next graphical boot. Do not start it
# here: loading once during the next boot preserves the safe no-unload cycle.
cp "${SCRIPT_DIR}/modules/vivobook-cam-fix-2.0/vivobook-camera.service" /etc/systemd/system/ 2>/dev/null || true
install_ov02c10_ipa_data || warn "  Tuning OV02C10 não instalado"
write_camera_dma_heap_rule || warn "  Regra uaccess do DMA heap não instalada"
udevadm control --reload-rules 2>/dev/null || true
systemctl daemon-reload 2>/dev/null || true
systemctl enable vivobook-camera.service 2>/dev/null || warn "  Autostart da câmera não habilitado"

# Install user command
cp "${SCRIPT_DIR}/modules/vivobook-cam-fix-2.0/vivobook-camera" /usr/local/bin/vivobook-camera 2>/dev/null || true
chmod +x /usr/local/bin/vivobook-camera 2>/dev/null || true
log "  vivobook-camera habilitada para o próximo boot gráfico"

# ─── Extras ──────────────────────────────────────────────────────────────────

# Disable auto-updates
log "Desabilitando auto-updates..."
systemctl disable --now dnf-makecache.timer 2>/dev/null || true
systemctl mask packagekit.service 2>/dev/null || true

# Install vivobook-update
if [[ -f "${SCRIPT_DIR}/vivobook-update.sh" ]]; then
    cp "${SCRIPT_DIR}/vivobook-update.sh" /usr/local/bin/vivobook-update
    chmod +x /usr/local/bin/vivobook-update
    log "vivobook-update instalado em /usr/local/bin/"
fi

# ─── Rebuild initramfs ──────────────────────────────────────────────────────
log "Regenerando initramfs..."
depmod "$ACTIVE_KERNEL" || {
    err "depmod falhou após os installs DKMS"
    exit 1
}
if ! publish_initramfs_candidate "$ACTIVE_KERNEL"; then
    err "Candidato initramfs falhou; setup abortado sem declarar sucesso"
    exit 1
fi

# ─── Update GRUB ────────────────────────────────────────────────────────────
log "Atualizando GRUB..."
grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null || \
    grub2-mkconfig -o /boot/efi/EFI/fedora/grub.cfg 2>/dev/null || true

# ─── Limpar scripts antigos ─────────────────────────────────────────────────
log "Removendo scripts antigos (substituídos por build-vivobook-iso.sh + setup-vivobook.sh)..."
removed=0
for old_script in \
    "${SCRIPT_DIR}/prepare-fedora-snapdragon.sh" \
    "${SCRIPT_DIR}/build-v3-iso.sh" \
    "${SCRIPT_DIR}/build-v4-iso.sh" \
    "${SCRIPT_DIR}/setup-all.sh" \
    "${SCRIPT_DIR}/fix.sh"; do
    if [[ -f "$old_script" ]]; then
        rm -f "$old_script"
        log "  Removido: $(basename "$old_script")"
        ((removed++))
    fi
done
if [[ $removed -eq 0 ]]; then
    info "  Nenhum script antigo encontrado"
else
    log "  ${removed} scripts removidos"
fi

# ─── Resultado ──────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}════════════════════════════════════════════${NC}"
if [[ $desktop_extension_status -eq 3 ]]; then
    echo -e "${BOLD}  SETUP PENDENTE — ATIVAÇÃO GNOME NO PRÓXIMO LOGIN${NC}"
else
    echo -e "${BOLD}  SETUP CONCLUÍDO — DESKTOP VERIFICADO${NC}"
fi
echo -e "${BOLD}════════════════════════════════════════════${NC}"
echo ""
echo -e "  DKMS: ${GREEN}${dkms_ok} OK${NC}, ${RED}${dkms_fail} falhas${NC}"
echo ""

if [[ $dkms_fail -gt 0 ]]; then
    warn "Módulos DKMS com falha — verificar gcc e kernel-devel:"
    info "  sudo dnf install gcc kernel-devel-\$(uname -r)"
    info "  Execute novamente este setup para usar o fluxo DKMS/initramfs validado"
    echo ""
fi

info "Reboot para aplicar: ${BOLD}sudo reboot${NC}"
echo ""
info "Após o reboot, verificar:"
echo "    WiFi:     ip link show wlP4p1s0"
echo "    Teclado:  dmesg | grep vivobook-kbd"
echo "    Bateria:  cat /sys/class/power_supply/qcom-battmgr-bat/capacity"
echo "    Brilho:   ls /sys/class/backlight/vivobook-backlight/"
echo "    GPU:      glxinfo | grep renderer"
echo "    Boot:     systemd-analyze"
echo "    Áudio:    pactl list sinks short"
echo "    cpufreq:  cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor"
echo "    CDSP:     cat /sys/class/remoteproc/remoteproc1/state"
echo "    NPU:      npu-run /usr/local/bin/fastrpc_test -d 3 -U 1"
echo "              npu-run ~/.local/share/vivobook-qnn/bin/python ${SCRIPT_DIR}/tools/verify-qnn-npu.py"
echo "    Carga:    cat /sys/class/power_supply/qcom-battmgr-bat/charge_control_end_threshold"
echo "    Suspend:  systemctl suspend  (s2idle; hibernate.target deve seguir masked)"
echo "    Câmera:   systemctl status vivobook-camera.service"
echo ""

if [[ $desktop_extension_status -eq 3 ]]; then
    exit 3
fi
info "Scripts atuais:"
echo "    build-vivobook-iso.sh  — Criar ISO customizada"
echo "    setup-vivobook.sh      — Este script (setup pós-install)"
echo "    vivobook-update        — Updates seguros (sudo vivobook-update)"
echo "    vivobook-camera        — Verificar/iniciar câmera RGB"
echo ""
