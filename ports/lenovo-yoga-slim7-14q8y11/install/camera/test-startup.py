#!/usr/bin/env python3
"""Test startup guards offline; all target paths and mutating commands are mocked.

Run: python3 install/camera/test-startup.py [path/to/yoga-camera-up]
Requires Python 3, /bin/sh and the standard Linux text utilities used by startup.
Does not access the notebook, load modules, call systemd or write to real sysfs.
The media fixture follows the symlink layout observed on the Yoga in November 2026.
"""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

if len(sys.argv) > 2:
    raise SystemExit(f'usage: {sys.argv[0]} [path/to/yoga-camera-up]')
source_path = Path(sys.argv[1]) if len(sys.argv) == 2 else Path(__file__).with_name('yoga-camera-up')
source = source_path.read_text()
modules = 'qcom_pm8008 qcom_pm8008_regulator camcc_glymur i2c_qcom_cci phy_qcom_mipi_csi2 ov08x40 vd55g0 system_heap cma_heap qcom_camss leds_qcom_flash'.split()

def run_case(name, mutate=lambda root: None, overrides=None, expected=True, calls=None):
    with tempfile.TemporaryDirectory(prefix='yoga-startup-review-') as directory:
        root = Path(directory)
        def put(path, text):
            target = root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(text)
            return target
        put('proc/cmdline', 'quiet yoga.camera=1\n')
        put('sys/firmware/devicetree/base/compatible', 'lenovo,yoga-slim7x-gen11-x2plus-diag\0qcom,glymur\0')
        put('sys/class/drm/card1-eDP-1/status', 'connected\n')
        for pci in ('0004:01:00.0', '0005:01:00.0'):
            put(f'sys/bus/pci/devices/{pci}/power/runtime_status', 'active\n')
        put('sys/kernel/debug/regulator/regulator_summary', 'vreg_l1f1 1 1 0 normal 912mV\nvreg_l4f1 1 1 0 normal 1200mV\nvreg_bob1_e0 1 1 0 normal 3416mV\n')
        for bus, driver in ((5, 'vd55g0'), (6, 'ov08x40')):
            path = root / f'sys/bus/i2c/devices/{bus}-0010'
            path.mkdir(parents=True)
            (path / 'driver').symlink_to('/mock/drivers/' + driver)
        # Target sysfs observed on hardware: media is a bus, not a class.
        platform = root / 'sys/devices/platform/soc@0/acb6000.isp'
        (platform / 'media0').mkdir(parents=True)
        (platform / 'media0/dev').write_text('503:0\n')
        driver = root / 'sys/bus/platform/drivers/qcom-camss'
        driver.mkdir(parents=True)
        (platform / 'driver').symlink_to('../../../../bus/platform/drivers/qcom-camss')
        media_bus = root / 'sys/bus/media/devices'
        media_bus.mkdir(parents=True)
        (media_bus / 'media0').symlink_to('../../../devices/platform/soc@0/acb6000.isp/media0')
        for name_device in ('media0', 'dma_heap/system', 'dma_heap/default_cma_region'):
            path = root / 'dev' / name_device
            path.parent.mkdir(parents=True, exist_ok=True)
            path.symlink_to('/dev/null')
        put('sys/class/leds/ir:flash/brightness', 'pending\n')
        put('sys/class/leds/ir:flash/flash_strobe', 'pending\n')
        put('sys/kernel/debug/regmap/0-01/range', '0-ffff\n')
        regs = put('sys/kernel/debug/regmap/0-01/registers', '')
        with regs.open('r+b') as handle:
            for reg in (0xee46, 0xee4e):
                handle.seek(reg * 9)
                handle.write(f'{reg:04x}: 00\n'.encode())
        stub = '#!' + sys.executable + '''
import os, pathlib, sys
cmd=pathlib.Path(sys.argv[0]).name
if cmd=='uname': print('7.4.0-rc1-yoga-kalambo+')
elif cmd=='modinfo':
    module=sys.argv[-1]
    if module==os.getenv('MISSING_MODULE'): sys.exit(1)
    if sys.argv[1]=='-n': print('/lib/modules/release/'+('kernel' if module==os.getenv('STOCK_MODULE') else 'updates')+'/'+module+'.ko')
    else: print(('wrong' if module==os.getenv('BAD_MAGIC') else '7.4.0-rc1-yoga-kalambo+')+' SMP preempt mod_unload aarch64')
elif cmd=='modprobe':
    with open(os.environ['TRACE'],'a') as handle: handle.write(sys.argv[1]+'\\n')
    with open(os.environ['EVENT_TRACE'],'a') as handle: handle.write('modprobe '+sys.argv[1]+'\\n')
    sys.exit(1 if sys.argv[1]==os.getenv('FAIL_MODULE') else 0)
elif cmd=='udevadm':
    assert sys.argv[1:4]==['wait', '--timeout=10', '--initialized=yes'], sys.argv
    assert len(sys.argv)==6, sys.argv
    assert sys.argv[4].endswith('/dev/dma_heap/system'), sys.argv
    assert sys.argv[5].endswith('/dev/dma_heap/default_cma_region'), sys.argv
    with open(os.environ['EVENT_TRACE'],'a') as handle: handle.write('udev-wait\\n')
    sys.exit(1 if os.getenv('UDEV_WAIT_FAIL') else 0)
elif cmd=='systemctl': sys.exit(1 if sys.argv[-1]==os.getenv('INACTIVE_SERVICE') else 0)
elif cmd=='sleep': pass
else: raise RuntimeError(cmd)
'''
        for command in ('uname', 'modinfo', 'modprobe', 'systemctl', 'sleep', 'udevadm'):
            put('bin/' + command, stub).chmod(0o755)
        script = source
        for prefix in ('/sys/', '/proc/', '/dev/'):
            script = script.replace(prefix, str(root) + prefix)
        test_script = put('script.sh', script)
        mutate(root)
        env = os.environ.copy()
        env.update(PATH=str(root / 'bin') + ':' + env['PATH'], TRACE=str(root / 'trace'), EVENT_TRACE=str(root / 'events'))
        env.update(overrides or {})
        process = subprocess.run(['/bin/sh', str(test_script)], env=env, capture_output=True, text=True, timeout=10)
        actual_calls = (root / 'trace').read_text().splitlines() if (root / 'trace').exists() else []
        assert (process.returncode == 0) == expected, (name, process.returncode, process.stderr, process.stdout)
        if calls is not None:
            assert actual_calls == calls, (name, actual_calls, calls)
        if expected:
            events = (root / 'events').read_text().splitlines()
            assert events == ['modprobe ' + m for m in modules[:9]] + ['udev-wait'] + ['modprobe ' + m for m in modules[9:]], (name, events)
        if name == 'first_off_write_fails':
            assert (root / 'sys/class/leds/ir:flash/brightness').read_text() == '0\n', name
        print(f'PASS {name}: exit={process.returncode}, module_calls={len(actual_calls)}')

run_case('healthy', calls=modules)
run_case('missing_cmdline', lambda r: (r / 'proc/cmdline').write_text('quiet\n'), expected=False, calls=[])
run_case('wrong_board', lambda r: (r / 'sys/firmware/devicetree/base/compatible').write_text('wrong\0'), expected=False, calls=[])
run_case('video_inactive', overrides={'INACTIVE_SERVICE':'yoga-video.service'}, expected=False, calls=[])
run_case('bob_voltage_wrong', lambda r: (r / 'sys/kernel/debug/regulator/regulator_summary').write_text('vreg_l1f1 1 1 0 normal 912mV\nvreg_l4f1 1 1 0 normal 1200mV\nvreg_bob1_e0 1 1 0 normal 3400mV\n'), expected=False, calls=[])
run_case('cci_preloaded', lambda r: (r / 'sys/module/i2c_qcom_cci').mkdir(parents=True), expected=False, calls=[])
run_case('flash_preloaded', lambda r: (r / 'sys/module/leds_qcom_flash').mkdir(parents=True), expected=False, calls=[])
run_case('stock_cci', overrides={'STOCK_MODULE':'i2c_qcom_cci'}, expected=False, calls=[])
run_case('stock_camss', overrides={'STOCK_MODULE':'qcom_camss'}, expected=False, calls=[])
run_case('last_module_missing', overrides={'MISSING_MODULE':'cma_heap'}, expected=False, calls=[])
run_case('wrong_flash_vermagic', overrides={'BAD_MAGIC':'leds_qcom_flash'}, expected=False, calls=[])
run_case('module_load_error', overrides={'FAIL_MODULE':'phy_qcom_mipi_csi2'}, expected=False, calls=modules[:5])
def fail_first_off(root):
    path = root / 'sys/class/leds/ir:flash/flash_strobe'
    path.unlink()
    path.mkdir()
run_case('first_off_write_fails', fail_first_off, expected=False, calls=modules)
def active_flash(root):
    with (root / 'sys/kernel/debug/regmap/0-01/registers').open('r+b') as handle:
        handle.seek(0xee46 * 9)
        handle.write(b'ee46: 80\n')
run_case('flash_still_enabled', active_flash, expected=False, calls=modules)
run_case('sensor_not_bound', lambda r: (r / 'sys/bus/i2c/devices/5-0010/driver').unlink(), expected=False, calls=modules[:9])
run_case('heap_missing', lambda r: (r / 'dev/dma_heap/system').unlink(), expected=False, calls=modules[:9])
run_case('udev_wait_failed', overrides={'UDEV_WAIT_FAIL': '1'}, expected=False, calls=modules[:9])
run_case('media_missing', lambda r: (r / 'sys/bus/media/devices/media0').unlink(), expected=False, calls=modules)
def wrong_media_driver(root):
    driver = root / 'sys/devices/platform/soc@0/acb6000.isp/driver'
    driver.unlink()
    target = root / 'sys/bus/platform/drivers/other-driver'
    target.mkdir(parents=True)
    driver.symlink_to('../../../../bus/platform/drivers/other-driver')
run_case('wrong_media_driver', wrong_media_driver, expected=False, calls=modules)
run_case('media_dev_node_missing', lambda r: (r / 'dev/media0').unlink(), expected=False, calls=modules)
