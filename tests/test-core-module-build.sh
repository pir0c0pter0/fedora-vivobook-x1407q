#!/usr/bin/env bash
set -euo pipefail

setup=setup-vivobook.sh
[[ -f $setup ]] || { echo 'setup script missing' >&2; exit 1; }

declare -A core_sources=(
    [wcn-regulator-fix]=wcn_regulator_fix.c
    [vivobook-kbd-fix]=vivobook_kbd_fix.c
    [vivobook-bl-fix]=vivobook_bl_fix.c
    [vivobook-hotkey-fix]=vivobook_hotkey_fix.c
)
for module in "${!core_sources[@]}"; do
    directory="modules/${module}-1.0"
    for file in "${core_sources[$module]}" Makefile dkms.conf; do
        [[ -f "$directory/$file" ]] || {
            echo "repository core module package is incomplete: ${module}-1.0/$file" >&2
            exit 1
        }
    done
done

for token in \
    f9fef3d14c0df53819026f4be74459835c2a0b0dcbf5b5bbd9ea19f0829402b3 \
    'make olddefconfig modules_prepare' \
    'make -j8 vmlinux' \
    'make -j8 modules' \
    'Module.symvers' \
    '/lib/modules/${kernel}/build' \
    'dkms add' \
    'dkms build' \
    'dkms install' \
    'depmod'; do
    grep -qF "$token" "$setup" || {
        echo "setup lacks persistent core build contract: $token" >&2
        exit 1
    }
done

for isolation_token in \
    'unshare --mount --propagation private' \
    'post_transaction=""' \
    'modprobe_on_install=""' \
    'mount --bind "$override_root/framework.conf" /etc/dkms/framework.conf' \
    'mount --bind "$override_root/framework.conf.d" /etc/dkms/framework.conf.d' \
    'preflight_dkms_namespace' \
    'dkms install --no-depmod'; do
    grep -qF "$isolation_token" "$setup" || {
        echo "setup lacks isolated DKMS contract: $isolation_token" >&2
        exit 1
    }
done
if grep -qE '^[[:space:]]*dkms (add|build|install)' "$setup"; then
    echo 'setup invokes a mutating DKMS action outside the isolated wrapper' >&2
    exit 1
fi
if grep -qE -- '--directive=.*post_transaction' "$setup"; then
    echo 'setup relies on a DKMS directive that the lazy framework reload can override' >&2
    exit 1
fi

if grep -qF 'KBUILD_MODPOST_WARN' "$setup"; then
    echo 'setup must not weaken missing-symbol validation' >&2
    exit 1
fi

for build_dependency in gcc make dkms perl elfutils-libelf-devel openssl-devel flex bison; do
    grep -qE "build_packages=.*${build_dependency}" "$setup" || {
        echo "setup omits deterministic build dependency: $build_dependency" >&2
        exit 1
    }
done

grep -qF '/var/lib/x1407qa-kernel-7.2/module-build' "$setup" || {
    echo 'setup does not prepare the persistent kernel module build tree' >&2
    exit 1
}
grep -qF 'wcn-regulator-fix:wcn_regulator_fix.c' "$setup" || {
    echo 'setup does not explicitly preserve the repository Wi-Fi source' >&2
    exit 1
}

echo 'PASS: setup owns a complete persistent core module build path'
