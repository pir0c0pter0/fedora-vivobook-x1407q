#!/usr/bin/env python3
"""Synthetic decoder tests; no proprietary input or camera required."""
import copy
import math
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib

from chromatix32 import Chromatix32, FormatError, cct_nodes, yaml_candidate


def fixture(branching=1):
    # Two deliberately unequal matrices make transposition and mixing visible.
    matrices = [(1.8, -.5, -.3, -.1, 1.3, -.2, -.4, -.6, 2.),
                (1.4, -.1, -.3, -.3, 1.5, -.2, -.2, -.3, 1.5)]
    items = [
        (1, "revision", b"0\0"),
        (2, "control_var_type", struct.pack("<5I", 2, 5, 100, 0, 6)),
        (3, "region", b""), (4, "trigger", b""),
    ]
    for i in range(4):
        items.append((10 + i, "mod_cc13_trigger_data" if i == 0 else "trigger",
                      struct.pack("<ffIIII", 0, 1, 2 if i == 3 else branching,
                                  11 + i, 0, 3) * branching))
    items += [(14, "trigger", struct.pack("<ffIIIIffIIII", 2000, 2500, 0, 4, 1, 20,
                                         4000, 6000, 0, 4, 1, 21))]
    for i, matrix in enumerate(matrices):
        items.append((20 + i, "region", struct.pack("<9f3i", *matrix, 0, 0, 0)))
    items += [(30, "cc13_ipe_v2", struct.pack("<8I2f3I", 1, 1, 3, 1, 2, 1, 5, 2,
                                             1., 100., 0, branching, 10))]
    payload = bytearray()
    symbols = bytearray()
    for sid, name, data in items:
        symbols += struct.pack("<I32s5I", sid, name.encode(),
                               0x30001 if sid == 30 else 0, 1 if sid == 30 else 0,
                               4 if sid == 30 else 0xFFFFFFFF, len(payload), len(data))
        payload += data
    raw = bytearray(0xCC)
    raw[:20] = b"QTI Chromatix Header"
    struct.pack_into("<II", raw, 0x20, 3, 1)
    raw[0x28:0x2C] = b"test"
    struct.pack_into("<II", raw, 0xA0, 0xA8, 3)
    pos = 0xCC
    for idx, data in enumerate((symbols, payload, b"")):
        struct.pack_into("<III", raw, 0xA8 + idx * 12, idx, pos, len(data))
        pos += len(data)
    raw += symbols + payload
    struct.pack_into("<I", raw, 0x1C, len(raw))
    return checksum(raw + bytes(4))


def checksum(raw):
    raw = bytearray(raw)
    struct.pack_into("<I", raw, len(raw) - 4, zlib.crc32(raw[:-4]))
    return bytes(raw)


class DecoderTests(unittest.TestCase):
    def setUp(self):
        self.raw = fixture()
        self.file = Chromatix32(self.raw)
        self.module = self.file.cc13(30)

    def mutate_symbol(self, sid, offset, fmt, *values):
        raw = bytearray(self.raw)
        struct.pack_into(fmt, raw, self.file.location(sid)["file_offset"] + offset, *values)
        return Chromatix32(checksum(raw))

    def test_references_preserve_order_and_offsets(self):
        leaves = self.module["leaves"]
        self.assertEqual(len(leaves), 2)
        self.assertEqual([p["symbol_id"] for p in leaves[0]["path"]], [10, 11, 12, 13, 14])
        self.assertAlmostEqual(leaves[0]["ccm"][1], -.5)
        self.assertAlmostEqual(leaves[0]["ccm"][3], -.1)
        self.assertEqual(leaves[0]["offsets"], (0, 0, 0))

    def test_crc_rejected(self):
        raw = bytearray(self.raw)
        raw[-10] ^= 1
        with self.assertRaisesRegex(FormatError, "CRC"):
            Chromatix32(raw)

    def test_truncated_file_rejected(self):
        for n in (0, 20, 0xCC, len(self.raw) - 1):
            with self.assertRaises(FormatError):
                Chromatix32(self.raw[:n])

    def test_section_overlap_rejected(self):
        raw = bytearray(self.raw)
        struct.pack_into("<I", raw, 0xB8, 0xCC)
        with self.assertRaisesRegex(FormatError, "section"):
            Chromatix32(checksum(raw))

    def test_symbol_outside_payload_rejected(self):
        raw = bytearray(self.raw)
        struct.pack_into("<I", raw, 0xCC + 48, len(raw))
        with self.assertRaisesRegex(FormatError, "outside"):
            Chromatix32(checksum(raw))

    def test_cycle_rejected(self):
        with self.assertRaisesRegex(FormatError, "cycle"):
            self.mutate_symbol(11, 12, "<I", 10).cc13(30)

    def test_missing_reference_rejected(self):
        with self.assertRaisesRegex(FormatError, "missing"):
            self.mutate_symbol(14, 20, "<I", 9999).cc13(30)

    def test_nan_rejected(self):
        with self.assertRaisesRegex(FormatError, "coefficient"):
            self.mutate_symbol(20, 0, "<f", math.nan).cc13(30)

    def test_invalid_led_range_rejected(self):
        for a, b in ((math.nan, 100.), (100., 1.)):
            with self.assertRaisesRegex(FormatError, "LED sensitivity"):
                self.mutate_symbol(30, 32, "<2f", a, b).cc13(30)

    def test_excessive_dag_expansion_rejected(self):
        with self.assertRaisesRegex(FormatError, "4096 leaves"):
            Chromatix32(fixture(9)).cc13(30)

    def test_output_cannot_overwrite_input(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "source.bin"
            source.write_bytes(self.raw)
            result = subprocess.run([sys.executable, str(Path(__file__).with_name("chromatix32.py")),
                                     str(source), "--json", str(source)], capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(source.read_bytes(), self.raw)

    def test_offset_cannot_be_silently_dropped(self):
        module = self.mutate_symbol(20, 36, "<i", 1).cc13(30)
        with self.assertRaisesRegex(FormatError, "offsets"):
            cct_nodes(module, (0, 0, 0, 0))

    def test_branch_must_exist(self):
        with self.assertRaisesRegex(FormatError, "does not exist"):
            cct_nodes(self.module, (1, 0, 0, 0))

    def test_disabled_module_rejected(self):
        module = self.mutate_symbol(30, 0, "<I", 0).cc13(30)
        with self.assertRaisesRegex(FormatError, "disabled"):
            cct_nodes(module, (0, 0, 0, 0))

    def test_wrong_ct_dimension_rejected(self):
        module = self.mutate_symbol(2, 16, "<I", 99).cc13(30)
        with self.assertRaisesRegex(FormatError, "not CCT"):
            cct_nodes(module, (0, 0, 0, 0))

    def test_overlapping_ct_rejected(self):
        module = copy.deepcopy(self.module)
        module["leaves"][1]["path"][-1]["start"] = 2400.
        with self.assertRaisesRegex(FormatError, "overlapping"):
            cct_nodes(module, (0, 0, 0, 0))

    def test_interpolation_matches_plateaus_and_gaps(self):
        points = cct_nodes(self.module, (0, 0, 0, 0))
        self.assertEqual([p["ct"] for p in points], [2000, 2500, 4000, 6000])
        a, b = (leaf["ccm"] for leaf in self.module["leaves"])
        for ct in range(1000, 7500, 7):
            ratio = min(1., max(0., (ct - 2500) / 1500))
            expected = [x * (1 - ratio) + y * ratio for x, y in zip(a, b)]
            if ct <= points[0]["ct"]:
                actual = points[0]["ccm"]
            elif ct >= points[-1]["ct"]:
                actual = points[-1]["ccm"]
            else:
                lo, hi = next((x, y) for x, y in zip(points, points[1:])
                              if x["ct"] <= ct <= y["ct"])
                f = (ct - lo["ct"]) / (hi["ct"] - lo["ct"])
                actual = [x * (1 - f) + y * f for x, y in zip(lo["ccm"], hi["ccm"])]
            for x, y in zip(actual, expected):
                self.assertAlmostEqual(x, y)

    def test_yaml_algorithm_order(self):
        text = yaml_candidate(self.file.report(), self.module, (0, 0, 0, 0))
        names = [line.strip() for line in text.splitlines() if line.startswith("  - ")]
        self.assertEqual(names, ["- BlackLevel:", "- Awb:", "- Ccm:", "- Adjust:", "- Agc:"])
        self.assertNotIn("blackLevel:", text)
        self.assertNotIn("Lsc:", text)


if __name__ == "__main__":
    unittest.main(verbosity=2)
