#!/usr/bin/env python3
"""
hex_to_png.py

Converts output_image.hex (produced by tb_actual_image.sv) back into
a viewable PNG: edges_out.png.

Run this AFTER the simulation:
    python3 hex_to_png.py
"""

from PIL import Image

IN_FILE  = "output_image.hex"
OUT_FILE = "edges_out.png"
W, H = 256, 256

def main():
    with open(IN_FILE) as f:
        vals = [int(line.strip(), 16) for line in f if line.strip()]

    if len(vals) != W * H:
        print(f"WARNING: expected {W*H} values, got {len(vals)}")

    img = Image.new("L", (W, H))
    px = img.load()
    for y in range(H):
        for x in range(W):
            idx = y * W + x
            px[x, y] = vals[idx] if idx < len(vals) else 0

    img.save(OUT_FILE)
    print(f"Saved {OUT_FILE}")

if __name__ == "__main__":
    main()
