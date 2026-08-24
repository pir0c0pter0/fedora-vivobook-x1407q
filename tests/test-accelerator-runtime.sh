#!/usr/bin/env bash
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

export VIVOBOOK_SETUP_LIBRARY_ONLY=1
# shellcheck source=../setup-vivobook.sh
source "$repo/setup-vivobook.sh"

REAL_USER=$(id -un)
export REAL_USER
REAL_HOME="$test_root/home"
VULKAN_CONFIG_DIR="$REAL_HOME/.config/environment.d"
UDEV_RULES_DIR="$test_root/udev"
LIBCAMERA_IPA_SIMPLE_DIR="$test_root/libcamera/simple"

write_vulkan_hardware_config
write_fastrpc_access_rule
write_camera_dma_heap_rule
install_ov02c10_ipa_data

vulkan_config="$VULKAN_CONFIG_DIR/vulkan-hardware.conf"
fastrpc_rule="$UDEV_RULES_DIR/99-x1407qa-fastrpc.rules"
camera_dma_rule="$UDEV_RULES_DIR/71-vivobook-camera-dma-heap.rules"
camera_data="$LIBCAMERA_IPA_SIMPLE_DIR/ov02c10.yaml"

[[ $(<"$vulkan_config") == \
    'VK_DRIVER_FILES=/usr/share/vulkan/icd.d/freedreno_icd.aarch64.json' ]] || {
    echo 'Vulkan config does not force the hardware Freedreno ICD' >&2
    exit 1
}

grep -qxF 'SUBSYSTEM=="misc", KERNEL=="fastrpc-cdsp", GROUP="render", MODE="0660"' \
    "$fastrpc_rule" || {
    echo 'FastRPC rule does not grant only the non-secure CDSP node to render' >&2
    exit 1
}
if grep -q 'secure' "$fastrpc_rule"; then
    echo 'FastRPC rule exposes a secure DSP node' >&2
    exit 1
fi

grep -qxF 'SUBSYSTEM=="dma_heap", KERNEL=="system", TAG+="uaccess"' \
    "$camera_dma_rule" || {
    echo 'Camera DMA heap rule is not restricted to the active local user' >&2
    exit 1
}

grep -qxF 'version: 1' "$camera_data" || {
    echo 'OV02C10 IPA data is not a libcamera v1 tuning file' >&2
    exit 1
}
for algorithm in BlackLevel Awb Adjust Agc; do
    grep -q -- "- ${algorithm}:" "$camera_data" || {
        echo "OV02C10 IPA data is missing ${algorithm}" >&2
        exit 1
    }
done

camera_systemd_root="$test_root/systemd-root"
camera_unit="$camera_systemd_root/etc/systemd/system/vivobook-camera.service"
install -Dm0644 \
    "$repo/modules/vivobook-cam-fix-2.0/vivobook-camera.service" "$camera_unit"
systemctl --root="$camera_systemd_root" enable vivobook-camera.service
[[ -L "$camera_systemd_root/etc/systemd/system/graphical.target.wants/vivobook-camera.service" ]] || {
    echo 'Camera service is not enabled for graphical boot' >&2
    exit 1
}

echo 'PASS: accelerator runtime files are installed with the safe hardware contract'
