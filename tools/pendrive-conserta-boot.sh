#!/usr/bin/env bash
# X1407QA — roda o reparo de boot do sistema instalado e copia o relatório
# completo de volta para o pendrive onde este script está.
# Uso (no live, com este pendrive plugado): sudo bash CONSERTAR.sh
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
[[ $EUID -eq 0 ]] || { echo 'rode com sudo: sudo bash CONSERTAR.sh' >&2; exit 1; }

STAMP=$(date +%Y%m%d-%H%M%S)
OUT=$HERE/relatorio-$STAMP
mkdir -p "$OUT"

# tudo que aparecer na tela também fica gravado no pendrive
bash "$HERE/rescue-installed-boot.sh" --repair 2>&1 | tee "$OUT/terminal.txt"
rc=${PIPESTATUS[0]}
echo "exit code do reparo: $rc" | tee -a "$OUT/terminal.txt"

cp -r /run/x1407qa-rescue/report/. "$OUT/" 2>/dev/null \
    || echo 'AVISO: relatório interno não encontrado em /run/x1407qa-rescue/report' | tee -a "$OUT/terminal.txt"

# retrato final do /boot real depois do reparo, para conferência offline
mkdir -p /run/x1407qa-postcheck
if mount -o ro /dev/nvme0n1p2 /run/x1407qa-postcheck 2>/dev/null; then
    ls -laR /run/x1407qa-postcheck/loader /run/x1407qa-postcheck/grub2 \
        > "$OUT/boot-final.txt" 2>&1
    ls -la /run/x1407qa-postcheck/ /run/x1407qa-postcheck/dtb-x1407qa/qcom \
        >> "$OUT/boot-final.txt" 2>&1
    mkdir -p "$OUT/entries-final"
    cp /run/x1407qa-postcheck/loader/entries/*.conf "$OUT/entries-final/" 2>/dev/null
    cp /run/x1407qa-postcheck/grub2/custom.cfg "$OUT/custom.cfg.final" 2>/dev/null
    grub2-editenv /run/x1407qa-postcheck/grub2/grubenv list \
        > "$OUT/grubenv-final.txt" 2>&1 || :
    umount /run/x1407qa-postcheck
else
    echo 'AVISO: não consegui montar /dev/nvme0n1p2 para o retrato final' | tee -a "$OUT/terminal.txt"
fi

sync
echo
echo "PRONTO. Relatório completo em: $OUT"
echo 'Ejete o pendrive (ícone no Files) e reinicie: systemctl reboot'
