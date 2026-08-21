#!/usr/bin/env bash
set -euo pipefail

ARTIFACT_ROOT=${1:?usage: write-linux-artifact-manifest.sh ARTIFACT_ROOT}

[[ -d $ARTIFACT_ROOT && ! -L $ARTIFACT_ROOT ]] || {
    echo "ERROR: artifact root is missing or unsafe: $ARTIFACT_ROOT" >&2
    exit 1
}
[[ ! -e $ARTIFACT_ROOT/SHA256SUMS || \
    (-f $ARTIFACT_ROOT/SHA256SUMS && ! -L $ARTIFACT_ROOT/SHA256SUMS) ]] || {
    echo 'ERROR: SHA256SUMS target is not a safe regular file' >&2
    exit 1
}

(
    cd "$ARTIFACT_ROOT"
    find . -type f ! -name SHA256SUMS -print0 |
        sort -z |
        xargs -0 sha256sum > SHA256SUMS
)

echo "PASS: relative artifact manifest written to $ARTIFACT_ROOT/SHA256SUMS"
