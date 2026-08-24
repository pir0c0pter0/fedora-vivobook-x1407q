#!/usr/bin/env bash
set -euo pipefail

root=${1:?usage: verify-live-root.sh ROOTFS}
sudo_path=$root/usr/bin/sudo
[[ -e $sudo_path ]] || { echo 'ERROR: live root missing /usr/bin/sudo' >&2; exit 1; }
read -r sudo_uid sudo_mode < <(stat -Lc '%u %a' "$sudo_path")
[[ $sudo_uid == 0 && $((8#$sudo_mode & 04000)) -ne 0 ]] || {
    echo "ERROR: live root sudo must be root-owned and setuid: uid=$sudo_uid mode=$sudo_mode" >&2
    exit 1
}
for firmware in gen71500_sqe.fw.xz gen71500_gmu.bin.xz; do
    [[ -s $root/usr/lib/firmware/qcom/$firmware ]] || {
        echo "ERROR: live root missing /usr/lib/firmware/qcom/$firmware" >&2
        exit 1
    }
done
