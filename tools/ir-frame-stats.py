#!/usr/bin/env python3
"""Report deterministic statistics for the last 560x360-style Y10P frame."""

import math
import struct
import sys
import zlib


def unpack_y10p(frame: bytes, width: int, height: int, stride: int) -> bytearray:
    row_bytes = width * 10 // 8
    pixels = bytearray(width * height)

    for y in range(height):
        row = frame[y * stride : y * stride + row_bytes]
        output = y * width
        x = 0
        offset = 0
        while x < width and offset + 5 <= len(row):
            group = row[offset : offset + 5]
            offset += 5
            for index in range(4):
                if x >= width:
                    break
                value = (group[index] << 2) | ((group[4] >> (2 * index)) & 3)
                pixels[output + x] = value >> 2
                x += 1

    return pixels


def nearest_rank(sorted_values: list[int], percentile: int) -> int:
    index = max(0, math.ceil(percentile * len(sorted_values) / 100) - 1)
    return sorted_values[index]


def png_chunk(tag: bytes, payload: bytes) -> bytes:
    content = tag + payload
    return (
        struct.pack(">I", len(payload))
        + content
        + struct.pack(">I", zlib.crc32(content) & 0xFFFFFFFF)
    )


def write_contrast_png(path: str, pixels: bytearray, width: int, height: int) -> None:
    low = min(pixels)
    high = max(pixels)
    span = max(1, high - low)
    stretched = bytes(min(255, (value - low) * 255 // span) for value in pixels)
    scanlines = b"".join(
        b"\x00" + stretched[y * width : (y + 1) * width] for y in range(height)
    )
    png = (
        b"\x89PNG\r\n\x1a\n"
        + png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 0, 0, 0, 0))
        + png_chunk(b"IDAT", zlib.compress(scanlines, 9))
        + png_chunk(b"IEND", b"")
    )
    with open(path, "wb") as output:
        output.write(png)


def main() -> int:
    if len(sys.argv) not in (4, 5):
        print(f"usage: {sys.argv[0]} RAW WIDTH HEIGHT [PNG]", file=sys.stderr)
        return 2

    raw_path = sys.argv[1]
    width = int(sys.argv[2])
    height = int(sys.argv[3])
    png_path = sys.argv[4] if len(sys.argv) == 5 else None
    if width <= 0 or height <= 0 or width % 4:
        print(
            "Y10P dimensions must be positive and width must be divisible by four",
            file=sys.stderr,
        )
        return 2
    stride = ((width * 10 // 8) + 63) // 64 * 64
    frame_size = stride * height

    with open(raw_path, "rb") as source:
        data = source.read()
    if len(data) < frame_size:
        print(
            f"raw input is too short: {len(data)} bytes, need at least {frame_size}",
            file=sys.stderr,
        )
        return 1
    if len(data) % frame_size:
        print(
            f"raw input has a partial frame: {len(data)} bytes is not aligned to {frame_size}",
            file=sys.stderr,
        )
        return 1

    pixels = unpack_y10p(data[-frame_size:], width, height, stride)
    ordered = sorted(pixels)
    low = ordered[0]
    high = ordered[-1]
    mean = sum(ordered) / len(ordered)

    if png_path:
        write_contrast_png(png_path, pixels, width, height)
        print(f"{png_path}: contraste esticado de [{low},{high}] para [0,255]")

    print(
        f"IR_STATS min={low} max={high} mean={mean:.2f} "
        f"p50={nearest_rank(ordered, 50)} "
        f"p95={nearest_rank(ordered, 95)} "
        f"p99={nearest_rank(ordered, 99)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
