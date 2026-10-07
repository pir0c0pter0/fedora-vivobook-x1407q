#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source_tree=${LINUX73_SOURCE:-${HOME}/build/x1407qa-linux-7.3-rc6/source}
build_tree=${LINUX73_BUILD:-${HOME}/build/x1407qa-linux-7.3-rc6/build}
patch_file="$root/kernel/linux-7.3-x1407qa-runtime-fixes.patch"
camera_patch="$root/kernel/linux-7.2-camera-warning-fix.patch"
apply_script="$root/kernel/apply-linux-7.3-x1407qa-runtime-fixes.sh"
expected_commit=a90ee4305c4a5df72c11b31dacfdc76e00fcf78a

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

[[ -s $patch_file ]] || fail "Linux 7.3 runtime patch is missing"
[[ -x $apply_script ]] || fail "Linux 7.3 runtime patch helper is missing or not executable"
[[ -d $source_tree/.git ]] || fail "kernel source tree unavailable: $source_tree"
[[ -f $build_tree/.config ]] || fail "kernel build config unavailable: $build_tree/.config"
[[ $(git -C "$source_tree" rev-parse HEAD) == "$expected_commit" ]] ||
    fail "kernel source is not pinned to the validated v7.3-rc6 commit"

if git -C "$source_tree" apply --unidiff-zero --reverse --check "$patch_file" 2>/dev/null; then
    : # The live build tree is already patched.
else
    git -C "$source_tree" apply --unidiff-zero --check "$patch_file" ||
        fail "runtime patch does not apply cleanly to Linux 7.3-rc6"
fi

if git -C "$source_tree" apply --reverse --check "$camera_patch" 2>/dev/null; then
    : # The validated tree already contains the camera fixes.
else
    git -C "$source_tree" apply --check "$camera_patch" ||
        fail "camera patch does not apply cleanly to Linux 7.3-rc6"
fi

grep -q '"OOD"' "$patch_file" || fail "battery firmware chemistry OOD is not covered"
grep -q 'SNDRV_CTL_ELEM_ACCESS_VOLATILE' "$patch_file" ||
    fail "headphone detection controls are not made read-only and volatile"
grep -q -- '-m BT_RFCOMM' "$apply_script" || fail "RFCOMM is not enabled as a module"
grep -q -- '-e SECURITY_LANDLOCK' "$apply_script" ||
    fail "Landlock is not enabled despite being listed in CONFIG_LSM"
grep -q "$expected_commit" "$apply_script" ||
    fail "kernel helper does not enforce the validated upstream commit"
grep -q 'linux-7.2-camera-warning-fix.patch' "$apply_script" ||
    fail "kernel helper omits the camera fixes present in the validated build"

required_config=(
    'CONFIG_LOCALVERSION="-x1407qa-perf"'
    '# CONFIG_LOCALVERSION_AUTO is not set'
    'CONFIG_PREEMPT=y'
    'CONFIG_HZ_250=y'
    'CONFIG_HZ=250'
    'CONFIG_CPU_FREQ_DEFAULT_GOV_SCHEDUTIL=y'
    'CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE=y'
    'CONFIG_ARM64_4K_PAGES=y'
    'CONFIG_LTO_NONE=y'
    'CONFIG_BT_RFCOMM=m'
    'CONFIG_SECURITY_LANDLOCK=y'
    'CONFIG_SECURITY_LANDLOCK_LOG=y'
    'CONFIG_LSM="landlock,lockdown,yama,loadpin,safesetid,ipe,bpf"'
)
for option in "${required_config[@]}"; do
    grep -qxF "$option" "$build_tree/.config" ||
        fail "validated kernel config is missing: $option"
done

# Prove that the helper repairs a divergent base config rather than merely
# accepting whatever local-version and active-LSM policy it inherited.
cp "$build_tree/.config" "$tmp/.config"
"$source_tree/scripts/config" --file "$tmp/.config" -e LOCALVERSION_AUTO
"$source_tree/scripts/config" --file "$tmp/.config" \
    --set-str LSM 'lockdown,yama,loadpin,safesetid,ipe,bpf'
"$apply_script" "$source_tree" "$tmp" >/dev/null
grep -qxF '# CONFIG_LOCALVERSION_AUTO is not set' "$tmp/.config" ||
    fail "kernel helper preserved CONFIG_LOCALVERSION_AUTO"
grep -qxF 'CONFIG_LSM="landlock,lockdown,yama,loadpin,safesetid,ipe,bpf"' "$tmp/.config" ||
    fail "kernel helper did not activate Landlock in CONFIG_LSM"
kernelrelease=$(make -s -C "$source_tree" O="$tmp" LOCALVERSION= kernelrelease)
[[ $kernelrelease == 7.3.0-rc6-x1407qa-perf ]] ||
    fail "unexpected normalized kernel release: $kernelrelease"

echo 'PASS: Linux 7.3 source, camera/runtime patches and performance config match the validated build'
