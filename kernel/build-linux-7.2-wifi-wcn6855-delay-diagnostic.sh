#!/usr/bin/env bash
set -euo pipefail

readonly REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly BASE_BUILDER=$REPO_ROOT/kernel/build-linux-7.2-x1407qa.sh
readonly PATCH_FILE=$REPO_ROOT/kernel/linux-7.2-wifi-wcn6855-delay.patch
readonly VERSION=7.2.0-x1407qa-wifi-wcn6855-delay-diag
readonly LOCALVERSION=-x1407qa-wifi-wcn6855-delay-diag
readonly MARKER='X1407QA Wi-Fi diagnostic: WCN6855 stabilization delay 6000 ms'

TARBALL=${1:-/var/lib/x1407qa-kernel-7.2/linux-7.2.tar.xz}
WORK_ROOT=${2:-/var/lib/x1407qa-kernel-7.2-wifi-wcn6855-delay-diag}
ARTIFACT_ROOT=${3:-$WORK_ROOT/artifacts}

[[ -x $BASE_BUILDER ]] || { echo 'ERROR: base Linux 7.2 builder missing' >&2; exit 1; }
[[ -f $PATCH_FILE && ! -L $PATCH_FILE ]] || { echo 'ERROR: WCN6855 delay patch missing or unsafe' >&2; exit 1; }

export X1407QA_KERNEL_VERSION=$VERSION
export X1407QA_LOCALVERSION=$LOCALVERSION
export X1407QA_SOURCE_PATCH=$PATCH_FILE

"$BASE_BUILDER" "$TARBALL" "$WORK_ROOT" "$ARTIFACT_ROOT"

WCN_PWRSEQ_MODULE=$ARTIFACT_ROOT/lib/modules/$VERSION/kernel/drivers/power/sequencing/pwrseq-qcom-wcn.ko
[[ -f $WCN_PWRSEQ_MODULE && ! -L $WCN_PWRSEQ_MODULE ]] || {
    echo 'ERROR: built WCN pwrseq module missing or unsafe' >&2
    exit 1
}
grep -aFq "$MARKER" "$WCN_PWRSEQ_MODULE" || {
    echo 'ERROR: built WCN pwrseq module lacks the delay diagnostic marker' >&2
    exit 1
}

echo "PASS: Linux $VERSION contains the WCN6855 delay diagnostic"
