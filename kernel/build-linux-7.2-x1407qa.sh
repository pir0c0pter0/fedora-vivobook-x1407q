#!/usr/bin/env bash
set -euo pipefail

readonly VERSION=${X1407QA_KERNEL_VERSION:-7.2.0-x1407qa}
readonly LOCALVERSION=${X1407QA_LOCALVERSION:--x1407qa}
readonly EXPECTED_SHA256=f9fef3d14c0df53819026f4be74459835c2a0b0dcbf5b5bbd9ea19f0829402b3
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly REPO_ROOT
readonly CONFIG_PREPARER=$REPO_ROOT/kernel/prepare-linux-7.2-x1407qa-config.sh
readonly MANIFEST_WRITER=$REPO_ROOT/kernel/write-linux-artifact-manifest.sh
readonly DEFAULT_TARBALL=$REPO_ROOT/linux-7.2.tar.xz
readonly DEFAULT_WORK=/var/lib/x1407qa-kernel-7.2
readonly REFERENCE_CONFIG=${X1407QA_REFERENCE_CONFIG:-/boot/config-7.2.0-x1407qa}

TARBALL=${1:-$DEFAULT_TARBALL}
WORK_ROOT=${2:-$DEFAULT_WORK}
ARTIFACT_ROOT=${3:-$WORK_ROOT/artifacts}
TARBALL=$(realpath -m "$TARBALL")
WORK_ROOT=$(realpath -m "$WORK_ROOT")
ARTIFACT_ROOT=$(realpath -m "$ARTIFACT_ROOT")
case "$WORK_ROOT" in
    /|/var|/var/lib|/var/tmp|/tmp|/work|"$REPO_ROOT"|"$REPO_ROOT"/*)
        echo "ERROR: unsafe work root: $WORK_ROOT" >&2
        exit 1
        ;;
esac
[[ $(basename "$WORK_ROOT") == x1407qa-* ]] || {
    echo "ERROR: work root must use an x1407qa-* directory: $WORK_ROOT" >&2
    exit 1
}
case "$ARTIFACT_ROOT" in
    "$WORK_ROOT"/*) ;;
    *) echo "ERROR: artifact root must be inside work root: $ARTIFACT_ROOT" >&2; exit 1 ;;
esac
case "$TARBALL" in
    "$WORK_ROOT"|"$WORK_ROOT"/*)
        echo "ERROR: source tarball must be outside work root: $TARBALL" >&2
        exit 1
        ;;
esac
SOURCE_ROOT=$WORK_ROOT/linux-7.2
BUILD_ROOT=$WORK_ROOT/build
STAGING_ROOT=$WORK_ROOT/staging
SOURCE_PATCH=${X1407QA_SOURCE_PATCH:-}

make_arch=(ARCH=arm64)
if [[ $(uname -m) != aarch64 ]]; then
    CROSS_COMPILE=${CROSS_COMPILE:-aarch64-linux-gnu-}
    command -v "${CROSS_COMPILE}gcc" >/dev/null || {
        echo "ERROR: AArch64 cross compiler missing: ${CROSS_COMPILE}gcc" >&2
        exit 1
    }
    make_arch+=(CROSS_COMPILE="$CROSS_COMPILE")
fi
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
# firmware de topologia de audio (tplg X1E80100) so existe como .xz no linux-firmware
"$SOURCE_ROOT/scripts/config" --file "$BUILD_ROOT/.config" \
    --enable FW_LOADER_COMPRESS --enable FW_LOADER_COMPRESS_XZ
make -C "$SOURCE_ROOT" O="$BUILD_ROOT" "${make_arch[@]}" olddefconfig

make -C "$SOURCE_ROOT" O="$BUILD_ROOT" "${make_arch[@]}" \
    LOCALVERSION="$LOCALVERSION" -j"$(nproc)" Image dtbs modules
make -C "$SOURCE_ROOT" O="$BUILD_ROOT" "${make_arch[@]}" \
    LOCALVERSION="$LOCALVERSION" INSTALL_MOD_PATH="$STAGING_ROOT" modules_install

for module_dir in \
    wcn-regulator-fix-1.0 \
    vivobook-hotkey-fix-1.0 \
    vivobook-kbd-fix-1.0 \
    vivobook-bl-fix-1.0; do
    module_path="$REPO_ROOT/modules/$module_dir"
    [[ -d $module_path ]] || { echo "ERROR: core module source missing: $module_path" >&2; exit 1; }
    make -C "$SOURCE_ROOT" O="$BUILD_ROOT" "${make_arch[@]}" \
        LOCALVERSION=-x1407qa M="$module_path" clean
    make -C "$SOURCE_ROOT" O="$BUILD_ROOT" "${make_arch[@]}" \
        LOCALVERSION=-x1407qa M="$module_path" modules
    make -C "$SOURCE_ROOT" O="$BUILD_ROOT" "${make_arch[@]}" \
        LOCALVERSION=-x1407qa M="$module_path" INSTALL_MOD_PATH="$STAGING_ROOT" \
        INSTALL_MOD_DIR=extra modules_install
done
depmod -b "$STAGING_ROOT" "$VERSION"

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
