#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
patch_file="$script_dir/linux-7.3-x1407qa-runtime-fixes.patch"
camera_patch="$script_dir/linux-7.2-camera-warning-fix.patch"
source_tree=${1:-${HOME}/build/x1407qa-linux-7.3-rc6/source}
build_tree=${2:-${HOME}/build/x1407qa-linux-7.3-rc6/build}
expected_commit=a90ee4305c4a5df72c11b31dacfdc76e00fcf78a

[[ -d $source_tree/.git ]] || {
    echo "Kernel source tree not found: $source_tree" >&2
    exit 1
}
[[ -f $build_tree/.config ]] || {
    echo "Kernel build configuration not found: $build_tree/.config" >&2
    exit 1
}

actual_commit=$(git -C "$source_tree" rev-parse HEAD)
[[ $actual_commit == "$expected_commit" ]] || {
    echo "Unexpected kernel source commit: $actual_commit" >&2
    echo "Expected Linux v7.3-rc6 commit: $expected_commit" >&2
    exit 1
}

apply_once() {
    local patch=$1 description=$2
    local -a apply_options=()
    if [[ $patch == "$patch_file" ]]; then
        apply_options+=(--unidiff-zero)
    fi
    if git -C "$source_tree" apply "${apply_options[@]}" --reverse --check "$patch" 2>/dev/null; then
        echo "$description already applied"
    else
        git -C "$source_tree" apply "${apply_options[@]}" --check "$patch"
        git -C "$source_tree" apply "${apply_options[@]}" "$patch"
        echo "Applied $description"
    fi
}

apply_once "$patch_file" "Linux 7.3 X1407QA runtime patch"
apply_once "$camera_patch" "X1407QA camera warning patch"

config="$source_tree/scripts/config"
"$config" --file "$build_tree/.config" --set-str LOCALVERSION -x1407qa-perf
"$config" --file "$build_tree/.config" -d LOCALVERSION_AUTO
"$config" --file "$build_tree/.config" -e PREEMPT -d PREEMPT_NONE -d PREEMPT_VOLUNTARY
"$config" --file "$build_tree/.config" -e HZ_250 --set-val HZ 250
"$config" --file "$build_tree/.config" -e CPU_FREQ_DEFAULT_GOV_SCHEDUTIL
"$config" --file "$build_tree/.config" -e CC_OPTIMIZE_FOR_PERFORMANCE -d CC_OPTIMIZE_FOR_SIZE
"$config" --file "$build_tree/.config" -e ARM64_4K_PAGES -d ARM64_16K_PAGES -d ARM64_64K_PAGES
"$config" --file "$build_tree/.config" -e LTO_NONE -d LTO_CLANG
"$config" --file "$build_tree/.config" -m BT_RFCOMM
"$config" --file "$build_tree/.config" -e SECURITY_LANDLOCK -e SECURITY_LANDLOCK_LOG
"$config" --file "$build_tree/.config" \
    --set-str LSM 'landlock,lockdown,yama,loadpin,safesetid,ipe,bpf'
make -C "$source_tree" O="$build_tree" olddefconfig

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
    grep -qxF "$option" "$build_tree/.config" || {
        echo "Required kernel configuration is missing: $option" >&2
        exit 1
    }
done

# The validated build command passes LOCALVERSION= explicitly. Linux otherwise
# adds an SCM dirty suffix because these versioned patches modify the source.
kernelrelease=$(make -s -C "$source_tree" O="$build_tree" LOCALVERSION= kernelrelease)
[[ $kernelrelease == 7.3.0-rc6-x1407qa-perf ]] || {
    echo "Unexpected kernel release after normalization: $kernelrelease" >&2
    exit 1
}
