#!/bin/bash
# Compila no PC (podman + qemu-user aarch64, imagem fedora:45) um Mesa so com
# freedreno (gallium) + turnip, com a entrada do Adreno X2-45 (chip id
# 0x44060020), para o prefixo /opt/mesa-x2-45. Nao toca no Mesa do sistema.
#
# uso: build-mesa-x2-45.sh [arvore]     (arvore = mesa-26.2.3 (padrao) ou mesa-main)
# saida: <mesa-build>/mesa-x2-45-<versao>-aarch64.tar.xz  (extrair em / no notebook)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(cd "$HERE/../../local/iso-build/mesa-build" && pwd)
TREE=${1:-mesa-26.2.3}
[ -d "$WORK/$TREE" ] || { echo "falta $WORK/$TREE (git clone --depth 1 -b $TREE do mesa + git apply do patch)"; exit 1; }
grep -q 0xffff44060020 "$WORK/$TREE/src/freedreno/common/freedreno_devices.py" ||
	git -C "$WORK/$TREE" apply "$HERE/$TREE-freedreno-add-adreno-x2-45.patch"

exec podman run --rm --arch arm64 --security-opt label=disable \
	-v "$WORK:/work" -e TREE="$TREE" fedora:45 bash -euxc '
dnf -y -q install --setopt=install_weak_deps=False \
	gcc gcc-c++ meson ninja-build pkgconf-pkg-config bison flex glslang tar xz \
	python3-mako python3-pyyaml python3-packaging \
	libdrm-devel expat-devel zlib-ng-compat-devel libzstd-devel systemd-devel \
	elfutils-libelf-devel libglvnd-devel libdisplay-info-devel spirv-tools-devel \
	wayland-devel wayland-protocols-devel \
	libX11-devel libxcb-devel libXext-devel libXfixes-devel libXxf86vm-devel \
	libXrandr-devel libxshmfence-devel xorg-x11-proto-devel xcb-util-keysyms-devel
VER=$(cat /work/$TREE/VERSION)
BUILD=/work/build-$TREE
[ -f $BUILD/build.ninja ] || meson setup $BUILD /work/$TREE \
	--prefix=/opt/mesa-x2-45 --libdir=lib64 --buildtype=release -Db_ndebug=true \
	-Dplatforms=x11,wayland -Dgallium-drivers=freedreno -Dvulkan-drivers=freedreno \
	-Dfreedreno-kmds=msm -Dllvm=disabled -Dglx=dri -Degl=enabled -Dgbm=enabled \
	-Dgles2=enabled -Dglvnd=enabled -Dvideo-codecs= -Dgallium-va=disabled \
	-Dvalgrind=disabled -Dlibunwind=disabled -Dlmsensors=disabled \
	-Dbuild-tests=false -Dtools=
ninja -C $BUILD
rm -rf /work/dest-$TREE
DESTDIR=/work/dest-$TREE ninja -C $BUILD install
strip --strip-unneeded /work/dest-$TREE/opt/mesa-x2-45/lib64/*.so* /work/dest-$TREE/opt/mesa-x2-45/lib64/*/*.so 2>/dev/null || true
tar -C /work/dest-$TREE -cJf /work/mesa-x2-45-$VER-aarch64.tar.xz opt
sha256sum /work/mesa-x2-45-$VER-aarch64.tar.xz
'
