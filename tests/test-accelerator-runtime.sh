#!/usr/bin/env bash
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

export VIVOBOOK_SETUP_LIBRARY_ONLY=1
# shellcheck source=../setup-vivobook.sh
source "$repo/setup-vivobook.sh"

boot_root="$test_root/boot-root"
mkdir -p "$boot_root/etc/default" "$boot_root/etc/kernel" "$boot_root/boot/grub2"
printf 'GRUB_CMDLINE_LINUX="quiet rd.live.ram pd_ignore_unused pd_ignore_unused mem_sleep_default=deep mem_sleep_default=deep systemd.zram=1 systemd.zram=2 plymouth.enable=1 plymouth.enable=2"\n' \
    > "$boot_root/etc/default/grub"
printf 'root=UUID=test ro rd.live.ram pd_ignore_unused mem_sleep_default=deep systemd.zram=1 plymouth.enable=1\n' \
    > "$boot_root/etc/kernel/cmdline"
printf '  linux /vmlinuz root=UUID=test ro rd.live.ram pd_ignore_unused mem_sleep_default=deep systemd.zram=1 plymouth.enable=1\n' \
    > "$boot_root/boot/grub2/custom.cfg"
write_installed_boot_params "$boot_root"
required_boot_params='clk_ignore_unused mem_sleep_default=s2idle systemd.zram=0 plymouth.enable=0 systemd.tpm2_wait=0 rd.driver.pre=pwrseq_qcom_wcn rd.driver.pre=wcn_regulator_fix rd.systemd.mask=dev-tpm0.device rd.systemd.mask=dev-tpmrm0.device'
for config in "$boot_root/etc/default/grub" "$boot_root/etc/kernel/cmdline" \
    "$boot_root/boot/grub2/custom.cfg"; do
    grep -qF "$required_boot_params" "$config" || {
        echo "Installed boot policy was not persisted in $config" >&2
        exit 1
    }
    if grep -Eq 'rd\.live\.ram|pd_ignore_unused|mem_sleep_default=deep|systemd.zram=1|plymouth.enable=1' "$config"; then
        echo "Obsolete installed boot policy remains in $config" >&2
        exit 1
    fi
done

readonly_root="$test_root/readonly-root"
mkdir -p "$readonly_root/etc/default"
printf 'GRUB_CMDLINE_LINUX="quiet"\n' > "$readonly_root/etc/default/grub"
chmod 0555 "$readonly_root/etc/default"
if write_installed_boot_params "$readonly_root" 2>/dev/null; then
    echo 'Installed boot policy writer hid a configuration write failure' >&2
    exit 1
fi
chmod 0755 "$readonly_root/etc/default"

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
camera_overlay="$repo/modules/vivobook-cam-fix-2.0/vivobook_cam_phase1.dts"

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

grep -Eq 'rotation = <180>;' "$camera_overlay" || {
    echo 'OV02C10 mounting rotation must stay 180 so libcamera flips the sensor' >&2
    exit 1
}

camera_systemd_root="$test_root/systemd-root"
camera_unit="$camera_systemd_root/etc/systemd/system/vivobook-camera.service"
install -Dm0644 \
    "$repo/modules/vivobook-cam-fix-2.0/vivobook-camera.service" "$camera_unit"
systemctl --root="$camera_systemd_root" enable vivobook-camera.service
[[ -L "$camera_systemd_root/etc/systemd/system/graphical.target.wants/vivobook-camera.service" ]] || {
    echo 'Camera service is not enabled for graphical boot' >&2
    exit 1
}
if grep -Eq 'udevadm settle|ExecStartPost=/bin/sleep|wireplumber' "$camera_unit"; then
    echo 'Camera service still blocks graphical boot after the sensor is ready' >&2
    exit 1
fi

echo 'PASS: accelerator runtime files are installed with the safe hardware contract'
