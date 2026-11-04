#!/usr/bin/env python3
"""Oferece o RAM-dump MELF oficial ao Sahara sem permitir execução."""

from __future__ import annotations

import argparse
import hashlib
import struct
from dataclasses import dataclass
from pathlib import Path


EXPECTED_SHA256 = (
    "57bbd49ad7c8dc75b3157ef2cf7cf9f1ca6e8c713711f00828470fb480e0f1d2",
    "f327e4c7d44969c3b76b4a6fea4bc57e64f49490ce5ac435e427c2271056cf49",
    "538acdb3b72550818573b2a5d4fd0c2699884ef05e249d5121910362f49d651a",
)
EXPERIMENTAL_SHA256 = (
    "57bbd49ad7c8dc75b3157ef2cf7cf9f1ca6e8c713711f00828470fb480e0f1d2",
    "dc014d428d66071b416aa80f0da2b698229cd76412aa3e447aa65ccda76220c4",
    "62f634a885b07e3dfa8ec889380f49819191cd83e5674bed660368571da410ab",
)


class ProbeError(RuntimeError):
    pass


class ProbeTimeout(ProbeError):
    pass


@dataclass(frozen=True)
class ProbeResult:
    image_id: int
    status: int
    bytes_sent: int
    requests: int
    max_end: int


@dataclass(frozen=True)
class ChipIdentityV3:
    soc_version: int
    msm_id: int
    oem_id: int
    model_id: int
    root_hash_algorithm: int


def compose(prefix: bytes, ramdump: bytes, watchdog: bytes) -> bytes:
    parts = (prefix, ramdump, watchdog)
    hashes = tuple(hashlib.sha256(part).hexdigest() for part in parts)
    if hashes not in (EXPECTED_SHA256, EXPERIMENTAL_SHA256):
        raise ProbeError("SHA-256 dos componentes autorizados não corresponde")
    return b"".join(parts)


def _enter_mode(transport, mode: int) -> None:
    try:
        hello = transport.read()
    except ProbeTimeout:
        version = 2
    else:
        if len(hello) < 48 or struct.unpack_from("<I", hello)[0] != 1:
            raise ProbeError("SAHARA_HELLO_REQ não recebido")
        version = struct.unpack_from("<I", hello, 8)[0]
    response = struct.pack(
        "<12I", 2, 48, version, 1, 0, mode, 1, 2, 3, 4, 5, 6
    )
    transport.write(response)


def read_chip_id_v3(transport) -> bytes:
    _enter_mode(transport, 3)
    ready = transport.read()
    if len(ready) < 8 or struct.unpack_from("<I", ready)[0] != 0x0B:
        raise ProbeError("SAHARA_CMD_READY não recebido")

    transport.write(struct.pack("<3I", 0x0D, 12, 0x0A))
    response = transport.read()
    if len(response) < 16:
        raise ProbeError("SAHARA_EXECUTE_RSP truncado")
    command, _, client_command, size = struct.unpack_from("<4I", response)
    if command != 0x0E or client_command != 0x0A or not 44 <= size <= 4096:
        raise ProbeError("resposta inválida ao READ_CHIP_ID_V3")

    transport.write(struct.pack("<3I", 0x0F, 12, 0x0A))
    payload = transport.read()
    if len(payload) != size:
        raise ProbeError("payload READ_CHIP_ID_V3 truncado")
    transport.write(struct.pack("<3I", 0x0C, 12, 0))
    return payload


def decode_chip_id_v3(payload: bytes) -> ChipIdentityV3:
    if len(payload) < 52:
        raise ProbeError("payload READ_CHIP_ID_V3 curto demais")
    return ChipIdentityV3(
        soc_version=struct.unpack_from("<I", payload, 32)[0] >> 16,
        msm_id=struct.unpack_from("<I", payload, 36)[0],
        oem_id=struct.unpack_from("<I", payload, 40)[0],
        model_id=struct.unpack_from("<I", payload, 44)[0],
        root_hash_algorithm=struct.unpack_from("<I", payload, 48)[0],
    )


def reset_state(transport) -> None:
    transport.write(struct.pack("<II", 0x13, 8))


def probe(transport, image: bytes) -> ProbeResult:
    _enter_mode(transport, 0)
    sent = 0
    requests = 0
    max_end = 0
    while requests < 4096:
        packet = transport.read()
        if len(packet) < 8:
            raise ProbeError("pacote Sahara truncado")
        command, packet_size = struct.unpack_from("<II", packet)
        if packet_size > len(packet):
            raise ProbeError("tamanho declarado do pacote Sahara é inválido")

        if command == 0x12:
            if len(packet) < 32:
                raise ProbeError("SAHARA_READ_DATA_64 truncado")
            image_id, offset, size = struct.unpack_from("<QQQ", packet, 8)
        elif command == 3:
            if len(packet) < 20:
                raise ProbeError("SAHARA_READ_DATA truncado")
            image_id, offset, size = struct.unpack_from("<III", packet, 8)
        elif command == 4:
            if len(packet) < 16:
                raise ProbeError("SAHARA_END_TRANSFER truncado")
            image_id, status = struct.unpack_from("<II", packet, 8)
            return ProbeResult(image_id, status, sent, requests, max_end)
        else:
            raise ProbeError(f"comando Sahara inesperado: 0x{command:x}")

        if image_id != 13:
            raise ProbeError(f"image ID inesperado: {image_id}")
        if size == 0 or offset + size > len(image):
            raise ProbeError("PBL solicitou dados fora da imagem")
        transport.write(image[offset:offset + size])
        sent += size
        requests += 1
        max_end = max(max_end, offset + size)

    raise ProbeError("limite de solicitações Sahara excedido")


class UsbTransport:
    def __init__(self):
        try:
            import usb.core
            import usb.util
        except ImportError as exc:
            raise ProbeError("PyUSB não está instalado") from exc

        self._usb_util = usb.util
        self._device = usb.core.find(idVendor=0x05C6, idProduct=0x9008)
        if self._device is None:
            raise ProbeError("dispositivo 05c6:9008 não encontrado")
        try:
            try:
                config = self._device.get_active_configuration()
            except usb.core.USBError:
                self._device.set_configuration()
                config = self._device.get_active_configuration()
            self._interface = config[(0, 0)]
            usb.util.claim_interface(self._device, self._interface.bInterfaceNumber)
            self._in = usb.util.find_descriptor(
                self._interface,
                custom_match=lambda ep: usb.util.endpoint_direction(ep.bEndpointAddress)
                == usb.util.ENDPOINT_IN,
            )
            self._out = usb.util.find_descriptor(
                self._interface,
                custom_match=lambda ep: usb.util.endpoint_direction(ep.bEndpointAddress)
                == usb.util.ENDPOINT_OUT,
            )
        except Exception as exc:
            raise ProbeError(f"não foi possível abrir o USB EDL: {exc}") from exc
        if self._in is None or self._out is None:
            raise ProbeError("endpoints bulk do EDL não encontrados")

    def read(self) -> bytes:
        try:
            return bytes(self._in.read(4096, timeout=10000))
        except Exception as exc:
            if getattr(exc, "errno", None) == 110:
                raise ProbeTimeout(f"timeout de leitura USB: {exc}") from exc
            raise ProbeError(f"falha de leitura USB: {exc}") from exc

    def write(self, data: bytes) -> None:
        try:
            written = self._out.write(data, timeout=10000)
        except Exception as exc:
            raise ProbeError(f"falha de escrita USB: {exc}") from exc
        if written != len(data):
            raise ProbeError("transferência USB parcial")

    def close(self) -> None:
        self._usb_util.release_interface(
            self._device, self._interface.bInterfaceNumber
        )
        self._usb_util.dispose_resources(self._device)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--chipinfo-v3", action="store_true", help="imprime a resposta bruta 0x0A"
    )
    parser.add_argument(
        "--reset-state", action="store_true", help="reinicia somente o estado Sahara"
    )
    parser.add_argument("prefix", nargs="?", type=Path, help="prefixo ASUS com 3 ELFs")
    parser.add_argument("ramdump", nargs="?", type=Path, help="XBLRamDump ASUS")
    parser.add_argument("watchdog", nargs="?", type=Path, help="watchdog ASUS")
    args = parser.parse_args()

    transport = None
    try:
        if args.chipinfo_v3:
            transport = UsbTransport()
            payload = read_chip_id_v3(transport)
            print(f"READ_CHIP_ID_V3 ({len(payload)} bytes): {payload.hex()}")
            identity = decode_chip_id_v3(payload)
            print(
                f"SoC={identity.soc_version:04x} MSM={identity.msm_id:08x} "
                f"OEM={identity.oem_id:04x} MODEL={identity.model_id:04x} "
                f"ROOT_HASH_ALGO={identity.root_hash_algorithm}"
            )
            return 0
        if not all((args.prefix, args.ramdump, args.watchdog)):
            raise ProbeError("informe prefix, ramdump e watchdog")
        image = compose(
            args.prefix.read_bytes(),
            args.ramdump.read_bytes(),
            args.watchdog.read_bytes(),
        )
        transport = UsbTransport()
        if args.reset_state:
            reset_state(transport)
        result = probe(transport, image)
    except (OSError, ProbeError) as exc:
        print(f"ERRO: {exc}")
        return 2
    finally:
        if transport is not None:
            transport.close()

    print(
        f"END_TRANSFER image_id={result.image_id} status=0x{result.status:02x} "
        f"requests={result.requests} bytes={result.bytes_sent} max_end={result.max_end}"
    )
    if result.status == 0:
        print("AUTENTICADO, NÃO EXECUTADO: SAHARA_DONE_REQ não foi enviado")
        return 0
    print("REJEITADO PELO PBL; nenhum comando de execução foi enviado")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
