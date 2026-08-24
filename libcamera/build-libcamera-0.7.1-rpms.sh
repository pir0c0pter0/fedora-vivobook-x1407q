#!/usr/bin/env bash
set -euo pipefail

readonly VERSION=0.7.1
readonly RELEASE=1.fc44
readonly EXPECTED_SRPM_SHA256=7511fb0023f92f994a07e38f3bb2f9ca4b5d87fa3cdff2a01e1e3f6b9edfbbd6
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly REPO_ROOT
readonly OV02C10_PATCH=$REPO_ROOT/libcamera/libcamera-0.7.1-ov02c10.patch

SRPM=${1:-}
OUTPUT=${2:-$PWD/libcamera-rpms}
OUTPUT=$(realpath -m "$OUTPUT")
work=$(mktemp -d /tmp/x1407qa-libcamera-rpm.XXXXXX)
trap 'rm -rf -- "$work"' EXIT

if [[ -z $SRPM ]]; then
    command -v dnf >/dev/null || { echo 'ERROR: dnf is required to download the Fedora SRPM' >&2; exit 1; }
    mkdir -p "$work/download"
    dnf download --source --destdir "$work/download" "libcamera-$VERSION-$RELEASE"
    SRPM=$(find "$work/download" -maxdepth 1 -type f -name 'libcamera-*.src.rpm' -print -quit)
fi
SRPM=$(realpath "$SRPM")

[[ -f $SRPM && ! -L $SRPM ]] || { echo "ERROR: invalid source RPM: $SRPM" >&2; exit 1; }
[[ -f $OV02C10_PATCH && ! -L $OV02C10_PATCH ]] || { echo 'ERROR: OV02C10 patch is missing' >&2; exit 1; }
echo "$EXPECTED_SRPM_SHA256  $SRPM" | sha256sum --check --status || {
    echo "ERROR: unexpected libcamera $VERSION-$RELEASE source RPM" >&2
    exit 1
}
command -v rpmbuild >/dev/null || {
    echo "ERROR: rpmbuild is missing; install build dependencies with: sudo dnf builddep -y $SRPM" >&2
    exit 1
}

mkdir -p "$work/rpmbuild"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS} "$OUTPUT"
(cd "$work/rpmbuild/SOURCES" && rpm2cpio "$SRPM" | cpio -idm --quiet)
mv "$work/rpmbuild/SOURCES/libcamera.spec" "$work/rpmbuild/SPECS/"
install -m 0644 "$OV02C10_PATCH" "$work/rpmbuild/SOURCES/"
sed -i \
    -e 's/^Release:.*/Release: 1%{?dist}.x1407qa/' \
    -e '/^Patch01:/a Patch02: libcamera-0.7.1-ov02c10.patch' \
    "$work/rpmbuild/SPECS/libcamera.spec"

rpmbuild -ba "$work/rpmbuild/SPECS/libcamera.spec" \
    --define "_topdir $work/rpmbuild" \
    --define "_rpmdir $OUTPUT" \
    --define "_srcrpmdir $OUTPUT"

echo "Patched libcamera RPMs ready at $OUTPUT"
