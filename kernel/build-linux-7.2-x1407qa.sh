#!/usr/bin/env bash
set -euo pipefail

readonly VERSION=${X1407QA_KERNEL_VERSION:-7.2.0-x1407qa}
readonly LOCALVERSION=${X1407QA_LOCALVERSION:--x1407qa}
readonly EXPECTED_SHA256=f9fef3d14c0df53819026f4be74459835c2a0b0dcbf5b5bbd9ea19f0829402b3
readonly REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly CONFIG_PREPARER=$REPO_ROOT/kernel/prepare-linux-7.2-x1407qa-config.sh
readonly MANIFEST_WRITER=$REPO_ROOT/kernel/write-linux-artifact-manifest.sh
readonly DEFAULT_TARBALL=$REPO_ROOT/linux-7.2.tar.xz
readonly DEFAULT_WORK=/var/lib/x1407qa-kernel-7.2
readonly REFERENCE_CONFIG=${X1407QA_REFERENCE_CONFIG:-/boot/config-7.2.0-x1407qa}

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

[[ -x $CONFIG_PREPARER ]] || { echo 'ERROR: Linux config preparer missing' >&2; exit 1; }
"$CONFIG_PREPARER" "$SOURCE_ROOT" "$BUILD_ROOT" "$REFERENCE_CONFIG"

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
[[ -x $MANIFEST_WRITER ]] || { echo 'ERROR: artifact manifest writer missing' >&2; exit 1; }
"$MANIFEST_WRITER" "$ARTIFACT_ROOT"

"$REPO_ROOT/kernel/verify-linux-7.2-x1407qa.sh" "$ARTIFACT_ROOT" "$VERSION"
echo "Linux $VERSION artifacts ready at $ARTIFACT_ROOT"
