#!/usr/bin/env bash
set -euo pipefail

readonly VERSION=7.2.0-x1407qa
ARTIFACT_ROOT=${1:?usage: verify-linux-7.2-x1407qa.sh ARTIFACT_ROOT}
IMAGE=$ARTIFACT_ROOT/boot/vmlinuz-$VERSION
MODULE_ROOT=$ARTIFACT_ROOT/lib/modules/$VERSION
DTB=$ARTIFACT_ROOT/boot/dtb/qcom/x1p42100-asus-zenbook-a14.dtb
CONFIG=$ARTIFACT_ROOT/boot/config-$VERSION

[[ -s $IMAGE ]] || { echo 'ERROR: kernel Image missing' >&2; exit 1; }
file "$IMAGE" | grep -Eq 'ARM64|ARM aarch64' || { file "$IMAGE" >&2; exit 1; }
[[ -s $MODULE_ROOT/modules.dep ]] || { echo 'ERROR: modules.dep missing' >&2; exit 1; }
[[ -s $DTB ]] || { echo 'ERROR: x1p42100-asus-zenbook-a14 DTB missing' >&2; exit 1; }
[[ -s $CONFIG ]] || { echo 'ERROR: kernel config missing' >&2; exit 1; }
for required_config in \
    CONFIG_ISO9660_FS=y CONFIG_JOLIET=y CONFIG_EROFS_FS=y \
    CONFIG_EROFS_FS_ZIP=y CONFIG_DM_SNAPSHOT=m; do
    grep -qxF "$required_config" "$CONFIG" || {
        echo "ERROR: kernel config missing $required_config" >&2
        exit 1
    }
done

(cd "$ARTIFACT_ROOT" && sha256sum --check SHA256SUMS)
echo "PASS: Linux $VERSION aarch64 artifacts verified"
