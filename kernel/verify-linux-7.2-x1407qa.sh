#!/usr/bin/env bash
set -euo pipefail

ARTIFACT_ROOT=${1:?usage: verify-linux-7.2-x1407qa.sh ARTIFACT_ROOT [VERSION]}
readonly VERSION=${2:-7.2.0-x1407qa}
readonly REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly USB_CONFIG_GUARD=$REPO_ROOT/kernel/verify-linux-usb-config-preservation.sh
readonly REFERENCE_CONFIG=${X1407QA_REFERENCE_CONFIG:-/boot/config-7.2.0-x1407qa}
IMAGE=$ARTIFACT_ROOT/boot/vmlinuz-$VERSION
MODULE_ROOT=$ARTIFACT_ROOT/lib/modules/$VERSION
DTB=$ARTIFACT_ROOT/boot/dtb/qcom/x1p42100-asus-zenbook-a14.dtb
CONFIG=$ARTIFACT_ROOT/boot/config-$VERSION

[[ -s $IMAGE ]] || { echo 'ERROR: kernel Image missing' >&2; exit 1; }
file "$IMAGE" | grep -Eq 'ARM64|ARM aarch64' || { file "$IMAGE" >&2; exit 1; }
LC_ALL=C grep -aFq "Linux version $VERSION " "$IMAGE" || {
    echo "ERROR: kernel Image release does not match $VERSION" >&2
    exit 1
}
if [[ $VERSION == 7.2.0-x1407qa-wifi-pwrctrl-diag ]]; then
    LC_ALL=C grep -aFq \
        'X1407QA Wi-Fi diagnostic: PERST# deasserted before WCN power-on' \
        "$IMAGE" || {
        echo 'ERROR: diagnostic kernel Image does not contain the pwrctrl marker' >&2
        exit 1
    }
fi
[[ -s $MODULE_ROOT/modules.dep ]] || { echo 'ERROR: modules.dep missing' >&2; exit 1; }
[[ -s $DTB ]] || { echo 'ERROR: x1p42100-asus-zenbook-a14 DTB missing' >&2; exit 1; }
[[ -s $CONFIG ]] || { echo 'ERROR: kernel config missing' >&2; exit 1; }
[[ -x $USB_CONFIG_GUARD ]] || { echo 'ERROR: USB config preservation guard missing' >&2; exit 1; }
"$USB_CONFIG_GUARD" "$REFERENCE_CONFIG" "$CONFIG"
for required_config in \
    CONFIG_ISO9660_FS=y CONFIG_JOLIET=y CONFIG_EROFS_FS=y \
    CONFIG_EROFS_FS_ZIP=y CONFIG_DM_SNAPSHOT=m \
    CONFIG_FW_LOADER_COMPRESS=y CONFIG_FW_LOADER_COMPRESS_XZ=y \
    CONFIG_QCOM_Q6V5_PAS=m CONFIG_QCOM_Q6V5_ADSP=m \
    CONFIG_QCOM_PMIC_GLINK=m CONFIG_BATTERY_QCOM_BATTMGR=m; do
    grep -qxF "$required_config" "$CONFIG" || {
        echo "ERROR: kernel config missing $required_config" >&2
        exit 1
    }
done
for required_config in \
    CONFIG_HID CONFIG_I2C_HID_CORE CONFIG_BACKLIGHT_CLASS_DEVICE \
    CONFIG_REGULATOR CONFIG_SPMI CONFIG_MFD_SPMI_PMIC CONFIG_REGMAP_SPMI; do
    grep -Eq "^${required_config}=[ym]$" "$CONFIG" || {
        echo "ERROR: kernel config missing $required_config" >&2
        exit 1
    }
done
for required_config in \
    CONFIG_I2C_QCOM_GENI=m CONFIG_ATH11K=m CONFIG_ATH11K_PCI=m \
    CONFIG_QCOM_Q6V5_PAS=m CONFIG_QCOM_PMIC_GLINK=m \
    CONFIG_BATTERY_QCOM_BATTMGR=m; do
    grep -qxF "$required_config" "$CONFIG" || {
        echo "ERROR: kernel config must be $required_config" >&2
        exit 1
    }
done
for required_config in \
    CONFIG_USB_USBNET=m CONFIG_USB_NET_CDCETHER=m CONFIG_USB_NET_CDC_NCM=m \
    CONFIG_USB_NET_RNDIS_HOST=m CONFIG_BT_BNEP=m \
    CONFIG_POWER_SEQUENCING_QCOM_WCN=m; do
    grep -qxF "$required_config" "$CONFIG" || {
        echo "ERROR: kernel config must be $required_config" >&2
        exit 1
    }
done
for module in \
    wcn_regulator_fix vivobook_hotkey_fix vivobook_kbd_fix vivobook_bl_fix; do
    module_path=$(find "$MODULE_ROOT/extra" -type f -name "$module.ko*" -size +0c -print -quit)
    [[ -n $module_path ]] || {
            echo "ERROR: core X1407QA module missing: $module" >&2
            exit 1
    }
    file "$module_path" | grep -Eq 'ARM aarch64|ARM64' || {
        echo "ERROR: core X1407QA module is not aarch64: $module_path" >&2
        exit 1
    }
    [[ $(modinfo -F vermagic "$module_path" | cut -d' ' -f1) == "$VERSION" ]] || {
        echo "ERROR: core X1407QA module vermagic mismatch: $module_path" >&2
        exit 1
    }
    modprobe -d "$ARTIFACT_ROOT" -S "$VERSION" --show-depends "$module" >/dev/null || {
        echo "ERROR: dependencies do not resolve for $module" >&2
        exit 1
    }
    if [[ $module == wcn_regulator_fix ]] &&
        [[ $(modinfo -F softdep "$module_path") != *pwrseq_qcom_wcn* ]]; then
        echo 'ERROR: wcn_regulator_fix must load after pwrseq_qcom_wcn' >&2
        exit 1
    fi
done
modprobe -d "$ARTIFACT_ROOT" -S "$VERSION" --show-depends pwrseq_qcom_wcn >/dev/null || {
    echo 'ERROR: dependencies do not resolve for pwrseq_qcom_wcn' >&2
    exit 1
}

rndis_module=
for module_filename in rndis_host.ko rndis_host.ko.xz rndis_host.ko.zst rndis_host.ko.gz; do
    rndis_module=$(find "$MODULE_ROOT" -type f -name "$module_filename" -print -quit)
    [[ -z $rndis_module ]] || break
done
[[ -n $rndis_module && -s $rndis_module ]] || {
    echo 'ERROR: kernel artifacts missing rndis_host.ko required for USB tethering' >&2
    exit 1
}

module_relative=./${rndis_module#"$ARTIFACT_ROOT"/}
awk -v expected="$module_relative" '$2 == expected { found = 1 } END { exit !found }' \
    "$ARTIFACT_ROOT/SHA256SUMS" || {
    echo 'ERROR: rndis_host module is not covered by SHA256SUMS' >&2
    exit 1
}

(cd "$ARTIFACT_ROOT" && sha256sum --check SHA256SUMS)

command -v modinfo >/dev/null || {
    echo 'ERROR: modinfo is required to validate rndis_host.ko' >&2
    exit 1
}
module_name=$(modinfo -F name "$rndis_module") || {
    echo 'ERROR: rndis_host artifact is not a valid kernel module' >&2
    exit 1
}
[[ $module_name == rndis_host ]] || {
    echo "ERROR: unexpected RNDIS module name: $module_name" >&2
    exit 1
}
module_vermagic=$(modinfo -F vermagic "$rndis_module") || {
    echo 'ERROR: rndis_host artifact has no valid vermagic' >&2
    exit 1
}
[[ ${module_vermagic%% *} == "$VERSION" ]] || {
    echo "ERROR: rndis_host vermagic does not match $VERSION: $module_vermagic" >&2
    exit 1
}

echo "PASS: Linux $VERSION aarch64 artifacts verified"
