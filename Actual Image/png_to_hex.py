#!/usr/bin/env python3
"""
png_to_hex.py

Converts test.png (must be 256x256) into image_in.hex: one 8-bit
hex byte per line, in row-major order (row 0 first, left to right),
suitable for $readmemh() in tb_actual_image.sv.

Run this BEFORE the simulation:
    python3 png_to_hex.py

Requires Pillow: pip install pillow --break-system-packages
"""

from PIL import Image
import sys

IN_FILE  = "test.png"
OUT_FILE = "image_in.hex"
W, H = 256, 256

def main():
    img = Image.open(IN_FILE)

    if img.mode != "L":
        print(f"Note: input mode is {img.mode}, converting to 8-bit grayscale (L).")
        img = img.convert("L")

    if img.size != (W, H):
        print(f"Note: input is {img.size}, resizing to {W}x{H}.")
        img = img.resize((W, H))

    px = img.load()
    with open(OUT_FILE, "w") as f:
        for y in range(H):
            for x in range(W):
                f.write(f"{px[x, y]:02x}\n")

    print(f"Wrote {W*H} pixel values to {OUT_FILE}")

if __name__ == "__main__":
    main()
