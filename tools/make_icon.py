#!/usr/bin/env python3
"""Draws assets/FantasyManager.ico (used by the Windows shortcuts).

A blue rounded square with a white football, at 16, 32, 48 and 256 pixels.
Standard library only: each size is a PNG image inside the .ico file.
"""

import math
import os
import struct
import zlib

BLUE = (31, 111, 235)
WHITE = (255, 255, 255)


def coverage(inside, x, y, n=4):
    """Share of the pixel (x, y) that is inside the shape, by sampling."""
    hits = sum(1 for i in range(n) for j in range(n) if inside(x + (i + 0.5) / n, y + (j + 0.5) / n))
    return hits / float(n * n)


def draw(size):
    s = float(size)
    radius = 0.22 * s

    def square(px, py):
        cx = min(max(px, radius), s - radius)
        cy = min(max(py, radius), s - radius)
        return (px - cx) ** 2 + (py - cy) ** 2 <= radius ** 2

    # A football: the overlap of two circles, tilted 35 degrees.
    angle = math.radians(-35)
    half_len, half_wid = 0.36 * s, 0.20 * s
    r = (half_len ** 2 + half_wid ** 2) / (2 * half_wid)

    def local(px, py):
        dx, dy = px - s / 2, py - s / 2
        return dx * math.cos(angle) - dy * math.sin(angle), dx * math.sin(angle) + dy * math.cos(angle)

    def ball(px, py):
        u, v = local(px, py)
        return u * u + (v - (r - half_wid)) ** 2 <= r * r and u * u + (v + (r - half_wid)) ** 2 <= r * r

    def laces(px, py):
        u, v = local(px, py)
        seam = abs(v) <= 0.022 * s and abs(u) <= 0.17 * s
        stitch = abs(v) <= 0.075 * s and any(abs(u - k * 0.085 * s) <= 0.018 * s for k in (-1.5, -0.5, 0.5, 1.5))
        return seam or (size >= 32 and stitch)

    rows = []
    for y in range(size):
        row = bytearray([0])
        for x in range(size):
            a = coverage(square, x, y)
            w = coverage(ball, x, y) * (1.0 - coverage(laces, x, y))
            row += bytes(int(round(BLUE[c] + (WHITE[c] - BLUE[c]) * w)) for c in range(3)) + bytes([int(round(255 * a))])
        rows.append(bytes(row))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(b"".join(rows), 9)) + chunk(b"IEND", b""))


def main():
    sizes = (16, 32, 48, 256)
    images = [draw(size) for size in sizes]
    header = struct.pack("<HHH", 0, 1, len(sizes))
    offset = len(header) + 16 * len(sizes)
    entries = b""
    for size, image in zip(sizes, images):
        entries += struct.pack("<BBBBHHII", size % 256, size % 256, 0, 0, 1, 32, len(image), offset)
        offset += len(image)
    out = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "assets", "FantasyManager.ico")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "wb") as fh:
        fh.write(header + entries + b"".join(images))
    print("wrote %s (%d bytes)" % (out, offset))


if __name__ == "__main__":
    main()
