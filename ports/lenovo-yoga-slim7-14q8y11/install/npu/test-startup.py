#!/usr/bin/env python3
"""Offline NPU sequencing checks: no hardware, firmware or native runtime opened."""
import os
from pathlib import Path
import subprocess
import tempfile

source = Path(__file__).with_name('yoga-npu-up').read_text()
assert '[ "$EUID" = 0 ]' in source
assert 'stage=/var/lib/yoga-npu-fw' in source
firmware = 'qcom/glymur/LENOVO/83QR/qccdsp8480.mbn'
dtb = 'qcom/glymur/LENOVO/83QR/cdsp_dtbs.elf'


def run(name, mutate=lambda root: None, env=None, success=False, preflight=False, oldpath=''):
    with tempfile.TemporaryDirectory(prefix='yoga-npu-review-') as directory:
        root = Path(directory)

        def put(path, value):
            target = root/path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(value)
            return target

        put('proc/cmdline', 'quiet yoga.npu=1\n')
        put('sys/firmware/devicetree/base/compatible', 'lenovo,yoga-slim7x-gen11-x2plus-diag\0')
        put('sys/firmware/devicetree/base/soc@0/remoteproc@32300000/firmware-name', firmware+'\0'+dtb+'\0')
        put('sys/devices/soc0/soc_id', '729\n')
        for index, (rname, state) in enumerate([('soccp', 'attached'), ('adsp', 'running'), ('cdsp', 'offline')]):
            put(f'sys/class/remoteproc/remoteproc{index}/name', rname+'\n')
            put(f'sys/class/remoteproc/remoteproc{index}/state', state+'\n')
            put(f'sys/class/remoteproc/remoteproc{index}/recovery', 'enabled\n')
        put('sys/class/remoteproc/remoteproc2/firmware', firmware+'\n')
        put('sys/class/power_supply/qcom-battmgr-bat/capacity', '60\n')
        put('sys/module/firmware_class/parameters/path', '')
        put('fw-model', oldpath)
        put('calls', '')
        (root/'dev').mkdir()
        (root/'dev/null').symlink_to('/dev/null')
        mocks = put('mocks', r'''
printf() {
    local target
    target=$(readlink /proc/$$/fd/1)
    if [ "$target" = "$TEST_ROOT/sys/module/firmware_class/parameters/path" ]; then
        builtin printf "$@" > "$TEST_ROOT/write"
        if [ -s "$TEST_ROOT/write" ]; then cp "$TEST_ROOT/write" "$TEST_ROOT/fw-model"; fi
        builtin echo fw-path >> "$TEST_ROOT/calls"
    elif [ "$target" = "$TEST_ROOT/sys/class/remoteproc/remoteproc2/state" ]; then
        [ "$(command cat "$TEST_ROOT/sys/class/remoteproc/remoteproc2/recovery")" = disabled ] || exit 90
        [ "$(command cat "$TEST_ROOT/fw-model")" = "$TEST_ROOT/var/lib/yoga-npu-fw" ] || exit 91
        builtin echo cdsp-start >> "$TEST_ROOT/calls"
        if [ "${FAIL_START:-0}" = 1 ]; then builtin echo offline; return 1; fi
        builtin echo running
        if [ "${LOSE_ADSP:-0}" = 1 ]; then builtin echo offline > "$TEST_ROOT/sys/class/remoteproc/remoteproc1/state"; fi
    else builtin printf "$@"; fi
}
cat() {
    if [ "$1" = "$TEST_ROOT/sys/module/firmware_class/parameters/path" ]; then
        command cat "$TEST_ROOT/fw-model"
    else command cat "$@"; fi
}
sha256sum() { command cat >/dev/null; return "${FAIL_HASH:-0}"; }
systemctl() { return "${FAIL_GPU:-0}"; }
modprobe() {
    [ "$*" = fastrpc ] || exit 92
    [ "$(command cat "$TEST_ROOT/fw-model")" = "$OLD_FW_PATH" ] || exit 93
    [ "$(command cat "$TEST_ROOT/sys/class/remoteproc/remoteproc2/state")" = running ] || exit 94
    builtin echo fastrpc >> "$TEST_ROOT/calls"
    return "${FAIL_MODULE:-0}"
}
udevadm() {
    builtin echo udev >> "$TEST_ROOT/calls"
    return "${FAIL_UDEV:-0}"
}
''')
        script = source.replace('[ "$EUID" = 0 ]', '[ 0 = 0 ]')
        for prefix in ['/sys/', '/proc/', '/var/', '/dev/']:
            script = script.replace(prefix, f'{root}{prefix}')
        path = put('npu-up', script)
        mutate(root)
        protected_states = [(root/f'sys/class/remoteproc/remoteproc{i}/state').read_text() for i in (0, 1)]
        result = subprocess.run(['bash', str(path)], text=True, capture_output=True,
                                env=dict(os.environ, BASH_ENV=str(mocks), TEST_ROOT=str(root), OLD_FW_PATH=oldpath, **(env or {})))
        assert (result.returncode == 0) == success, (name, result.stdout, result.stderr)
        assert (root/'fw-model').read_text().rstrip('\n') == oldpath, (name, 'firmware path leak')
        calls = (root/'calls').read_text().splitlines()
        if preflight:
            assert not calls, (name, 'hardware started before preflight')
            assert (root/'sys/class/remoteproc/remoteproc2/recovery').read_text() == 'enabled\n'
        if success:
            assert calls.index('cdsp-start') < calls.index('fastrpc') < calls.index('udev')
        assert (root/'sys/class/remoteproc/remoteproc0/recovery').read_text() == 'enabled\n'
        assert (root/'sys/class/remoteproc/remoteproc1/recovery').read_text() == 'enabled\n'
        for index, state in enumerate(protected_states):
            if index == 1 and (env or {}).get('LOSE_ADSP') == '1':
                continue
            assert (root/f'sys/class/remoteproc/remoteproc{index}/state').read_text() == state
        print('PASS', name)


run('CDSP then restored path then FastRPC', success=True)
run('restore existing firmware search path', success=True, oldpath='/existing/path')
for name, path, value in [
    ('missing opt-in', 'proc/cmdline', 'quiet\n'),
    ('regex-shaped opt-in rejected', 'proc/cmdline', 'quiet yogaXnpu=1\n'),
    ('prefixed opt-in rejected', 'proc/cmdline', 'quiet other=yoga.npu=1\n'),
    ('extended opt-in rejected', 'proc/cmdline', 'quiet yoga.npu=10\n'),
    ('suffixed opt-in rejected', 'proc/cmdline', 'quiet yoga.npu=1.extra\n'),
    ('wrong board', 'sys/firmware/devicetree/base/compatible', 'other\0'),
    ('wrong native SoC', 'sys/devices/soc0/soc_id', '728\n'),
    ('SoCCP not attached', 'sys/class/remoteproc/remoteproc0/state', 'offline\n'),
    ('ADSP not running', 'sys/class/remoteproc/remoteproc1/state', 'offline\n'),
    ('CDSP already running', 'sys/class/remoteproc/remoteproc2/state', 'running\n'),
    ('wrong firmware name', 'sys/class/remoteproc/remoteproc2/firmware', 'other.mbn\n'),
    ('wrong DT firmware first name', 'sys/firmware/devicetree/base/soc@0/remoteproc@32300000/firmware-name', 'other.mbn\0'+dtb+'\0'),
    ('wrong DT firmware second name', 'sys/firmware/devicetree/base/soc@0/remoteproc@32300000/firmware-name', firmware+'\0other.elf\0'),
    ('missing DT firmware second name', 'sys/firmware/devicetree/base/soc@0/remoteproc@32300000/firmware-name', firmware+'\0'),
    ('extra DT firmware name', 'sys/firmware/devicetree/base/soc@0/remoteproc@32300000/firmware-name', firmware+'\0'+dtb+'\0other.elf\0'),
]:
    run(name, lambda root, p=path, v=value: (root/p).write_text(v), preflight=True)
run('GPU prerequisite failure', env={'FAIL_GPU': '1'}, preflight=True)
run('firmware digest failure', env={'FAIL_HASH': '1'}, preflight=True)
run('battery unreadable', lambda root: (root/'sys/class/power_supply/qcom-battmgr-bat/capacity').unlink(), preflight=True)
run('CDSP absent', lambda root: (root/'sys/class/remoteproc/remoteproc2/name').write_text('other\n'), preflight=True)
def duplicate_cdsp(root):
    duplicate = root/'sys/class/remoteproc/remoteproc3'
    duplicate.mkdir()
    (duplicate/'name').write_text('cdsp\n')


run('CDSP ambiguous', duplicate_cdsp, preflight=True)
run('restore path after CDSP start error', env={'FAIL_START': '1'})
run('FastRPC module failure', env={'FAIL_MODULE': '1'})
run('FastRPC device not initialized', env={'FAIL_UDEV': '1'})
run('detect ADSP regression after start', env={'LOSE_ADSP': '1'})
