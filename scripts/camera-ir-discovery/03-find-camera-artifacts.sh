#!/usr/bin/env bash
# Find camera-relevant files in the unpacked BIOS tree.
# Searches for: strings (CAMI, hm1092, QCOM0C99) and magic (AeoB, DSDT).

source "$(dirname "$0")/00-env.sh"

[[ -d "$DUMP_DIR" ]] || die "dump dir not found — run 02-unpack-uefi.sh first"

MATCHES_LOG="$BIOS_DIR/matches.log"
: > "$MATCHES_LOG"

log "searching for CAMI / hm1092 / QCOM0C99 strings"
grep -rlaI --null \
    -e 'CAMI' -e 'hm1092' -e 'HM1092' -e 'QCOM0C99' \
    "$DUMP_DIR" 2>/dev/null | tr '\0' '\n' | tee -a "$MATCHES_LOG"

log "searching for AeoB magic (4 bytes: 41 65 6f 42)"
# -l: list filenames only; -P: perl regex; hex escape for binary match
grep -rlaP --null -e '\x41\x65\x6f\x42' "$DUMP_DIR" 2>/dev/null \
    | tr '\0' '\n' | tee -a "$MATCHES_LOG"

log "searching for DSDT magic (4 bytes: 44 53 44 54)"
# DSDT appears at offset 0 in ACPI table files
# Use a python helper instead of grep to enforce offset-0 match
python3 - <<'PY' | tee -a "$MATCHES_LOG"
import os
root = os.environ.get('DUMP_DIR', '/tmp/x1407qa-bios/bios.cap.dump')
for dp, _, fs in os.walk(root):
    for f in fs:
        p = os.path.join(dp, f)
        try:
            with open(p, 'rb') as fh:
                if fh.read(4) == b'DSDT':
                    print(p)
        except OSError:
            pass
PY

# Dedupe and count
sort -u "$MATCHES_LOG" > "$MATCHES_LOG.dedup"
mv "$MATCHES_LOG.dedup" "$MATCHES_LOG"
count=$(wc -l < "$MATCHES_LOG")
log "total unique matches: $count (see $MATCHES_LOG)"
(( count > 0 )) || die "no camera-relevant files found in BIOS dump"
