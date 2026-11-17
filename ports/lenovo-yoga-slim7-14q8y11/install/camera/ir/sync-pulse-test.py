#!/usr/bin/env python3
"""One hardware-synchronized IR exposure using the private diagnostic modules.

Default performs checks with the illuminator OFF. --fire holds the V4L2 flash
fd while v4l2-ctl captures one frame; sensor firmware limits the frame count.
No torch, timed trigger loop, direct register writes or unbind is used here.
"""
import argparse
import fcntl
import importlib.util
import os
import re
from pathlib import Path
import signal
import struct
import subprocess
import time

spec = importlib.util.spec_from_file_location('pulse', Path(__file__).with_name('pulse-test.py'))
pulse = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pulse)
pulse.REGISTERS += (0xee67,)
require = pulse.require
LED = Path('/sys/class/leds/ir:flash')
BASE = 0x009c0900
MODE, SOURCE, TIMEOUT, INTENSITY, FAULT = (BASE + n for n in (1, 2, 6, 7, 10))
EXPOSURE_AUTO = 0x009a0901
EXPOSURE = 0x00980911
VIDIOC_G_CTRL, VIDIOC_S_CTRL = 0xc008561b, 0xc008561c


def ctrl(fd, cid, value=None):
    data = bytearray(struct.pack('Ii', cid, 0 if value is None else value))
    fcntl.ioctl(fd, VIDIOC_G_CTRL if value is None else VIDIOC_S_CTRL, data, True)
    return struct.unpack('Ii', data)[1]


def named_node(path, prefix):
    require(path.parent == Path('/dev') and path.name.startswith('v4l-subdev'),
            'expected V4L2 subdevice path')
    name = (Path('/sys/class/video4linux') / path.name / 'name').read_text().strip()
    require(name.startswith(prefix), f'unexpected subdevice identity: {name}')


def check_prepared(values, armed=False):
    if not armed:
        # The diagnostic OFF callbacks preserve previous current/timer registers.
        # The external-arm callback programs them before enabling the gates;
        # the armed check below verifies their physical readback before capture.
        pulse.check_off(values)
        return
    require(values[0xee3e] == values[0xee41] == 0x80, 'both timers must be 10 ms')
    require(values[0xee42] & 0x7f == values[0xee45] & 0x7f == 1,
            'expected 25 mA per physical channel')
    require(values[0xee49] & 9 == 0, 'expected 12.5 mA resolution')
    require(values[0xee4a] & 0x7f == values[0xee4d] & 0x7f == 5,
            'unexpected strobe source/polarity/input selection')
    require(values[0xee67] & 1 == 0, 'Windows HW-strobe configuration requires ee67 bit0=0')
    require(values[0xee46] & 0x80 and values[0xee4e] & 0x0f == 9,
            'expected module and only channels 1+4 armed')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sensor', type=Path, required=True)
    parser.add_argument('--flash', type=Path, required=True)
    parser.add_argument('--video', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--fire', action='store_true')
    args = parser.parse_args()
    require((pulse.DT / 'model').read_text().rstrip('\0') ==
            'Lenovo Yoga Slim 7x Gen 11 X2 Plus (diagnostic)', 'unexpected model')
    require(Path('/sys/module/vd55g0/parameters/diagnostic_one_frame').read_text().strip() == 'Y',
            'private one-frame driver must be loaded with diagnostic_one_frame=1')
    require(Path('/sys/module/leds_qcom_flash/parameters/diagnostic_windows_ee67').read_text().strip() == 'Y',
            'private flash driver requires diagnostic_windows_ee67=1')
    named_node(args.sensor, 'vd55g0 ')
    named_node(args.flash, 'ir:flash')
    require(args.video.parent == Path('/dev') and args.video.name.startswith('video'),
            'expected capture video device')
    device = (Path('/sys/class/video4linux') / args.video.name / 'device').resolve(strict=True)
    require(any((node / 'driver').is_symlink() and
                (node / 'driver').resolve().name == 'qcom-camss'
                for node in (device, *device.parents)), 'capture device is not qcom-camss')
    fmt = subprocess.run(['v4l2-ctl', '-d', str(args.video), '--get-fmt-video'],
                         capture_output=True, text=True, timeout=3, check=True).stdout
    require(re.search(r'Width/Height\s*:\s*640/480\b', fmt) and
            re.search(r"Pixel Format\s*:\s*'Y10P'", fmt) and
            re.search(r'Bytes per Line\s*:\s*800\b', fmt),
            'configure capture as 640x480 Y10P with stride800 first')
    require(not args.output.exists(), 'refusing to overwrite a previous capture')
    require(int((LED / 'max_flash_brightness').read_text()) == 50000 and
            int((LED / 'max_flash_timeout').read_text()) == 10000,
            'requires diagnostic DT limits of 50 mA / 10 ms')
    require('[none]' in (LED / 'trigger').read_text(), 'automatic LED trigger is active')
    # Read the loaded DT's actual sensor/flash wiring instead of inferring from names.
    sensors = list(pulse.DT.glob('**/camera@10/st,leds'))
    require(len(sensors) == 1 and sensors[0].read_bytes() == struct.pack('>I', 0),
            'expected exactly VD55G0 GPIO0 in st,leds')
    with open('/run/yoga-ir-pulse-test.lock', 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(sig, pulse.interrupted)
        baseline = pulse.snapshot()
        require(baseline[0x0105] == 0x5d and baseline[0xee00] == 1 and
                baseline[0xee04] == 0x18 and baseline[0xee05] == 7,
                'unexpected PMH0101/flash revision')
        pulse.check_off(baseline)
        sensor_fd = flash_fd = None
        child = None
        try:
            # Sysfs preparation runs before V4L2 takes exclusive LED control.
            for attr, value in [('brightness', 0), ('flash_strobe', 0),
                                ('flash_brightness', 50000), ('flash_timeout', 10000),
                                ('flash_strobe', 0)]:
                (LED / attr).write_text(f'{value}\n')
            require(int((LED / 'flash_brightness').read_text()) == 50000 and
                    int((LED / 'flash_timeout').read_text()) == 10000,
                    'sysfs did not retain the requested 50 mA / 10 ms settings')
            require(not (LED / 'flash_fault').read_text().strip(), 'pre-existing flash fault')
            check_prepared(pulse.snapshot())
            sensor_fd = os.open(args.sensor, os.O_RDWR)
            require(ctrl(sensor_fd, EXPOSURE_AUTO) == 1, 'set sensor manual exposure first')
            require(1 <= ctrl(sensor_fd, EXPOSURE) <= 1166, 'manual exposure exceeds 10 ms')
            ctrl(sensor_fd, MODE, 0)
            flash_fd = os.open(args.flash, os.O_RDWR)
            ctrl(flash_fd, MODE, 0)
            ctrl(flash_fd, INTENSITY, 50000)
            ctrl(flash_fd, TIMEOUT, 10000)
            ctrl(flash_fd, SOURCE, 1)  # Cached while MODE is NONE.
            require(ctrl(flash_fd, INTENSITY) == 50000 and
                    ctrl(flash_fd, TIMEOUT) == 10000 and
                    ctrl(flash_fd, SOURCE) == 1 and ctrl(flash_fd, MODE) == 0,
                    'V4L2 did not retain OFF/external/50 mA/10 ms settings')
            require(ctrl(flash_fd, FAULT) == 0, 'V4L2 flash reports a pre-existing fault')
            checked_off = pulse.snapshot()
            check_prepared(checked_off)
            pulse.report('checked_off', checked_off)
            if not args.fire:
                return
            ctrl(sensor_fd, MODE, 1)  # Strobe envelope; inactive until STREAMING.
            ctrl(flash_fd, MODE, 1)   # External mode, no software pulse.
            armed = pulse.snapshot()
            check_prepared(armed, armed=True)
            pulse.report('armed_external', armed, monotonic=time.monotonic())
            command = ['v4l2-ctl', '-d', str(args.video), '--stream-mmap=4',
                       '--stream-count=1', '--stream-poll', f'--stream-to={args.output}']
            child = subprocess.Popen(command)
            result = child.wait(timeout=8)
            require(result == 0, f'capture failed with status {result}')
            require(args.output.stat().st_size == 384000,
                    'expected exactly one RAW10 packed 640x480 frame, stride 800')
            pulse.report('after_frame', pulse.snapshot(), monotonic=time.monotonic(),
                         faults=ctrl(flash_fd, FAULT))
        finally:
            errors = []
            # Disarm first, even on timeout. Keep trying every OFF/close path.
            for fd, cid, value in [(flash_fd, MODE, 0), (sensor_fd, MODE, 0),
                                   (flash_fd, SOURCE, 0)]:
                if fd is not None:
                    try:
                        ctrl(fd, cid, value)
                    except Exception as exc:
                        errors.append(f'control {cid:#x}: {exc}')
            if child is not None and child.poll() is None:
                child.kill()
                child.wait()
            for fd in (flash_fd, sensor_fd):
                if fd is not None:
                    try:
                        os.close(fd)
                    except Exception as exc:
                        errors.append(f'close: {exc}')
            for attr in ('flash_strobe', 'brightness'):
                try:
                    (LED / attr).write_text('0\n')
                except Exception as exc:
                    errors.append(f'{attr}: {exc}')
            final = pulse.snapshot()
            pulse.report('cleanup', final, errors=errors)
            pulse.check_off(final)
            require(final[0xee67] & 1 == baseline[0xee67] & 1,
                    'ee67 bit0 was not restored to its baseline value')
            require(not errors, 'cleanup reported errors: ' + '; '.join(errors))


if __name__ == '__main__':
    main()
