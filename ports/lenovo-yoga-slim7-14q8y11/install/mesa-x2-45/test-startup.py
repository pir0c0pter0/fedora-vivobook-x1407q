#!/usr/bin/env python3
"""GPU boot guards with fake sysfs and commands; never opens a render node."""
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile

here = Path(__file__).resolve().parent
source = (here / 'yoga-gpu-up').read_text()
files = [
    'opt/mesa-x2-45/lib64/libgallium-26.2.3.so',
    'opt/mesa-x2-45/lib64/libEGL_mesa.so.0',
    'opt/mesa-x2-45/lib64/libgbm.so.1',
    *['usr/lib/firmware/qcom/' + name for name in
      ('gen80100_aqe.fw', 'gen80100_sqe.fw', 'gen80100_gmu.bin')],
]


def run(name, mutate=lambda root: None, options=None, success=False, preflight=False):
    with tempfile.TemporaryDirectory(prefix='yoga-gpu-review-') as directory:
        root = Path(directory)

        def put(path, data):
            target = root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(data)
            return target

        put('proc/cmdline', 'quiet yoga.gpu=1\n')
        put('sys/firmware/devicetree/base/compatible', 'lenovo,yoga-slim7x-gen11-x2plus-diag\0')
        put('sys/module/msm/parameters/separate_gpu_kms', '1\n')
        put('sys/bus/platform/devices/3d00000.gpu/driver_override', 'none\n')
        put('sys/bus/platform/devices/3d00000.gpu/drm/renderD128/dev', '226:128\n')
        put('sys/bus/platform/drivers/adreno/bind', '')
        put('sys/bus/platform/drivers_probe', '')
        put('sys/class/devfreq/3d00000.gpu/available_frequencies', '310000000 410000000 1850000000\n')
        put('sys/class/devfreq/3d00000.gpu/max_freq', '1850000000\n')
        put('run/calls', '')
        for path in files:
            put(path, 'fixture\n')
        for device in ['3d90000.clock-controller', '3d64000.clock-controller', '3da0000.iommu']:
            path = root / f'sys/bus/platform/devices/{device}'
            path.mkdir(parents=True)
            (path / 'driver').symlink_to('/mock/driver')
        stub = '#!' + sys.executable + r'''
import os, pathlib, sys
r=pathlib.Path(os.environ['TEST_ROOT'])
name=pathlib.Path(sys.argv[0]).name
args=sys.argv[1:]
if name == 'systemctl':
    if args[0] == 'show': print(os.getenv('GDM_STATE', 'inactive'))
    else: sys.exit(int(os.getenv('SERVICE_FAIL', '0')))
elif name == 'cat':
    if os.getenv('BAD_CAP') and args and args[0].endswith('/max_freq'): print('1850000000')
    else: os.execv('/usr/bin/cat', ['cat', *args])
else:
    with (r/'run/calls').open('a') as f: f.write(name+' '+' '.join(args)+'\n')
    if name == 'timeout':
        assert (r/'sys/class/devfreq/3d00000.gpu/max_freq').read_text().strip() == '310000000'
    sys.exit(int(os.getenv('FAIL_'+name.upper(), '0')))
'''
        for command in ['systemctl', 'cat', 'modprobe', 'udevadm', 'timeout']:
            put('bin/' + command, stub).chmod(0o755)
        script = source
        for prefix in ['/sys/', '/proc/', '/usr/', '/opt/', '/run/', '/dev/']:
            script = script.replace(prefix, f'{root}{prefix}')
        path = put('gpu-up', script)
        mutate(root)
        result = subprocess.run(['sh', str(path)], text=True, capture_output=True,
                                env=dict(os.environ, TEST_ROOT=str(root), PATH=str(root/'bin')+os.pathsep+os.environ['PATH'], **(options or {})))
        assert (result.returncode == 0) == success, (name, result.stdout, result.stderr)
        assert (root/'run/yoga-gpu.env').exists() == success, (name, 'environment published without success')
        if preflight:
            assert not (root/'run/calls').read_text(), (name, 'hardware commands before preflight')
        print('PASS', name)


run('valid boot publishes environment after capped draw', success=True)
for name, path, value in [
    ('opt-in absent', 'proc/cmdline', 'quiet\n'),
    ('wrong board', 'sys/firmware/devicetree/base/compatible', 'other\0'),
    ('KMS not separated', 'sys/module/msm/parameters/separate_gpu_kms', '0\n'),
]:
    run(name, lambda root, p=path, v=value: (root/p).write_text(v), preflight=True)
run('USB3 inactive', options={'SERVICE_FAIL': '1'}, preflight=True)
run('desktop active', options={'GDM_STATE': 'active'}, preflight=True)
run('GPU already bound', lambda root: (root/'sys/bus/platform/devices/3d00000.gpu/driver').symlink_to('/mock/adreno'), preflight=True)
run('Mesa file missing', lambda root: (root/files[0]).unlink(), preflight=True)
run('firmware missing', lambda root: (root/files[-1]).unlink(), preflight=True)
run('module load failure', options={'FAIL_MODPROBE': '1'})
run('dependency remains unbound', lambda root: (root/'sys/bus/platform/devices/3d64000.clock-controller/driver').unlink())
run('unexpected OPPs', lambda root: (root/'sys/class/devfreq/3d00000.gpu/available_frequencies').write_text('410000000\n'))
run('cap readback mismatch', options={'BAD_CAP': '1'})
run('render node absent', lambda root: (root/'sys/bus/platform/devices/3d00000.gpu/drm/renderD128/dev').unlink())
run('udev initialization failed', options={'FAIL_UDEVADM': '1'})
run('EGL validation failed', options={'FAIL_TIMEOUT': '1'})
run('EGL validation timed out', options={'FAIL_TIMEOUT': '124'})
run('stale environment removed on failed restart', lambda root: (root/'run/yoga-gpu.env').write_text('old-success\n'), options={'FAIL_TIMEOUT': '1'})

def extra_render(root):
    path = root/'sys/bus/platform/devices/3d00000.gpu/drm/renderD129'
    path.mkdir()
    (path/'dev').write_text('226:129\n')

run('ambiguous render nodes', extra_render)

# GDM must fail closed after an attempted GPU boot, without starting the USB chain.
dropin = (here/'90-yoga-mesa.conf').read_text()
assert 'After=yoga-gpu.service' in dropin
gate = next(line.removeprefix('ExecStartPre=') for line in dropin.splitlines() if line.startswith('ExecStartPre='))
with tempfile.TemporaryDirectory(prefix='yoga-gdm-review-') as directory:
    root = Path(directory)
    ctl = root/'systemctl'
    ctl.write_text('#!/bin/sh\nexit "${GPU_FAILED:-0}"\n')
    ctl.chmod(0o755)
    for flag, active, envfile in [(False, False, False), (True, True, True), (True, False, True), (True, True, False)]:
        (root/'cmdline').write_text('yoga.gpu=1' if flag else 'quiet')
        (root/'gpu.env').write_text('LD_LIBRARY_PATH=/mock' if envfile else '')
        command = gate.replace('/proc/cmdline', str(root/'cmdline')).replace('/run/yoga-gpu.env', str(root/'gpu.env'))
        command = command.replace('/usr/bin/systemctl', str(ctl))
        result = subprocess.run(shlex.split(command), capture_output=True, text=True,
                                env=dict(os.environ, PATH=str(root)+os.pathsep+os.environ['PATH'], GPU_FAILED='0' if active else '1'))
        assert (result.returncode == 0) == (not flag or active and envfile), (flag, active, envfile, result.stderr)
        print(f'PASS GDM gate flag={flag} GPU={active} environment={envfile}')
