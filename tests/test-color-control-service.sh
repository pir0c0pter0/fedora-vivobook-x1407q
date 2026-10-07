#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
service="$repo_root/modules/vivobook-color-ctrl-1.0/vivobook-color-control.service"

[[ -f $service ]] || {
    echo 'FAIL: late color-control service is missing' >&2
    exit 1
}

systemd-analyze verify "$service"

grep -q '^After=.*display-manager\.service.*vivobook-camera\.service' "$service"
grep -qx 'ExecStart=/sbin/modprobe vivobook_color_ctrl' "$service"
grep -qx 'WantedBy=graphical.target' "$service"

echo 'PASS: color control loads after the graphical prerequisites'
