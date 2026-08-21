#!/usr/bin/env bash
set -euo pipefail

readonly REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly BASE_BUILDER=$REPO_ROOT/kernel/build-linux-7.2-x1407qa.sh
readonly PATCH_FILE=$REPO_ROOT/kernel/linux-7.2-wifi-pwrctrl-order.patch
readonly VERSION=7.2.0-x1407qa-wifi-pwrctrl-diag
readonly LOCALVERSION=-x1407qa-wifi-pwrctrl-diag

TARBALL=${1:-/var/lib/x1407qa-kernel-7.2/linux-7.2.tar.xz}
WORK_ROOT=${2:-/var/lib/x1407qa-kernel-7.2-wifi-pwrctrl-diag}
ARTIFACT_ROOT=${3:-$WORK_ROOT/artifacts}

[[ -x $BASE_BUILDER ]] || { echo 'ERROR: base Linux 7.2 builder missing' >&2; exit 1; }
[[ -f $PATCH_FILE && ! -L $PATCH_FILE ]] || { echo 'ERROR: diagnostic patch missing or unsafe' >&2; exit 1; }

export X1407QA_KERNEL_VERSION=$VERSION
export X1407QA_LOCALVERSION=$LOCALVERSION
export X1407QA_SOURCE_PATCH=$PATCH_FILE

exec "$BASE_BUILDER" "$TARBALL" "$WORK_ROOT" "$ARTIFACT_ROOT"
