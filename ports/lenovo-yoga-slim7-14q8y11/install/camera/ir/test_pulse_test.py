"""Offline flow tests. No sysfs, GPIO, I2C or PMIC access is performed."""
import builtins
import contextlib
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('pulse_test', Path(__file__).with_name('pulse-test.py'))
pulse = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pulse)


class PulseFlowTest(unittest.TestCase):
    def run_flow(self, fire=False, bad_timer=False, sleep_error=False, off_error=False):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            led = root / 'leds/ir:flash'
            dt = root / 'dt'
            led.mkdir(parents=True)
            dt.mkdir()
            (dt / 'compatible').write_bytes(b'lenovo,yoga-slim7x-gen11-x2plus-diag\0qcom,kalambo\0')
            (dt / 'model').write_text('Lenovo Yoga Slim 7x Gen 11 X2 Plus (diagnostic)\0')
            for name, value in {'max_flash_brightness': '100000', 'max_flash_timeout': '10000',
                                'trigger': '[none]', 'flash_fault': ''}.items():
                (led / name).write_text(value)
            regs = dict.fromkeys(pulse.REGISTERS, 0)
            regs.update({0x0105: 0x5d, 0xee00: 1, 0xee04: 0x18, 0xee05: 7})
            journal = []
            real_write = Path.write_text
            real_open = builtins.open
            fired = False
            off_failed = False

            def path_factory(value):
                value = str(value)
                if value.startswith('/sys/class/leds'):
                    return root / ('leds' + value[len('/sys/class/leds'):])
                return Path(value)

            def open_fake(file, *args, **kwargs):
                if file == '/run/yoga-ir-pulse-test.lock':
                    file = root / 'lock'
                return real_open(file, *args, **kwargs)

            def write_fake(path, data, *args, **kwargs):
                nonlocal fired, off_failed
                if path.parent != led:
                    return real_write(path, data, *args, **kwargs)
                value = int(data)
                journal.append((path.name, value))
                if path.name == 'brightness':
                    self.assertEqual(value, 0)
                    regs[0xee46] = regs[0xee4e] = 0
                    regs[0xee3e] = regs[0xee41] = 0
                if path.name == 'flash_strobe':
                    if value == 1:
                        fired = True
                        regs[0xee46], regs[0xee4e] = 0x80, 9
                    else:
                        if off_error and fired and not off_failed:
                            off_failed = True
                            raise OSError('injected OFF failure')
                        regs[0xee46] = regs[0xee4e] = 0
                    regs[0xee3e] = regs[0xee41] = 0x81 if bad_timer else 0x80
                    regs[0xee42] = regs[0xee45] = 1
                    regs[0xee4a] = regs[0xee4d] = 1
                return len(data)

            def sleep_fake(duration):
                self.assertEqual(duration, .03)
                if sleep_error:
                    raise InterruptedError('injected signal')

            argv = ['pulse-test.py'] + (['--fire'] if fire else [])
            error = None
            with patch.object(pulse, 'DT', dt), patch.object(pulse, 'Path', path_factory), \
                 patch.object(pulse, 'snapshot', side_effect=lambda: dict(regs)), \
                 patch.object(Path, 'write_text', write_fake), patch('builtins.open', open_fake), \
                 patch('sys.argv', argv), patch.object(pulse.signal, 'signal'), \
                 patch.object(pulse.time, 'sleep', side_effect=sleep_fake), \
                 contextlib.redirect_stdout(io.StringIO()):
                try:
                    pulse.main()
                except (RuntimeError, InterruptedError) as exc:
                    error = exc
            self.assertEqual(regs[0xee46] & 0x80, 0)
            self.assertEqual(regs[0xee4e] & 0xf, 0)
            self.assertEqual(journal[-2:], [('flash_strobe', 0), ('brightness', 0)])
            return journal, error

    def test_default_never_fires(self):
        journal, error = self.run_flow()
        self.assertIsNone(error)
        self.assertNotIn(('flash_strobe', 1), journal)

    def test_exactly_one_pulse(self):
        journal, error = self.run_flow(fire=True)
        self.assertIsNone(error)
        self.assertEqual(journal.count(('flash_strobe', 1)), 1)

    def test_wrong_timer_blocks_fire(self):
        journal, error = self.run_flow(fire=True, bad_timer=True)
        self.assertIsInstance(error, RuntimeError)
        self.assertNotIn(('flash_strobe', 1), journal)

    def test_interrupt_still_cleans_up(self):
        journal, error = self.run_flow(fire=True, sleep_error=True)
        self.assertIsInstance(error, InterruptedError)
        self.assertEqual(journal.count(('flash_strobe', 1)), 1)

    def test_first_off_error_still_uses_second_off(self):
        journal, error = self.run_flow(fire=True, off_error=True)
        self.assertIsInstance(error, RuntimeError)
        self.assertEqual(journal.count(('flash_strobe', 1)), 1)


if __name__ == '__main__':
    unittest.main()
