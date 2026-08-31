#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

export VIVOBOOK_SETUP_LIBRARY_ONLY=1
source "$repo_root/setup-vivobook.sh"

CAMERA_DKMS_SOURCE_ROOT="$work_dir/usr/src"
CAMERA_DKMS_STATE_ROOT="$work_dir/var/lib/dkms"
MODPROBE_CONFIG_DIR="$work_dir/etc/modprobe.d"
call_log="$work_dir/dkms-calls"
state_dir="$work_dir/dkms-state"
install_failure_package=
install_failures_remaining=0
mkdir -p \
	"$CAMERA_DKMS_SOURCE_ROOT/vivobook-cam-fix-2.0" \
	"$CAMERA_DKMS_SOURCE_ROOT/vivobook-ir-cam-1.0" \
	"$state_dir"
printf 'stale source\n' > \
	"$CAMERA_DKMS_SOURCE_ROOT/vivobook-ir-cam-1.0/hm1092.c"

dkms()
{
	local package=${2:-} state

	[[ ${1:-} == status ]] || return 2
	if [[ -e "$state_dir/${package//\//-}" ]]; then
		state=$(<"$state_dir/${package//\//-}")
		printf '%s, %s, %s\n' "${package%/*}" "${package#*/}" "$state"
	fi
}

run_dkms_without_runtime_hooks()
{
	local package module version artifact kernel

	printf '%s\n' "$*" >> "$call_log"
	if [[ $1 == dkms && $2 == build ]]; then
		package=$4
		module=${package%/*}
		version=${package#*/}
		kernel=$6
		case $module in
			vivobook-cam-fix) artifact=vivobook_cam_fix ;;
			vivobook-ir-cam) artifact=hm1092 ;;
			*) return 2 ;;
		esac
		mkdir -p "$CAMERA_DKMS_STATE_ROOT/$module/$version/$kernel/aarch64/module"
		: > "$CAMERA_DKMS_STATE_ROOT/$module/$version/$kernel/aarch64/module/$artifact.ko"
		printf 'built\n' > "$state_dir/${package//\//-}"
	fi
	if [[ $1 == dkms && $2 == add ]]; then
		package=${3##*/}
		package=${package%-*}/${package##*-}
		printf 'added\n' > "$state_dir/${package//\//-}"
	fi
	if [[ $1 == dkms && $2 == install ]]; then
		if [[ ${5:-} == "$install_failure_package" &&
		      $install_failures_remaining -gt 0 ]]; then
			((--install_failures_remaining))
			return 1
		fi
		printf 'installed\n' > "$state_dir/${5//\//-}"
	fi
	if [[ $1 == dkms && $2 == remove ]]; then
		unlink "$state_dir/${3//\//-}" 2>/dev/null || true
	fi
}

modinfo()
{
	[[ $1 == -F && $2 == vermagic ]] || return 2
	printf '7.2.0-test SMP preempt mod_unload aarch64\n'
}

dependency_path="$work_dir/dependency-path"
mkdir -p "$dependency_path"
for dependency_command in \
	awk bc cpp curl depmod dnf dracut fdtget flock grep install lsinitrd make \
	mount mv sha256sum systemctl tar unshare xz xxd grubby grub2-mkconfig \
	modprobe; do
	ln -s /usr/bin/true "$dependency_path/$dependency_command"
done
rpm()
{
	return 0
}
if PATH="$dependency_path" install_exact_dependencies setup >/dev/null 2>&1; then
	echo 'setup accepted a camera build environment without dtc' >&2
	exit 1
fi
ln -s /usr/bin/true "$dependency_path/dtc"
unlink "$dependency_path/xxd"
if PATH="$dependency_path" install_exact_dependencies setup >/dev/null 2>&1; then
	echo 'setup accepted a camera build environment without xxd' >&2
	exit 1
fi
ln -s /usr/bin/true "$dependency_path/xxd"
PATH="$dependency_path" install_exact_dependencies setup >/dev/null
unset -f rpm

stage_camera_dkms_sources
cmp "$repo_root/modules/vivobook-ir-cam-1.0/hm1092.c" \
	"$CAMERA_DKMS_SOURCE_ROOT/vivobook-ir-cam-1.0/hm1092.c" || {
	echo 'camera DKMS stage did not replace an existing stale source' >&2
	exit 1
}

printf 'preserved old camera tree\n' > \
	"$CAMERA_DKMS_SOURCE_ROOT/vivobook-cam-fix-2.0/Makefile"
install_calls=0
install()
{
	((++install_calls == 2)) && return 1
	command install "$@"
}
if stage_camera_dkms_sources >/dev/null 2>&1; then
	echo 'camera DKMS stage accepted an injected copy failure' >&2
	exit 1
fi
unset -f install
grep -qxF 'preserved old camera tree' \
	"$CAMERA_DKMS_SOURCE_ROOT/vivobook-cam-fix-2.0/Makefile" || {
	echo 'failed camera DKMS stage partially published a source tree' >&2
	exit 1
}
stage_camera_dkms_sources

printf 'old cam fix tree\n' > \
	"$CAMERA_DKMS_SOURCE_ROOT/vivobook-cam-fix-2.0/Makefile"
printf 'old IR tree\n' > \
	"$CAMERA_DKMS_SOURCE_ROOT/vivobook-ir-cam-1.0/Makefile"
mv_calls=0
mv()
{
	if [[ $1 == -T ]]; then
		((++mv_calls == 3)) && return 1
	fi
	command mv "$@"
}
if stage_camera_dkms_sources >/dev/null 2>&1; then
	echo 'camera DKMS stage accepted an injected publication failure' >&2
	exit 1
fi
unset -f mv
grep -qxF 'old cam fix tree' \
	"$CAMERA_DKMS_SOURCE_ROOT/vivobook-cam-fix-2.0/Makefile" &&
	grep -qxF 'old IR tree' \
	"$CAMERA_DKMS_SOURCE_ROOT/vivobook-ir-cam-1.0/Makefile" || {
	echo 'failed multi-package publication did not roll back both DKMS trees' >&2
	exit 1
}
stage_camera_dkms_sources

printf 'pre-signal cam fix tree\n' > \
	"$CAMERA_DKMS_SOURCE_ROOT/vivobook-cam-fix-2.0/Makefile"
printf 'pre-signal IR tree\n' > \
	"$CAMERA_DKMS_SOURCE_ROOT/vivobook-ir-cam-1.0/Makefile"
mv_calls=0
mv()
{
	if [[ $1 == -T ]]; then
		((++mv_calls))
		command mv "$@" || return
		((mv_calls == 4)) && kill -TERM "$BASHPID"
		return 0
	fi
	command mv "$@"
}
if stage_camera_dkms_sources >/dev/null 2>&1; then
	echo 'camera DKMS stage ignored SIGTERM between package publications' >&2
	exit 1
fi
unset -f mv
grep -qxF 'pre-signal cam fix tree' \
	"$CAMERA_DKMS_SOURCE_ROOT/vivobook-cam-fix-2.0/Makefile" &&
	grep -qxF 'pre-signal IR tree' \
	"$CAMERA_DKMS_SOURCE_ROOT/vivobook-ir-cam-1.0/Makefile" || {
	echo 'signal during publication did not roll back both DKMS trees' >&2
	exit 1
}
stage_camera_dkms_sources

printf 'pre-checkpoint cam fix tree\n' > \
	"$CAMERA_DKMS_SOURCE_ROOT/vivobook-cam-fix-2.0/Makefile"
printf 'pre-checkpoint IR tree\n' > \
	"$CAMERA_DKMS_SOURCE_ROOT/vivobook-ir-cam-1.0/Makefile"
set -T
trap 'if [[ ${BASH_COMMAND:-} == "publication_active=0" ]] &&
    (( ${publication_active:-0} == 1 && ${published:-0} == 1 )); then
        trap - DEBUG
        kill -TERM "$BASHPID"
    fi' DEBUG
if stage_camera_dkms_sources >/dev/null 2>&1; then
	trap - DEBUG
	set +T
	echo 'camera DKMS stage ignored SIGTERM at publication checkpoint' >&2
	exit 1
fi
trap - DEBUG
set +T
grep -qxF 'pre-checkpoint cam fix tree' \
	"$CAMERA_DKMS_SOURCE_ROOT/vivobook-cam-fix-2.0/Makefile" &&
	grep -qxF 'pre-checkpoint IR tree' \
	"$CAMERA_DKMS_SOURCE_ROOT/vivobook-ir-cam-1.0/Makefile" || {
	echo 'checkpoint signal double-rolled back a DKMS source tree' >&2
	exit 1
}
stage_camera_dkms_sources

printf 'pre-backup-cleanup cam fix tree\n' > \
	"$CAMERA_DKMS_SOURCE_ROOT/vivobook-cam-fix-2.0/Makefile"
printf 'pre-backup-cleanup IR tree\n' > \
	"$CAMERA_DKMS_SOURCE_ROOT/vivobook-ir-cam-1.0/Makefile"
backup_removals=0
rm()
{
	if [[ $1 == -rf && ${3:-} == *.old.* ]]; then
		command rm "$@" || return
		((++backup_removals == 1)) && kill -TERM "$BASHPID"
		return 0
	fi
	command rm "$@"
}
if stage_camera_dkms_sources >/dev/null 2>&1; then
	echo 'camera DKMS stage ignored SIGTERM during backup cleanup' >&2
	exit 1
fi
unset -f rm
cmp "$repo_root/modules/vivobook-cam-fix-2.0/Makefile" \
	"$CAMERA_DKMS_SOURCE_ROOT/vivobook-cam-fix-2.0/Makefile" &&
	cmp "$repo_root/modules/vivobook-ir-cam-1.0/Makefile" \
	"$CAMERA_DKMS_SOURCE_ROOT/vivobook-ir-cam-1.0/Makefile" || {
	echo 'signal during backup cleanup damaged the committed DKMS trees' >&2
	exit 1
}
stage_camera_dkms_sources

printf 'transaction pre-stage cam fix tree\n' > \
	"$CAMERA_DKMS_SOURCE_ROOT/vivobook-cam-fix-2.0/Makefile"
printf 'transaction pre-stage IR tree\n' > \
	"$CAMERA_DKMS_SOURCE_ROOT/vivobook-ir-cam-1.0/Makefile"
install_calls=0
install()
{
	((++install_calls == 2)) && return 1
	command install "$@"
}
if update_camera_dkms_transaction 7.2.0-test >/dev/null 2>&1; then
	echo 'camera DKMS transaction accepted an injected staging failure' >&2
	exit 1
fi
unset -f install
grep -qxF 'transaction pre-stage cam fix tree' \
	"$CAMERA_DKMS_SOURCE_ROOT/vivobook-cam-fix-2.0/Makefile" &&
grep -qxF 'transaction pre-stage IR tree' \
	"$CAMERA_DKMS_SOURCE_ROOT/vivobook-ir-cam-1.0/Makefile" || {
	echo 'transaction double-rolled back sources after a staging failure' >&2
	exit 1
}
stage_camera_dkms_sources

printf 'transaction handoff cam fix tree\n' > \
	"$CAMERA_DKMS_SOURCE_ROOT/vivobook-cam-fix-2.0/Makefile"
printf 'transaction handoff IR tree\n' > \
	"$CAMERA_DKMS_SOURCE_ROOT/vivobook-ir-cam-1.0/Makefile"
set -T
trap 'if [[ -n $(find "$CAMERA_DKMS_SOURCE_ROOT" -maxdepth 1 \
	-name ".vivobook-camera-dkms-staged.*" -print -quit) ]]; then
	trap - RETURN
	kill -TERM "$BASHPID"
fi' RETURN
if update_camera_dkms_transaction 7.2.0-test >/dev/null 2>&1; then
	trap - RETURN
	set +T
	echo 'camera DKMS transaction ignored a signal during staging handoff' >&2
	exit 1
fi
trap - RETURN
set +T
grep -qxF 'transaction handoff cam fix tree' \
	"$CAMERA_DKMS_SOURCE_ROOT/vivobook-cam-fix-2.0/Makefile" &&
grep -qxF 'transaction handoff IR tree' \
	"$CAMERA_DKMS_SOURCE_ROOT/vivobook-ir-cam-1.0/Makefile" &&
[[ -z $(find "$CAMERA_DKMS_SOURCE_ROOT" -maxdepth 1 -name '*.old.*' -print -quit) ]] || {
	echo 'signal during staging handoff left new sources or retained backups' >&2
	exit 1
}
stage_camera_dkms_sources

printf 'transaction old cam fix tree\n' > \
	"$CAMERA_DKMS_SOURCE_ROOT/vivobook-cam-fix-2.0/Makefile"
printf 'transaction old IR tree\n' > \
	"$CAMERA_DKMS_SOURCE_ROOT/vivobook-ir-cam-1.0/Makefile"
mkdir -p "$MODPROBE_CONFIG_DIR"
printf 'transaction old config\n' > "$MODPROBE_CONFIG_DIR/hm1092-ir.conf"
printf 'installed\n' > "$state_dir/vivobook-cam-fix-2.0"
printf 'installed\n' > "$state_dir/vivobook-ir-cam-1.0"
install_failure_package=vivobook-ir-cam/1.0
install_failures_remaining=1
if update_camera_dkms_transaction 7.2.0-test; then
	echo 'camera DKMS transaction accepted a second-module install failure' >&2
	exit 1
fi
grep -qxF 'transaction old cam fix tree' \
	"$CAMERA_DKMS_SOURCE_ROOT/vivobook-cam-fix-2.0/Makefile" &&
	grep -qxF 'transaction old IR tree' \
	"$CAMERA_DKMS_SOURCE_ROOT/vivobook-ir-cam-1.0/Makefile" &&
	grep -qxF 'transaction old config' \
	"$MODPROBE_CONFIG_DIR/hm1092-ir.conf" &&
	[[ -e $state_dir/vivobook-cam-fix-2.0 &&
	   -e $state_dir/vivobook-ir-cam-1.0 ]] || {
	echo 'failed camera DKMS transaction did not restore sources, config and installed state' >&2
	exit 1
}
grep -qxF \
	'dkms install --no-depmod --force vivobook-ir-cam/1.0 -k 7.2.0-test' \
	"$call_log" || {
	echo 'camera DKMS transaction did not reach the injected install failure' >&2
	exit 1
}

printf 'transaction state cam fix tree\n' > \
	"$CAMERA_DKMS_SOURCE_ROOT/vivobook-cam-fix-2.0/Makefile"
printf 'transaction state IR tree\n' > \
	"$CAMERA_DKMS_SOURCE_ROOT/vivobook-ir-cam-1.0/Makefile"
printf 'transaction state config\n' > "$MODPROBE_CONFIG_DIR/hm1092-ir.conf"
printf 'added\n' > "$state_dir/vivobook-cam-fix-2.0"
printf 'built\n' > "$state_dir/vivobook-ir-cam-1.0"
install_failures_remaining=1
if update_camera_dkms_transaction 7.2.0-test >/dev/null 2>&1; then
	echo 'camera DKMS state transaction accepted an injected install failure' >&2
	exit 1
fi
[[ $(<"$state_dir/vivobook-cam-fix-2.0") == added &&
   $(<"$state_dir/vivobook-ir-cam-1.0") == built ]] &&
grep -qxF 'transaction state cam fix tree' \
	"$CAMERA_DKMS_SOURCE_ROOT/vivobook-cam-fix-2.0/Makefile" &&
grep -qxF 'transaction state IR tree' \
	"$CAMERA_DKMS_SOURCE_ROOT/vivobook-ir-cam-1.0/Makefile" &&
grep -qxF 'transaction state config' \
	"$MODPROBE_CONFIG_DIR/hm1092-ir.conf" || {
	echo 'rollback did not restore exact added/built DKMS states' >&2
	exit 1
}
install_failure_package=
unlink "$state_dir/vivobook-cam-fix-2.0"
unlink "$state_dir/vivobook-ir-cam-1.0"
: > "$call_log"
stage_camera_dkms_sources

install_camera_dkms_modules 7.2.0-test
install_camera_dkms_modules 7.2.0-test

expected_log="$work_dir/expected-calls"
printf '%s\n' \
	"dkms add $CAMERA_DKMS_SOURCE_ROOT/vivobook-cam-fix-2.0" \
	'dkms build --force vivobook-cam-fix/2.0 -k 7.2.0-test' \
	"dkms add $CAMERA_DKMS_SOURCE_ROOT/vivobook-ir-cam-1.0" \
	'dkms build --force vivobook-ir-cam/1.0 -k 7.2.0-test' \
	'dkms install --no-depmod --force vivobook-cam-fix/2.0 -k 7.2.0-test' \
	'dkms install --no-depmod --force vivobook-ir-cam/1.0 -k 7.2.0-test' \
	'dkms build --force vivobook-cam-fix/2.0 -k 7.2.0-test' \
	'dkms build --force vivobook-ir-cam/1.0 -k 7.2.0-test' \
	'dkms install --no-depmod --force vivobook-cam-fix/2.0 -k 7.2.0-test' \
	'dkms install --no-depmod --force vivobook-ir-cam/1.0 -k 7.2.0-test' \
	> "$expected_log"

cmp "$expected_log" "$call_log" || {
	echo 'camera DKMS install is not idempotent or does not update both modules' >&2
	exit 1
}

cmp "$repo_root/modules/vivobook-ir-cam-1.0/hm1092-ir.conf" \
	"$MODPROBE_CONFIG_DIR/hm1092-ir.conf" || {
	echo 'HM1092 module configuration was not installed exactly' >&2
	exit 1
}

echo 'PASS: camera DKMS modules and HM1092 configuration install idempotently'
