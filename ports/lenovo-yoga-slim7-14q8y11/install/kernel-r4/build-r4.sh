#!/bin/bash
# Kernel R4 do Yoga Slim 7 14Q8Y11 = arvore do R3 (qcom for-next 6a876df + v7.4-rc3 + patches 0001/0002)
# + 0003 (PLL do PHY eDP v8) + r4.config. /work/kernel-r4 e um clone local de /work/kernel-rc3.
# Roda DENTRO do container yoga-iso-build:  podman exec yoga-iso-build bash /work/kernel-out-r4/build-r4.sh [fase]
#   fases: config | build | install | all (padrao)
# Fonte: /work/kernel-r4 (git, ramo yoga-r4). Saida: /work/kernel-out-r4/{build,modroot,dist}.
# Base do .config: o final do R3 (/work/kernel-out-r3/build/.config) + r4.config.
set -euo pipefail
R=/work/kernel-out-r4; SRC=/work/kernel-r4; O=$R/build; HERE=$(dirname "$(readlink -f "$0")")
J=${J:-16}
mk() { make -C "$SRC" LLVM=1 ARCH=arm64 O="$O" "$@"; }

do_config() {
    mkdir -p "$O"
    BASE=/work/kernel-out-r3/build/.config; [ -s "$BASE" ] || { echo "falta $BASE"; exit 1; }
    echo "base do .config: $BASE ($(sha256sum <"$BASE" | cut -d' ' -f1))" | tee "$R/config-merge.log"
    cp "$BASE" "$O/.config"; cp "$BASE" "$R/config-base"
    (cd "$O" && "$SRC/scripts/kconfig/merge_config.sh" -m -O "$O" "$O/.config" "$HERE/r4.config") >>"$R/config-merge.log" 2>&1
    # Opcoes que a arvore nova tem e a base nao define (antes de o olddefconfig escolher o padrao).
    mk -s listnewconfig >"$R/config-new-options.txt" 2>>"$R/config-merge.log" || true
    mk olddefconfig >>"$R/config-merge.log" 2>&1
    bad=0
    while IFS= read -r l; do
        grep -qxF "$l" "$O/.config" || { echo "NAO APLICADO: $l (ficou: $(grep -E "^(# )?${l%%=*}[= ]" "$O/.config" || echo ausente))"; bad=1; }
    done < <(grep -E '^CONFIG_' "$HERE/r4.config")
    "$SRC/scripts/diffconfig" /work/kernel-out/.config "$O/.config" >"$R/config-r1-vs-r4.diffconfig" || true
    "$SRC/scripts/diffconfig" "$BASE" "$O/.config" >"$R/config-base-vs-r4.diffconfig" || true
    [ $bad = 0 ] || { echo "config: ha simbolos nao aplicados"; exit 1; }
    echo "config OK: $(mk -s kernelrelease)"
}

do_build() { mk -j"$J" Image modules dtbs; }

do_install() {
    rm -rf "$R/modroot" "$R/dist"; mkdir -p "$R/dist"
    # INSTALL_MOD_STRIP=1 = strip --strip-debug (igual ao R1/R2).
    mk INSTALL_MOD_PATH="$R/modroot" INSTALL_MOD_STRIP=1 -j"$J" modules_install
    KV=$(cat "$O/include/config/kernel.release")
    rm -f "$R/modroot/lib/modules/$KV/build" "$R/modroot/lib/modules/$KV/source"
    cp "$O/arch/arm64/boot/Image" "$R/dist/vmlinuz-$KV"
    cp "$O/System.map" "$R/dist/System.map-$KV"
    cp "$O/.config" "$R/dist/config-$KV"
    cp "$R"/config-*.diffconfig "$R/config-new-options.txt" "$R/dist/"
    (cd "$R/modroot/lib/modules/$KV" && find kernel -name '*.ko' | sort) >"$R/dist/modules-$KV.list"
    tar -C "$R/modroot/lib/modules" -cf "$R/dist/modules-$KV.tar" "$KV"
    echo "$KV" >"$R/dist/KVER"
    (cd "$R/dist" && sha256sum -- * >SHA256SUMS)
    echo "install OK: $KV, $(wc -l <"$R/dist/modules-$KV.list") modulos"
}

case ${1:-all} in
    config) do_config ;;
    build) do_build ;;
    install) do_install ;;
    all) do_config; do_build; do_install ;;
    *) echo "uso: $0 [config|build|install|all]"; exit 2 ;;
esac
