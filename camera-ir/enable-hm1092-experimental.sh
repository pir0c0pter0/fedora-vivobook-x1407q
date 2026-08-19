#!/usr/bin/env bash
set -euo pipefail

apply=false
overlay=""
while (($#)); do
    case "$1" in
        --apply) apply=true ;;
        --overlay) shift; overlay="${1:-}" ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

model="$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)"
board="$(cat /sys/class/dmi/id/board_name 2>/dev/null || true)"
if [[ "$model $board" != *X1407QA* ]]; then
    echo "refusing: this experimental HM1092 helper only supports X1407QA" >&2
    exit 1
fi

if ! grep -RqsE 'HM1092|QCOM0C99|CameraAuxSensor|13041043' /usr/lib/firmware /lib/firmware 2>/dev/null; then
    echo 'refusing: HM1092/QCOM0C99/CameraAuxSensor firmware evidence is absent' >&2
    exit 1
fi

if [[ "$apply" != true ]]; then
    echo 'dry-run: model and firmware evidence checks passed'
    echo 'No regulator, device-tree, sysfs, or kernel state was changed.'
    echo 'Use --apply --overlay /path/to/reviewed.dtbo only after the overlay has been hardware-reviewed.'
    exit 0
fi

if [[ -z "$overlay" || ! -f "$overlay" ]]; then
    echo 'refusing: --apply requires an explicit, reviewed --overlay file' >&2
    exit 1
fi
if [[ ! -d /sys/kernel/config/device-tree/overlays ]]; then
    echo 'refusing: runtime device-tree overlays are unavailable on this kernel/firmware' >&2
    exit 1
fi

echo 'refusing: automatic HM1092 power-up remains disabled until PMIC and regulator assignments are verified on X1407QA hardware' >&2
echo "Reviewed overlay retained at: $overlay" >&2
exit 1
