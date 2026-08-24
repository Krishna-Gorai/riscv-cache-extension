#!/usr/bin/env python3
"""Convert a flat binary image into the word-per-line hex format $readmemh wants.

The ITCM is a 32-bit word array starting at address 0, so the image is emitted
as little-endian words, one 8-digit hex value per line, zero padded to a whole
word at the end.
"""
import sys


def main() -> int:
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} <in.bin> <out.hex>", file=sys.stderr)
        return 2

    with open(sys.argv[1], "rb") as f:
        data = f.read()

    if len(data) % 4:
        data += b"\x00" * (4 - len(data) % 4)

    with open(sys.argv[2], "w") as f:
        for i in range(0, len(data), 4):
            word = int.from_bytes(data[i:i + 4], "little")
            f.write(f"{word:08x}\n")

    print(f"{sys.argv[2]}: {len(data)//4} words ({len(data)} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
