#!/usr/bin/env bash
# Unpack Asus BIOS .cap into a tree of section files using UEFIExtract.
# Falls back to binwalk if UEFIExtract cannot descend.

source "$(dirname "$0")/00-env.sh"

[[ -f "$BIOS_CAP" ]] || die "BIOS not found — run 01-fetch-bios.sh first"

need UEFIExtract

log "running UEFIExtract on $BIOS_CAP"
# UEFIExtract emits output next to the input, as <file>.dump/
rm -rf "$DUMP_DIR"
(cd "$BIOS_DIR" && UEFIExtract "$(basename "$BIOS_CAP")" all)

if [[ ! -d "$DUMP_DIR" ]]; then
    log "UEFIExtract did not produce dump dir — falling back to binwalk"
    need binwalk
    mkdir -p "$DUMP_DIR"
    (cd "$DUMP_DIR" && binwalk -e -M "$BIOS_CAP" || true)
fi

file_count=$(find "$DUMP_DIR" -type f 2>/dev/null | wc -l)
log "unpack complete: $file_count files in $DUMP_DIR"
(( file_count > 0 )) || die "unpack produced no files"
