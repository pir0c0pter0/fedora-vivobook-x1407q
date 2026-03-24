#!/bin/bash
# =============================================================================
# prepare-usb4-kernel.sh — Generate a dedicated Fedora kernel spec for USB4 work
# =============================================================================

set -euo pipefail

SOURCE_SPEC="${1:-${HOME}/rpmbuild/SPECS/kernel.spec}"
OUTPUT_SPEC="${2:-${HOME}/rpmbuild/SPECS/kernel-usb4.spec}"
SOURCES_DIR="${HOME}/rpmbuild/SOURCES"
BUILD_ID=".usb4"

log()  { echo "[+] $*"; }
warn() { echo "[!] $*"; }
err()  { echo "[x] $*" >&2; }

if [[ "${SOURCE_SPEC}" == "${OUTPUT_SPEC}" ]]; then
    err "Spec de origem e destino nao podem ser o mesmo arquivo"
    exit 1
fi

if [[ ! -f "${SOURCE_SPEC}" ]]; then
    err "Spec de origem nao encontrado: ${SOURCE_SPEC}"
    exit 1
fi

if [[ ! -d "${SOURCES_DIR}" ]]; then
    err "Diretorio de fontes nao encontrado: ${SOURCES_DIR}"
    exit 1
fi

mapfile -t usb4_patches < <(
    find "${SOURCES_DIR}" -maxdepth 1 -type f -name 'usb4-*.patch' -printf '%f\n' | sort
)

patch_defs=""
patch_apply=""
patch_num=2100

for patch_name in "${usb4_patches[@]}"; do
    patch_defs+="Patch${patch_num}: ${patch_name}"$'\n'
    patch_apply+="ApplyOptionalPatch ${patch_name}"$'\n'
    ((patch_num++))
done

tmp_spec="$(mktemp)"
trap 'rm -f "${tmp_spec}"' EXIT

awk \
    -v build_id="${BUILD_ID}" \
    -v patch_defs="${patch_defs}" \
    -v patch_apply="${patch_apply}" \
    '
    BEGIN {
        inserted_defs = 0
        inserted_apply = 0
    }

    /^%define buildid / {
        print "%define buildid " build_id
        next
    }

    /^# Qualcomm s2idle\/PDC patches/ {
        next
    }

    /^Patch2000: s2idle-combined-qualcomm-pdc-idle\.patch$/ {
        next
    }

    /^ApplyOptionalPatch s2idle-combined-qualcomm-pdc-idle\.patch$/ {
        next
    }

    /^Patch999999: linux-kernel-test\.patch$/ {
        if (!inserted_defs) {
            print "# Qualcomm USB4/TB3 patches"
            if (length(patch_defs) > 0) {
                printf "%s", patch_defs
            } else {
                print "# No public usb4-*.patch files staged in ~/rpmbuild/SOURCES yet"
            }
            print ""
            inserted_defs = 1
        }
        print
        next
    }

    /^ApplyOptionalPatch linux-kernel-test\.patch$/ {
        if (!inserted_apply) {
            print "# Qualcomm USB4/TB3 patches"
            if (length(patch_apply) > 0) {
                printf "%s", patch_apply
            } else {
                print "# No public usb4-*.patch files staged in ~/rpmbuild/SOURCES yet"
            }
            print ""
            inserted_apply = 1
        }
        print
        next
    }

    {
        print
    }
    ' "${SOURCE_SPEC}" > "${tmp_spec}"

if [[ -e "${OUTPUT_SPEC}" ]]; then
    backup_path="${OUTPUT_SPEC}.bak.$(date +%Y%m%d-%H%M%S)"
    cp -a "${OUTPUT_SPEC}" "${backup_path}"
    warn "Backup do spec anterior salvo em ${backup_path}"
fi

install -D -m 0644 "${tmp_spec}" "${OUTPUT_SPEC}"

log "Spec USB4 gerado em ${OUTPUT_SPEC}"
log "Build ID configurado para ${BUILD_ID}"

if ((${#usb4_patches[@]} == 0)); then
    warn "Nenhum patch usb4-*.patch encontrado em ${SOURCES_DIR}"
    warn "O spec foi preparado, mas ainda sem patches publicos do host/router"
else
    log "Patches USB4 injetados no spec:"
    for patch_name in "${usb4_patches[@]}"; do
        echo "    - ${patch_name}"
    done
fi
