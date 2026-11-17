#!/usr/bin/env python3
"""Modelo ONNX Abs float32 [1,4], sem dependencia protobuf no notebook."""
import sys
from pathlib import Path


def varint(value):
    assert value >= 0
    result = bytearray()
    while value > 127:
        result.append((value & 127) | 128)
        value >>= 7
    return bytes(result) + bytes([value])


def field(number, value):
    if isinstance(value, int):
        return varint(number << 3) + varint(value)
    if isinstance(value, str):
        value = value.encode()
    return varint((number << 3) | 2) + varint(len(value)) + value


def tensor_info(name):
    shape = field(1, field(1, 1)) + field(1, field(1, 4))
    tensor = field(1, 1) + field(2, shape)
    return field(1, name) + field(2, field(1, tensor))


assert varint(128) == b'\x80\x01' and field(1, 8) == b'\x08\x08'
node = field(1, 'input') + field(2, 'output') + field(3, 'abs') + field(4, 'Abs')
graph = (field(1, node) + field(2, 'yoga_abs') +
         field(11, tensor_info('input')) + field(12, tensor_info('output')))
model = field(1, 8) + field(7, graph) + field(8, field(2, 13))
Path(sys.argv[1]).write_bytes(model)
