#!/usr/bin/env python3
"""Offline inventory of the original Yoga Windows IR sensor/config blobs.

Reads the user's private export and writes JSON to an explicitly selected
private output directory. Does not install or apply registers to hardware.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct


def table(path):
    b = path.read_bytes()
    base = struct.unpack_from('<I', b, 0xb8)[0]
    assert base >= 0xcc and (base - 0xcc) % 56 == 0
    records = {}
    for pos in range(0xcc, base, 56):
        rid = struct.unpack_from('<I', b, pos)[0]
        name = b[pos + 4:pos + 36].split(b'\0', 1)[0].decode('ascii')
        a, c, d, off, size = struct.unpack_from('<5I', b, pos + 36)
        assert rid not in records and base + off + size <= len(b)
        records[rid] = dict(id=rid, name=name, meta=[a, c, d], offset=off, length=size)
    def payload(rid):
        rec = records[rid]
        return b[base + rec['offset']:base + rec['offset'] + rec['length']]
    return records, payload


def inspect(sensor, platform):
    records, data = table(sensor)
    settings = []
    for rec in records.values():
        if rec['name'] != 'regSetting':
            continue
        b = data(rec['id'])
        assert len(b) % 40 == 0
        for index, pos in enumerate(range(0, len(b), 40)):
            f = struct.unpack_from('<10I', b, pos)
            values = list(struct.unpack('<' + str(f[3]) + 'I', data(f[4])[:f[3] * 4]))
            delays = list(struct.unpack('<' + str(f[8]) + 'I', data(f[9])[:f[8] * 4]))
            settings.append(dict(set_record=rec['id'], index=index, address=f[2], data=values,
                                 address_type=f[5], data_type=f[6], operation=f[7],
                                 delay_us=delays, raw_fields=list(f)))
    blob = platform.read_bytes()
    assert blob[:4] == b'AeoB'
    kind, size = struct.unpack_from('<HH', blob, 12)
    assert kind == 3
    vals = []
    for pos in range(16, 16 + size, 12):
        kind, size = struct.unpack_from('<HH', blob, pos)
        assert kind == 0 and size == 8
        vals.append(struct.unpack_from('<Q', blob, pos + 4)[0])
    fields = {'orientation': (0, 4), 'direction': (4, 4), 'flash_present': (8, 1),
              'flash_index': (9, 3), 'flash_cci_timer_index': (12, 2),
              'flash_trigger_type': (14, 2), 'i2c_master': (16, 4), 'csiphy': (20, 4),
              'face_authentication': (24, 1), 'shutter_type': (25, 1)}
    platform_data = dict(raw_values=vals, presence_bitmap=vals[0], slots=[])
    for i, word in enumerate(vals[1:9]):
        platform_data['slots'].append(dict(slot=i, present=bool(vals[0] & (1 << i)),
            raw_word=word, **{n: (word >> shift) & ((1 << bits) - 1)
                             for n, (shift, bits) in fields.items()}))
    return list(records.values()), settings, platform_data


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('export', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    def unique(name):
        paths = list(args.export.rglob(name))
        assert len(paths) == 1, (name, len(paths))
        return paths[0]
    sensor = unique('com.qti.sensormodule.st_vd55g0.bin')
    platform = unique('CAMP_PCFG_QRD.bin')
    records, settings, plat = inspect(sensor, platform)
    args.output.mkdir(parents=True, exist_ok=True)
    objects = {'vd55g0-sensor-records.json': records,
               'vd55g0-register-settings.json': settings, 'platform-ir.json': plat}
    files = [sensor, platform, unique('qccamplatform8480.sys'), unique('qccamflash8480.sys'),
             unique('qcpmic8480.sys'), unique('com.qti.tuned.lvi_st_vd55g0.bin'),
             unique('com.qti.tuned.chi_st_vd55g0.bin')]
    objects['source-manifest.json'] = [dict(file=str(p.relative_to(args.export)), size=p.stat().st_size,
        sha256=hashlib.sha256(p.read_bytes()).hexdigest()) for p in files]
    for name, obj in objects.items():
        (args.output / name).write_text(json.dumps(obj, indent=2) + '\n')
    print(f'Extracted {len(records)} records, {len(settings)} register operations, {len(plat["slots"])} platform slots')


if __name__ == '__main__':
    main()
