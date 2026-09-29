#!/usr/bin/env python3
"""Generate a PLACEHOLDER Parlor app icon (needs production art — R-DS-6.1).

Writes a 1024x1024 master PNG using only the Python standard library (no Pillow, no
network) so it runs in a headless/offline build environment. The master is then
downscaled by `sips` into the sizes an Xcode AppIcon set expects (see the sibling
Makefile-less caller in App/Sources/Assets.xcassets/AppIcon.appiconset).

The art is deliberately plain and clearly a stand-in: a felt-green rounded panel, a
diagonal "placeholder" hazard stripe, and a centered chip/token disc. It is flagged
"needs production art" in tasks.md (Placeholder-art register) and README.txt beside the
icon set. Replace before any release build (task 8.5 audit).
"""

import math
import struct
import sys
import zlib

SIZE = 1024


def clamp(v: float) -> int:
    return max(0, min(255, int(round(v))))


def make_master(size: int) -> bytes:
    """Return raw RGBA pixel rows for the master icon."""
    # Palette (felt-club-table placeholder).
    bg = (14, 46, 32)          # deep felt green
    bg2 = (20, 66, 46)         # lighter felt green
    stripe = (198, 168, 74)    # brass "placeholder hazard" stripe
    disc = (232, 232, 224)     # chip/token disc
    disc_ring = (176, 60, 60)  # chip ring

    r = size * 0.20            # corner radius (macOS icons are rounded via mask too)
    cx = cy = size / 2.0
    disc_r = size * 0.26
    ring_r = size * 0.30

    rows = bytearray()
    for y in range(size):
        rows.append(0)  # PNG filter byte (None) per scanline
        for x in range(size):
            # Rounded-rectangle alpha mask.
            dx = max(r - x, x - (size - r), 0.0)
            dy = max(r - y, y - (size - r), 0.0)
            corner = math.hypot(dx, dy)
            alpha = 255 if corner <= r else 0

            # Diagonal felt gradient.
            t = (x + y) / (2.0 * size)
            rr = bg[0] + (bg2[0] - bg[0]) * t
            gg = bg[1] + (bg2[1] - bg[1]) * t
            bb = bg[2] + (bg2[2] - bg[2]) * t

            # Diagonal "placeholder" hazard stripes near the top-left corner.
            band = ((x - y) % (size // 6))
            if x + y < size * 0.55 and band < (size // 24):
                rr, gg, bb = stripe

            # Centered chip/token disc with a ring.
            d = math.hypot(x - cx, y - cy)
            if d <= disc_r:
                rr, gg, bb = disc
            elif d <= ring_r:
                rr, gg, bb = disc_ring

            rows.extend((clamp(rr), clamp(gg), clamp(bb), alpha))
    return bytes(rows)


def write_png(path: str, size: int, raw: bytes) -> None:
    def chunk(tag: bytes, data: bytes) -> bytes:
        return (
            struct.pack(">I", len(data))
            + tag
            + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        )

    sig = b"\x89PNG\r\n\x1a\n"
    ihdr = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)  # 8-bit RGBA
    idat = zlib.compress(raw, 9)
    with open(path, "wb") as f:
        f.write(sig)
        f.write(chunk(b"IHDR", ihdr))
        f.write(chunk(b"IDAT", idat))
        f.write(chunk(b"IEND", b""))


def main() -> int:
    out = sys.argv[1] if len(sys.argv) > 1 else "icon_1024.png"
    write_png(out, SIZE, make_master(SIZE))
    print(f"wrote {out} ({SIZE}x{SIZE})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
