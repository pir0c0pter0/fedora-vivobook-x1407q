#!/usr/bin/env bash
set -euo pipefail

SOURCE_ROOT=${1:?usage: prepare-linux-7.2-x1407qa-config.sh SOURCE_ROOT BUILD_ROOT REFERENCE_CONFIG}
BUILD_ROOT=${2:?usage: prepare-linux-7.2-x1407qa-config.sh SOURCE_ROOT BUILD_ROOT REFERENCE_CONFIG}
REFERENCE_CONFIG=${3:?usage: prepare-linux-7.2-x1407qa-config.sh SOURCE_ROOT BUILD_ROOT REFERENCE_CONFIG}
readonly REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly USB_CONFIG_GUARD=$REPO_ROOT/kernel/verify-linux-usb-config-preservation.sh

[[ -d $SOURCE_ROOT && ! -L $SOURCE_ROOT ]] || {
    echo "ERROR: Linux source root is missing or unsafe: $SOURCE_ROOT" >&2
    exit 1
}
[[ -d $BUILD_ROOT && ! -L $BUILD_ROOT ]] || {
    echo "ERROR: Linux build root is missing or unsafe: $BUILD_ROOT" >&2
    exit 1
}
[[ -f $REFERENCE_CONFIG && ! -L $REFERENCE_CONFIG && -r $REFERENCE_CONFIG ]] || {
    echo "ERROR: stable reference config is missing or unsafe: $REFERENCE_CONFIG" >&2
    exit 1
}
[[ -x $SOURCE_ROOT/scripts/config ]] || {
    echo 'ERROR: Linux scripts/config is missing' >&2
    exit 1
}
[[ -x $USB_CONFIG_GUARD ]] || {
    echo 'ERROR: USB config preservation guard is missing' >&2
    exit 1
}

install -m 0644 "$REFERENCE_CONFIG" "$BUILD_ROOT/.config"
config=("$SOURCE_ROOT/scripts/config" --file "$BUILD_ROOT/.config")
for option in \
    CONFIG_ARCH_QCOM CONFIG_ARM64 CONFIG_ACPI CONFIG_EFI CONFIG_DRM_MSM \
    CONFIG_QCOM_Q6V5_PAS CONFIG_QCOM_RPROC_COMMON CONFIG_QCOM_SYSMON \
    CONFIG_QCOM_PMIC_GLINK CONFIG_BATTERY_QCOM_BATTMGR CONFIG_QCOM_SPMI_ADC_TM5 \
    CONFIG_QCOM_CLK_RPMH CONFIG_QCOM_COMMAND_DB CONFIG_QCOM_RPMH \
    CONFIG_QCOM_SCM CONFIG_QCOM_SMEM CONFIG_QCOM_AOSS_QMP \
    CONFIG_ISO9660_FS CONFIG_JOLIET CONFIG_EROFS_FS CONFIG_EROFS_FS_ZIP \
    CONFIG_DM_SNAPSHOT \
    CONFIG_ATH11K CONFIG_ATH11K_PCI \
    CONFIG_BT_HCIUART CONFIG_BT_HCIUART_QCA CONFIG_SND_SOC_QCOM \
    CONFIG_SND_SOC_X1E80100 CONFIG_I2C_QCOM_CCI CONFIG_VIDEO_QCOM_CAMSS \
    CONFIG_VIDEO_OV02C10 CONFIG_ARM_SCMI_PROTOCOL CONFIG_ARM_SCMI_CPUFREQ \
    CONFIG_QCOM_FASTRPC CONFIG_QCOM_PD_MAPPER CONFIG_NF_TABLES_INET; do
    "${config[@]}" --enable "${option#CONFIG_}" 2>/dev/null || true
done
for option in \
    CONFIG_NF_TABLES CONFIG_NF_CONNTRACK_BROADCAST \
    CONFIG_NF_CONNTRACK_NETBIOS_NS CONFIG_NFT_CT CONFIG_NFT_NAT \
    CONFIG_NFT_REJECT CONFIG_NFT_REJECT_INET CONFIG_NFT_FIB_IPV4 \
    CONFIG_NFT_FIB_IPV6 CONFIG_NFT_FIB_INET; do
    "${config[@]}" --module "${option#CONFIG_}" 2>/dev/null || true
done

make -C "$SOURCE_ROOT" O="$BUILD_ROOT" ARCH=arm64 olddefconfig
"$USB_CONFIG_GUARD" "$REFERENCE_CONFIG" "$BUILD_ROOT/.config"

for required_config in \
    CONFIG_ISO9660_FS=y CONFIG_JOLIET=y CONFIG_EROFS_FS=y \
    CONFIG_EROFS_FS_ZIP=y CONFIG_DM_SNAPSHOT=m \
    CONFIG_NF_TABLES=m CONFIG_NF_CONNTRACK_BROADCAST=m \
    CONFIG_NF_CONNTRACK_NETBIOS_NS=m \
    CONFIG_NF_TABLES_INET=y CONFIG_NFT_CT=m \
    CONFIG_NFT_NAT=m CONFIG_NFT_REJECT=m CONFIG_NFT_REJECT_INET=m \
    CONFIG_NFT_FIB_IPV4=m CONFIG_NFT_FIB_IPV6=m CONFIG_NFT_FIB_INET=m; do
    grep -qxF "$required_config" "$BUILD_ROOT/.config" || {
        echo "ERROR: kernel config missing $required_config" >&2
        exit 1
    }
done

echo 'PASS: Linux config inherits stable baseline and preserves USB/Type-C'
