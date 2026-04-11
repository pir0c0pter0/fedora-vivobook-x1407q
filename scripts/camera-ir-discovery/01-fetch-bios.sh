#!/usr/bin/env bash
# Fetch or user-provide the Asus BIOS .cap for Vivobook X1407QA.
# Usage:
#   ./01-fetch-bios.sh              # interactive: prompts if needed
#   ./01-fetch-bios.sh /path/to.cap # copies user's existing file

source "$(dirname "$0")/00-env.sh"

if [[ -n "${1:-}" ]]; then
    [[ -f "$1" ]] || die "file not found: $1"
    log "copying user-provided BIOS: $1"
    cp "$1" "$BIOS_CAP"
elif [[ -f "$BIOS_CAP" ]]; then
    log "BIOS already present: $BIOS_CAP (skipping fetch)"
else
    log "No BIOS provided and nothing cached at $BIOS_CAP"
    cat <<EOF

MANUAL STEP REQUIRED:
  1. Open https://www.asus.com/support/ in a browser
  2. Search for "Vivobook X1407QA"
  3. Go to Support -> Driver & Utility -> BIOS & FIRMWARE
  4. Download the latest BIOS .zip (or .cap) file
  5. Unzip if needed (the .cap is typically inside a .zip)
  6. Re-run this script with the path:
       $0 /path/to/X1407QAAS.XXX

EOF
    die "waiting for user to provide BIOS file"
fi

# Validate: should be at least 8MB (typical BIOS is 32-64MB)
size=$(stat -c '%s' "$BIOS_CAP")
(( size >= 8 * 1024 * 1024 )) || die "BIOS file too small ($size bytes) — suspect wrong file"

# Record size + hash for reference
sha256sum "$BIOS_CAP" | tee -a "$FINDINGS_LOG"
log "BIOS acquired: $BIOS_CAP ($size bytes)"
