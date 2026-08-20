#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

if [[ $EUID -ne 0 ]]; then
    sudo -n env REPO_ROOT="$root" bash "$root/tests/test-dkms-namespace-preflight.sh"
    exit $?
fi

export VIVOBOOK_SETUP_LIBRARY_ONLY=1
# shellcheck source=../setup-vivobook.sh
source "$root/setup-vivobook.sh"

preflight_dkms_namespace
run_dkms_without_runtime_hooks bash -c '
    set -euo pipefail
    source /etc/dkms/framework.conf
    [[ -z $post_transaction ]]
    [[ -z $modprobe_on_install ]]
    [[ $(find /etc/dkms -mindepth 1 -maxdepth 1 -printf "%f\n") == framework.conf ]]
'
if find /run -maxdepth 1 -name 'vivobook-dkms.*' -print -quit | grep -q .; then
    echo 'private DKMS preflight leaked its host-side temporary directory' >&2
    exit 1
fi

echo 'PASS: private DKMS namespace hides the complete host configuration'
