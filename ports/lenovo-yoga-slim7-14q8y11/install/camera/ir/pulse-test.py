#!/usr/bin/env python3
"""Prepare, or emit one 50 mA / 10 ms test pulse on the Yoga X2 Plus.

Requires the test DTS and corrected qcom flash driver. Default is preparation
only. --fire emits exactly one pulse. Never uses torch brightness above zero.
Debugfs register access is read-only and limited to named configuration bytes.
"""
import argparse
import fcntl
import json
import os
from pathlib import Path
import signal
import time

DT = Path('/sys/firmware/devicetree/base')
REGMAP = Path('/sys/kernel/debug/regmap/0-01')
REGISTERS = (0x0105, 0xee00, 0xee04, 0xee05, 0xee3e, 0xee41,
             0xee42, 0xee45, 0xee46, 0xee49, 0xee4a, 0xee4d, 0xee4e)


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def snapshot():
    # This regmap has reg_bits=16, val_bits=8, max_register=0xffff and no holes.
    # Validate every addressed line; do not dump unrelated PMIC registers.
    require((REGMAP / 'range').read_text().strip() == '0-ffff',
            'unexpected regmap range')
    values = {}
    fd = os.open(REGMAP / 'registers', os.O_RDONLY)
    try:
        for reg in REGISTERS:
            line = os.pread(fd, 9, reg * 9).decode('ascii')
            require(len(line) == 9 and line[:6] == f'{reg:04x}: ',
                    f'unexpected regmap layout at {reg:04x}')
            values[reg] = int(line[6:8], 16)
    finally:
        os.close(fd)
    return values


def report(stage, registers, **extra):
    print(json.dumps({'stage': stage,
                      'registers': {f'{r:04x}': f'{v:02x}' for r, v in registers.items()},
                      **extra}), flush=True)


def check_off(values):
    require(values[0xee46] & 0x80 == 0, 'flash module is not OFF')
    require(values[0xee4e] & 0x0f == 0, 'one or more flash channels are not OFF')


def interrupted(signum, frame):
    raise InterruptedError(f'signal {signum}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--led', type=Path, default=Path('/sys/class/leds/ir:flash'))
    parser.add_argument('--fire', action='store_true')
    args = parser.parse_args()
    compat = (DT / 'compatible').read_bytes().split(b'\0')
    model = (DT / 'model').read_text().rstrip('\0')
    require(b'lenovo,yoga-slim7x-gen11-x2plus-diag' in compat or
            model == 'Lenovo Yoga Slim 7x Gen 11 X2 Plus (diagnostic)',
            'this test is restricted to the Yoga X2 Plus diagnostic DT')
    require(args.led.parent == Path('/sys/class/leds'), 'use a LED class path')
    require(args.led.is_dir(), 'requested LED class device is absent')

    def read(name):
        return (args.led / name).read_text().strip()

    def write(name, value):
        (args.led / name).write_text(f'{value}\n')

    require(int(read('max_flash_brightness')) == 100000,
            'expected test cap of 100000 microamps')
    require(int(read('max_flash_timeout')) == 10000,
            'expected test timeout cap of 10000 microseconds')
    if (args.led / 'trigger').exists():
        require('[none]' in read('trigger'), 'automatic LED trigger is active')

    with open('/run/yoga-ir-pulse-test.lock', 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(sig, interrupted)
        baseline = snapshot()
        require(baseline[0x0105] == 0x5d and baseline[0xee00] == 1 and
                baseline[0xee04] == 0x18 and baseline[0xee05] == 7,
                'expected PMH0101 model 5d, flash revision 1/type 18/subtype 7')
        report('baseline', baseline, model=model)
        try:
            write('brightness', 0)
            write('flash_strobe', 0)
            check_off(snapshot())
            require(not read('flash_fault'), 'pre-existing flash fault')
            write('flash_brightness', 50000)
            write('flash_timeout', 10000)
            # Setters cache their values; strobe OFF applies both to hardware.
            write('flash_strobe', 0)
            prepared = snapshot()
            check_off(prepared)
            require(prepared[0xee3e] == 0x80 and prepared[0xee41] == 0x80,
                    '10 ms hardware timeout is not programmed on both channels')
            require(prepared[0xee42] & 0x7f == 1 and prepared[0xee45] & 0x7f == 1,
                    '25 mA per channel target is not programmed')
            require(prepared[0xee49] & 9 == 0, 'expected 12.5 mA flash resolution')
            require(prepared[0xee4a] & 7 == 1 and prepared[0xee4d] & 7 == 1,
                    'expected active-high software strobe')
            report('prepared', prepared, current_microamp=50000, timeout_microsecond=10000)
            if args.fire:
                write('flash_strobe', 1)
                # Hardware bounds the pulse. This wait is solely for observation.
                time.sleep(0.03)
                report('after_pulse', snapshot(), faults=read('flash_fault'))
        finally:
            errors = []
            # Try both OFF paths even if the first one fails.
            for attr in ('flash_strobe', 'brightness'):
                try:
                    write(attr, 0)
                except Exception as exc:
                    errors.append(f'{attr}: {exc}')
            final = snapshot()
            report('cleanup', final, errors=errors)
            check_off(final)
            require(not errors, 'OFF writes failed: ' + '; '.join(errors))


if __name__ == '__main__':
    main()
