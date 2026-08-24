#!/usr/bin/env bash
# =============================================================================
# setup-npu-runtime.sh — deixa a NPU (CDSP Hexagon + FastRPC) pronta
# ASUS Vivobook 14 X1407QA (Snapdragon X, x1p42100 "Purwa") — Fedora 44 aarch64
#
# Problema:   onnxruntime-qnn registra a NPU mas o backend HTP nao inicializa.
# Causa raiz: 3 pecas de userspace ausentes no Fedora —
#   1) libcdsprpc.so (NEEDED de libQnnHtpV73Stub.so) nao existe;
#   2) binarios Hexagon do CDSP (fastrpc shell + skels) nao instalados;
#   3) YAML mapeando o model do device-tree para o DSP_LIBRARY_PATH.
# Solucao:    este script. Idempotente — cada passo detecta "ja feito" e pula.
#
# Fora de escopo: o SoC ID. O libQnnHtp.so le /sys/devices/soc0/soc_id (635) e
# nao conhece esse ID; isso e tratado pelo shim de runtime, nao aqui.
#
# Uso: sudo bash tools/setup-npu-runtime.sh
#
# Variaveis de ambiente:
#   NPU_WORK_DIR      clones/builds        (default: ~<usuario>/repositorios)
#   NPU_FASTRPC_REPO  git do fastrpc       (default: upstream Qualcomm)
#   NPU_HEXAGON_DIR   binarios Hexagon prontos (default: <repo>/hexagon-dsp/cdsp)
#   NPU_WINDOWS_DUMP  dump .tar.zst dos drivers Windows (fallback do anterior)
#                     (default: <repo>/windows-drivers/*.tar.zst)
#   NPU_CDSP_MBN      firmware CDSP assinado em uso
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REAL_USER="${SUDO_USER:-${USER:-root}}"
REAL_HOME="$(eval echo "~${REAL_USER}")"

WORK_DIR="${NPU_WORK_DIR:-${REAL_HOME}/repositorios}"
FASTRPC_REPO="${NPU_FASTRPC_REPO:-https://github.com/qualcomm/fastrpc}"
FASTRPC_DIR="${WORK_DIR}/fastrpc"
LD_CONF="/etc/ld.so.conf.d/fastrpc.conf"
DSP_ROOT="/usr/share/qcom/x1p42100/Qualcomm/Purwa-IoT-EVK/dsp"
DSP_CDSP_DIR="${DSP_ROOT}/cdsp"
QCOM_CONF="/usr/share/qcom/conf.d/hexagon-dsp-binaries-asus-vivobook-x1407qa.yaml"
DT_MODEL="ASUS Zenbook A14 (UX3407QA)"
CDSP_MBN="${NPU_CDSP_MBN:-/usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/qccdsp8380.mbn}"
AUTHCHECK="${SCRIPT_DIR}/lib/hexagon-authcheck.py"
REPO_HEXAGON_DIR="${NPU_HEXAGON_DIR:-${REPO_ROOT}/hexagon-dsp/cdsp}"
BUILD_DEPS=(autoconf automake libtool libyaml-devel libmd-devel libbsd-devel gcc gcc-c++ make git)
TOTAL_STEPS=6

# ─── Colors & logging ────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[x]${NC} $*"; }
info() { echo -e "${CYAN}[i]${NC} $*"; }
step() { echo -e "\n${BOLD}${GREEN}[${1}/${TOTAL_STEPS}]${NC} ${BOLD}${2}${NC}"; }

CLEANUP_DIRS=()
cleanup() {
    local dir
    for dir in ${CLEANUP_DIRS[@]+"${CLEANUP_DIRS[@]}"}; do
        [[ -n $dir && -d $dir ]] && rm -rf "$dir"
    done
}
trap cleanup EXIT

run_as_user() {
    if [[ $REAL_USER == root ]]; then
        "$@"
    else
        runuser -u "$REAL_USER" -- "$@"
    fi
}

write_file_if_changed() {
    local path=$1 content=$2
    if [[ -f $path && $(cat "$path") == "$content" ]]; then
        info "Ja no conteudo esperado: ${path}"
        return 0
    fi
    install -d -m 0755 "$(dirname "$path")"
    printf '%s\n' "$content" >"$path"
    chown root:root "$path"
    chmod 0644 "$path"
    log "Escrito: ${path}"
}

# ─── 1. Pre-requisitos ───────────────────────────────────────────────────────
cdsp_state() {
    local rproc name
    for rproc in /sys/class/remoteproc/remoteproc*; do
        [[ -r "$rproc/name" && -r "$rproc/state" ]] || continue
        name=$(<"$rproc/name")
        [[ $name == cdsp ]] || continue
        cat "$rproc/state"
        return 0
    done
    return 1
}

check_prereqs() {
    local model state command_name

    if [[ $EUID -ne 0 ]]; then
        err "Execute como root: sudo bash tools/setup-npu-runtime.sh"
        return 1
    fi
    if [[ $(uname -m) != aarch64 ]]; then
        err "Arquitetura $(uname -m): rode este script no proprio Vivobook (aarch64)"
        return 1
    fi
    for command_name in python3 git tar install awk ldconfig runuser dnf; do
        if ! command -v "$command_name" &>/dev/null; then
            err "Comando obrigatorio ausente: $command_name"
            return 1
        fi
    done
    if [[ ! -r $AUTHCHECK ]]; then
        err "Helper de validacao ausente: $AUTHCHECK"
        return 1
    fi
    if [[ ! -r $CDSP_MBN ]]; then
        err "Firmware CDSP assinado nao encontrado: $CDSP_MBN"
        info "Ajuste com NPU_CDSP_MBN=<caminho do .mbn em uso>"
        return 1
    fi
    if ! state=$(cdsp_state); then
        err "Nenhum remoteproc chamado 'cdsp' em /sys/class/remoteproc"
        info "Sem CDSP nao ha NPU: confira o firmware qccdsp8380.mbn no initramfs"
        return 1
    fi
    if [[ $state != running ]]; then
        err "CDSP em estado '${state}' (esperado: running)"
        info "journalctl -b | grep -i cdsp"
        return 1
    fi
    model=""
    [[ -r /sys/firmware/devicetree/base/model ]] &&
        model=$(tr -d '\0' </sys/firmware/devicetree/base/model)
    if [[ $model != "$DT_MODEL" ]]; then
        warn "Model do device-tree: '${model}' (esperado '${DT_MODEL}')"
        warn "O YAML do passo 5 mapeia '${DT_MODEL}'; o DSP pode nao ser encontrado"
    fi
    log "aarch64, CDSP running, firmware ${CDSP_MBN##*/} presente"
}

# ─── 2. Dependencias de build ────────────────────────────────────────────────
install_build_deps() {
    local package
    local -a missing=()

    for package in "${BUILD_DEPS[@]}"; do
        rpm -q "$package" &>/dev/null || missing+=("$package")
    done
    if [[ ${#missing[@]} -eq 0 ]]; then
        info "Todas as dependencias ja instaladas"
        return 0
    fi
    warn "Faltando: ${missing[*]}"
    if ! dnf install -y --skip-unavailable "${missing[@]}"; then
        err "Falha ao instalar dependencias de build"
        return 1
    fi
    for package in "${missing[@]}"; do
        rpm -q "$package" &>/dev/null || { err "Dependencia ausente: $package"; return 1; }
    done
    log "Dependencias instaladas: ${missing[*]}"
}

# ─── 3. fastrpc (libcdsprpc.so + dsp_check + fastrpc_test) ───────────────────
fastrpc_installed() {
    ldconfig -p 2>/dev/null | grep -q 'libcdsprpc\.so' &&
        [[ -x /usr/local/bin/dsp_check && -x /usr/local/bin/fastrpc_test ]]
}

build_fastrpc() {
    # /usr/local/lib nao e varrido pelo Fedora aarch64 — precisa do ld.so.conf.d
    write_file_if_changed "$LD_CONF" "/usr/local/lib"
    ldconfig

    if fastrpc_installed; then
        info "libcdsprpc.so e os diagnosticos ja estao instalados — pulando build"
        return 0
    fi

    install -d -m 0755 -o "$REAL_USER" "$WORK_DIR"
    if [[ -d ${FASTRPC_DIR}/.git ]]; then
        info "Atualizando ${FASTRPC_DIR}"
        run_as_user git -C "$FASTRPC_DIR" pull --ff-only ||
            warn "Nao foi possivel atualizar o clone; seguindo com a copia local"
    else
        log "Clonando ${FASTRPC_REPO}"
        run_as_user git clone "$FASTRPC_REPO" "$FASTRPC_DIR"
    fi

    log "Compilando fastrpc (-DENABLE_UPSTREAM_DRIVER_INTERFACE)..."
    run_as_user bash -c "cd '${FASTRPC_DIR}' && ./gitcompile"
    make -C "$FASTRPC_DIR" install
    ldconfig

    if ! fastrpc_installed; then
        err "Build concluido mas libcdsprpc.so nao aparece no ldconfig"
        return 1
    fi
    log "fastrpc instalado em /usr/local"
}

# ─── 4. Binarios Hexagon do CDSP ─────────────────────────────────────────────
# O firmware CDSP assinado so executa binarios cujos segmentos ELF estejam no
# whitelist de SHA-256 embutido no .mbn. Shell de outra build = falha.
authcheck() { python3 "$AUTHCHECK" --mbn "$CDSP_MBN" "$1" 2>/dev/null; }

install_from_dir() {
    local source_dir=$1 file score
    local -a files=()

    mapfile -t files < <(find "$source_dir" -maxdepth 1 -type f | sort)
    install -d -o root -g root -m 0755 "$DSP_CDSP_DIR"
    for file in "${files[@]}"; do
        install -o root -g root -m 0644 "$file" "$DSP_CDSP_DIR/"
    done
    log "${#files[@]} arquivos instalados em ${DSP_CDSP_DIR}"

    if ! score=$(authcheck "$DSP_CDSP_DIR"); then
        err "Validacao pos-instalacao falhou (${score:-0/0})"
        return 1
    fi
    log "Validacao pos-instalacao: ${score} binarios autorizados"
}

find_windows_dump() {
    local candidate
    if [[ -n ${NPU_WINDOWS_DUMP:-} ]]; then
        [[ -r $NPU_WINDOWS_DUMP ]] && { printf '%s\n' "$NPU_WINDOWS_DUMP"; return 0; }
        return 1
    fi
    for candidate in "${REPO_ROOT}"/windows-drivers/*.tar.zst; do
        [[ -r $candidate ]] || continue
        printf '%s\n' "$candidate"
        return 0
    done
    return 1
}

install_hexagon_binaries() {
    local dump tmp winner="" score candidate
    local -a candidates=()

    if [[ -d $DSP_CDSP_DIR ]] && score=$(authcheck "$DSP_CDSP_DIR"); then
        info "Binarios Hexagon ja instalados e autorizados pelo firmware (${score})"
        return 0
    fi
    if [[ -d $DSP_CDSP_DIR ]]; then
        warn "Binarios instalados NAO autorizados (${score:-0/0}) — reinstalando"
    fi

    # Fonte 1: os binarios versionados no repo (nao precisa do dump de drivers).
    if [[ -d $REPO_HEXAGON_DIR ]] && score=$(authcheck "$REPO_HEXAGON_DIR"); then
        log "Usando os binarios do repo: ${REPO_HEXAGON_DIR} (${score})"
        install_from_dir "$REPO_HEXAGON_DIR"
        return
    fi
    [[ -d $REPO_HEXAGON_DIR ]] &&
        warn "${REPO_HEXAGON_DIR} nao casa com ${CDSP_MBN##*/} (${score:-0/0}) — tentando o dump"

    # Fonte 2: extrair do dump dos drivers Windows.
    if ! command -v zstd &>/dev/null; then
        err "zstd ausente (necessario para abrir o dump): dnf install zstd"
        return 1
    fi
    if ! dump=$(find_windows_dump); then
        err "Dump dos drivers Windows nao encontrado"
        info "Copie o .tar.zst para ${REPO_ROOT}/windows-drivers/ ou aponte NPU_WINDOWS_DUMP"
        return 1
    fi
    log "Dump: ${dump}"

    tmp=$(mktemp -d /var/tmp/npu-hexagon.XXXXXX)
    CLEANUP_DIRS+=("$tmp")
    info "Extraindo o pacote CDSP (zstd --long=31, pode demorar)..."
    tar -I 'zstd -d --long=31' -xf "$dump" -C "$tmp" \
        --wildcards '*qcnspmcdm_ext_cdsp8380*/CDSP/*'

    mapfile -t candidates < <(find "$tmp" -type d -name CDSP | sort)
    if [[ ${#candidates[@]} -eq 0 ]]; then
        err "Nenhum diretorio */qcnspmcdm_ext_cdsp8380*/CDSP no dump"
        return 1
    fi
    for candidate in "${candidates[@]}"; do
        if score=$(authcheck "$candidate"); then
            info "  $(basename "$(dirname "$candidate")"): ${score} binarios autorizados"
            winner=$candidate
            break
        fi
        info "  $(basename "$(dirname "$candidate")"): ${score:-0/0} binarios autorizados"
    done
    if [[ -z $winner ]]; then
        err "Nenhum pacote do dump casa 100% com ${CDSP_MBN##*/}"
        info "O firmware CDSP assinado carrega um whitelist de SHA-256 por segmento"
        info "ELF; instalar um pacote que nao casa quebra o carregamento no Hexagon."
        info "Firmware em uso: $(strings "$CDSP_MBN" 2>/dev/null | grep -m1 'CDSP\.HT' || echo desconhecido)"
        return 1
    fi
    log "Pacote autorizado: ${winner}"

    install_from_dir "$winner"
}

# ─── 5. Mapeamento model do device-tree -> DSP_LIBRARY_PATH ──────────────────
write_qcom_conf() {
    write_file_if_changed "$QCOM_CONF" "# SPDX-License-Identifier: MIT
# ASUS Vivobook 14 X1407QA (Snapdragon X, x1p42100 \"Purwa\").
# Boota o DTB do Zenbook A14, entao /sys/firmware/devicetree/base/model reporta
# o nome do Zenbook. Reusa o layout de binarios do Purwa IoT EVK.
machines:
  ${DT_MODEL}:
    DSP_LIBRARY_PATH: x1p42100/Qualcomm/Purwa-IoT-EVK/dsp"
}

# ─── 6. Validacao real ───────────────────────────────────────────────────────
validate_runtime() {
    local output line signed unsigned failures=0

    if ! output=$(dsp_check 2>&1); then
        err "dsp_check falhou"
        printf '%s\n' "$output"
        return 1
    fi
    line=$(awk '$1 == "CDSP" { print; exit }' <<<"$output")
    signed=$(awk '{ print $3 }' <<<"$line")
    unsigned=$(awk '{ print $4 }' <<<"$line")
    if [[ $signed == Yes && $unsigned == Yes ]]; then
        log "dsp_check: ${line}"
    else
        err "dsp_check: CDSP sem SignedPD/UnsignedPD (linha: '${line:-ausente}')"
        failures=1
    fi

    info "Rodando fastrpc_test -d 3 -U 1 (execucao real no Hexagon)..."
    output=$(/usr/local/bin/fastrpc_test -d 3 -U 1 2>&1) || true
    if grep -q '^\[PASS\] libmultithreading.so' <<<"$output"; then
        log "fastrpc_test: [PASS] libmultithreading.so"
    else
        err "fastrpc_test: libmultithreading.so nao passou"
        printf '%s\n' "$output" | tail -20
        failures=1
    fi
    return "$failures"
}

# ─── Main ────────────────────────────────────────────────────────────────────
echo -e "${BOLD}Setup do runtime da NPU — Vivobook X1407QA${NC}"

step 1 "Pre-requisitos"
check_prereqs

step 2 "Dependencias de build"
install_build_deps

step 3 "fastrpc / libcdsprpc.so"
build_fastrpc

step 4 "Binarios Hexagon do CDSP"
install_hexagon_binaries

step 5 "Mapeamento do DSP_LIBRARY_PATH"
write_qcom_conf

step 6 "Validacao"
if validate_runtime; then
    echo
    log "${BOLD}NPU pronta.${NC} CDSP com SignedPD/UnsignedPD e execucao no Hexagon confirmada."
    info "Inferencia QNN ainda precisa do shim de SoC ID (soc_id 635 desconhecido pelo libQnnHtp.so)."
    exit 0
fi
echo
err "${BOLD}Validacao falhou.${NC} A NPU nao esta pronta — veja as mensagens acima."
exit 1
