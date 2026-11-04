#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$repo_root" <<'PY'
import hashlib
import importlib.util
import inspect
import struct
import sys
from pathlib import Path

tool = Path(sys.argv[1]) / "tools" / "sahara-auth-probe.py"
spec = importlib.util.spec_from_file_location("sahara_auth_probe", tool)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)

main_source = inspect.getsource(module.main)
assert "SAHARA_DONE_REQ não foi enviado" in main_source
assert "não garante ausência de execução ou efeitos colaterais" in main_source
assert "AUTENTICADO, NÃO EXECUTADO" not in main_source
assert "não garante ausência de execução ou efeitos colaterais" in module.__doc__


class FakeTransport:
    def __init__(self, packets):
        self.packets = list(packets)
        self.writes = []

    def read(self):
        return self.packets.pop(0)

    def write(self, data):
        self.writes.append(bytes(data))


prefix = b"prefix"
ramdump = b"ramdump"
watchdog = b"watchdog"
module.EXPECTED_SHA256 = tuple(
    hashlib.sha256(item).hexdigest() for item in (prefix, ramdump, watchdog)
)
image = module.compose(prefix, ramdump, watchdog)

experimental = (b"asus-prefix", b"iq-devprg", b"iq-watchdog")
module.EXPERIMENTAL_SHA256 = tuple(
    hashlib.sha256(item).hexdigest() for item in experimental
)
assert module.compose(*experimental) == b"".join(experimental)
try:
    module.compose(prefix, ramdump, b"unknown")
except module.ProbeError as exc:
    assert "SHA-256" in str(exc)
else:
    raise AssertionError("composição não autorizada deveria falhar")

hello = struct.pack("<12I", 1, 48, 3, 1, 0x100000, 0, 0, 0, 0, 0, 0, 0)
read = struct.pack("<IIQQQ", 0x12, 32, 13, 2, 7)
end = struct.pack("<4I", 4, 16, 13, 0)
transport = FakeTransport([hello, read, end])
result = module.probe(transport, image)

assert result.status == 0
assert result.image_id == 13
assert result.bytes_sent == 7
assert result.max_end == 9
assert struct.unpack_from("<I", transport.writes[0])[0] == 2
assert transport.writes[1] == image[2:9]
assert all(struct.unpack_from("<I", item)[0] != 5 for item in transport.writes if len(item) >= 4)


class TimeoutTransport(FakeTransport):
    def read(self):
        if self.packets and self.packets[0] == "timeout":
            self.packets.pop(0)
            raise module.ProbeTimeout("timeout")
        return super().read()


transport = TimeoutTransport(["timeout", read, end])
result = module.probe(transport, image)
assert result.status == 0
assert result.max_end == 9
hello_response = struct.unpack("<12I", transport.writes[0])
assert hello_response[:6] == (2, 48, 2, 1, 0, 0)
assert transport.writes[1] == image[2:9]
assert all(struct.unpack_from("<I", item)[0] != 5 for item in transport.writes if len(item) >= 4)

bad_read = struct.pack("<IIQQQ", 0x12, 32, 13, len(image), 1)
transport = FakeTransport([hello, bad_read])
try:
    module.probe(transport, image)
except module.ProbeError as exc:
    assert "fora" in str(exc)
else:
    raise AssertionError("leitura fora da imagem deveria falhar")
assert len(transport.writes) == 1

transport = FakeTransport([])
module.reset_state(transport)
assert transport.writes == [struct.pack("<II", 0x13, 8)]

raw_identity = bytes(range(48))
transport = FakeTransport([
    hello,
    struct.pack("<II", 0x0B, 8),
    struct.pack("<4I", 0x0E, 16, 0x0A, len(raw_identity)),
    raw_identity,
])
assert module.read_chip_id_v3(transport) == raw_identity
commands = [struct.unpack_from("<I", item)[0] for item in transport.writes]
assert commands == [2, 0x0D, 0x0F, 0x0C]
assert 5 not in commands

captured = bytes.fromhex(
    "0000020000000000000000000000000000000000000000000000000000000000"
    "000016a0e1d02a00290000000100000003000000000000000000000001000000"
    "00000000010000000100000000000000"
)
identity = module.decode_chip_id_v3(captured)
assert identity.soc_version == 0xA016
assert identity.msm_id == 0x002AD0E1
assert identity.oem_id == 0x29
assert identity.model_id == 1
assert identity.root_hash_algorithm == 3
PY

echo "PASS: sahara-auth-probe"
