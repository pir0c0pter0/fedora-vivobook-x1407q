#!/usr/bin/env python3
"""x1407qa-sahara-stateprobe.py

Explora a maquina de estados Sahara do PBL a016 (ASUS X1407QA):

 * um HELLO_RSP(mode=3) e aceito; exec funciona ate o primeiro NAK;
 * apos um NAK o PBL sai do command mode (exec passa a responder 0x01);
 * RESET_STATE_MACHINE(0x13) -> HELLO novo -> HELLO_RSP(mode=3) -> CMD_READY
   recupera o command mode sem replug fisico (rec A validada em 2026-11-05);
 * a sessao enverga apos ~13-15 escritas USB; --wait-fresh aguarda o
   watchdog/replug e continua em fatias.

Nenhum loader e enviado; nenhuma escrita de firmware acontece.
"""

from __future__ import annotations

import argparse
import hashlib
import struct
import sys
import time
from dataclasses import dataclass
from pathlib import Path

READ_TIMEOUT_MS = 2000


class ProbeError(RuntimeError):
    pass


class UsbTransport:
    def __init__(self):
        import usb.core
        import usb.util

        self._usb_util = usb.util
        self._device = usb.core.find(idVendor=0x05C6, idProduct=0x9008)
        if self._device is None:
            raise ProbeError("dispositivo 05c6:9008 nao encontrado; replugue o cabo")
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

    def read(self, timeout_ms: int = READ_TIMEOUT_MS) -> bytes:
        try:
            return bytes(self._in.read(4096, timeout=timeout_ms))
        except Exception as exc:
            if getattr(exc, "errno", None) == 110 or "timed out" in str(exc).lower():
                return b""
            raise ProbeError(f"falha de leitura USB: {exc}") from exc

    def write(self, data: bytes) -> None:
        try:
            written = self._out.write(data, timeout=10000)
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


def hello(transport, log, mode: int, version: int) -> None:
    transport.write(struct.pack("<12I", 2, 48, version, 1, 0, mode, 1, 2, 3, 4, 5, 6))


def drain(transport, log, label: str, timeout_ms: int = 300) -> bytes:
    packet = transport.read(timeout_ms)
    if packet:
        cmd = struct.unpack_from("<I", packet)[0]
        log.out(f"  [drain {label}] cmd=0x{cmd:x} len={len(packet)}B {packet.hex()[:96]}")
    return packet


def exec_command(transport, log, mcmd: int, collect_chunks: bool = False) -> dict:
    transport.write(struct.pack("<3I", 0x0D, 12, mcmd))
    packet = transport.read()
    if not packet:
        log.out(f"  exec 0x{mcmd:02x}: timeout (sem resposta)")
        return {"kind": "timeout"}
    command = struct.unpack_from("<I", packet)[0]
    if command == 0x0E:
        if len(packet) < 16:
            return {"kind": "truncated", "hex": packet.hex()}
        _, _, client_command, data_len = struct.unpack_from("<4I", packet)
        payload = b""
        if collect_chunks:
            rounds = 0
            while 0 < data_len and rounds < 32:
                transport.write(struct.pack("<3I", 0x0F, 12, mcmd))
                chunk = transport.read(min(data_len, 4096) + 500)
                payload += chunk[:data_len]
                if len(chunk) < data_len:
                    break
                more = transport.read(800)
                if not more:
                    break
                cm = struct.unpack_from("<I", more)[0]
                if cm == 0x0E and len(more) >= 16:
                    _, _, client_command, data_len = struct.unpack_from("<4I", more)
                    rounds += 1
                else:
                    break
        elif 0 < data_len <= 4096:
            transport.write(struct.pack("<3I", 0x0F, 12, mcmd))
            payload = transport.read(data_len + 500)[:data_len]
        digest = hashlib.sha256(payload).hexdigest()[:16] if payload else "-"
        log.out(
            f"  exec 0x{mcmd:02x}: OK client=0x{client_command:x} data_len={data_len} "
            f"payload={len(payload)}B sha256[:16]={digest}"
        )
        if payload:
            hexview = payload.hex()
            log.out(f"    payload: {hexview[:256]}{'...' if len(hexview) > 256 else ''}")
        return {"kind": "ok", "payload": payload}
    if command == 0x04:
        if len(packet) < 16:
            return {"kind": "truncated", "hex": packet.hex()}
        image_id, status = struct.unpack_from("<II", packet, 8)
        log.out(f"  exec 0x{mcmd:02x}: NAK image_id={image_id} status=0x{status:02x}")
        return {"kind": "nak", "status": status}
    log.out(f"  exec 0x{mcmd:02x}: resposta inesperada 0x{command:x} {packet.hex()[:96]}")
    return {"kind": "other", "hex": packet.hex()}


def recovery_lean(transport, log, version) -> bool:
    transport.write(struct.pack("<II", 0x13, 8))
    pkt = transport.read()
    if pkt and struct.unpack_from("<I", pkt)[0] == 1:
        hello(transport, log, 3, version)
        drain(transport, log, "cmd_ready")
        return True
    log.out(f"  recovery_lean: sem HELLO apos 0x13: {pkt[:32].hex() if pkt else 'timeout'}")
    return False


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dmss", action="store_true", help="inclui SWITCH_TO_DMSS_DLOAD (0x04) na varredura")
    parser.add_argument("--stream", action="store_true", help="inclui SWITCH_TO_STREAM_DLOAD (0x05) na varredura")
    parser.add_argument("--start", type=lambda v: int(v, 0), default=0x00, help="inicio da varredura (default 0x00)")
    parser.add_argument("--end", type=lambda v: int(v, 0), default=0x40, help="fim da varredura, exclusivo (default 0x40)")
    parser.add_argument("--skip-baseline", action="store_true", help="pula baseline/NAK/canario e vai direto a varredura")
    parser.add_argument("--no-post", action="store_true", help="pula SWITCH_MODE/MEMORY_DEBUG/MEMORY_READ pos-varredura")
    parser.add_argument("--wait-fresh", type=int, default=0, metavar="MIN", help="aguarda ate N minutos por HELLO novo antes de desistir")
    args = parser.parse_args()

    timestamp = time.strftime("%Y%m%d-%H%M%S")
    outdir = Path(__file__).resolve().parent.parent
    txt_path = outdir / f"pbl-stateprobe-{timestamp}.txt"

    log = SessionLog([])
    log.out(f"=== x1407qa-sahara-stateprobe {timestamp} ===")

    try:
        transport = UsbTransport()
    except ProbeError as exc:
        log.out(f"ERRO: {exc}")
        txt_path.write_text("\n".join(log.lines) + "\n")
        return 2

    try:
        # Aquisicao do HELLO (com espera opcional por watchdog/replug)
        hello_pkt = b""
        if args.wait_fresh > 0:
            deadline = time.time() + args.wait_fresh * 60
            while time.time() < deadline:
                pkt = transport.read(3000)
                if pkt and struct.unpack_from("<I", pkt)[0] == 1 and len(pkt) >= 48:
                    hello_pkt = pkt
                    break
                log.out("sem HELLO novo; aguardando 30s (watchdog/replug)...")
                transport.close()
                time.sleep(30)
                try:
                    transport = UsbTransport()
                except ProbeError as exc:
                    log.out(f"ERRO reabrindo USB: {exc}")
                    txt_path.write_text("\n".join(log.lines) + "\n")
                    return 2
            if not hello_pkt:
                log.out("tempo esgotado aguardando HELLO")
                txt_path.write_text("\n".join(log.lines) + "\n")
                return 2
        else:
            hello_pkt = transport.read(5000)
            if not hello_pkt:
                log.out("sem HELLO em 5s; tentando HELLO_RSP proativo (estado pendente)")
                hello(transport, log, 3, 3)
                hello_pkt = transport.read()
            if not hello_pkt:
                log.out("ERRO: nenhuma resposta; replugue e rode novamente")
                txt_path.write_text("\n".join(log.lines) + "\n")
                return 2

        if struct.unpack_from("<I", hello_pkt)[0] != 1 or len(hello_pkt) < 48:
            log.out(f"ERRO: esperado HELLO, recebido {hello_pkt[:16].hex()}")
            txt_path.write_text("\n".join(log.lines) + "\n")
            return 2
        version = struct.unpack_from("<I", hello_pkt, 8)[0]
        cmd_packet_length = struct.unpack_from("<I", hello_pkt, 16)[0]
        mode = struct.unpack_from("<I", hello_pkt, 20)[0]
        log.out(f"HELLO_REQ: version={version} cmd_packet_length={cmd_packet_length} mode={mode}")

        skip = set()
        if not args.dmss:
            skip.add(0x04)
        if not args.stream:
            skip.add(0x05)

        if args.skip_baseline:
            hello(transport, log, 3, version)
            drain(transport, log, "hello m3 (skip-baseline)")
        else:
            log.out("Baseline (fresh state):")
            hello(transport, log, 3, version)
            drain(transport, log, "hello m3 inicial")
            exec_command(transport, log, 0x00)
            exec_command(transport, log, 0x01)
            log.out("NAK intencional (exec 0x02):")
            exec_command(transport, log, 0x02)
            log.out("Canario apos NAK (exec 0x01):")
            canary = exec_command(transport, log, 0x01)
            if canary["kind"] == "ok":
                log.out("Estado command mode manteve-se apos NAK (inesperado)")
            else:
                log.out("Estado perdido apos NAK; recuperando (rec A)...")
                try:
                    recovery_lean(transport, log, version)
                    probe = exec_command(transport, log, 0x01)
                    log.out("rec A " + ("OK" if probe["kind"] == "ok" else "FALHOU"))
                except ProbeError as exc:
                    log.out(f"rec A falhou: {exc}")

        log.out(f"Varredura client commands 0x{args.start:02x}..0x{args.end:02x}:")
        for mcmd in range(args.start, args.end):
            if mcmd in skip:
                log.out(f"  exec 0x{mcmd:02x}: omitido")
                continue
            try:
                res = exec_command(transport, log, mcmd, collect_chunks=(mcmd == 0x06))
            except ProbeError as exc:
                log.out(f"  exec 0x{mcmd:02x}: {exc}; encerrando")
                break
            if res["kind"] == "ok":
                if mcmd == 0x06 and res.get("payload"):
                    dbg_path = outdir / f"pbl-stateprobe-{timestamp}-debug.bin"
                    dbg_path.write_bytes(res["payload"])
                    log.out(f"    debug salvo em {dbg_path.name} ({len(res['payload'])}B)")
                continue
            try:
                ok = recovery_lean(transport, log, version)
                if not ok:
                    log.out("  recuperacao falhou no meio da varredura; encerrando")
                    break
            except ProbeError as exc:
                log.out(f"  wedge na recuperacao: {exc}; encerrando")
                break

        if args.no_post:
            log.out("pos-varredura omitida (--no-post)")
        else:
            # SWITCH_MODE 0..3
            log.out("SWITCH_MODE (0x0C):")
            for sw_mode in range(0, 4):
                if sw_mode > 0:
                    try:
                        recovery_lean(transport, log, version)
                    except ProbeError as exc:
                        log.out(f"  wedge antes do SWITCH_MODE {sw_mode}: {exc}")
                        break
                try:
                    transport.write(struct.pack("<3I", 0x0C, 12, sw_mode))
                    packet = transport.read()
                    if not packet:
                        log.out(f"  SWITCH_MODE {sw_mode}: timeout")
                        continue
                    command = struct.unpack_from("<I", packet)[0]
                    if command == 0x0B:
                        log.out(f"  SWITCH_MODE {sw_mode}: CMD_READY")
                    elif command == 0x04:
                        status = struct.unpack_from("<I", packet, 12)[0]
                        log.out(f"  SWITCH_MODE {sw_mode}: NAK status=0x{status:02x}")
                    else:
                        log.out(f"  SWITCH_MODE {sw_mode}: cmd 0x{command:x} {packet.hex()[:96]}")
                except ProbeError as exc:
                    log.out(f"  SWITCH_MODE {sw_mode}: {exc}")
                    break

            # MEMORY_DEBUG via HELLO mode=2
            log.out("MEMORY_DEBUG (HELLO mode=2):")
            try:
                recovery_lean(transport, log, version)
            except ProbeError as exc:
                log.out(f"  wedge antes do MEMORY_DEBUG: {exc}")
            else:
                try:
                    hello(transport, log, 2, version)
                    packet = transport.read()
                    if not packet:
                        log.out("  MEMORY_DEBUG: timeout")
                    else:
                        command = struct.unpack_from("<I", packet)[0]
                        if command == 0x10:
                            addr, length = struct.unpack_from("<QQ", packet, 8)
                            log.out(f"  MEMORY_DEBUG 64-bit: table_addr=0x{addr:x} length={length}")
                        elif command == 0x09:
                            addr, length = struct.unpack_from("<II", packet, 8)
                            log.out(f"  MEMORY_DEBUG 32-bit: table_addr=0x{addr:x} length={length}")
                        elif command == 0x04:
                            status = struct.unpack_from("<I", packet, 12)[0]
                            log.out(f"  MEMORY_DEBUG: NAK status=0x{status:02x}")
                        else:
                            log.out(f"  MEMORY_DEBUG: cmd 0x{command:x} {packet.hex()[:96]}")
                except ProbeError as exc:
                    log.out(f"  MEMORY_DEBUG: {exc}")

            # MEMORY_READ 64-bit direto
            log.out("MEMORY_READ 64-bit direto (64B):")
            for addr in (0x0, 0x14000000):
                try:
                    recovery_lean(transport, log, version)
                except ProbeError as exc:
                    log.out(f"  wedge antes do MEMORY_READ @0x{addr:x}: {exc}")
                    break
                try:
                    transport.write(struct.pack("<IIQQ", 0x11, 24, addr, 64))
                    packet = transport.read()
                    if not packet:
                        log.out(f"  MEMORY_READ @0x{addr:x}: timeout")
                        continue
                    command = struct.unpack_from("<I", packet)[0]
                    if command == 0x04:
                        status = struct.unpack_from("<I", packet, 12)[0]
                        log.out(f"  MEMORY_READ @0x{addr:x}: NAK status=0x{status:02x}")
                    else:
                        log.out(f"  MEMORY_READ @0x{addr:x}: cmd 0x{command:x} {packet.hex()[:96]}")
                except ProbeError as exc:
                    log.out(f"  MEMORY_READ @0x{addr:x}: {exc}")
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
