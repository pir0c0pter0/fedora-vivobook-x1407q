#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-384 \
  -sha384 -nodes -subj /CN=TestRoot -days 1 \
  -keyout "$tmpdir/key.pem" -out "$tmpdir/root.der" -outform DER \
  >/dev/null 2>&1

python3 - "$repo_root" "$tmpdir" <<'PY'
import hashlib
import importlib.util
import inspect
import struct
import sys
from pathlib import Path

repo = Path(sys.argv[1])
tmp = Path(sys.argv[2])
tool = repo / "tools" / "inspect-edl-loader.py"
spec = importlib.util.spec_from_file_location("inspect_edl_loader", tool)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)

main_source = inspect.getsource(module.main)
assert "PASSOU NA TRIAGEM ESTRUTURAL" in main_source
assert "assinaturas de todo o código e de todos os estágios não foram validadas" in main_source
assert "não autoriza transmissão" in main_source
assert "CANDIDATO COMPATÍVEL" not in main_source


def elf(payload=b"", signed=b""):
    phnum = 1 + bool(signed)
    payload_offset = 0x200
    signed_offset = 0x400
    ident = b"\x7fELF\x02\x01\x01" + b"\0" * 9
    header = struct.pack(
        "<16sHHIQQQIHHHHHH",
        ident, 2, 183, 1, 0x1000, 64, 0, 0, 64, 56, phnum, 0, 0, 0,
    )
    phdrs = [struct.pack(
        "<IIQQQQQQ", 1, 5, payload_offset, 0x1000, 0x1000,
        len(payload), len(payload), 0x1000,
    )]
    if signed:
        phdrs.append(struct.pack(
            "<IIQQQQQQ", 0, 0x02000000, signed_offset, 0, 0,
            len(signed), len(signed), 0x1000,
        ))
    size = max(payload_offset + len(payload), signed_offset + len(signed) if signed else 0)
    image = bytearray(max(size, payload_offset))
    image[:64] = header
    image[64:64 + 56 * phnum] = b"".join(phdrs)
    image[payload_offset:payload_offset + len(payload)] = payload
    if signed:
        image[signed_offset:signed_offset + len(signed)] = signed
    return bytes(image)


def elf32(payload=b""):
    payload_offset = 0x100
    ident = b"\x7fELF\x01\x01\x01" + b"\0" * 9
    header = struct.pack(
        "<16sHHIIIIIHHHHHH",
        ident, 2, 183, 1, 0x1000, 52, 0, 0, 52, 32, 1, 0, 0, 0,
    )
    phdr = struct.pack(
        "<IIIIIIII", 1, payload_offset, 0x1000, 0x1000,
        len(payload), len(payload), 5, 0x1000,
    )
    image = bytearray(payload_offset + len(payload))
    image[:52] = header
    image[52:84] = phdr
    image[payload_offset:] = payload
    return bytes(image)


def mbn_v7(cert, oem_id=0x29):
    common = struct.pack("<6I", 0, 0, 0x42, 0, 3, 0)
    metadata = bytearray(224)
    struct.pack_into("<4I", metadata, 0, 2, 0, 0, 0)
    struct.pack_into("<12I", metadata, 16, 0xA009, 0xA016, *([0] * 10))
    struct.pack_into("<II", metadata, 136, oem_id, 1)
    struct.pack_into("<I", metadata, 220, 0x155A56)
    header = struct.pack(
        "<10I", 0, 7, len(common), 0, len(metadata), 0, 0, 0, 0, len(cert),
    )
    return header + common + metadata + cert


root = (tmp / "root.der").read_bytes()
root_hash = hashlib.sha384(root).hexdigest()
stages = [
    elf32(b"SocHamoaWP"),
    elf32(b"xbl stage 2"),
    elf(b"xbl stage 3"),
    elf(b"devprg_entry.c storage_device_nvme", mbn_v7(root)),
    elf(b"xbl_ramdump_wdog"),
]
candidate = tmp / "candidate.melf"
candidate.write_bytes(b"".join(stages))

module.TARGET_PK_HASH = root_hash
result = module.inspect(candidate)
assert result.compatible, result
assert result.elf_count == 5
assert result.devprg_stage == 4
assert result.root_hash == module.TARGET_PK_HASH
assert result.metadata.soc_versions == (0xA009, 0xA016)
assert result.metadata.oem_id == 0x29
assert result.metadata.model_id == 1

padded = tmp / "candidate-padded.melf"
padded_stages = stages.copy()
padded_stages[3] = elf(
    b"devprg_entry.c storage_device_nvme", mbn_v7(root) + b"\xff" * 16,
)
padded.write_bytes(b"".join(padded_stages))
assert module.inspect(padded).compatible

module.TARGET_PK_HASH = "00" * 48
result = module.inspect(candidate)
assert not result.compatible
assert "raiz" in result.reason.lower()
assert result.root_hash == root_hash

module.TARGET_PK_HASH = root_hash
bad_oem = tmp / "bad-oem.melf"
bad_stages = stages.copy()
bad_stages[3] = elf(
    b"devprg_entry.c storage_device_nvme", mbn_v7(root, oem_id=2),
)
bad_oem.write_bytes(b"".join(bad_stages))
result = module.inspect(bad_oem)
assert not result.compatible
assert "oem" in result.reason.lower()

bad = tmp / "bad.bin"
bad.write_bytes(b"not an ELF")
try:
    module.inspect(bad)
except module.AnalysisError:
    pass
else:
    raise AssertionError("arquivo sem ELF deveria falhar")
PY

echo "PASS: inspect-edl-loader"
