#!/usr/bin/env python3
"""
uart_image_transfer.py

Talks to basys3_top over the Basys3's USB-UART bridge:
  1. Reads image_in.hex (produced by png_to_hex.py: one hex byte per line,
     65536 lines for a 256x256 image).
  2. Sends the raw bytes over UART.
  3. Waits for 65536 bytes back and writes them to output_image.hex in the
     same one-hex-byte-per-line format that hex_to_png.py expects.

Usage:
    python3 png_to_hex.py                 # produces image_in.hex
    python3 uart_image_transfer.py COM5   # or /dev/ttyUSB1, etc.
    python3 hex_to_png.py                 # produces edges_out.png

Requires pyserial: pip install pyserial --break-system-packages
"""

import sys
import time

try:
    import serial
except ImportError:
    print("This script needs pyserial: pip install pyserial --break-system-packages")
    sys.exit(1)

IN_FILE  = "image_in.hex"
OUT_FILE = "output_image.hex"
W, H     = 256, 256
NPIX     = W * H
BAUD     = 115200


def main():
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <serial-port>")
        print("  e.g. python3 uart_image_transfer.py COM5")
        print("       python3 uart_image_transfer.py /dev/ttyUSB1")
        sys.exit(1)

    port = sys.argv[1]

    with open(IN_FILE) as f:
        vals = [int(line.strip(), 16) for line in f if line.strip()]
    if len(vals) != NPIX:
        print(f"WARNING: expected {NPIX} bytes in {IN_FILE}, got {len(vals)}")
    payload = bytes(vals[:NPIX])

    print(f"Opening {port} at {BAUD} baud...")
    with serial.Serial(port, BAUD, timeout=5) as ser:
        # let the board settle / flush any junk
        time.sleep(0.2)
        ser.reset_input_buffer()

        print(f"Sending {len(payload)} bytes...")
        t0 = time.time()
        ser.write(payload)
        ser.flush()
        print(f"  sent in {time.time()-t0:.2f}s")

        print(f"Waiting for {NPIX} bytes back...")
        t0 = time.time()
        result = bytearray()
        while len(result) < NPIX:
            chunk = ser.read(NPIX - len(result))
            if not chunk:
                print(f"Timed out after receiving {len(result)}/{NPIX} bytes")
                break
            result.extend(chunk)
        print(f"  received {len(result)} bytes in {time.time()-t0:.2f}s")

    with open(OUT_FILE, "w") as f:
        for b in result:
            f.write(f"{b:02x}\n")
    print(f"Wrote {OUT_FILE} ({len(result)} bytes)")


if __name__ == "__main__":
    main()
