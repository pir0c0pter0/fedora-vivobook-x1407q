#!/usr/bin/env bash
set -euo pipefail

arch="$(uname -m)"
if [[ "$arch" != aarch64 && "$arch" != arm64 ]]; then
    echo "refusing: ARM64/aarch64 build host required, got $arch" >&2
    exit 1
fi

sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    bc bison build-essential cpio curl device-tree-compiler dosfstools \
    dracut-core e2fsprogs file flex gcc git gnupg kmod libelf-dev \
    libssl-dev make openssl pahole python3 rsync squashfs-tools tar \
    erofs-utils util-linux wget xorriso xz-utils zstd

required=(xorriso unsquashfs mksquashfs fsck.erofs mkfs.erofs dracut gcc bc bison flex openssl rsync cpio git dtc)
for command_name in "${required[@]}"; do
    command -v "$command_name" >/dev/null || {
        echo "missing required command after bootstrap: $command_name" >&2
        exit 1
    }
done

BUILD_ROOT=${BUILD_ROOT:-/mnt/c/LinuxBuild}
mkdir -p "$BUILD_ROOT/.state"
printf '%s\n' "$(date -Is)" > "$BUILD_ROOT/.state/build-env-ready"
echo 'ARM64 ISO/kernel build environment ready'
