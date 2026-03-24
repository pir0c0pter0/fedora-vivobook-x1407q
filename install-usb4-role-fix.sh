#!/bin/bash
# =============================================================================
# install-usb4-role-fix.sh — Install udev host-role fix for Vivobook USB-C
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RULE_SRC="${SCRIPT_DIR}/modules/vivobook-usb4-fix-1.0/70-vivobook-usb4.rules"
HELPER_SRC="${SCRIPT_DIR}/modules/vivobook-usb4-fix-1.0/vivobook-usb4-role-fix"
RULE_DST="/etc/udev/rules.d/70-vivobook-usb4.rules"
HELPER_DST="/usr/local/libexec/vivobook-usb4-role-fix"

log()  { echo "[+] $*"; }
warn() { echo "[!] $*"; }
err()  { echo "[x] $*"; }

if [[ $EUID -ne 0 ]]; then
    err "Execute como root: sudo bash install-usb4-role-fix.sh"
    exit 1
fi

if [[ ! -f "$RULE_SRC" || ! -f "$HELPER_SRC" ]]; then
    err "Arquivos fonte do fix USB4 nao encontrados no repositorio"
    exit 1
fi

install -D -m 0755 "$HELPER_SRC" "$HELPER_DST"
sed "s|@HELPER_PATH@|${HELPER_DST}|g" "$RULE_SRC" > "$RULE_DST"
chmod 0644 "$RULE_DST"

log "Helper instalado em ${HELPER_DST}"
log "Udev rule instalada em ${RULE_DST}"

udevadm control --reload
udevadm trigger --subsystem-match=typec || true

for port in /sys/class/typec/port[0-9]*; do
    [[ -L "$port" ]] || continue
    [[ "$(basename "$port")" =~ ^port[0-9]+$ ]] || continue
    "$HELPER_DST" "$(basename "$port")" || true
done

log "Fix de host role instalado"
warn "Isso corrige apenas o papel host/device. Tunneling TB3/USB4 continua dependente do stack upstream."
