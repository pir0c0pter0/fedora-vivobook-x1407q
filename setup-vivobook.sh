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
REAL_USER_UID=$(id -u "$REAL_USER" 2>/dev/null || true)
REAL_RUNTIME_DIR="${VIVOBOOK_REAL_RUNTIME_DIR:-/run/user/${REAL_USER_UID}}"
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
check_deps() {
    local package command_name
    local -a build_packages=(gcc make dkms perl elfutils-libelf-devel openssl-devel flex bison)
    local -a missing_packages=()

    for package in "${build_packages[@]}"; do
        rpm -q "$package" &>/dev/null || missing_packages+=("$package")
    done
    if [[ ${#missing_packages[@]} -gt 0 ]]; then
        warn "Dependências de build faltando: ${missing_packages[*]}"
        info "Instalando somente as dependências de build aprovadas..."
        if ! dnf install -y "${missing_packages[@]}"; then
            err "Falha ao instalar dependências de build aprovadas"
            exit 1
        fi
    fi
    for package in "${build_packages[@]}"; do
        if ! rpm -q "$package" &>/dev/null; then
            err "Dependência de build obrigatória ausente: $package"
            exit 1
        fi
    done
    for command_name in dracut grubby grub2-mkconfig modprobe unshare mount; do
        if ! command -v "$command_name" &>/dev/null; then
            err "Comando obrigatório ausente: $command_name"
            exit 1
        fi
    done
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
    [[ -n "$REAL_USER_UID" && -S "${REAL_RUNTIME_DIR}/bus" ]]
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
    local build_link="/lib/modules/${kernel}/build"
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
    if [[ ! -d "/lib/modules/${kernel}" || -L "/lib/modules/${kernel}" ]]; then
        err "Diretório de módulos ausente, não diretório ou symlink: /lib/modules/${kernel}"
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
    local build_link="/lib/modules/${kernel}/build"
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
            make -j8 vmlinux
            make -j8 modules
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
    if [[ -d "${SCRIPT_DIR}/firmware" ]]; then
        cp -a "${SCRIPT_DIR}/firmware/." /usr/lib/firmware/ 2>/dev/null && \
            log "  Firmware bundled instalado em /usr/lib/firmware/"
    fi
}

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
    mkdir -p "$DRACUT_CONFIG_DIR" || return 1
    if [[ "$DRACUT_CONFIG_DIR" == /etc/dracut.conf.d ]]; then
        cat > /etc/dracut.conf.d/qcom-remoteproc.conf <<EOF
force_drivers+=" qcom_q6v5_pas qcom_q6v5_adsp qcom_glink_smem "
# Required basenames: qcadsp8380.mbn adsp_dtbs.elf qccdsp8380.mbn cdsp_dtbs.elf
# Required basenames: adspr.jsn adsps.jsn adspua.jsn battmgr.jsn cdspr.jsn
install_items+=" ${RESOLVED_REMOTEPROC_FIRMWARE[*]} "
EOF
    else
        cat > "${DRACUT_CONFIG_DIR}/qcom-remoteproc.conf" <<EOF
force_drivers+=" qcom_q6v5_pas qcom_q6v5_adsp qcom_glink_smem "
# Required basenames: qcadsp8380.mbn adsp_dtbs.elf qccdsp8380.mbn cdsp_dtbs.elf
# Required basenames: adspr.jsn adsps.jsn adspua.jsn battmgr.jsn cdspr.jsn
install_items+=" ${RESOLVED_REMOTEPROC_FIRMWARE[*]} "
EOF
    fi
}

write_gpu_bluetooth_firmware_dracut_config() {
    mkdir -p "$DRACUT_CONFIG_DIR" || return 1
    if [[ "$DRACUT_CONFIG_DIR" == /etc/dracut.conf.d ]]; then
        cat > /etc/dracut.conf.d/qcom-gpu-firmware.conf <<EOF
# Selected existing paths for GPU/ZAP and Bluetooth firmware.
install_items+=" ${RESOLVED_GPU_FIRMWARE[*]} ${RESOLVED_BLUETOOTH_FIRMWARE[*]} "
EOF
    else
        cat > "${DRACUT_CONFIG_DIR}/qcom-gpu-firmware.conf" <<EOF
# Selected existing paths for GPU/ZAP and Bluetooth firmware.
install_items+=" ${RESOLVED_GPU_FIRMWARE[*]} ${RESOLVED_BLUETOOTH_FIRMWARE[*]} "
EOF
    fi
}

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
if ! grep -q "clk_ignore_unused" /etc/default/grub 2>/dev/null; then
    sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet rhgb clk_ignore_unused pd_ignore_unused rd.systemd.mask=dev-tpm0.device rd.systemd.mask=dev-tpmrm0.device"/' /etc/default/grub
fi
grubby --update-kernel=ALL --args="clk_ignore_unused pd_ignore_unused rd.driver.pre=wcn_regulator_fix rd.systemd.mask=dev-tpm0.device rd.systemd.mask=dev-tpmrm0.device" 2>/dev/null || true
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
# LVP still gets loaded without this override, degrading GTK4 rendering and
# causing terminal flicker during Claude Code reloads
cat > /usr/local/bin/ptyxis-fixed << 'WRAPPER'
#!/bin/sh
export VK_DRIVER_FILES=/usr/share/vulkan/icd.d/freedreno_icd.aarch64.json
export LD_PRELOAD=/usr/local/lib64/vk_pool_fix.so
exec /usr/bin/ptyxis "$@"
WRAPPER
chmod +x /usr/local/bin/ptyxis-fixed

# Global hardware Vulkan for ALL apps (environment.d)
mkdir -p "${REAL_HOME}/.config/environment.d"
cat > "${REAL_HOME}/.config/environment.d/vulkan-hardware.conf" << 'ENVD'
# Force hardware Vulkan only (freedreno/turnip on Adreno GPU)
# Prevents LVP from loading — MR 37622 fixes device select but LVP still
# gets loaded without this, degrading GTK4 rendering performance
VK_DRIVER_FILES=/usr/share/vulkan/icd.d/freedreno_icd.aarch64.json
ENVD
chown -R "${REAL_USER}:${REAL_USER}" "${REAL_HOME}/.config/environment.d"

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

# ─── 13. Lid close — Suspend desabilitado ───────────────────────────────────
step 13 $TOTAL "Lid close (suspend desabilitado, lid = lock)..."
mkdir -p /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/no-suspend.conf << 'EOF'
[Login]
HandleLidSwitch=lock
HandleLidSwitchExternalPower=lock
HandleLidSwitchDocked=lock
IdleAction=ignore
EOF
for target in suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target sleep.target; do
    systemctl mask "$target" 2>/dev/null || true
done
systemctl mask dev-tpm0.device dev-tpmrm0.device 2>/dev/null || true
log "  Suspend disabled, lid = lock screen"

# ─── 14. cpufreq — scmi_cpufreq autoload ────────────────────────────────────
step 14 $TOTAL "CPU frequency scaling (scmi_cpufreq)..."
echo "scmi_cpufreq" > /etc/modules-load.d/scmi-cpufreq.conf
modprobe scmi_cpufreq 2>/dev/null || true
log "  cpufreq autoload"

# ─── 15. CDSP/NPU — contrato early boot já configurado ──────────────────────
step 15 $TOTAL "CDSP/NPU (firmware early boot)..."
log "  firmware CDSP incluído em qcom-remoteproc.conf"

# ─── 16. Charge control — udev rule 80% ─────────────────────────────────────
step 16 $TOTAL "Charge control (limite 80%)..."
echo 'SUBSYSTEM=="power_supply", KERNEL=="qcom-battmgr-bat", ATTR{charge_control_end_threshold}="80"' > /etc/udev/rules.d/99-battery-charge-limit.rules
udevadm control --reload-rules 2>/dev/null || true
echo 80 > /sys/class/power_supply/qcom-battmgr-bat/charge_control_end_threshold 2>/dev/null || true
log "  Charge limit 80%"

# ─── 17. Câmera RGB — DKMS + systemd on-demand ──────────────────────────────
log "Câmera RGB (vivobook_cam_fix — on-demand)..."
# Camera module is version 2.0
CAM_SRC="/usr/src/vivobook-cam-fix-2.0"
if [[ -d "$CAM_SRC" ]]; then
    if ! dkms status 2>/dev/null | grep -q "vivobook-cam-fix.*installed"; then
        run_dkms_without_runtime_hooks dkms add "$CAM_SRC" 2>/dev/null || true
        run_dkms_without_runtime_hooks dkms build "vivobook-cam-fix/2.0" &&
            run_dkms_without_runtime_hooks dkms install --no-depmod \
                "vivobook-cam-fix/2.0" && \
            log "  vivobook-cam-fix compilado e instalado" || \
            warn "  vivobook-cam-fix FALHOU"
    else
        log "  vivobook-cam-fix já instalado"
    fi
fi

# Install systemd service (on-demand only, never enabled)
cp "${SCRIPT_DIR}/modules/vivobook-cam-fix-2.0/vivobook-camera.service" /etc/systemd/system/ 2>/dev/null || true
systemctl daemon-reload 2>/dev/null || true

# Install user command
cp "${SCRIPT_DIR}/modules/vivobook-cam-fix-2.0/vivobook-camera" /usr/local/bin/vivobook-camera 2>/dev/null || true
chmod +x /usr/local/bin/vivobook-camera 2>/dev/null || true
log "  vivobook-camera command instalado (use: vivobook-camera start)"

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

# Install sync_render + claude shim (flicker-free Claude Code)
sync_render_installed=false
if [[ -f "${SCRIPT_DIR}/sync_render.c" ]] && command -v gcc &>/dev/null; then
    # Compile to temp path then mv — avoids "Text file busy" if sync_render is running
    if gcc -O2 -o /tmp/sync_render.new "${SCRIPT_DIR}/sync_render.c" -lutil 2>/dev/null; then
        mv /tmp/sync_render.new /usr/local/bin/sync_render
        chmod +x /usr/local/bin/sync_render
        sync_render_installed=true
        log "sync_render compilado e instalado"
    fi
fi
if [[ "$sync_render_installed" == false && -f "${SCRIPT_DIR}/sync_render" ]]; then
    cp "${SCRIPT_DIR}/sync_render" /tmp/sync_render.new
    mv /tmp/sync_render.new /usr/local/bin/sync_render
    chmod +x /usr/local/bin/sync_render
    sync_render_installed=true
    log "sync_render pre-built copiado"
fi
if [[ "$sync_render_installed" == true ]]; then
    # Configure Ptyxis profile to use sync_render as shell wrapper
    PTYXIS_UUID=$(sudo -u "${REAL_USER}" dconf read /org/gnome/Ptyxis/default-profile-uuid 2>/dev/null | tr -d "'")
    if [[ -n "$PTYXIS_UUID" ]]; then
        sudo -u "${REAL_USER}" dconf write "/org/gnome/Ptyxis/Profiles/${PTYXIS_UUID}/use-custom-command" true
        sudo -u "${REAL_USER}" dconf write "/org/gnome/Ptyxis/Profiles/${PTYXIS_UUID}/custom-command" "'sync_render /bin/bash --login'"
        log "Ptyxis profile: sync_render /bin/bash --login"
    else
        warn "Ptyxis profile não encontrado — configurar manualmente"
        info "  dconf write /org/gnome/Ptyxis/Profiles/<UUID>/use-custom-command true"
        info "  dconf write /org/gnome/Ptyxis/Profiles/<UUID>/custom-command \"'sync_render /bin/bash --login'\""
    fi

    # Fallback: auto-activate sync_render in bash startup files
    # Catches tabs opened bypassing the Ptyxis profile custom-command
    # (e.g. ptyxis-agent session restore, dock icon click edge cases)
    SYNC_BASHRC_BLOCK='# Flicker-free terminal: re-exec bash inside sync_render PTY proxy
if [ -z "$SYNC_RENDER_ACTIVE" ] && [ -t 1 ] && [ -x /usr/local/bin/sync_render ]; then
    export SYNC_RENDER_ACTIVE=1
    exec /usr/local/bin/sync_render /bin/bash --login
fi'
    SYNC_PROFILE_BLOCK='# Auto-activate sync_render for flicker-free terminal rendering
if [[ -t 1 && -z "$SYNC_RENDER_ACTIVE" ]] && command -v sync_render &>/dev/null; then
    export SYNC_RENDER_ACTIVE=1
    exec sync_render /bin/bash --login
fi'
    for f in "${REAL_HOME}/.bashrc" "${REAL_HOME}/.bash_profile"; do
        if [[ -f "$f" ]] && ! grep -q "SYNC_RENDER_ACTIVE" "$f"; then
            echo "" >> "$f"
            if [[ "$f" == *bashrc ]]; then
                echo "$SYNC_BASHRC_BLOCK" >> "$f"
            else
                echo "$SYNC_PROFILE_BLOCK" >> "$f"
            fi
            log "sync_render fallback adicionado a $f"
        fi
    done
    chown "${REAL_USER}:${REAL_USER}" "${REAL_HOME}/.bashrc" "${REAL_HOME}/.bash_profile" 2>/dev/null || true
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
echo "    Carga:    cat /sys/class/power_supply/qcom-battmgr-bat/charge_control_end_threshold"
echo "    Suspend:  systemctl is-enabled suspend.target"
echo "    Câmera:   vivobook-camera start  (on-demand, não auto-load)"
echo ""

if [[ $desktop_extension_status -eq 3 ]]; then
    exit 3
fi
info "Scripts atuais:"
echo "    build-vivobook-iso.sh  — Criar ISO customizada"
echo "    setup-vivobook.sh      — Este script (setup pós-install)"
echo "    vivobook-update        — Updates seguros (sudo vivobook-update)"
echo "    vivobook-camera        — Ligar câmera RGB sob demanda"
echo ""
