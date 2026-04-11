#!/usr/bin/env bash
# Decompile every DSDT-magic file found in Task 7 and extract CAMI device blocks.

source "$(dirname "$0")/00-env.sh"

need iasl

MATCHES_LOG="$BIOS_DIR/matches.log"
DSDT_WORKDIR="$BIOS_DIR/dsdt"
mkdir -p "$DSDT_WORKDIR"

[[ -f "$MATCHES_LOG" ]] || die "matches.log missing — run 03-find-camera-artifacts.sh first"

# Pick only the files that start with DSDT magic
dsdt_files=()
while IFS= read -r path; do
    [[ -f "$path" ]] || continue
    head=$(head -c 4 "$path" 2>/dev/null)
    if [[ "$head" == "DSDT" ]]; then
        dsdt_files+=("$path")
    fi
done < "$MATCHES_LOG"

(( ${#dsdt_files[@]} > 0 )) || die "no DSDT-magic files in matches.log"
log "found ${#dsdt_files[@]} DSDT candidate(s)"

for src in "${dsdt_files[@]}"; do
    id=$(basename "$(dirname "$src")")
    out="$DSDT_WORKDIR/dsdt-${id}.aml"
    dsl="$DSDT_WORKDIR/dsdt-${id}.dsl"
    cp "$src" "$out"
    log "decompiling $id"
    if iasl -d "$out" 2>&1 | tail -5; then
        if [[ -f "$dsl" ]]; then
            # Extract CAMI device block with surrounding context
            log "CAMI block in $dsl:"
            awk '
                /Device *\(CAMI\)/ { in_cami=1; depth=0 }
                in_cami {
                    print
                    for (i=1; i<=length($0); i++) {
                        c = substr($0, i, 1)
                        if (c == "{") depth++
                        if (c == "}") { depth--; if (depth == 0) { in_cami=0; print "---"; next } }
                    }
                }
            ' "$dsl" | tee -a "$FINDINGS_LOG"
        fi
    fi
done

log "DSDT parsing complete — review $DSDT_WORKDIR/*.dsl manually for _PR0 / _PS0 / _CRS details"
