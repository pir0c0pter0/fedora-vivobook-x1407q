#!/usr/bin/env bash
# ir-camera-capture.sh - monta o pipeline do camss para a camera IR (HM1092)
# e captura frames em Y10P, opcionalmente convertendo para PNG.
#
# O camss nao auto-configura o grafo: sem media-ctl o STREAMON falha. E no
# Purwa (x1p42100) so existem IFE0/CSID0 — o IFE1 nao tem GDSC que ligue, entao
# o caminho e obrigatoriamente csiphy0 -> csid0 -> vfe0_rdi0.
#
# Uso: ir-camera-capture.sh [n_frames] [saida.png]

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FRAMES=${1:-5}
PNG=${2:-}
MEDIA=${MEDIA_DEV:-/dev/media0}
W=560
H=360
RAW=$(mktemp /tmp/ir-capture-XXXXXX.raw)
trap 'rm -f "$RAW"' EXIT

need() { command -v "$1" >/dev/null || { echo "falta $1 (dnf install v4l-utils)" >&2; exit 1; }; }
need media-ctl
need v4l2-ctl
need python3

if ! media-ctl -d "$MEDIA" -p >/dev/null 2>&1; then
    echo "sem acesso a $MEDIA — rode como root" >&2
    exit 1
fi

entity_node() {
    media-ctl -d "$MEDIA" -p 2>/dev/null |
        sed -n "/entity .*$1 /,/pad0/p" | awk '/device node name/ {print $NF}'
}

VIDEO=$(entity_node msm_vfe0_video0)
SENSOR=$(entity_node 'hm1092 9-0024')
if [ -z "$VIDEO" ] || [ -z "$SENSOR" ]; then
    echo "camera IR nao esta no grafo (hm1092 nao probou?)" >&2
    exit 1
fi

# A RGB usa o mesmo csid0/rdi0; solta o link dela antes.
media-ctl -d "$MEDIA" -l '"msm_csiphy4":1 -> "msm_csid0":0 [0]' 2>/dev/null || true
media-ctl -d "$MEDIA" -l '"msm_csiphy0":1 -> "msm_csid0":0 [1]'
media-ctl -d "$MEDIA" -l '"msm_csid0":1 -> "msm_vfe0_rdi0":0 [1]'

for pad in "\"hm1092 9-0024\":0" '"msm_csiphy0":0' '"msm_csiphy0":1' \
           '"msm_csid0":0' '"msm_csid0":1' '"msm_vfe0_rdi0":0' '"msm_vfe0_rdi0":1'; do
    media-ctl -d "$MEDIA" -V "$pad [fmt:Y10_1X10/${W}x${H}]"
done

v4l2-ctl -d "$VIDEO" --set-fmt-video=width=$W,height=$H,pixelformat=Y10P >/dev/null
v4l2-ctl -d "$VIDEO" --stream-mmap --stream-count="$FRAMES" --stream-to="$RAW" >/dev/null

BYTES=$(stat -c %s "$RAW")
echo "capturados $BYTES bytes ($((BYTES / (704 * H))) frames de ${W}x${H} Y10P) em $VIDEO"

[ -n "$PNG" ] || { cp "$RAW" "${RAW%.raw}.keep.raw"; echo "raw em ${RAW%.raw}.keep.raw"; exit 0; }

python3 "$SCRIPT_DIR/ir-frame-stats.py" "$RAW" "$W" "$H" "$PNG"
