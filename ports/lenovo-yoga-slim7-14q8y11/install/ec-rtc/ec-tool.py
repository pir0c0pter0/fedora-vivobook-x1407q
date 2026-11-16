#!/usr/bin/python3
"""Teste do EC do Yoga 14Q8Y11 sem IRQ e sem DTB novo (rodar como root no notebook).

Fala com o EC (i2c9, 0x70) pelo /dev/i2c-N com o mesmo protocolo do driver
lenovo-yoga-slim7x-gen11-ec e do DSDT (escrita de 7 bytes no registrador 0x02,
leitura de 6 bytes do 0x01), e observa o gpio66 em /sys/kernel/debug/gpio.

  ec-tool.py status        so leitura: gpio66 + RAM (KBLT, SCUK, 0xA3, termistores)
  ec-tool.py drain         le eventos (0x84) ate a fila esvaziar; gpio66 antes/depois
  ec-tool.py watch [seg]   mostra eventos enquanto voce aperta teclas (padrao 60 s)
  ec-tool.py ps0 --write   o que o ACPI faz no _PS0 do teclado: RAM 0xA3 |= 0x40

Nenhum driver pode estar ligado ao 0x70 (as transacoes se misturariam):
  echo N-0070 > /sys/bus/i2c/drivers/lenovo-yoga-slim7x-gen11-ec/unbind
"""
import ctypes
import fcntl
import glob
import os
import sys
import time

ADDR = 0x70
I2C_RDWR = 0x0707
I2C_M_RD = 0x0001
ADAPTER = "/sys/devices/platform/soc@0/ac0000.geniqup/a84000.i2c/i2c-*"

# DSDT \_SB.IC10.INTR (acpi-registry-0000.dsl:101682-101890)
EVENTS = {
    0x07: "WMI 0x10", 0x0E: "WMI 0x3D", 0x0F: "Fn-Lock (o host alterna SCUK)",
    0x13: "WMI 0x29", 0x14: "WMI 0x2A", 0x15: "VPC 3 / termico",
    0x16: "luz do teclado mudou (o EC ja trocou KBLT)", 0x18: "mic mute",
    0x19: "modo aviao", 0x20: "USB", 0x21: "UCSI", 0x22: "HPD",
    0x24: "bateria: estado", 0x25: "bateria: info", 0x29: "camera (CAME)",
    0x30: "WMI 0x48", 0x37: "adaptador AC", 0x3E: "WMI 0x04", 0x3F: "WMI 0x01",
    0x54: "termico (polling)",
}


class Msg(ctypes.Structure):
    _fields_ = [("addr", ctypes.c_uint16), ("flags", ctypes.c_uint16),
                ("len", ctypes.c_uint16), ("buf", ctypes.POINTER(ctypes.c_uint8))]


class Rdwr(ctypes.Structure):
    _fields_ = [("msgs", ctypes.POINTER(Msg)), ("nmsgs", ctypes.c_uint32)]


def xfer(fd, *parts):
    """parts: bytes para escrever, int para ler N bytes. Devolve a ultima leitura."""
    bufs = [(ctypes.c_uint8 * (p if isinstance(p, int) else len(p)))(*([] if isinstance(p, int) else p))
            for p in parts]
    msgs = (Msg * len(parts))(*[
        Msg(ADDR, I2C_M_RD if isinstance(p, int) else 0, len(b),
            ctypes.cast(b, ctypes.POINTER(ctypes.c_uint8)))
        for p, b in zip(parts, bufs)])
    fcntl.ioctl(fd, I2C_RDWR, Rdwr(msgs, len(parts)))
    return bytes(bufs[-1])


def command(fd, cmd, a0=0, a1=0):
    xfer(fd, bytes([0x02, cmd, a0, a1, 0, 0, 0, 0]))
    time.sleep(0.003)
    return xfer(fd, bytes([0x01]), 6)


def ram_read(fd, addr):
    return command(fd, 0xB0, addr)[0]


def event(fd):
    return command(fd, 0x84)[0]


def gpio66():
    with open("/sys/kernel/debug/gpio") as f:
        for line in f:
            if line.startswith(" gpio66 "):
                return line.split()
    sys.exit("gpio66 nao encontrado em /sys/kernel/debug/gpio")


def sample(n=150):
    seq = "".join("H" if gpio66()[3] == "high" else "L" for _ in range(n))
    print(f"gpio66: {seq.count('H')}/{n} amostras em alto, {seq.count('HL')} bordas de descida  [{' '.join(gpio66()[2:])}]")
    return seq


def drain(fd):
    for n in range(64):
        ev = event(fd)
        if not ev:
            print(f"fila vazia depois de {n} evento(s)")
            return True
        print(f"  evento {ev:#04x}  {EVENTS.get(ev, '?')}")
    print("64 eventos lidos e a fila NAO esvaziou")
    return False


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd not in ("status", "drain", "watch", "ps0"):
        sys.exit(__doc__)
    adapters = glob.glob(ADAPTER)
    if len(adapters) != 1:
        sys.exit("barramento a84000.i2c nao encontrado (DTB sem i2c9?)")
    bus = os.path.basename(adapters[0])[4:]
    if os.path.exists(f"/sys/bus/i2c/devices/{bus}-0070/driver"):
        sys.exit(f"ha um driver ligado a {bus}-0070; faca o unbind antes (ver --help)")
    fd = os.open(f"/dev/i2c-{bus}", os.O_RDWR)

    if cmd == "status":
        sample()
        for name, addr in (("KBLT", 0x03), ("SCUK", 0x1C), ("ECDR/0xA3", 0xA3)):
            print(f"{name:10} = {ram_read(fd, addr):#04x}")
        print("S7T1..6    =", [ram_read(fd, a) for a in range(0x12, 0x18)])

    elif cmd == "drain":
        sample()
        ok = drain(fd)
        time.sleep(0.2)
        seq = sample()
        idle = "L" not in seq
        print("RESULTADO:", "gpio66 parou em alto: e a linha de IRQ do EC" if ok and idle
              else "gpio66 continua pulsando: NAO usar o no com IRQ")
        sys.exit(0 if ok and idle else 1)

    elif cmd == "watch":
        end = time.time() + (float(sys.argv[2]) if len(sys.argv) > 2 else 60)
        last = time.time()
        print("aperte as teclas Fn (mic mute, modo aviao, Fn+Esc, luz do teclado)...")
        while time.time() < end:
            low = gpio66()[3] == "low"
            # leitura incondicional 1x/s: pega evento que nao baixou o gpio66
            if low or time.time() - last > 1:
                last = time.time()
                ev = event(fd)
                if ev:
                    print(f"evento {ev:#04x}  {EVENTS.get(ev, '?')}  "
                          f"({'gpio66 em baixo' if low else 'SEM gpio66 em baixo'})")
                elif low:
                    print("gpio66 em baixo e nenhum evento na fila")

    elif cmd == "ps0":
        old = ram_read(fd, 0xA3)
        print(f"0xA3 = {old:#04x}")
        if "--write" not in sys.argv:
            sys.exit("so leitura; com --write grava 0xA3 |= 0x40 (DSDT:94488-94497)")
        command(fd, 0xB1, 0xA3, old | 0x40)
        print(f"0xA3 = {ram_read(fd, 0xA3):#04x}")


if __name__ == "__main__":
    main()
