#!/bin/bash
# Kernel R2 do Yoga Slim 7 14Q8Y11. Roda DENTRO do container yoga-iso-build:
#   podman start yoga-iso-build
#   podman exec yoga-iso-build bash /work/../<este arquivo>   (ou copie para /work/kernel-out-r2/)
#   fases: config | build | install | all (padrao)
# Fonte: /work/kernel-out-r2/src = `git archive 6a876df46` de /work/kernel + patches 0001/0002
# (a arvore /work/kernel e /work/kernel-out NAO sao tocadas). Saida: /work/kernel-out-r2/{build,modroot,dist}.
set -euo pipefail
R=/work/kernel-out-r2; SRC=$R/src; O=$R/build; HERE=$(dirname "$(readlink -f "$0")")
J=${J:-16}
mk() { make -C "$SRC" LLVM=1 ARCH=arm64 O="$O" "$@"; }

do_config() {
    mkdir -p "$O"
    cp /work/kernel-out/.config "$O/.config"
    # merge_config.sh -m: so aplica o fragmento; olddefconfig resolve dependencias.
    (cd "$O" && "$SRC/scripts/kconfig/merge_config.sh" -m -O "$O" "$O/.config" "$HERE/r2.config") >"$R/config-merge.log" 2>&1
    mk olddefconfig >>"$R/config-merge.log" 2>&1
    # Auto-verificacao: todo simbolo pedido tem de sair com o valor pedido.
    bad=0
    while IFS= read -r l; do
        grep -qxF "$l" "$O/.config" || { echo "NAO APLICADO: $l (ficou: $(grep -E "^(# )?${l%%=*}[= ]" "$O/.config" || echo ausente))"; bad=1; }
    done < <(grep -E '^CONFIG_' "$HERE/r2.config")
    "$SRC/scripts/diffconfig" /work/kernel-out/.config "$O/.config" >"$R/config-r1-vs-r2.diffconfig" || true
    [ $bad = 0 ] || { echo "config: ha simbolos nao aplicados"; exit 1; }
    echo "config OK: $(mk -s kernelrelease)"
}

do_build() { mk -j"$J" Image modules; }

do_install() {
    rm -rf "$R/modroot" "$R/dist"; mkdir -p "$R/dist"
    # INSTALL_MOD_STRIP=1 = strip --strip-debug (igual ao R1): tira so DWARF, vermagic/modinfo ficam.
    mk INSTALL_MOD_PATH="$R/modroot" INSTALL_MOD_STRIP=1 -j"$J" modules_install
    KV=$(cat "$O/include/config/kernel.release")
    rm -f "$R/modroot/lib/modules/$KV/build" "$R/modroot/lib/modules/$KV/source"
    cp "$O/arch/arm64/boot/Image" "$R/dist/vmlinuz-$KV"
    cp "$O/System.map" "$R/dist/System.map-$KV"
    cp "$O/.config" "$R/dist/config-$KV"
    cp "$R/config-r1-vs-r2.diffconfig" "$R/dist/"
    (cd "$R/modroot/lib/modules/$KV" && find kernel -name '*.ko' | sort) >"$R/dist/modules-$KV.list"
    tar -C "$R/modroot/lib/modules" -cf "$R/dist/modules-$KV.tar" "$KV"
    (cd "$R/dist" && sha256sum -- * >SHA256SUMS)
    echo "$KV" >"$R/dist/KVER"
    echo "install OK: $KV, $(wc -l <"$R/dist/modules-$KV.list") modulos"
}

case ${1:-all} in
    config) do_config ;;
    build) do_build ;;
    install) do_install ;;
    all) do_config; do_build; do_install ;;
    *) echo "uso: $0 [config|build|install|all]"; exit 2 ;;
esac
