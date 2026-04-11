#!/usr/bin/env bash
# Shared environment for camera-ir-discovery scripts.
# Source this file from other scripts:  source "$(dirname "$0")/00-env.sh"

set -euo pipefail

# Workspace (throwaway, under /tmp so nothing leaks into repo)
BIOS_DIR="${BIOS_DIR:-/tmp/x1407qa-bios}"
BIOS_CAP="${BIOS_CAP:-$BIOS_DIR/bios.cap}"
DUMP_DIR="${DUMP_DIR:-$BIOS_DIR/bios.cap.dump}"
FINDINGS_LOG="${FINDINGS_LOG:-$BIOS_DIR/findings.log}"

# Output root for per-step artifacts (matches.log, dsdt-*.dsl, aeob-*.txt)
mkdir -p "$BIOS_DIR"

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$FINDINGS_LOG"; }
die()  { log "ERROR: $*"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }

# Generic MTP baseline file for comparison (already present on system)
MTP_BASELINE="/lib/firmware/qcom/CAMI_RES_MTP.bin"
