#!/usr/bin/env python3
"""Offline audio guard tests; redirects target paths and mocks hardware commands."""
import os
from pathlib import Path
import subprocess
import tempfile

source = Path(__file__).with_name('yoga-audio.sh').read_text()
assert '[ "$EUID" = 0 ]' in source
speakers = ['WooferLeft', 'TweeterLeft', 'WooferRight', 'TweeterRight']
controls = [f'{s} {c}' for s in speakers for c in
            ['PA Volume', 'COMP Switch', 'BOOST Switch', 'PBR Switch',
             'VISENSE Switch', 'WSA MODE', 'DAC Switch']]
controls += ['WSA_CODEC_DMA_RX_0 Audio Mixer MultiMedia1']
controls += [f'{m} {c}' for m in ['WSA', 'WSA2'] for c in
             ['WSA RX0 MUX', 'WSA RX1 MUX', 'WSA_RX0 INP0', 'WSA_RX1 INP0',
              'WSA_COMP1 Switch', 'WSA_COMP2 Switch',
              'WSA_RX0 Digital Volume', 'WSA_RX1 Digital Volume']]


def run(name, args, expected=True, env=None, board=True, bootflag=True, oldpath=''):
    with tempfile.TemporaryDirectory(prefix='yoga-audio-review-') as temp:
        root = Path(temp)

        def put(path, data):
            p = root / path
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(data)
            return p

        put('sys/firmware/devicetree/base/compatible',
            ('lenovo,yoga-slim7x-gen11-x2plus-diag' if board else 'other-board') + '\0')
        put('proc/cmdline', 'quiet' + (' yoga.audio=1' if bootflag else '') + '\n')
        put('proc/asound/cards', ' 0 [glymur ]: GLYMUR-LENOVO-Yoga-Slim7x\n')
        put('sys/class/remoteproc/remoteproc0/name', 'soccp\n')
        put('sys/class/remoteproc/remoteproc0/state', 'attached\n')
        put('sys/class/remoteproc/remoteproc1/name', 'adsp\n')
        put('sys/class/remoteproc/remoteproc1/state', 'offline\n')
        put('sys/class/remoteproc/remoteproc1/recovery', 'enabled\n')
        put('sys/class/power_supply/qcom-battmgr-bat/capacity', '80\n')
        put('sys/module/firmware_class/parameters/path', '')
        put('fw-model', oldpath)
        put('calls', '')
        (root / 'dev').mkdir()
        (root / 'dev/null').symlink_to('/dev/null')
        for dev in ['6c90000.codec', '6cb0000.codec']:
            put(f'sys/bus/platform/devices/{dev}/power/control', 'auto\n')
        put('controls', ''.join(f"numid={i},iface=MIXER,name='{c}'\n"
                               for i, c in enumerate(controls, 1)))
        mocks = put('mocks', r'''
# Keep sysfs state separately: a zero-length write does not change an attribute.
_write() {
    local cmd=$1 target
    shift
    target=$(readlink /proc/$$/fd/1)
    if [ "$target" = "$TEST_ROOT/sys/module/firmware_class/parameters/path" ]; then
        builtin "$cmd" "$@" > "$TEST_ROOT/write"
        if [ -s "$TEST_ROOT/write" ]; then cp "$TEST_ROOT/write" "$TEST_ROOT/fw-model"; fi
        builtin echo fw-write >> "$TEST_ROOT/calls"
    elif [ "$target" = "$TEST_ROOT/sys/class/remoteproc/remoteproc1/state" ]; then
        if [ "${FAIL_ADSP:-0}" = 1 ]; then builtin echo offline; return 1; fi
        builtin echo running
    else
        builtin "$cmd" "$@"
    fi
}
echo() { _write echo "$@"; }
printf() { _write printf "$@"; }
cat() {
    if [ "$1" = "$TEST_ROOT/sys/module/firmware_class/parameters/path" ]; then
        command cat "$TEST_ROOT/fw-model"
    else command cat "$@"; fi
}
sha256sum() { command cat >/dev/null; return "${FAIL_HASH:-0}"; }
systemctl() { return "${FAIL_SERVICE:-0}"; }
amixer() {
    if [ "${*: -1}" = controls ]; then
        if [ "${MISSING_CONTROL:-0}" = 1 ]; then return; fi
        command cat "$TEST_ROOT/controls"
        if [ "${DUPLICATE_CONTROL:-0}" = 1 ]; then head -1 "$TEST_ROOT/controls"; fi
    else
        builtin echo "$*" >> "$TEST_ROOT/calls"
        return "${FAIL_CSET:-0}"
    fi
}
''')
        script = source.replace('[ "$EUID" = 0 ]', '[ 0 = 0 ]')
        for prefix in ['/sys/', '/proc/', '/usr/', '/var/', '/dev/']:
            script = script.replace(prefix, f'{root}{prefix}')
        path = put('audio', script)
        path.chmod(0o755)
        result = subprocess.run(['bash', str(path), *args], capture_output=True, text=True,
                                env=dict(os.environ, BASH_ENV=str(mocks), TEST_ROOT=str(root), **(env or {})))
        assert (result.returncode == 0) == expected, (name, result.stdout, result.stderr)
        calls = (root / 'calls').read_text()
        if args[0] == 'adsp':
            assert (root / 'fw-model').read_text().rstrip('\n') == oldpath, (name, 'firmware path leaked')
            assert (root / 'sys/class/remoteproc/remoteproc0/state').read_text() == 'attached\n'
            if board and not (env or {}).get('FAIL_HASH'):
                assert calls.count('fw-write') >= 3, (name, 'did not exercise restore')
            else:
                assert not calls, (name, 'write before preflight')
        if args[0] == 'mixer' and (not board or (len(args) > 1 and not expected)):
            assert not calls, (name, 'volume write before validation')
            assert (root / 'sys/bus/platform/devices/6c90000.codec/power/control').read_text() == 'auto\n'
        if args[0] == 'mixer' and expected:
            assert calls.count(' cset ') == len(controls), (name, calls)
        print('PASS', name)


run('wrong board refuses hardware', ['adsp'], False, board=False)
run('boot opt-in required', ['up'], False, bootflag=False)
run('base service required', ['up'], False, env={'FAIL_SERVICE': '1'})
run('installed UCM profile required', ['up'], False)
run('firmware hash failure has no writes', ['adsp'], False, env={'FAIL_HASH': '1'})
run('restore initially empty firmware path', ['adsp'])
run('restore nonempty firmware path', ['adsp'], oldpath='/previous/staging')
run('restore path after ADSP start failure', ['adsp'], False, env={'FAIL_ADSP': '1'})
run('mixer at validated defaults', ['mixer'])
run('mixer at zero gain', ['mixer', '0', '0'])
for dv, pa in [('67', '6'), ('66', '7'), ('-1', '0'), ('0', '-1'), ('bad', '0')]:
    run(f'refuse invalid gain {dv}/{pa}', ['mixer', dv, pa], False)
run('refuse missing control', ['mixer'], False, env={'MISSING_CONTROL': '1'})
run('refuse ambiguous control', ['mixer'], False, env={'DUPLICATE_CONTROL': '1'})
run('stop on mixer write error', ['mixer'], False, env={'FAIL_CSET': '1'})
