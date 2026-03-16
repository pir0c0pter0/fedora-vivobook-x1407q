#!/bin/bash
# =============================================================================
# vivobook-update — Safe update manager for ASUS Vivobook X1407QA (Snapdragon X)
#
# Analyzes kernel/mesa/firmware/gnome-shell/gtk4/alsa-ucm-conf/systemd/grub2
# updates for compatibility with DKMS modules and hardware fixes before applying.
#
# Usage: sudo vivobook-update
# =============================================================================

set -uo pipefail

# ─── Constants ───────────────────────────────────────────────────────────────
VERSION="1.0"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

LOG_DIR="/var/log/vivobook-update"
LOG_FILE=""
CLEANUP_DIRS=()
HAS_INTERNET=false

SENSITIVE_PATTERNS=(
    "^kernel"
    "^mesa"
    "^gnome-shell$"
    "^gtk4"
    "^alsa-ucm-conf$"
    "^systemd"
    "^grub2"
)

# 4 production DKMS modules (vivobook-cam-fix is experimental, never include)
DKMS_MODULES=(wcn-regulator-fix vivobook-kbd-fix vivobook-bl-fix vivobook-hotkey-fix)

# Kernel API functions our modules depend on
KERNEL_APIS=(
    "i2c_hid_core_probe"
    "irq_create_fwspec_mapping"
    "spmi_register_read"
    "of_overlay_fdt_apply"
    "regulator_get"
    "pci_rescan_bus"
    "backlight_device_register"
    "hid_hw_start"
)

# Firmware files we use in initramfs
OUR_FIRMWARE=(
    "qcadsp8380.mbn" "adsp_dtbs.elf"
    "qccdsp8380.mbn" "cdsp_dtbs.elf"
    "gen71500_sqe.fw" "gen71500_gmu.bin"
    "gen71500_zap.mbn" "qcdxkmsucpurwa.mbn"
)

# System config files that must survive updates
SYSTEM_CONFIGS=(
    "/etc/systemd/logind.conf.d/no-suspend.conf"
    "/etc/udev/rules.d/99-battery-charge-limit.rules"
    "/etc/modules-load.d/wcn-regulator-fix.conf"
    "/etc/modules-load.d/vivobook-kbd-fix.conf"
    "/etc/modules-load.d/vivobook-bl-fix.conf"
    "/etc/modules-load.d/vivobook-hotkey-fix.conf"
    "/etc/modules-load.d/scmi-cpufreq.conf"
)

# ─── Utility functions ───────────────────────────────────────────────────────
log()  { echo -e "${GREEN}[+]${NC} $*" | tee -a "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[!]${NC} $*" | tee -a "$LOG_FILE"; }
err()  { echo -e "${RED}[x]${NC} $*" | tee -a "$LOG_FILE"; }
info() { echo -e "${BLUE}[i]${NC} $*" | tee -a "$LOG_FILE"; }
header() {
    echo "" | tee -a "$LOG_FILE"
    echo -e "${BOLD}$*${NC}" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
}

prompt_yn() {
    local msg="$1" default="${2:-S}"
    local choice=""
    if [[ "$default" == "S" ]]; then
        read -rp "$(echo -e "$msg [${BOLD}S${NC}/n]: ")" choice </dev/tty || choice=""
        [[ -z "$choice" || "$choice" =~ ^[Ss]$ ]]
    else
        read -rp "$(echo -e "$msg [S/${BOLD}n${NC}]: ")" choice </dev/tty || choice=""
        [[ "$choice" =~ ^[Ss]$ ]]
    fi
}

prompt_snd() {
    local msg="$1"
    local choice=""
    read -rp "$(echo -e "$msg [${BOLD}S${NC}/n/d]: ")" choice </dev/tty || choice="n"
    echo "${choice:-S}"
}

cleanup() {
    [[ ${#CLEANUP_DIRS[@]} -eq 0 ]] && return
    for dir in "${CLEANUP_DIRS[@]}"; do
        rm -rf "$dir" 2>/dev/null
    done
}
trap cleanup EXIT

# ─── Preflight ───────────────────────────────────────────────────────────────
check_root() {
    if [[ $EUID -ne 0 ]]; then
        err "Execute como root: sudo vivobook-update"
        exit 1
    fi
}

check_internet() {
    if curl -sf --max-time 5 https://fedoraproject.org > /dev/null 2>&1; then
        HAS_INTERNET=true
    else
        warn "Sem internet — release notes upstream indisponíveis (changelog RPM ainda funciona)"
        HAS_INTERNET=false
    fi
}

check_dnf_lock() {
    if [[ -f /var/run/dnf/lock ]] || [[ -f /var/cache/dnf/metadata_lock.pid ]]; then
        err "Outro gerenciador de pacotes está rodando (lock file encontrado)"
        exit 1
    fi
    if pgrep -x "dnf|dnf5|packagekitd" > /dev/null 2>&1; then
        err "Outro gerenciador de pacotes está rodando (processo ativo)"
        exit 1
    fi
}

init_log() {
    mkdir -p "$LOG_DIR"
    LOG_FILE="${LOG_DIR}/$(date +%Y%m%d-%H%M%S).log"
    # Rotate: keep last 10 logs
    local old_logs
    old_logs=$(ls -t "$LOG_DIR"/*.log 2>/dev/null | tail -n +11)
    if [[ -n "$old_logs" ]]; then
        echo "$old_logs" | xargs rm -f
    fi
    log "vivobook-update v${VERSION} — $(date)"
    log "Kernel atual: $(uname -r)"
}

preflight() {
    check_root
    init_log
    header "══════════════════════════════════════════
  VIVOBOOK UPDATE v${VERSION}
══════════════════════════════════════════"
    check_dnf_lock
    check_internet
}

# ─── Discovery ───────────────────────────────────────────────────────────────
declare -a SENSITIVE_PKGS=()
declare -a SENSITIVE_VERSIONS=()
declare -a NORMAL_PKGS=()
declare -a NORMAL_VERSIONS=()

is_sensitive_by_name() {
    local pkg_name="$1"
    for pattern in "${SENSITIVE_PATTERNS[@]}"; do
        if [[ "$pkg_name" =~ $pattern ]]; then
            return 0
        fi
    done
    return 1
}

is_firmware_qcom() {
    local pkg_nevra="$1"
    # Only check packages with "firmware" in the name (optimization)
    if [[ "$pkg_nevra" != *firmware* ]]; then
        return 1
    fi
    dnf repoquery -l "$pkg_nevra" 2>/dev/null | grep -q "firmware/qcom"
}

parse_kernel_version() {
    # Input: "6.20.1-300.fc44" from dnf check-update
    # Output: "6.20.1-300.fc44.aarch64" for DKMS
    local ver_rel="$1"
    local arch
    arch=$(uname -m)
    echo "${ver_rel}.${arch}"
}

discover_updates() {
    log "Verificando updates disponíveis..."

    local raw_output
    raw_output=$(dnf check-update 2>/dev/null) || true
    # dnf check-update exits 100 if updates available, 0 if none

    if [[ -z "$raw_output" ]]; then
        log "Nenhum update disponível."
        exit 0
    fi

    # Parse output: "package-name.arch   version-release   repo"
    # Match lines with 3-column format: name.arch  version  repo
    while IFS= read -r line; do
        # Only match lines that look like package entries (name.arch  version  repo)
        [[ "$line" =~ ^[a-zA-Z0-9].*\.[a-zA-Z0-9_]+[[:space:]]+[0-9] ]] || continue

        local pkg_full pkg_ver _repo
        read -r pkg_full pkg_ver _repo <<< "$line"
        [[ -z "$pkg_full" || -z "$pkg_ver" ]] && continue

        # Extract package name (remove .arch suffix)
        local pkg_name="${pkg_full%.*}"
        local pkg_arch="${pkg_full##*.}"

        # Construct NEVRA for repoquery
        local pkg_nevra="${pkg_name}-${pkg_ver}.${pkg_arch}"

        if is_sensitive_by_name "$pkg_name"; then
            SENSITIVE_PKGS+=("$pkg_full")
            SENSITIVE_VERSIONS+=("$pkg_ver")
        elif is_firmware_qcom "$pkg_nevra"; then
            SENSITIVE_PKGS+=("$pkg_full")
            SENSITIVE_VERSIONS+=("$pkg_ver")
        else
            NORMAL_PKGS+=("$pkg_full")
            NORMAL_VERSIONS+=("$pkg_ver")
        fi
    done <<< "$raw_output"

    local total=$(( ${#SENSITIVE_PKGS[@]} + ${#NORMAL_PKGS[@]} ))
    header "══════════════════════════════════════════
  VIVOBOOK UPDATE — Análise de pacotes
══════════════════════════════════════════"
    info "${total} pacotes disponíveis para update"
    info "  ├── ${#NORMAL_PKGS[@]} normais"
    info "  └── ${#SENSITIVE_PKGS[@]} sensíveis (requerem análise)"
    echo "" | tee -a "$LOG_FILE"

    if [[ ${#SENSITIVE_PKGS[@]} -gt 0 ]]; then
        echo -e "${YELLOW}SENSÍVEIS:${NC}" | tee -a "$LOG_FILE"
        for i in "${!SENSITIVE_PKGS[@]}"; do
            echo -e "  ${SENSITIVE_PKGS[$i]}  →  ${SENSITIVE_VERSIONS[$i]}" | tee -a "$LOG_FILE"
        done
        echo "" | tee -a "$LOG_FILE"
    fi
}

# ─── Normal updates ──────────────────────────────────────────────────────────
update_normal_packages() {
    if [[ ${#NORMAL_PKGS[@]} -eq 0 ]]; then
        info "Nenhum pacote normal para atualizar."
        return 0
    fi

    header "────────────────────────────────────────
  PACOTES NORMAIS (${#NORMAL_PKGS[@]} pacotes)
────────────────────────────────────────"

    for i in "${!NORMAL_PKGS[@]}"; do
        echo -e "  ${DIM}${NORMAL_PKGS[$i]}${NC}  →  ${NORMAL_VERSIONS[$i]}" | tee -a "$LOG_FILE"
    done
    echo "" | tee -a "$LOG_FILE"

    if prompt_yn "Atualizar pacotes normais?"; then
        log "Atualizando ${#NORMAL_PKGS[@]} pacotes normais..."
        # Build exclude list from sensitive packages
        local exclude_args=()
        for pkg in "${SENSITIVE_PKGS[@]}"; do
            local name="${pkg%.*}"
            exclude_args+=(--exclude="$name")
        done
        if dnf update -y "${exclude_args[@]}" "${NORMAL_PKGS[@]}" 2>&1 | tee -a "$LOG_FILE"; then
            log "Pacotes normais atualizados com sucesso."
        else
            warn "Alguns pacotes normais podem ter falhado — verifique o log."
        fi
    else
        info "Pacotes normais pulados."
    fi
}

# ─── Changelog & Release Notes ───────────────────────────────────────────────
get_rpm_changelog() {
    local pkg="$1"
    local output
    output=$(dnf changelog --upgrades "$pkg" 2>/dev/null | head -60) || true
    if [[ -n "$output" ]]; then
        echo "$output"
    else
        echo "[Changelog RPM indisponível]"
    fi
}

get_upstream_notes() {
    local pkg_name="$1" version="$2"
    [[ "$HAS_INTERNET" == false ]] && echo "[Sem internet — release notes indisponíveis]" && return

    local url="" content=""

    case "$pkg_name" in
        kernel*)
            local major="${version%%.*}"
            # Strip release suffix: 6.20.1-300.fc44 → 6.20.1
            local upstream_ver="${version%%-*}"
            url="https://cdn.kernel.org/pub/linux/kernel/v${major}.x/ChangeLog-${upstream_ver}"
            content=$(curl -sf --max-time 10 "$url" 2>/dev/null | head -80) || true
            ;;
        mesa*)
            local upstream_ver="${version%%-*}"
            url="https://docs.mesa3d.org/relnotes/${upstream_ver}.html"
            content=$(curl -sf --max-time 10 "$url" 2>/dev/null \
                | sed -n '/<h2/,/<h2/p' | head -40 \
                | sed 's/<[^>]*>//g; s/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g; /^$/d') || true
            ;;
        gnome-shell)
            url="https://gitlab.gnome.org/GNOME/gnome-shell/-/raw/main/NEWS"
            local upstream_ver="${version%%-*}"
            content=$(curl -sf --max-time 10 "$url" 2>/dev/null \
                | sed -n "/^${upstream_ver}/,/^[0-9]/p" | head -40) || true
            ;;
        gtk4*)
            url="https://gitlab.gnome.org/GNOME/gtk/-/raw/main/NEWS"
            local upstream_ver="${version%%-*}"
            content=$(curl -sf --max-time 10 "$url" 2>/dev/null \
                | sed -n "/^${upstream_ver}/,/^[0-9]/p" | head -40) || true
            ;;
        alsa-ucm-conf)
            url="https://raw.githubusercontent.com/alsa-project/alsa-ucm-conf/master/NEWS"
            local upstream_ver="${version%%-*}"
            content=$(curl -sf --max-time 10 "$url" 2>/dev/null \
                | sed -n "/^${upstream_ver}/,/^[0-9]/p" | head -20) || true
            ;;
        *)
            echo "[Sem URL upstream para $pkg_name]"
            return
            ;;
    esac

    if [[ -n "$content" ]]; then
        echo "$content"
    else
        echo "[Release notes indisponíveis — URL: ${url:-N/A}]"
    fi
}

# ─── Compatibility checks ────────────────────────────────────────────────────
check_kernel_compat() {
    local new_ver="$1"
    local kernel_ver
    kernel_ver=$(parse_kernel_version "$new_ver")
    local tmpdir
    tmpdir=$(mktemp -d)
    CLEANUP_DIRS+=("$tmpdir")

    local results=()

    # --- DKMS build test ---
    # Download kernel-devel without installing (side-effect free)
    info "Baixando kernel-devel-${new_ver} para análise..."
    if dnf download "kernel-devel-${new_ver}" --destdir="$tmpdir" > /dev/null 2>&1; then
        (cd "$tmpdir" && rpm2cpio *.rpm | cpio -idm 2>/dev/null)

        # Check API symbols in extracted headers
        local headers_dir
        headers_dir=$(find "$tmpdir" -type d -name "kernels" -path "*/usr/src/*" 2>/dev/null)
        if [[ -n "$headers_dir" ]]; then
            local kernel_headers
            kernel_headers=$(find "$headers_dir" -maxdepth 1 -type d | tail -1)
            if [[ -n "$kernel_headers" && -d "$kernel_headers/include" ]]; then
                local missing_apis=()
                for func in "${KERNEL_APIS[@]}"; do
                    if ! grep -rq "$func" "$kernel_headers/include/" 2>/dev/null; then
                        missing_apis+=("$func")
                    fi
                done
                if [[ ${#missing_apis[@]} -eq 0 ]]; then
                    results+=("$(echo -e "  ${GREEN}✅${NC} APIs: todas funções usadas presentes nos headers")")
                else
                    results+=("$(echo -e "  ${RED}❌${NC} APIs removidas: ${missing_apis[*]}")")
                    results+=("$(echo -e "     ${YELLOW}Módulos DKMS provavelmente NÃO compilam${NC}")")
                fi
            fi
        fi
    else
        results+=("$(echo -e "  ${YELLOW}⚠️${NC}  Não foi possível baixar kernel-devel para análise")")
    fi

    # --- DKMS build dry-run ---
    # Note: dkms build -k needs the actual kernel-devel installed, not just extracted.
    # We attempt it if kernel-devel for new version is already installed, otherwise
    # we rely on the API header check above as best-effort analysis.
    local dkms_ok=0 dkms_fail=0 dkms_total=${#DKMS_MODULES[@]}
    local failed_mods=()
    if [[ -d "/usr/src/kernels/${kernel_ver}" ]]; then
        for mod in "${DKMS_MODULES[@]}"; do
            local ver
            ver=$(dkms status "$mod" 2>/dev/null | head -1 | awk -F'[,/]' '{print $2}' | tr -d ' ')
            if [[ -n "$ver" ]]; then
                if dkms build "${mod}/${ver}" -k "$kernel_ver" > /dev/null 2>&1; then
                    ((dkms_ok++))
                else
                    ((dkms_fail++))
                    failed_mods+=("$mod")
                fi
            fi
        done
        if [[ $dkms_fail -eq 0 ]]; then
            results+=("$(echo -e "  ${GREEN}✅${NC} DKMS: ${dkms_ok}/${dkms_total} módulos compilam com kernel ${kernel_ver}")")
        else
            results+=("$(echo -e "  ${RED}❌${NC} DKMS: ${dkms_fail} módulo(s) falharam: ${failed_mods[*]}")")
        fi
    else
        # kernel-devel not installed for new version — report current status
        for mod in "${DKMS_MODULES[@]}"; do
            if dkms status "$mod" 2>/dev/null | grep -q "installed"; then
                ((dkms_ok++))
            fi
        done
        results+=("$(echo -e "  ${BLUE}[i]${NC} DKMS: ${dkms_ok}/${dkms_total} instalados (build test precisa kernel-devel-${new_ver})")")
    fi

    # --- scmi_cpufreq check ---
    results+=("$(echo -e "  ${BLUE}[i]${NC} scmi_cpufreq será verificado pós-update no novo kernel")")

    # tmpdir cleaned by EXIT trap

    # Print results
    for r in "${results[@]}"; do
        echo -e "$r" | tee -a "$LOG_FILE"
    done
}

check_mesa_compat() {
    local pkg="$1"
    local tmpdir
    tmpdir=$(mktemp -d)
    CLEANUP_DIRS+=("$tmpdir")

    info "Baixando $pkg para análise de símbolos..."
    if dnf download "$pkg" --destdir="$tmpdir" > /dev/null 2>&1; then
        (cd "$tmpdir" && rpm2cpio *.rpm | cpio -idm 2>/dev/null)

        local vulkan_so
        vulkan_so=$(find "$tmpdir" -name "libvulkan_freedreno.so" -o -name "libvulkan_*.so" 2>/dev/null | head -1)

        if [[ -n "$vulkan_so" ]]; then
            if objdump -T "$vulkan_so" 2>/dev/null | grep -q "vkCreateDescriptorPool"; then
                echo -e "  ${GREEN}✅${NC} vkCreateDescriptorPool presente — vk_pool_fix.so compatível" | tee -a "$LOG_FILE"
            else
                echo -e "  ${RED}❌${NC} vkCreateDescriptorPool NÃO encontrado — vk_pool_fix.so vai quebrar!" | tee -a "$LOG_FILE"
            fi
        else
            echo -e "  ${BLUE}[i]${NC} Pacote não contém driver Vulkan (freedreno)" | tee -a "$LOG_FILE"
        fi
    else
        echo -e "  ${YELLOW}⚠️${NC}  Não foi possível baixar $pkg para análise" | tee -a "$LOG_FILE"
    fi
    # tmpdir cleaned by EXIT trap
}

check_gnome_compat() {
    local new_ver="$1"
    local major="${new_ver%%.*}"
    local real_user="${SUDO_USER:-$USER}"
    local real_home
    real_home=$(eval echo "~${real_user}")
    local metadata="${real_home}/.local/share/gnome-shell/extensions/battery-time@wifiteste/metadata.json"

    if [[ -f "$metadata" ]]; then
        if grep -q "\"${major}\"" "$metadata"; then
            echo -e "  ${GREEN}✅${NC} Extensão battery-time suporta GNOME $major" | tee -a "$LOG_FILE"
        else
            local supported
            supported=$(grep -o '"shell-version".*' "$metadata" | head -1)
            echo -e "  ${YELLOW}⚠️${NC}  Extensão battery-time: $supported" | tee -a "$LOG_FILE"
            echo -e "     GNOME $major pode desabilitar a extensão — atualizar metadata.json" | tee -a "$LOG_FILE"
        fi
    else
        echo -e "  ${BLUE}[i]${NC} Extensão battery-time não instalada" | tee -a "$LOG_FILE"
    fi
}

check_gtk4_compat() {
    local changelog="$1"
    if echo "$changelog" | grep -qi "vulkan\|descriptor\|GSK.*render"; then
        echo -e "  ${YELLOW}⚠️${NC}  Changelog menciona mudanças Vulkan/GSK — testar vk_pool_fix.so após update" | tee -a "$LOG_FILE"
    else
        echo -e "  ${GREEN}✅${NC} Sem mudanças Vulkan/GSK detectadas no changelog" | tee -a "$LOG_FILE"
    fi
}

check_ucm_compat() {
    local pkg="$1"
    local tmpdir
    tmpdir=$(mktemp -d)
    CLEANUP_DIRS+=("$tmpdir")

    if dnf download "$pkg" --destdir="$tmpdir" > /dev/null 2>&1; then
        (cd "$tmpdir" && rpm2cpio *.rpm | cpio -idm 2>/dev/null)

        local conf
        conf=$(find "$tmpdir" -path "*/x1e80100/x1e80100.conf" 2>/dev/null | head -1)

        if [[ -n "$conf" ]]; then
            if grep -qi "vivobook" "$conf"; then
                echo -e "  ${GREEN}✅${NC} Vivobook presente no regex UCM2" | tee -a "$LOG_FILE"
            else
                echo -e "  ${YELLOW}⚠️${NC}  Vivobook NÃO no regex UCM2 — áudio pode quebrar" | tee -a "$LOG_FILE"
                echo -e "     Precisará re-aplicar patch UCM2 após update" | tee -a "$LOG_FILE"
            fi
        else
            echo -e "  ${BLUE}[i]${NC} x1e80100.conf não encontrado no pacote" | tee -a "$LOG_FILE"
        fi
    else
        echo -e "  ${YELLOW}⚠️${NC}  Não foi possível baixar $pkg para análise" | tee -a "$LOG_FILE"
    fi
    # tmpdir cleaned by EXIT trap
}

check_firmware_compat() {
    local pkg="$1"
    local tmpdir
    tmpdir=$(mktemp -d)
    CLEANUP_DIRS+=("$tmpdir")

    if dnf download "$pkg" --destdir="$tmpdir" > /dev/null 2>&1; then
        (cd "$tmpdir" && rpm2cpio *.rpm | cpio -idm 2>/dev/null)

        local changed=()
        for fw in "${OUR_FIRMWARE[@]}"; do
            local new_file
            new_file=$(find "$tmpdir" -name "${fw}*" 2>/dev/null | head -1)
            [[ -z "$new_file" ]] && continue

            local installed_rel
            installed_rel=$(find /usr/lib/firmware/qcom -name "${fw}*" -printf '%P\n' 2>/dev/null | head -1)
            local installed="/usr/lib/firmware/qcom/${installed_rel}"

            if [[ ! -f "$installed" ]]; then
                changed+=("$fw (NOVO)")
                continue
            fi
            if ! cmp -s "$new_file" "$installed"; then
                changed+=("$fw")
            fi
        done

        if [[ ${#changed[@]} -gt 0 ]]; then
            echo -e "  ${YELLOW}⚠️${NC}  Firmwares alterados: ${changed[*]}" | tee -a "$LOG_FILE"
            echo -e "     Rebuild initramfs necessário após update" | tee -a "$LOG_FILE"
        else
            echo -e "  ${GREEN}✅${NC} Nenhum firmware que usamos mudou" | tee -a "$LOG_FILE"
        fi
    else
        echo -e "  ${YELLOW}⚠️${NC}  Não foi possível baixar $pkg para análise" | tee -a "$LOG_FILE"
    fi
    # tmpdir cleaned by EXIT trap
}

check_systemd_compat() {
    local changelog="$1"
    if echo "$changelog" | grep -qi "logind\|suspend\|udev\|rules"; then
        echo -e "  ${YELLOW}⚠️${NC}  Changelog menciona logind/suspend/udev — verificar configs pós-update" | tee -a "$LOG_FILE"
    else
        echo -e "  ${GREEN}✅${NC} Sem mudanças em logind/suspend/udev no changelog" | tee -a "$LOG_FILE"
    fi
}

check_grub_compat() {
    local changelog="$1"
    # Pre-check: custom GRUB entry exists
    if [[ ! -f /etc/grub.d/08_vivobook ]]; then
        echo -e "  ${RED}❌${NC} /etc/grub.d/08_vivobook NÃO existe — GRUB update pode quebrar boot!" | tee -a "$LOG_FILE"
    else
        echo -e "  ${GREEN}✅${NC} Custom GRUB entry (08_vivobook) presente" | tee -a "$LOG_FILE"
    fi
    if ! grep -q "clk_ignore_unused" /etc/default/grub 2>/dev/null || \
       ! grep -q "pd_ignore_unused" /etc/default/grub 2>/dev/null; then
        echo -e "  ${RED}❌${NC} clk_ignore_unused/pd_ignore_unused ausente em /etc/default/grub!" | tee -a "$LOG_FILE"
    else
        echo -e "  ${GREEN}✅${NC} Kernel params (clk_ignore_unused pd_ignore_unused) presentes" | tee -a "$LOG_FILE"
    fi
    if echo "$changelog" | grep -qi "BLS\|devicetree\|aarch64\|boot.*loader"; then
        echo -e "  ${YELLOW}⚠️${NC}  Changelog menciona BLS/devicetree/aarch64 — atenção ao boot" | tee -a "$LOG_FILE"
    fi
}

# ─── Sensitive package analysis ──────────────────────────────────────────────
analyze_sensitive_package() {
    local pkg="$1" version="$2"
    local pkg_name="${pkg%.*}"  # Remove .arch

    header "══════════════════════════════════════════
  ANÁLISE: $pkg  →  $version
══════════════════════════════════════════"

    # --- Changelog RPM ---
    echo -e "${BOLD}📋 CHANGELOG (RPM):${NC}" | tee -a "$LOG_FILE"
    local changelog
    changelog=$(get_rpm_changelog "$pkg_name")
    echo -e "${DIM}${changelog}${NC}" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"

    # --- Upstream release notes ---
    echo -e "${BOLD}🌐 RELEASE NOTES (upstream):${NC}" | tee -a "$LOG_FILE"
    local notes
    notes=$(get_upstream_notes "$pkg_name" "$version")
    echo -e "${DIM}${notes}${NC}" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"

    # --- Compatibility check ---
    echo -e "${BOLD}🔍 COMPATIBILIDADE:${NC}" | tee -a "$LOG_FILE"
    local combined_changelog="${changelog}
${notes}"

    case "$pkg_name" in
        kernel*)
            check_kernel_compat "$version"
            ;;
        mesa*)
            check_mesa_compat "$pkg"
            ;;
        gnome-shell)
            check_gnome_compat "$version"
            ;;
        gtk4*)
            check_gtk4_compat "$combined_changelog"
            ;;
        alsa-ucm-conf)
            check_ucm_compat "$pkg"
            ;;
        systemd*)
            check_systemd_compat "$combined_changelog"
            ;;
        grub2*)
            check_grub_compat "$combined_changelog"
            ;;
        *firmware*|*linux-firmware*)
            check_firmware_compat "$pkg"
            ;;
        *)
            info "  Sem checagem específica para $pkg_name"
            ;;
    esac
    echo "" | tee -a "$LOG_FILE"
}

process_sensitive_packages() {
    if [[ ${#SENSITIVE_PKGS[@]} -eq 0 ]]; then
        info "Nenhum pacote sensível para analisar."
        return
    fi

    local accepted=()
    local updated_kernel="" updated_mesa=false updated_firmware=false
    local updated_gnome=false updated_ucm=false

    for i in "${!SENSITIVE_PKGS[@]}"; do
        local pkg="${SENSITIVE_PKGS[$i]}"
        local version="${SENSITIVE_VERSIONS[$i]}"
        local pkg_name="${pkg%.*}"

        analyze_sensitive_package "$pkg" "$version"

        local choice
        choice=$(prompt_snd "Atualizar ${pkg_name}?")

        case "$choice" in
            [Ss]|"")
                accepted+=("$pkg")
                log "ACEITO: $pkg → $version"
                # Track what was accepted for post-update
                case "$pkg_name" in
                    kernel*)
                        updated_kernel=$(parse_kernel_version "$version")
                        ;;
                    mesa*)
                        updated_mesa=true
                        ;;
                    gnome-shell)
                        updated_gnome=true
                        ;;
                    alsa-ucm-conf)
                        updated_ucm=true
                        ;;
                    *firmware*)
                        updated_firmware=true
                        ;;
                esac
                ;;
            [Nn])
                info "REJEITADO: $pkg"
                ;;
            [Dd])
                # Detail: show full changelog via less
                local full_changelog
                full_changelog=$(dnf changelog --upgrades "${pkg_name}" 2>/dev/null)
                echo "$full_changelog" | less
                # Re-prompt after detail view
                if prompt_yn "Atualizar ${pkg_name}?"; then
                    accepted+=("$pkg")
                    log "ACEITO: $pkg → $version"
                    case "$pkg_name" in
                        kernel*) updated_kernel=$(parse_kernel_version "$version") ;;
                        mesa*) updated_mesa=true ;;
                        gnome-shell) updated_gnome=true ;;
                        alsa-ucm-conf) updated_ucm=true ;;
                        *firmware*) updated_firmware=true ;;
                    esac
                else
                    info "REJEITADO: $pkg"
                fi
                ;;
        esac
    done

    # --- Apply accepted ---
    if [[ ${#accepted[@]} -gt 0 ]]; then
        header "────────────────────────────────────────
  APLICANDO ${#accepted[@]} PACOTES SENSÍVEIS
────────────────────────────────────────"
        for pkg in "${accepted[@]}"; do
            echo -e "  ${pkg}" | tee -a "$LOG_FILE"
        done
        echo "" | tee -a "$LOG_FILE"

        if prompt_yn "Confirmar update dos pacotes acima?"; then
            log "Instalando pacotes sensíveis..."
            if dnf update -y "${accepted[@]}" 2>&1 | tee -a "$LOG_FILE"; then
                log "Pacotes sensíveis atualizados com sucesso."
                # Run post-update
                post_update "$updated_kernel" "$updated_mesa" "$updated_firmware" "$updated_gnome" "$updated_ucm"
            else
                err "Falha no update — verifique o log: $LOG_FILE"
                info "Para desfazer: sudo dnf history undo last"
            fi
        else
            info "Update de pacotes sensíveis cancelado."
        fi
    else
        info "Nenhum pacote sensível aceito para update."
    fi
}

# ─── Post-update ─────────────────────────────────────────────────────────────
post_update() {
    local updated_kernel="$1"
    local updated_mesa="$2"
    local updated_firmware="$3"
    local updated_gnome="${4:-false}"
    local updated_ucm="${5:-false}"
    local need_initramfs=false

    header "────────────────────────────────────────
  PÓS-UPDATE — Verificações
────────────────────────────────────────"

    # DKMS autoinstall for new kernel
    if [[ -n "$updated_kernel" ]]; then
        log "Rebuilding DKMS modules para kernel $updated_kernel..."
        if dkms autoinstall -k "$updated_kernel" 2>&1 | tee -a "$LOG_FILE"; then
            log "DKMS modules rebuilt OK"
        else
            warn "DKMS autoinstall falhou — alguns módulos podem não funcionar no novo kernel"
        fi
        need_initramfs=true
    fi

    # Rebuild initramfs if kernel or firmware changed
    if [[ "$updated_firmware" == "true" ]]; then
        need_initramfs=true
    fi

    if [[ "$need_initramfs" == "true" ]]; then
        log "Rebuilding initramfs..."
        if [[ -n "$updated_kernel" ]]; then
            dracut --force "/boot/initramfs-${updated_kernel}.img" "$updated_kernel" 2>&1 | tee -a "$LOG_FILE"
        else
            dracut --force 2>&1 | tee -a "$LOG_FILE"
        fi
        log "initramfs rebuilt"
    fi

    # Verify vk_pool_fix.so
    if [[ "$updated_mesa" == "true" ]]; then
        log "Verificando vk_pool_fix.so..."
        if [[ -f /usr/local/lib64/vk_pool_fix.so ]]; then
            if ldd /usr/local/lib64/vk_pool_fix.so 2>&1 | grep -q "not found"; then
                warn "vk_pool_fix.so tem dependências faltando — recompilar:"
                warn "  gcc -shared -fPIC -o /usr/local/lib64/vk_pool_fix.so /path/to/vk_pool_fix.c -ldl"
            else
                log "vk_pool_fix.so OK"
            fi
        fi
    fi

    # GRUB regeneration if kernel changed
    if [[ -n "$updated_kernel" ]]; then
        # Pre-checks
        if [[ ! -f /etc/grub.d/08_vivobook ]]; then
            warn "/etc/grub.d/08_vivobook ausente! Restaurar antes de regenerar GRUB"
        fi
        if ! grep -q "clk_ignore_unused" /etc/default/grub 2>/dev/null; then
            warn "clk_ignore_unused ausente em /etc/default/grub!"
        fi
        log "Atualizando GRUB..."
        grub2-mkconfig -o /boot/grub2/grub.cfg 2>&1 | tee -a "$LOG_FILE" || \
            grub2-mkconfig -o /boot/efi/EFI/fedora/grub.cfg 2>&1 | tee -a "$LOG_FILE" || \
            warn "Falha ao regenerar GRUB"

        # Check scmi_cpufreq in new kernel
        if ! find /lib/modules/"$updated_kernel" -name "scmi_cpufreq.ko*" 2>/dev/null | grep -q .; then
            warn "scmi_cpufreq não encontrado no kernel $updated_kernel — cpufreq pode não funcionar"
        else
            log "scmi_cpufreq presente no kernel $updated_kernel"
        fi
    fi

    # Verify GNOME extension if gnome-shell was updated
    if [[ "$updated_gnome" == "true" ]]; then
        local real_user="${SUDO_USER:-$USER}"
        if sudo -u "$real_user" gnome-extensions list --enabled 2>/dev/null | grep -q "battery-time@wifiteste"; then
            log "Extensão battery-time habilitada no GNOME"
        else
            warn "Extensão battery-time pode estar desabilitada após update do GNOME Shell"
            warn "  Verificar: gnome-extensions enable battery-time@wifiteste"
        fi
    fi

    # Re-verify UCM2 regex if alsa-ucm-conf was updated
    if [[ "$updated_ucm" == "true" ]]; then
        local ucm_conf="/usr/share/alsa/ucm2/conf.d/x1e80100/x1e80100.conf"
        if [[ -f "$ucm_conf" ]]; then
            if grep -qi "vivobook" "$ucm_conf"; then
                log "UCM2 regex inclui Vivobook — áudio OK"
            else
                warn "UCM2 regex NÃO inclui Vivobook — áudio pode parar"
                warn "  Re-aplicar patch: ver README seção Áudio (#12)"
            fi
        else
            warn "UCM2 config $ucm_conf não encontrado!"
        fi
    fi

    # Always verify system configs
    verify_system_configs
}

verify_system_configs() {
    log "Verificando integridade dos configs do sistema..."
    local issues=0

    # logind config
    if [[ ! -f /etc/systemd/logind.conf.d/no-suspend.conf ]]; then
        warn "logind no-suspend.conf ausente! Suspend pode crashar o sistema"
        ((issues++))
    fi

    # Suspend masks
    if [[ ! -L /etc/systemd/system/suspend.target ]]; then
        warn "suspend.target não está masked!"
        ((issues++))
    fi
    if [[ ! -L /etc/systemd/system/suspend-then-hibernate.target ]]; then
        warn "suspend-then-hibernate.target não está masked!"
        ((issues++))
    fi

    # udev charge control
    if [[ ! -f /etc/udev/rules.d/99-battery-charge-limit.rules ]]; then
        warn "udev rule de charge control ausente!"
        ((issues++))
    fi

    # modules-load.d
    for conf in wcn-regulator-fix vivobook-kbd-fix vivobook-bl-fix vivobook-hotkey-fix scmi-cpufreq; do
        if [[ ! -f "/etc/modules-load.d/${conf}.conf" ]]; then
            warn "/etc/modules-load.d/${conf}.conf ausente!"
            ((issues++))
        fi
    done

    # dracut configs
    for conf in wcn-regulator-fix vivobook-kbd-fix qcom-adsp-firmware qcom-gpu-firmware qcom-cdsp-firmware; do
        if [[ ! -f "/etc/dracut.conf.d/${conf}.conf" ]]; then
            warn "/etc/dracut.conf.d/${conf}.conf ausente!"
            ((issues++))
        fi
    done

    if [[ $issues -eq 0 ]]; then
        log "Configs do sistema intactos"
    else
        warn "$issues config(s) precisam de atenção — rodar setup-all.sh para restaurar"
    fi
}

# ─── Main ────────────────────────────────────────────────────────────────────
main() {
    preflight
    discover_updates
    update_normal_packages
    process_sensitive_packages

    header "══════════════════════════════════════════
  VIVOBOOK UPDATE — Concluído
══════════════════════════════════════════"
    log "Log salvo em: $LOG_FILE"

    # Check if reboot needed
    local reboot_needed=false
    if [[ -f /var/run/reboot-required ]]; then
        reboot_needed=true
    elif command -v needs-restarting &>/dev/null && ! needs-restarting -r > /dev/null 2>&1; then
        reboot_needed=true
    else
        # Check manually if kernel was updated
        local running
        running=$(uname -r)
        local latest
        latest=$(ls -t /lib/modules/ 2>/dev/null | head -1)
        if [[ -n "$latest" && "$running" != "$latest" ]]; then
            reboot_needed=true
        fi
    fi

    if [[ "$reboot_needed" == "true" ]]; then
        warn "Reboot recomendado: sudo reboot"
    else
        log "Nenhum reboot necessário."
    fi
}

main "$@"
