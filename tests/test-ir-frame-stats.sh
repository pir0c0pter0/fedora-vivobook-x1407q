#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

python3 - "$work_dir/frame.raw" <<'PY'
import sys

values = [0, 256, 512, 1023]
packed = bytes([
    *(value >> 2 for value in values),
    sum((value & 3) << (2 * index) for index, value in enumerate(values)),
])
open(sys.argv[1], "wb").write(packed + bytes(64 - len(packed)))
PY

stats=$(python3 "$repo_root/tools/ir-frame-stats.py" \
	"$work_dir/frame.raw" 4 1)

[[ $stats == 'IR_STATS min=0 max=255 mean=111.75 p50=64 p95=255 p99=255' ]] || {
	echo "unexpected Y10P statistics: $stats" >&2
	exit 1
}

if python3 "$repo_root/tools/ir-frame-stats.py" "$work_dir/frame.raw" 3 1 \
	>/dev/null 2>&1; then
	echo 'Y10P statistics accepted a width not divisible by four' >&2
	exit 1
fi

cp "$work_dir/frame.raw" "$work_dir/partial.raw"
printf '\0' >> "$work_dir/partial.raw"
if python3 "$repo_root/tools/ir-frame-stats.py" "$work_dir/partial.raw" 4 1 \
	>/dev/null 2>&1; then
	echo 'Y10P statistics accepted a partial trailing frame' >&2
	exit 1
fi

echo 'PASS: Y10P frame statistics are exact on a hand-checked fixture'
