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

python3 - "$RAW" "$PNG" "$W" "$H" <<'PY'
import struct, sys, zlib

raw_path, png_path, W, H = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
STRIDE = ((W * 10 // 8) + 63) // 64 * 64   # camss alinha a linha em 64 bytes
ROW = W * 10 // 8
data = open(raw_path, "rb").read()
frame = data[-STRIDE * H:]                  # ultimo frame

def unpack(fr):
    """Y10P: 4 pixels em 5 bytes, os 2 LSB de cada um no 5o."""
    out = bytearray(W * H)
    for y in range(H):
        row = fr[y * STRIDE:y * STRIDE + ROW]
        o, x, i = y * W, 0, 0
        while x < W and i + 5 <= len(row):
            b = row[i:i + 5]; i += 5
            for k in range(4):
                if x >= W:
                    break
                out[o + x] = ((b[k] << 2) | ((b[4] >> (2 * k)) & 3)) >> 2
                x += 1
    return out

g = unpack(frame)
lo, hi = min(g), max(g)
# Sem iluminador IR a cena fica em ~10 niveis; sem esticar nao se ve nada.
span = max(1, hi - lo)
g = bytes(min(255, (v - lo) * 255 // span) for v in g)

def chunk(tag, payload):
    c = tag + payload
    return struct.pack(">I", len(payload)) + c + struct.pack(">I", zlib.crc32(c) & 0xffffffff)

scan = b"".join(b"\x00" + bytes(g[y * W:(y + 1) * W]) for y in range(H))
open(png_path, "wb").write(
    b"\x89PNG\r\n\x1a\n"
    + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 0, 0, 0, 0))
    + chunk(b"IDAT", zlib.compress(scan, 9))
    + chunk(b"IEND", b""))
print(f"{png_path}: contraste esticado de [{lo},{hi}] para [0,255]")
PY
