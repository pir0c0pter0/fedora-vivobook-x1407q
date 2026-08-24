#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
linux_source=${X1407QA_LINUX_SOURCE:?set X1407QA_LINUX_SOURCE to a Linux 7.2 source tree}
libcamera_source=${X1407QA_LIBCAMERA_SOURCE:?set X1407QA_LIBCAMERA_SOURCE to a libcamera 0.7.1 source tree}
linux_patch=$repo_root/kernel/linux-7.2-camera-warning-fix.patch
libcamera_patch=$repo_root/libcamera/libcamera-0.7.1-ov02c10.patch
work=$(mktemp -d /tmp/x1407qa-camera-warning-test.XXXXXX)
trap 'rm -rf -- "$work"' EXIT

[[ -f $linux_patch ]] || { echo "missing kernel camera warning patch" >&2; exit 1; }
[[ -f $libcamera_patch ]] || { echo "missing libcamera OV02C10 patch" >&2; exit 1; }

for file in \
    drivers/media/platform/qcom/camss/camss-csid.c \
    drivers/media/i2c/ov02c10.c; do
    install -D -m 0644 "$linux_source/$file" "$work/linux/$file"
done
for file in \
    src/libcamera/sensor/camera_sensor_properties.cpp \
    src/ipa/libipa/camera_sensor_helper.cpp; do
    install -D -m 0644 "$libcamera_source/$file" "$work/libcamera/$file"
done

git -C "$work/linux" apply --check "$linux_patch"
git -C "$work/linux" apply "$linux_patch"
git -C "$work/linux" apply --reverse --check "$linux_patch"
git -C "$work/libcamera" apply --check "$libcamera_patch"
git -C "$work/libcamera" apply "$libcamera_patch"
git -C "$work/libcamera" apply --reverse --check "$libcamera_patch"

echo "PASS: camera warning patches apply cleanly to Linux 7.2 and libcamera 0.7.1"
