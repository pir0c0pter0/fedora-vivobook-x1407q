#!/usr/bin/env python3
"""Inspect the CRC-terminated, 32-bit QTI Chromatix variant used on the Yoga.

No float-pattern scanning: every extracted CC13 value follows a named symbol
and a checked reference. This is a deliberately narrow decoder, not a general
Chromatix converter. Outputs contain private vendor data: keep them in local/.
The optional libcamera simple YAML freezes four non-CCT trigger dimensions;
it is a candidate for comparison, not a complete Windows ISP calibration.
"""

import argparse
from dataclasses import asdict, dataclass
import hashlib
import json
import math
from pathlib import Path
import struct
import zlib


class FormatError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise FormatError(message)


@dataclass(frozen=True)
class Symbol:
    id: int
    name: str
    version: int
    revision: int
    group: int
    offset: int
    size: int


class Chromatix32:
    def __init__(self, data):
        self.raw = data
        require(len(data) >= 0xD0, "truncated header")
        require(data[:20] == b"QTI Chromatix Header", "wrong magic")
        require(struct.unpack_from("<I", data, 0x1C)[0] == len(data) - 4,
                "declared size is not payload size plus CRC trailer")
        self.crc = struct.unpack_from("<I", data, len(data) - 4)[0]
        require(zlib.crc32(data[:-4]) == self.crc, "CRC32 mismatch")
        require(struct.unpack_from("<II", data, 0x20) == (3, 1),
                "unsupported container version")
        self.parser = data[0x28:0x58].split(b"\0", 1)[0].decode("ascii")
        self.name = data[0x58:0x98].split(b"\0", 1)[0].decode("ascii")
        table, count = struct.unpack_from("<II", data, 0xA0)
        require(table == 0xA8 and count == 3, "unsupported section table")
        self.sections = {}
        previous_end = table + 12 * count
        for pos in range(table, previous_end, 12):
            kind, start, size = struct.unpack_from("<III", data, pos)
            require(kind not in self.sections, "duplicate section type")
            require(start >= previous_end and start + size <= len(data) - 4,
                    "section out of bounds or overlaps previous section")
            self.sections[kind] = (start, size)
            previous_end = start + size
        require(set(self.sections) == {0, 1, 2}, "unsupported section types")
        require(previous_end == len(data) - 4, "unparsed bytes before CRC")
        start, size = self.sections[0]
        require(size % 56 == 0, "symbol table is not 56-byte entries")
        self.symbols = {}
        for pos in range(start, start + size, 56):
            sid, name, *fields = struct.unpack_from("<I32s5I", data, pos)
            require(sid not in self.symbols, "duplicate symbol ID")
            symbol = Symbol(sid, name.split(b"\0", 1)[0].decode("ascii"), *fields)
            require(symbol.offset + symbol.size <= self.sections[1][1],
                    f"symbol {sid} outside data section")
            self.symbols[sid] = symbol

    def symbol_data(self, sid, name=None, size=None):
        require(sid in self.symbols, f"missing symbol {sid}")
        sym = self.symbols[sid]
        require(name is None or sym.name == name,
                f"symbol {sid}: expected {name}, got {sym.name}")
        require(size is None or sym.size == size,
                f"symbol {sid}: expected {size} bytes, got {sym.size}")
        start = self.sections[1][0] + sym.offset
        return self.raw[start:start + sym.size]

    def location(self, sid):
        sym = self.symbols[sid]
        return {**asdict(sym), "file_offset": self.sections[1][0] + sym.offset}

    def cc13(self, sid):
        sym = self.symbols[sid]
        require(sym.name in {"cc13_ipe_v2", "cc13_bps_v2", "cc13_ife_v2"},
                "not a supported CC13 v2 module")
        data = self.symbol_data(sid, size=52)
        fields = struct.unpack("<8I2f3I", data)
        enabled, major, minor, revision, strlen, strid, ncontrol, controlid = fields[:8]
        require(enabled in (0, 1) and (major, minor, revision) == (1, 3, 1),
                "unsupported CC13 module version or enable flag")
        parameter_revision = self.symbol_data(strid, "revision", strlen)
        require(ncontrol == 5, "CC13 v2 requires five trigger dimensions")
        controls = struct.unpack("<5I", self.symbol_data(controlid, "control_var_type", 20))
        led_start, led_end, q_factor, count, root = fields[8:]
        require(math.isfinite(led_start) and math.isfinite(led_end) and led_start <= led_end,
                "invalid LED sensitivity range")
        require(q_factor <= 3 and count > 0, "invalid CC13 reserve/root")
        leaves = []

        def walk(ref, n, path, ancestors):
            depth = len(path)
            require(ref not in ancestors, "cycle in trigger graph")
            require(depth < 5 and 0 < n <= 1024, "invalid trigger depth/count")
            name = "mod_cc13_trigger_data" if depth == 0 else "trigger"
            nodes = self.symbol_data(ref, name, n * 24)
            for index in range(n):
                lo, hi, nc, child, nr, region = struct.unpack_from("<ffIIII", nodes, index * 24)
                require(math.isfinite(lo) and math.isfinite(hi) and lo <= hi,
                        "invalid trigger range")
                branch = path + [{"symbol_id": ref, "index": index,
                                  "control_code": controls[depth], "start": lo, "end": hi}]
                if depth < 4:
                    require(nc > 0 and nr == 0, "region before final dimension")
                    self.symbol_data(region, "region", 0)
                    walk(child, nc, branch, ancestors | {ref})
                else:
                    require(len(leaves) < 4096, "trigger graph exceeds 4096 leaves")
                    require(nc == 0 and nr == 1, "invalid leaf references")
                    self.symbol_data(child, "trigger", 0)
                    raw = self.symbol_data(region, "region", 48)
                    ccm = struct.unpack_from("<9f", raw)
                    offsets = struct.unpack_from("<3i", raw, 36)
                    require(all(math.isfinite(v) and abs(v) <= 15.99 for v in ccm),
                            "invalid CC13 coefficient")
                    leaves.append({"path": branch, "region": self.location(region),
                                   "ccm": ccm, "offsets": offsets})

        walk(root, count, [], set())
        return {"module": self.location(sid), "enabled": enabled,
                "module_version": [major, minor, revision],
                "parameter_revision": parameter_revision.rstrip(b"\0").decode("ascii"),
                "control_codes": controls, "led_sensitivity_range": [led_start, led_end],
                "q_factor": q_factor, "leaves": leaves}

    def report(self):
        return {"source_sha256": hashlib.sha256(self.raw).hexdigest(),
                "source_size": len(self.raw), "crc32": f"{self.crc:08x}",
                "parser": self.parser, "name": self.name, "sections": self.sections,
                "symbol_count": len(self.symbols),
                "cc13_modules": [self.cc13(s.id) for s in self.symbols.values()
                                 if s.name in {"cc13_ipe_v2", "cc13_bps_v2", "cc13_ife_v2"}]}


def cct_nodes(module, branch):
    """Preserve each selected CCT plateau and linear gap without invented CTs.

    GetIndexPtTrigger in the Qualcomm CC13 reference implementation clamps
    within each range and interpolates in gaps. Duplicating range endpoints
    gives that same function in libcamera's linear interpolator. This does not
    implement the other four dimensions or prove Windows' runtime selection.
    """
    require(module["enabled"] == 1, "cannot export a disabled module")
    require(len(branch) == 4, "select exactly four non-CCT branch indices")
    require(module["control_codes"][-1] == 6, "final control is not CCT")
    selected = [leaf for leaf in module["leaves"]
                if tuple(p["index"] for p in leaf["path"][:4]) == tuple(branch)]
    require(selected, "branch does not exist")
    points = []
    previous = None
    for leaf in selected:
        require(all(v == 0 for v in leaf["offsets"]),
                "libcamera Ccm cannot represent nonzero offsets")
        lo, hi = (leaf["path"][-1][key] for key in ("start", "end"))
        require(0 < lo <= hi and lo.is_integer() and hi.is_integer(), "invalid CCT endpoints")
        require(previous is None or previous < lo, "overlapping CCT ranges")
        for ct in sorted({int(lo), int(hi)}):
            points.append({"ct": ct, "ccm": leaf["ccm"]})
        previous = hi
    return points


def yaml_candidate(report, module, branch):
    points = cct_nodes(module, branch)
    text = ["%YAML 1.1", "---",
            "# Private vendor-derived candidate; not a complete Windows ISP profile.",
            f"# Source SHA256: {report['source_sha256']}",
            f"# Module ID {module['module']['id']}; fixed branch indices {list(branch)}.",
            "# Preserves CCT plateaus; AEC/DRC/LED selection is frozen.",
            "# AWB, AGC, black level and Adjust retain libcamera defaults.",
            "version: 1", "algorithms:", "  - BlackLevel:", "  - Awb:",
            "  - Ccm:", "      ccms:"]
    for point in points:
        text += [f"        - ct: {point['ct']}",
                 "          ccm: [ " + ", ".join(format(v, ".9g") for v in point["ccm"]) + " ]"]
    text += ["  - Adjust:", "  - Agc:"]
    return "\n".join(text) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("--json", type=Path, required=True, help="private extraction report")
    parser.add_argument("--yaml", type=Path, help="optional private libcamera candidate")
    parser.add_argument("--module-id", type=int)
    parser.add_argument("--branch", help="four explicit indices, e.g. 0,0,0,0")
    args = parser.parse_args()
    try:
        paths = [args.input.resolve(), args.json.resolve()]
        if args.yaml:
            paths.append(args.yaml.resolve())
        require(len(set(paths)) == len(paths), "input and output paths must be different")
        data = Chromatix32(args.input.read_bytes())
        report = data.report()
        report["source_file"] = str(args.input.resolve())
        candidate = None
        if args.yaml:
            require(args.module_id is not None and args.branch is not None,
                    "--yaml requires explicit --module-id and --branch")
            require(args.module_id in data.symbols, "unknown module ID")
            branch = tuple(int(v) for v in args.branch.split(","))
            module = data.cc13(args.module_id)
            candidate = yaml_candidate(report, module, branch)
            report["candidate"] = {"module_id": args.module_id, "branch_indices": branch,
                                   "status": "unvalidated fixed-branch candidate"}
        args.json.write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")
        if candidate is not None:
            args.yaml.write_text(candidate)
    except (ValueError, OSError) as error:
        parser.exit(1, f"chromatix32: {error}\n")


if __name__ == "__main__":
    main()
