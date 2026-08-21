#!/usr/bin/env bash
set -euo pipefail

readonly REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly PATCH_FILE=$REPO_ROOT/kernel/linux-7.2-wifi-pwrctrl-order.patch
SOURCE_ROOT=${1:?usage: apply-linux-7.2-wifi-pwrctrl-diagnostic.sh SOURCE_ROOT}
TARGET=$SOURCE_ROOT/drivers/pci/controller/dwc/pcie-qcom.c

[[ -d $SOURCE_ROOT && ! -L $SOURCE_ROOT ]] || {
    echo "ERROR: unsafe or missing Linux source root: $SOURCE_ROOT" >&2
    exit 1
}
[[ -f $SOURCE_ROOT/Makefile && ! -L $SOURCE_ROOT/Makefile ]] || {
    echo 'ERROR: Linux source Makefile missing or unsafe' >&2
    exit 1
}
[[ -f $TARGET && ! -L $TARGET ]] || {
    echo 'ERROR: Linux 7.2 Qualcomm PCIe source missing or unsafe' >&2
    exit 1
}
[[ -f $PATCH_FILE && ! -L $PATCH_FILE ]] || {
    echo 'ERROR: diagnostic patch missing or unsafe' >&2
    exit 1
}

version=$(awk '$1 == "VERSION" && $2 == "=" { print $3; exit }' "$SOURCE_ROOT/Makefile")
patchlevel=$(awk '$1 == "PATCHLEVEL" && $2 == "=" { print $3; exit }' "$SOURCE_ROOT/Makefile")
sublevel=$(awk '$1 == "SUBLEVEL" && $2 == "=" { print $3; exit }' "$SOURCE_ROOT/Makefile")
[[ $version == 7 && $patchlevel == 2 && $sublevel == 0 ]] || {
    echo 'ERROR: diagnostic patch requires pristine Linux 7.2.0 sources' >&2
    exit 1
}

patch --batch --forward --fuzz=0 --dry-run -d "$SOURCE_ROOT" -p1 < "$PATCH_FILE" >/dev/null || {
    echo 'ERROR: diagnostic patch does not apply cleanly to this Linux 7.2 tree' >&2
    exit 1
}
patch --batch --forward --fuzz=0 -d "$SOURCE_ROOT" -p1 < "$PATCH_FILE" >/dev/null

perst_line=$(grep -nF $'\tqcom_pcie_perst_deassert(pcie);' "$TARGET" | cut -d: -f1)
marker_line=$(grep -nF 'X1407QA Wi-Fi diagnostic: PERST# deasserted before WCN power-on' "$TARGET" | cut -d: -f1)
power_line=$(grep -nF $'\t\tret = pci_pwrctrl_power_on_devices(pci->dev);' "$TARGET" | cut -d: -f1)
[[ -n $perst_line && -n $marker_line && -n $power_line ]] || {
    echo 'ERROR: patched ordering markers are incomplete' >&2
    exit 1
}
[[ $perst_line -lt $power_line && $power_line -lt $marker_line ]] || {
    echo 'ERROR: diagnostic patch did not establish PERST-before-WCN-power ordering' >&2
    exit 1
}

echo 'PASS: Linux 7.2 diagnostic patch applied (PERST# before WCN power-on)'
