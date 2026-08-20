#!/usr/bin/env bash
set -euo pipefail

makefile=modules/vivobook-cam-fix-2.0/Makefile

grep -qF 'M=$(CURDIR)' "$makefile" || {
    echo 'camera Makefile does not support invocation through make -C' >&2
    exit 1
}
if grep -qF 'M=$(PWD)' "$makefile"; then
    echo 'camera Makefile still depends on the caller PWD' >&2
    exit 1
fi

echo 'PASS: camera module build path is independent of caller PWD'

color_source=modules/vivobook-color-ctrl-1.0/vivobook_color_ctrl.c
grep -q 'struct drm_atomic_commit \*state' "$color_source" || {
    echo 'color module does not use the Linux 7.2 DRM atomic commit type' >&2
    exit 1
}
for symbol in drm_atomic_commit_alloc drm_atomic_commit_clear drm_atomic_commit_put; do
    grep -q "$symbol" "$color_source" || {
        echo "color module does not use Linux 7.2 API: $symbol" >&2
        exit 1
    }
done
