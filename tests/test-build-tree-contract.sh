#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT
export VIVOBOOK_SETUP_LIBRARY_ONLY=1
# shellcheck source=../setup-vivobook.sh
source "$root/setup-vivobook.sh"

kernel=7.2.0-x1407qa
source_hash=f9fef3d14c0df53819026f4be74459835c2a0b0dcbf5b5bbd9ea19f0829402b3
input_hash=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
mkdir -p "$test_root/include/generated"
printf '#define UTS_RELEASE "%s"\n' "$kernel" > "$test_root/include/generated/utsrelease.h"
printf 'CONFIG_MODULES=y\n' > "$test_root/.config"
: > "$test_root/vmlinux"
: > "$test_root/vmlinux.o"
truncate -s 1 "$test_root/vmlinux" "$test_root/vmlinux.o"
for ((i=0; i<10000; i++)); do
    printf '0x%08x\ttest_symbol_%d\tvmlinux\tEXPORT_SYMBOL\n' "$i" "$i"
done > "$test_root/Module.symvers"
config_hash=$(sha256sum "$test_root/.config" | cut -d' ' -f1)
symvers_hash=$(sha256sum "$test_root/Module.symvers" | cut -d' ' -f1)
printf '%s\n' \
    "kernel=$kernel" \
    "source_archive_sha256=$source_hash" \
    "config_input_sha256=$input_hash" \
    "config_final_sha256=$config_hash" \
    "module_symvers_sha256=$symvers_hash" \
    'module_symvers_records=10000' > "$test_root/.x1407qa-build-complete"

validate_core_module_build_tree "$test_root" "$kernel" "$source_hash" "$input_hash"
mv "$test_root/.x1407qa-build-complete" "$test_root/.marker-away"
if validate_core_module_build_tree "$test_root" "$kernel" "$source_hash" "$input_hash"; then
    echo 'build tree accepted a missing completion marker' >&2
    exit 1
fi
mv "$test_root/.marker-away" "$test_root/.x1407qa-build-complete"
mv "$test_root/include/generated/utsrelease.h" "$test_root/include/generated/utsrelease.real"
ln -s utsrelease.real "$test_root/include/generated/utsrelease.h"
if validate_core_module_build_tree "$test_root" "$kernel" "$source_hash" "$input_hash"; then
    echo 'build tree accepted a symlinked identity artifact' >&2
    exit 1
fi
rm "$test_root/include/generated/utsrelease.h"
mv "$test_root/include/generated/utsrelease.real" "$test_root/include/generated/utsrelease.h"
printf 'CONFIG_MODULES=n\n' > "$test_root/.config"
if validate_core_module_build_tree "$test_root" "$kernel" "$source_hash" "$input_hash"; then
    echo 'build tree accepted a changed final config' >&2
    exit 1
fi
printf 'CONFIG_MODULES=y\n' > "$test_root/.config"
sed -i '1s/^0x/invalid/' "$test_root/Module.symvers"
symvers_hash=$(sha256sum "$test_root/Module.symvers" | cut -d' ' -f1)
sed -i "s/^module_symvers_sha256=.*/module_symvers_sha256=$symvers_hash/" \
    "$test_root/.x1407qa-build-complete"
if validate_core_module_build_tree "$test_root" "$kernel" "$source_hash" "$input_hash"; then
    echo 'build tree accepted malformed Module.symvers' >&2
    exit 1
fi

echo 'PASS: build tree requires atomic completion, hashes, UTS and robust symbols'
