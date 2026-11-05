#!/usr/bin/env python3
"""x1407qa-sahara-modes.py

Explora SWITCH_MODE (0x0C) 0..3, MEMORY_DEBUG (HELLO mode 2) e
MEMORY_READ 64-bit direto, com manejo de estado especifico do PBL a016:

 * fresh: HELLO -> HELLO_RSP(mode 3) -> CMD_READY -> command mode;
 * SWITCH_MODE 0 responde com HELLO novo (estado "aguardando HELLO_RSP";
   neste estado 0x13 nao e aceito - usar HELLO_RSP direto);
 * apos NAK de exec: 0x13 -> HELLO -> HELLO_RSP(mode 3) -> CMD_READY.
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
    txt_path = outdir / f"pbl-modes-{timestamp}.txt"
    log = SessionLog([])
    log.out(f"=== x1407qa-sahara-modes {timestamp} ===")

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

        def enter_command_mode() -> bool:
            hello(transport, 3, version)
            pkt = transport.read()
            if pkt and struct.unpack_from("<I", pkt)[0] == 0x0B:
                log.out("  CMD_READY")
                return True
            if pkt:
                cmd = struct.unpack_from("<I", pkt)[0]
                log.out(f"  resposta inesperada ao HELLO m3: cmd=0x{cmd:x} {pkt.hex()[:64]}")
            else:
                log.out("  timeout ao entrar em command mode")
            return False

        def reset_state_machine() -> bool:
            transport.write(struct.pack("<II", 0x13, 8))
            pkt = transport.read()
            if pkt and struct.unpack_from("<I", pkt)[0] == 1:
                log.out("  0x13 -> HELLO novo")
                return enter_command_mode()
            log.out(f"  0x13 sem HELLO: {pkt[:32].hex() if pkt else 'timeout'}")
            return False

        if not enter_command_mode():
            log.out("falha inicial em command mode; encerrando")
            txt_path.write_text("\n".join(log.lines) + "\n")
            return 2

        # SWITCH_MODE 0..3
        for sw_mode in range(0, 4):
            log.out(f"SWITCH_MODE {sw_mode}:")
            try:
                transport.write(struct.pack("<3I", 0x0C, 12, sw_mode))
                pkt = transport.read()
                if not pkt:
                    log.out("  timeout")
                    log.out("  tentando HELLO_RSP m3 apos timeout...")
                    if not enter_command_mode():
                        raise ProbeError("sem command mode")
                    continue
                cmd = struct.unpack_from("<I", pkt)[0]
                if cmd == 0x01 and len(pkt) >= 48:
                    mode_field = struct.unpack_from("<I", pkt, 20)[0]
                    log.out(f"  PBL resetou e enviou HELLO (mode={mode_field}); entrando em command mode...")
                    if not enter_command_mode():
                        raise ProbeError("sem command mode pos-HELLO")
                elif cmd == 0x0B:
                    log.out("  CMD_READY (permanece em command mode)")
                elif cmd == 0x04 and len(pkt) >= 16:
                    status = struct.unpack_from("<I", pkt, 12)[0]
                    log.out(f"  NAK status=0x{status:02x}")
                    log.out("  recuperando com 0x13...")
                    if not reset_state_machine():
                        raise ProbeError("recuperacao falhou")
                else:
                    log.out(f"  resposta 0x{cmd:x} {pkt.hex()[:96]}")
                    log.out("  recuperando com 0x13...")
                    if not reset_state_machine():
                        raise ProbeError("recuperacao falhou")
            except ProbeError as exc:
                log.out(f"  {exc}; encerrando")
                break

        # MEMORY_DEBUG via HELLO mode=2
        log.out("MEMORY_DEBUG (HELLO mode=2):")
        try:
            hello(transport, 2, version)
            pkt = transport.read()
            if not pkt:
                log.out("  timeout")
            else:
                cmd = struct.unpack_from("<I", pkt)[0]
                if cmd == 0x10:
                    addr, length = struct.unpack_from("<QQ", pkt, 8)
                    log.out(f"  TABELA 64-bit: addr=0x{addr:x} length={length}")
                elif cmd == 0x09:
                    addr, length = struct.unpack_from("<II", pkt, 8)
                    log.out(f"  TABELA 32-bit: addr=0x{addr:x} length={length}")
                elif cmd == 0x04 and len(pkt) >= 16:
                    status = struct.unpack_from("<I", pkt, 12)[0]
                    log.out(f"  NAK status=0x{status:02x}")
                else:
                    log.out(f"  cmd 0x{cmd:x} {pkt.hex()[:96]}")
        except ProbeError as exc:
            log.out(f"  {exc}")

        # MEMORY_READ 64-bit direto (64B em 0x0 e 0x14000000)
        for addr in (0x0, 0x14000000):
            log.out(f"MEMORY_READ 64-bit @0x{addr:x} (64B):")
            try:
                log.out("  entrando em command mode...")
                if not reset_state_machine():
                    raise ProbeError("sem command mode")
                transport.write(struct.pack("<IIQQ", 0x11, 24, addr, 64))
                pkt = transport.read()
                if not pkt:
                    log.out("  timeout")
                    continue
                cmd = struct.unpack_from("<I", pkt)[0]
                if cmd == 0x04 and len(pkt) >= 16:
                    status = struct.unpack_from("<I", pkt, 12)[0]
                    log.out(f"  NAK status=0x{status:02x}")
                elif cmd == 0x12:
                    log.out(f"  MEMORY_READ_DATA: {pkt.hex()[:96]}")
                else:
                    log.out(f"  cmd 0x{cmd:x} {pkt.hex()[:96]}")
            except ProbeError as exc:
                log.out(f"  {exc}; encerrando")
                break
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
