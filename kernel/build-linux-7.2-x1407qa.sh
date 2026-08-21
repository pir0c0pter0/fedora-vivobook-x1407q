#!/usr/bin/env bash
set -euo pipefail

readonly VERSION=${X1407QA_KERNEL_VERSION:-7.2.0-x1407qa}
readonly LOCALVERSION=${X1407QA_LOCALVERSION:--x1407qa}
readonly EXPECTED_SHA256=f9fef3d14c0df53819026f4be74459835c2a0b0dcbf5b5bbd9ea19f0829402b3
readonly REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly DEFAULT_TARBALL=$REPO_ROOT/linux-7.2.tar.xz
readonly DEFAULT_WORK=/var/lib/x1407qa-kernel-7.2

TARBALL=${1:-$DEFAULT_TARBALL}
WORK_ROOT=${2:-$DEFAULT_WORK}
ARTIFACT_ROOT=${3:-$WORK_ROOT/artifacts}
SOURCE_ROOT=$WORK_ROOT/linux-7.2
BUILD_ROOT=$WORK_ROOT/build
STAGING_ROOT=$WORK_ROOT/staging
SOURCE_PATCH=${X1407QA_SOURCE_PATCH:-}

[[ $(uname -m) == aarch64 ]] || { echo 'ERROR: native aarch64 builder required' >&2; exit 1; }
[[ -r $TARBALL ]] || { echo "ERROR: missing $TARBALL" >&2; exit 1; }
echo "$EXPECTED_SHA256  $TARBALL" | sha256sum --check --status || {
    echo 'ERROR: Linux 7.2 source checksum mismatch' >&2; exit 1;
}

mkdir -p "$WORK_ROOT"
rm -rf -- "$SOURCE_ROOT" "$BUILD_ROOT" "$STAGING_ROOT" "$ARTIFACT_ROOT"
tar -xJf "$TARBALL" -C "$WORK_ROOT"
mkdir -p "$BUILD_ROOT" "$STAGING_ROOT" "$ARTIFACT_ROOT"

if [[ -n $SOURCE_PATCH ]]; then
    [[ -f $SOURCE_PATCH && ! -L $SOURCE_PATCH ]] || {
        echo "ERROR: source patch missing or unsafe: $SOURCE_PATCH" >&2
        exit 1
    }
    patch --batch --forward --fuzz=0 --dry-run -d "$SOURCE_ROOT" -p1 < "$SOURCE_PATCH" >/dev/null || {
        echo "ERROR: source patch does not apply cleanly: $SOURCE_PATCH" >&2
        exit 1
    }
    patch --batch --forward --fuzz=0 -d "$SOURCE_ROOT" -p1 < "$SOURCE_PATCH" >/dev/null
fi

make -C "$SOURCE_ROOT" O="$BUILD_ROOT" ARCH=arm64 defconfig
config="$SOURCE_ROOT/scripts/config --file $BUILD_ROOT/.config"
for option in \
    CONFIG_ARCH_QCOM CONFIG_ARM64 CONFIG_ACPI CONFIG_EFI CONFIG_DRM_MSM \
    CONFIG_QCOM_Q6V5_PAS CONFIG_QCOM_RPROC_COMMON CONFIG_QCOM_SYSMON \
    CONFIG_QCOM_PMIC_GLINK CONFIG_BATTERY_QCOM_BATTMGR CONFIG_QCOM_SPMI_ADC_TM5 \
    CONFIG_QCOM_CLK_RPMH CONFIG_QCOM_COMMAND_DB CONFIG_QCOM_RPMH \
    CONFIG_QCOM_SCM CONFIG_QCOM_SMEM CONFIG_QCOM_AOSS_QMP \
    CONFIG_ISO9660_FS CONFIG_JOLIET CONFIG_EROFS_FS CONFIG_EROFS_FS_ZIP \
    CONFIG_DM_SNAPSHOT \
    CONFIG_PHY_QCOM_QMP_COMBO CONFIG_USB_DWC3_QCOM CONFIG_TYPEC_UCSI \
    CONFIG_UCSI_PMIC_GLINK CONFIG_ATH11K CONFIG_ATH11K_PCI \
    CONFIG_BT_HCIUART CONFIG_BT_HCIUART_QCA CONFIG_SND_SOC_QCOM \
    CONFIG_SND_SOC_X1E80100 CONFIG_I2C_QCOM_CCI CONFIG_VIDEO_QCOM_CAMSS \
    CONFIG_VIDEO_OV02C10 CONFIG_ARM_SCMI_PROTOCOL CONFIG_ARM_SCMI_CPUFREQ \
    CONFIG_QCOM_FASTRPC CONFIG_QCOM_PD_MAPPER; do
    $config --enable "${option#CONFIG_}" 2>/dev/null || true
done
make -C "$SOURCE_ROOT" O="$BUILD_ROOT" ARCH=arm64 olddefconfig
for required_config in \
    CONFIG_ISO9660_FS=y CONFIG_JOLIET=y CONFIG_EROFS_FS=y \
    CONFIG_EROFS_FS_ZIP=y CONFIG_DM_SNAPSHOT=m; do
    grep -qxF "$required_config" "$BUILD_ROOT/.config" || {
        echo "ERROR: kernel config missing $required_config" >&2
        exit 1
    }
done

make -C "$SOURCE_ROOT" O="$BUILD_ROOT" ARCH=arm64 \
    LOCALVERSION="$LOCALVERSION" -j"$(nproc)" Image dtbs modules
make -C "$SOURCE_ROOT" O="$BUILD_ROOT" ARCH=arm64 \
    LOCALVERSION="$LOCALVERSION" INSTALL_MOD_PATH="$STAGING_ROOT" modules_install

mkdir -p "$ARTIFACT_ROOT/boot/dtb/qcom" "$ARTIFACT_ROOT/lib"
install -m 0644 "$BUILD_ROOT/arch/arm64/boot/Image" "$ARTIFACT_ROOT/boot/vmlinuz-$VERSION"
rsync -a "$STAGING_ROOT/lib/modules/" "$ARTIFACT_ROOT/lib/modules/"
install -m 0644 "$REPO_ROOT/x1p42100-asus-zenbook-a14-wifi-fix.dtb" \
    "$ARTIFACT_ROOT/boot/dtb/qcom/x1p42100-asus-zenbook-a14.dtb"
cp "$BUILD_ROOT/.config" "$ARTIFACT_ROOT/boot/config-$VERSION"
find "$ARTIFACT_ROOT" -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > "$ARTIFACT_ROOT/SHA256SUMS"

"$REPO_ROOT/kernel/verify-linux-7.2-x1407qa.sh" "$ARTIFACT_ROOT" "$VERSION"
echo "Linux $VERSION artifacts ready at $ARTIFACT_ROOT"
