#!/usr/bin/env python3
"""Valida binarios Hexagon contra o whitelist de hashes do firmware CDSP assinado.

O firmware assinado (qccdsp8380.mbn) carrega o SHA-256 de cada segmento ELF que
aceita executar. Um binario so roda no DSP quando TODOS os digests dos seus
segmentos aparecem como bytes crus dentro do .mbn. Shell de build errado =
falha de carregamento no Hexagon.

Uso:
    hexagon-authcheck.py --mbn <qccdsp8380.mbn> <diretorio-com-binarios>
    hexagon-authcheck.py --self-check

Saida: uma linha por binario (com --verbose) e o resumo "<ok>/<total>".
Exit 0 somente quando todos os binarios ELF do diretorio estao autorizados.
"""

import argparse
import hashlib
import os
import struct
import sys

ELF_MAGIC = b"\x7fELF"


def segment_digests(data):
    """SHA-256 de cada segmento com conteudo de um ELF Hexagon (32-bit, LE)."""
    e_phoff = struct.unpack_from("<I", data, 28)[0]
    e_phentsize = struct.unpack_from("<H", data, 42)[0]
    e_phnum = struct.unpack_from("<H", data, 44)[0]
    digests = []
    for index in range(e_phnum):
        phdr = e_phoff + index * e_phentsize
        p_offset = struct.unpack_from("<I", data, phdr + 4)[0]
        p_filesz = struct.unpack_from("<I", data, phdr + 16)[0]
        if p_filesz == 0:
            continue
        end = p_offset + p_filesz
        if end > len(data):
            raise ValueError("program header aponta para fora do arquivo")
        digests.append(hashlib.sha256(data[p_offset:end]).digest())
    return digests


def check_binary(path, mbn):
    """(autorizados, total) do arquivo; None quando nao e um ELF."""
    with open(path, "rb") as handle:
        data = handle.read()
    if not data.startswith(ELF_MAGIC):
        return None
    try:
        digests = segment_digests(data)
    except (struct.error, ValueError):
        return (0, 0)
    found = sum(1 for digest in digests if digest in mbn)
    return (found, len(digests))


def check_dir(directory, mbn):
    rows = []
    for name in sorted(os.listdir(directory)):
        path = os.path.join(directory, name)
        if not os.path.isfile(path) or os.path.islink(path):
            continue
        result = check_binary(path, mbn)
        if result is None:
            continue
        rows.append((name, result[0], result[1]))
    return rows


def self_check():
    """Checagem minima do parser + da regra de autorizacao (sem tocar o disco)."""
    seg_a, seg_b = b"HEXAGON-A" * 7, b"HEXAGON-B" * 11
    ehsize, phentsize = 52, 32
    body = seg_a + seg_b
    off_a, off_b = ehsize + 2 * phentsize, ehsize + 2 * phentsize + len(seg_a)
    elf = bytearray(ELF_MAGIC + b"\x01\x01\x01" + b"\x00" * 9)
    elf += struct.pack("<HHIIIIIHHHHHH", 2, 164, 1, 0, ehsize, 0, 0,
                       ehsize, phentsize, 2, 40, 0, 0)
    for offset, size in ((off_a, len(seg_a)), (off_b, len(seg_b))):
        elf += struct.pack("<IIIIIIII", 1, offset, 0, 0, size, size, 5, 4096)
    elf += body
    elf = bytes(elf)

    digest_a = hashlib.sha256(seg_a).digest()
    digest_b = hashlib.sha256(seg_b).digest()
    assert segment_digests(elf) == [digest_a, digest_b], "parser de phdr quebrado"

    good_mbn = b"\xff" * 64 + digest_a + b"\x00" * 16 + digest_b + b"\xee" * 32
    bad_mbn = b"\xff" * 64 + digest_a + b"\x00" * 16
    assert sum(1 for d in segment_digests(elf) if d in good_mbn) == 2
    assert sum(1 for d in segment_digests(elf) if d in bad_mbn) == 1, \
        "shell nao autorizado passou como autorizado"
    print("self-check ok")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", nargs="?",
                        help="diretorio com os binarios Hexagon do CDSP")
    parser.add_argument("--mbn", help="firmware CDSP assinado em uso (.mbn)")
    parser.add_argument("--verbose", action="store_true",
                        help="imprime uma linha por binario")
    parser.add_argument("--self-check", action="store_true",
                        help="valida o proprio parser e sai")
    args = parser.parse_args()

    if args.self_check:
        return self_check()
    if not args.directory or not args.mbn:
        parser.error("--mbn e o diretorio sao obrigatorios")
    if not os.path.isdir(args.directory):
        print(f"nao e um diretorio: {args.directory}", file=sys.stderr)
        return 2
    with open(args.mbn, "rb") as handle:
        mbn = handle.read()

    rows = check_dir(args.directory, mbn)
    authorized = [row for row in rows if row[2] > 0 and row[1] == row[2]]
    if args.verbose:
        for name, found, total in rows:
            status = "ok " if total > 0 and found == total else "NAO"
            print(f"{status} {name}: {found}/{total} segmentos no whitelist")
    print(f"{len(authorized)}/{len(rows)}")
    return 0 if rows and len(authorized) == len(rows) else 1


if __name__ == "__main__":
    sys.exit(main())
