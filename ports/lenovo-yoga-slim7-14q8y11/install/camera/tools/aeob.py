#!/usr/bin/env python3
"""Decodifica AeoB (ACPI-less PEP resource binary da Qualcomm): TLV u16 tipo, u16 tamanho.
tipo 3 = pacote, 1 = string, 0 = inteiro (8 bytes LE), 2 = buffer."""
import struct, sys

def parse(b, off, end, depth, out):
    while off + 4 <= end:
        t, l = struct.unpack_from('<HH', b, off)
        off += 4
        p = b[off:off + l]
        if t == 3:
            out.append('  ' * depth + '(')
            parse(b, off, off + l, depth + 1, out)
            out.append('  ' * depth + ')')
        elif t == 1:
            out.append('  ' * depth + '"' + p.rstrip(b'\0').decode('latin1') + '"')
        elif t == 0 and l == 8:
            v = struct.unpack('<Q', p)[0]
            out.append('  ' * depth + f'{v} (0x{v:x})')
        else:
            out.append('  ' * depth + f'<t{t} l{l} {p.hex()}>')
        off += l
    return out

def flat(lines):
    """junta pacotes folha numa linha so"""
    res, i = [], 0
    while i < len(lines):
        s = lines[i]
        if s.strip() == '(':
            j = i + 1
            while j < len(lines) and lines[j].strip() not in '()':
                j += 1
            if j < len(lines) and lines[j].strip() == ')':
                res.append(s[:-1] + '( ' + ', '.join(x.strip() for x in lines[i + 1:j]) + ' )')
                i = j + 1
                continue
        res.append(s)
        i += 1
    return res

if __name__ == '__main__':
    b = open(sys.argv[1], 'rb').read()
    assert b[:4] == b'AeoB', 'nao e AeoB'
    size, ver = struct.unpack_from('<II', b, 4)
    print(f'# size={size} ver={ver} filelen={len(b)}')
    print('\n'.join(flat(parse(b, 12, len(b), 0, []))))
