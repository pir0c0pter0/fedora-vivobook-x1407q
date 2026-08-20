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
    grep -qxF 'AUTOINSTALL="no"' "$directory/dkms.conf" || {
        echo "repository core module enables unsafe autoinstall: $module" >&2
        exit 1
    }
    for file in "${core_sources[$module]}" Makefile dkms.conf; do
        hash=$(sha256sum "$directory/$file" | cut -d' ' -f1)
        grep -qF "$directory/$file:$hash" "$setup" || {
            echo "setup lacks blocking provenance for ${module}-1.0/$file" >&2
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
    '${KERNEL_MODULES_ROOT}/${kernel}/build' \
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
    'mount --bind "$override_root/etc-dkms" /etc/dkms' \
    'cleanup_dkms_namespace' \
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
if grep -qF 'dkms autoinstall' "$setup"; then
    echo 'setup exposes raw dkms autoinstall guidance' >&2
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

for build_dependency in gcc make dkms perl elfutils-libelf-devel openssl-devel flex bison bc; do
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

for contract_token in \
    'preflight_core_paths' \
    'verify_staged_core_sources' \
    'build_core_dkms_modules' \
    'verify_core_dkms_vermagic' \
    'install_built_core_dkms_modules' \
    '.x1407qa-build-complete' \
    'config_input_sha256=' \
    'config_final_sha256=' \
    'module_symvers_sha256=' \
    'records >= 10000' \
    'publish_initramfs_candidate' \
    'lsinitrd' \
    'mv -Tf -- "$candidate" "$target"'; do
    grep -qF "$contract_token" "$setup" || {
        echo "setup lacks reviewed safety contract: $contract_token" >&2
        exit 1
    }
done

preflight_line=$(grep -n 'preflight_core_paths "$ACTIVE_KERNEL"' "$setup" | tail -1 | cut -d: -f1 || true)
deps_line=$(grep -n '^[[:space:]]*check_deps$' "$setup" | tail -1 | cut -d: -f1)
stage_line=$(grep -n '^[[:space:]]*stage_bundled$' "$setup" | tail -1 | cut -d: -f1)
namespace_line=$(grep -n 'if ! preflight_dkms_namespace; then' "$setup" | tail -1 | cut -d: -f1 || true)
[[ -n $preflight_line && -n $deps_line && -n $stage_line &&
   -n $namespace_line && $preflight_line -lt $deps_line &&
   $deps_line -lt $namespace_line && $namespace_line -lt $stage_line ]] || {
    echo 'general preflight, dependencies, DKMS namespace and staging are misordered' >&2
    exit 1
}

preflight_body=$(sed -n '/^preflight_core_paths()/,/^}/p' "$setup")
for type_contract in \
    '[[ ! -f "/boot/config-${kernel}" || -L "/boot/config-${kernel}" ]]' \
    '[[ ! -d "${KERNEL_MODULES_ROOT}/${kernel}" || -L "${KERNEL_MODULES_ROOT}/${kernel}" ]]' \
    '[[ ! -d /usr/src || -L /usr/src ]]'; do
    grep -qF "$type_contract" <<< "$preflight_body" || {
        echo "core preflight lacks exact path type contract: $type_contract" >&2
        exit 1
    }
done

[[ $(grep -c '^[[:space:]]*depmod "\$ACTIVE_KERNEL"' "$setup") -eq 1 ]] || {
    echo 'setup must run exactly one depmod for the active kernel' >&2
    exit 1
}
if grep -qE '^[[:space:]]*depmod "\$kernel"' "$setup"; then
    echo 'core install phase retains an early depmod' >&2
    exit 1
fi

camera_install_line=$(grep -n 'run_dkms_without_runtime_hooks dkms install --no-depmod' "$setup" | tail -1 | cut -d: -f1 || true)
depmod_line=$(grep -n '^[[:space:]]*depmod "\$ACTIVE_KERNEL"' "$setup" | cut -d: -f1 || true)
candidate_line=$(grep -n 'publish_initramfs_candidate "\$ACTIVE_KERNEL"' "$setup" | tail -1 | cut -d: -f1 || true)
[[ -n $camera_install_line && -n $depmod_line && -n $candidate_line &&
   $camera_install_line -lt $depmod_line && $depmod_line -lt $candidate_line ]] || {
    echo 'depmod does not run after camera install and immediately before candidate publication' >&2
    exit 1
}

build_line=$(grep -n 'build_core_dkms_modules "$ACTIVE_KERNEL"' "$setup" | tail -1 | cut -d: -f1 || true)
vermagic_line=$(grep -n 'verify_core_dkms_vermagic "$ACTIVE_KERNEL"' "$setup" | tail -1 | cut -d: -f1 || true)
install_line=$(grep -n 'install_built_core_dkms_modules "$ACTIVE_KERNEL"' "$setup" | tail -1 | cut -d: -f1 || true)
[[ -n $build_line && -n $vermagic_line && -n $install_line &&
   $build_line -lt $vermagic_line && $vermagic_line -lt $install_line ]] || {
    echo 'core modules are not built, vermagic-gated, then installed in distinct phases' >&2
    exit 1
}

echo 'PASS: setup owns a complete persistent core module build path'
