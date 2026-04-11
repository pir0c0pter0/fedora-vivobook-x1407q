#!/usr/bin/env bash
# Find AeoB-format files in the BIOS dump and compare IR-related ones
# against the baseline /lib/firmware/qcom/CAMI_RES_MTP.bin.

source "$(dirname "$0")/00-env.sh"

MATCHES_LOG="$BIOS_DIR/matches.log"
AEOB_WORKDIR="$BIOS_DIR/aeob"
mkdir -p "$AEOB_WORKDIR"

[[ -f "$MATCHES_LOG" ]] || die "matches.log missing — run 03-find-camera-artifacts.sh first"

# Filter matches.log to files that start with AeoB magic
aeob_files=()
while IFS= read -r path; do
    [[ -f "$path" ]] || continue
    head=$(head -c 4 "$path" 2>/dev/null | od -A n -t x1 | tr -d ' \n')
    if [[ "$head" == "41656f42" ]]; then
        aeob_files+=("$path")
    fi
done < "$MATCHES_LOG"

log "found ${#aeob_files[@]} AeoB candidate file(s)"

# Dump strings from baseline for reference
log "=== baseline CAMI_RES_MTP.bin strings ==="
strings "$MTP_BASELINE" | tee "$AEOB_WORKDIR/baseline.txt"

for src in "${aeob_files[@]}"; do
    id=$(basename "$(dirname "$src")")__$(basename "$src")
    out="$AEOB_WORKDIR/aeob-${id//\//_}.txt"
    log "=== strings from $src ==="
    strings "$src" | tee "$out"

    # Diff against baseline — any LDO name that differs is the find
    if diff -u "$AEOB_WORKDIR/baseline.txt" "$out" > "$out.diff" 2>&1; then
        log "  NO DIFF vs baseline MTP (this file is identical to generic MTP)"
    else
        log "  DIFF vs baseline — see $out.diff (THIS MAY BE THE PURWA-SPECIFIC FILE)"
        grep -E 'LDO|PPP_RESOURCE|vreg_|PMICVREGVOTE|TLMMGPIO|CLOCK|mclk' "$out.diff" | tee -a "$FINDINGS_LOG"
    fi
done

# Also dump the sensormodule binary — it may have init sequences we can reuse
log "=== com.qti.sensormodule.hm1092.bin strings (first 200) ==="
strings /lib/firmware/qcom/com.qti.sensormodule.hm1092.bin | head -200 | tee "$AEOB_WORKDIR/sensormodule-strings.txt"
