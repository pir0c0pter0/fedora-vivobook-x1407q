#!/usr/bin/env python3
"""x1407qa-sahara-mem2.py

Testa o caminho SWITCH_MODE(2) -> HELLO(mode=2) -> variantes de entrada em
memory-debug no PBL a016:

 A. HELLO_RSP(mode=2)  apos o HELLO(mode=2);
 B. leitura extra (tabela pode vir sem HELLO_RSP);
 C. MEMORY_DEBUG 64-bit (0x10) escrito pelo host;
 D. MEMORY_READ 64-bit (0x11) no estado mode=2;
 E. MEMORY_DEBUG 32-bit (0x09) escrito pelo host.

Se qualquer variante retornar tabela (0x09/0x10), a tabela e lida e as
regioes sao listadas (somente leitura).
"""

from __future__ import annotations

import struct
import sys
import time
from dataclasses import dataclass
from pathlib import Path


class ProbeError(RuntimeError):
    pass


class UsbTransport:
    def __init__(self):
        import usb.core
        import usb.util

        self._usb_util = usb.util
        self._device = usb.core.find(idVendor=0x05C6, idProduct=0x9008)
        if self._device is None:
            raise ProbeError("dispositivo 05c6:9008 nao encontrado")
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
            raise ProbeError(f"nao foi possivel abrir o USB EDL: {exc}") from exc
        if self._in is None or self._out is None:
            raise ProbeError("endpoints bulk do EDL nao encontrados")

    def read(self, timeout_ms: int = 2000) -> bytes:
        try:
            return bytes(self._in.read(4096, timeout=timeout_ms))
        except Exception as exc:
            if getattr(exc, "errno", None) == 110 or "timed out" in str(exc).lower():
                return b""
            raise ProbeError(f"falha de leitura USB: {exc}") from exc

    def write(self, data: bytes) -> None:
        try:
            written = self._out.write(data, timeout=8000)
        except Exception as exc:
            raise ProbeError(f"falha de escrita USB: {exc}") from exc
        if written != len(data):
            raise ProbeError("transferencia USB parcial")

    def close(self) -> None:
        try:
            self._usb_util.release_interface(
                self._device, self._interface.bInterfaceNumber
            )
        except Exception:
            pass
        try:
            self._usb_util.dispose_resources(self._device)
        except Exception:
            pass


@dataclass
class SessionLog:
    lines: list

    def out(self, line: str) -> None:
        print(line, flush=True)
        self.lines.append(line)


def hello(transport, mode: int, version: int) -> None:
    transport.write(struct.pack("<12I", 2, 48, version, 1, 0, mode, 1, 2, 3, 4, 5, 6))


def main() -> int:
    timestamp = time.strftime("%Y%m%d-%H%M%S")
    outdir = Path(__file__).resolve().parent.parent
    txt_path = outdir / f"pbl-mem2-{timestamp}.txt"
    log = SessionLog([])
    log.out(f"=== x1407qa-sahara-mem2 {timestamp} ===")

    try:
        transport = UsbTransport()
    except ProbeError as exc:
        log.out(f"ERRO: {exc}")
        txt_path.write_text("\n".join(log.lines) + "\n")
        return 2

    try:
        hello_pkt = transport.read(5000)
        if not hello_pkt or len(hello_pkt) < 48 or struct.unpack_from("<I", hello_pkt)[0] != 1:
            log.out(f"ERRO: esperado HELLO, recebido {hello_pkt[:16].hex() if hello_pkt else 'vazio'}")
            txt_path.write_text("\n".join(log.lines) + "\n")
            return 2
        version = struct.unpack_from("<I", hello_pkt, 8)[0]
        log.out(f"HELLO_REQ: version={version}")

        def read_pkt(label, timeout=2500):
            pkt = transport.read(timeout)
            if not pkt:
                log.out(f"  [{label}] timeout")
                return None
            cmd = struct.unpack_from("<I", pkt)[0]
            log.out(f"  [{label}] cmd=0x{cmd:x} len={len(pkt)}B {pkt.hex()[:112]}")
            return pkt

        # entrar em command mode
        hello(transport, 3, version)
        if not read_pkt("hello m3"):
            raise ProbeError("sem resposta ao HELLO m3")

        # SWITCH_MODE(2)
        log.out("SWITCH_MODE(2):")
        transport.write(struct.pack("<3I", 0x0C, 12, 2))
        pkt = read_pkt("pos SWITCH_MODE(2)")
        if pkt is None or struct.unpack_from("<I", pkt)[0] != 1:
            raise ProbeError("esperado HELLO apos SWITCH_MODE(2)")

        # Variante A: HELLO_RSP(mode=2)
        log.out("Variante A: HELLO_RSP(mode=2)")
        hello(transport, 2, version)
        pkt = read_pkt("resposta A", 4000)
        table = None
        if pkt is not None:
            cmd = struct.unpack_from("<I", pkt)[0]
            if cmd in (0x09, 0x10):
                table = pkt
            elif cmd == 0x01:
                log.out("  A: PBL respondeu com HELLO de novo")
            elif cmd == 0x04 and len(pkt) >= 16:
                status = struct.unpack_from("<I", pkt, 12)[0]
                log.out(f"  A: NAK status=0x{status:02x}")

        # Variante B: leitura extra (sem nada enviado)
        if table is None:
            log.out("Variante B: leitura extra")
            pkt = read_pkt("resposta B", 3000)
            if pkt is not None:
                cmd = struct.unpack_from("<I", pkt)[0]
                if cmd in (0x09, 0x10):
                    table = pkt

        # Variante C: MEMORY_DEBUG 64-bit (0x10) escrito pelo host
        if table is None:
            log.out("Variante C: MEMORY_DEBUG 64-bit (0x10) do host")
            transport.write(struct.pack("<IIQQ", 0x10, 24, 0, 0))
            pkt = read_pkt("resposta C", 3000)
            if pkt is not None:
                cmd = struct.unpack_from("<I", pkt)[0]
                if cmd in (0x09, 0x10):
                    table = pkt
                elif cmd == 0x04 and len(pkt) >= 16:
                    status = struct.unpack_from("<I", pkt, 12)[0]
                    log.out(f"  C: NAK status=0x{status:02x}")

        # Variante D: MEMORY_READ 64-bit direto @0x0 (no estado mode=2)
        if table is None:
            log.out("Variante D: MEMORY_READ 64-bit @0x0 (64B)")
            transport.write(struct.pack("<IIQQ", 0x11, 24, 0, 64))
            pkt = read_pkt("resposta D", 3000)
            if pkt is not None:
                cmd = struct.unpack_from("<I", pkt)[0]
                if cmd == 0x04 and len(pkt) >= 16:
                    status = struct.unpack_from("<I", pkt, 12)[0]
                    log.out(f"  D: NAK status=0x{status:02x}")

        # Variante E: MEMORY_DEBUG 32-bit (0x09) do host
        if table is None:
            log.out("Variante E: MEMORY_DEBUG 32-bit (0x09) do host")
            transport.write(struct.pack("<IIII", 0x09, 16, 0, 0))
            pkt = read_pkt("resposta E", 3000)
            if pkt is not None:
                cmd = struct.unpack_from("<I", pkt)[0]
                if cmd in (0x09, 0x10):
                    table = pkt
                elif cmd == 0x04 and len(pkt) >= 16:
                    status = struct.unpack_from("<I", pkt, 12)[0]
                    log.out(f"  E: NAK status=0x{status:02x}")

        if table is None:
            log.out("RESULTADO: nenhuma variante retornou tabela de memoria")
        else:
            cmd = struct.unpack_from("<I", table)[0]
            if cmd == 0x10:
                addr, length = struct.unpack_from("<QQ", table, 8)
                bit64 = True
            else:
                addr, length = struct.unpack_from("<II", table, 8)
                bit64 = False
            log.out(f"TABELA OBTIDA: addr=0x{addr:x} length={length} bit64={bit64}")
            if 0 < length <= 65536:
                total = b""
                pos = 0
                while pos < length:
                    chunk = min(length - pos, 0x400)
                    if bit64:
                        transport.write(struct.pack("<IIQQ", 0x11, 24, addr + pos, chunk))
                    else:
                        transport.write(struct.pack("<IIII", 0x0A, 16, addr + pos, chunk))
                    data = transport.read(chunk + 100)
                    if not data:
                        log.out(f"  leitura da tabela parou em {pos}")
                        break
                    total += data[:chunk]
                    pos += len(data[:chunk])
                tbl_path = outdir / f"pbl-mem2-{timestamp}-table.bin"
                tbl_path.write_bytes(total)
                log.out(f"tabela lida: {len(total)}B salva em {tbl_path.name}")
                stride = 64 if bit64 else 52
                for off in range(0, min(len(total), length), stride):
                    chunk = total[off:off + stride]
                    if len(chunk) < stride:
                        break
                    if bit64:
                        save_pref, mem_base, rlen = struct.unpack_from("<QQQ", chunk)
                        desc = chunk[24:44].split(b"\x00")[0].decode("latin1", "replace")
                        fname = chunk[44:64].split(b"\x00")[0].decode("latin1", "replace")
                    else:
                        save_pref, mem_base, rlen = struct.unpack_from("<III", chunk)
                        desc = chunk[12:32].split(b"\x00")[0].decode("latin1", "replace")
                        fname = chunk[32:52].split(b"\x00")[0].decode("latin1", "replace")
                    log.out(f"  {fname!r} {desc!r}: base=0x{mem_base:x} length=0x{rlen:x}")
            else:
                log.out(f"  tamanho de tabela invalido: {length}")
    except ProbeError as exc:
        log.out(f"ERRO: {exc}")
    finally:
        if transport is not None:
            transport.close()

    txt_path.write_text("\n".join(log.lines) + "\n")
    log.out(f"Sessao salva em {txt_path.name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
