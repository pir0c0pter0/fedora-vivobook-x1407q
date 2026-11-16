#!/usr/bin/env bash
set -euo pipefail
echo 'YOGA-SELFTEST-BEGIN'
uname -r
test "$(noctalia --version)" = 'noctalia v5.5.0'
niri validate -c /etc/skel/.config/niri/config.kdl
test "$(find /usr/share/color/icc/lenovo -name '*.icm' -type f | wc -l)" = 7
(cd /usr/share/color/icc/lenovo && sha256sum -c /usr/share/yoga-port/colors.sha256)
test -L /run/initramfs/livedev
findmnt -n -o FSTYPE / | grep -qx overlay
echo 'YOGA-SELFTEST-PASS'
systemctl poweroff
