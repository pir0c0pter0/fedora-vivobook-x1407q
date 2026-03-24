#!/bin/bash
# =============================================================================
# build-usb4-kernel.sh — Build the prepared USB4 kernel RPM set safely
# =============================================================================

set -euo pipefail

SPEC_PATH="${1:-${HOME}/rpmbuild/SPECS/kernel-usb4.spec}"
cpu_total="$(nproc --all)"
half_cpus=$(( cpu_total / 2 ))

if (( half_cpus < 1 )); then
    half_cpus=1
fi

requested_jobs="${KERNEL_BUILD_JOBS:-${half_cpus}}"
jobs="${requested_jobs}"

log()  { echo "[+] $*"; }
warn() { echo "[!] $*"; }
err()  { echo "[x] $*" >&2; }

if [[ ! -f "${SPEC_PATH}" ]]; then
    err "Spec USB4 nao encontrado: ${SPEC_PATH}"
    exit 1
fi

if ! grep -q '^%define buildid \.usb4$' "${SPEC_PATH}"; then
    err "O spec ${SPEC_PATH} nao parece ser o spec dedicado de USB4 (.usb4)"
    exit 1
fi

if ! grep -Eq '^Patch21[0-9][0-9]: usb4-.*\.patch$' "${SPEC_PATH}"; then
    err "Nenhum patch usb4-*.patch foi injetado no spec"
    err "Recusando buildar um kernel stock apenas renomeado como .usb4"
    exit 1
fi

if (( jobs > half_cpus )); then
    warn "Limitando paralelismo de ${jobs} para metade dos nucleos (${half_cpus})"
    jobs="${half_cpus}"
fi

log "Buildando ${SPEC_PATH}"
log "Usando ${jobs} job(s) de um total de ${cpu_total} CPU(s)"

rpmbuild -bb --target=aarch64 \
    --without debug \
    --without debuginfo \
    --without doc \
    --without perf \
    --without tools \
    --without bpftool \
    --without selftests \
    --without cross_headers \
    --define "_smp_mflags -j${jobs}" \
    "${SPEC_PATH}"
