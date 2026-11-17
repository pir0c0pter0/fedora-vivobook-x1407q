"""Offline synchronization-helper checks; never accesses hardware."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('sync_pulse', Path(__file__).with_name('sync-pulse-test.py'))
sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sync)


class SyncRegisterTest(unittest.TestCase):
    def armed(self):
        values = dict.fromkeys(sync.pulse.REGISTERS, 0)
        values.update({0xee3e: 0x80, 0xee41: 0x80, 0xee42: 1, 0xee45: 1,
                       0xee4a: 5, 0xee4d: 5, 0xee46: 0x80, 0xee4e: 9})
        return values

    def test_off_accepts_previous_current_timer_source_and_saved_bit(self):
        # Observed V2 boot: neither OFF callback programs current or timeout.
        values = self.armed()
        values.update({0xee3e: 0x93, 0xee41: 0x93, 0xee42: 0, 0xee45: 0,
                       0xee46: 0, 0xee4e: 0, 0xee67: 1})
        sync.check_prepared(values)
        with self.assertRaises(RuntimeError):
            sync.check_prepared(values, armed=True)
        values.update({0xee3e: 0, 0xee41: 0, 0xee4a: 1, 0xee4d: 1, 0xee67: 0})
        sync.check_prepared(values)

    def test_off_rejects_either_enabled_gate(self):
        for address, value in ((0xee46, 0x80), (0xee4e, 1), (0xee4e, 8)):
            with self.subTest(address=address, value=value):
                values = self.armed()
                values.update({0xee46: 0, 0xee4e: 0, address: value})
                with self.assertRaises(RuntimeError):
                    sync.check_prepared(values)

    def test_armed_requires_exact_programmed_settings(self):
        sync.check_prepared(self.armed(), armed=True)
        for address, value in ((0xee3e, 0x93), (0xee41, 0),
                               (0xee42, 0), (0xee45, 2), (0xee49, 1), (0xee49, 8),
                               (0xee4a, 1), (0xee4d, 0x15), (0xee67, 1),
                               (0xee46, 0), (0xee4e, 1), (0xee4e, 0xf)):
            with self.subTest(address=address, value=value):
                values = self.armed()
                values[address] = value
                with self.assertRaises(RuntimeError):
                    sync.check_prepared(values, armed=True)


if __name__ == '__main__':
    unittest.main()
