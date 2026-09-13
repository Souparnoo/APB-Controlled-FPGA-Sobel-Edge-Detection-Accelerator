# APB-Controlled FPGA Sobel Edge Detection Accelerator

A synthesizable SystemVerilog hardware accelerator that performs **Sobel edge detection** on a 3×3 pixel window, controlled over an **APB (Advanced Peripheral Bus)** register interface. Verified in simulation from the arithmetic core up through a full 256×256 image, and brought up on a real **Digilent Basys3 (Xilinx Artix-7, `xc7a35tcpg236-1`)** FPGA with a working PC ↔ FPGA UART image pipeline.

> Looking for the full story — the original architecture idea that got dropped, every bug found and how, and every design decision along the way? See **[BUILD_LOG.md](./BUILD_LOG.md)** for the complete chronological write-up.

---

## What It Does

A host (in simulation, a testbench; on hardware, a PC over UART) writes nine 8-bit pixel values into a register bank, pulses a START bit, polls a STATUS register until DONE, and reads back one 8-bit edge-magnitude byte. Driven pixel-by-pixel across a full 256×256 image, this produces a complete edge-detected output image — computed entirely by dedicated hardware, no CPU involved in the datapath.

```
                 Software / APB Master
                         │
                         ▼
                 ┌───────────────┐
                 │   APB Slave   │
                 └───────┬───────┘
                         ▼
                 ┌───────────────┐
                 │ Register Bank │
                 │ CONTROL       │
                 │ STATUS        │
                 │ PIXEL00-22    │
                 │ RESULT        │
                 └───────┬───────┘
                         ▼
                 ┌───────────────┐
                 │ Controller FSM│
                 └───────┬───────┘
                         ▼
                 ┌───────────────┐
                 │   Sobel Core  │
                 └───────┬───────┘
                         ▼
                  Edge Magnitude
```

## Key Design Points

- **No multipliers.** Sobel kernel coefficients are only `{-2, -1, 0, +1, +2}`, so the entire datapath is built from adders, subtractors, and a single-bit shift.
- **Magnitude approximation:** `|Gx| + |Gy|` instead of `sqrt(Gx² + Gy²)` — avoids a multiplier and a square-root circuit at the cost of a small accuracy tradeoff.
- **Bit widths derived from the math, not guessed:** 8-bit unsigned pixels → 11-bit signed `Gx`/`Gy` → 12-bit unsigned absolute values → 13-bit sum → saturated (not wrapped) 8-bit result.
- **Interface contract, not just an FSM:** `BUSY` is a single-cycle pulse, so software polls the **sticky `DONE`** flag instead — a deliberate spec decision, not a limitation.
- **Reset-domain-safe:** `PRESETn` is run through a 2-flop synchronizer everywhere it's used, rather than treated as a plain async reset.
- **Board-fit bus:** the APB bus was narrowed from 32-bit to 8-bit (`PADDR`/`PWDATA`/`PRDATA`) specifically so the design's I/O count fits inside the Basys3's switch/button/LED budget.

## Repository Contents

```
System Verilog Files/
├── sobel_core.sv          Combinational Gx/Gy/abs/saturate datapath
├── apb_slave.sv           APB register interface (CONTROL/STATUS/PIXELxx/RESULT)
├── controller.sv          Sequencing FSM (latch pixels → compute → sticky DONE)
├── accelerator_top.sv     Wires apb_slave + controller + sobel_core
├── uart_rx.sv / uart_tx.sv  115200-baud 8N1 UART
├── basys3_top.sv          Board-level FSM: BRAM image buffers + UART + APB sequencing
└── basys3_pll_top.sv      Adds a Clocking Wizard (100MHz → 50MHz) for timing closure

Test_becnhes/
├── tb_sobel_core.sv, tb_controller.sv, tb_apb_slave.sv   Per-module testbenches
├── tb_accelerator_top.sv  Full system-level APB testbench
└── tb_basys3_top.sv       Simulated-UART verification of the board-level FSM

Actual Image/
├── png_to_hex.py / hex_to_png.py   PNG ⇄ hex conversion
├── uart_image_transfer.py          PC-side UART image transfer
├── tb_actual_image.sv              Real 256×256 image through the accelerator
└── test.png                        Sample input image

Bitstream/
└── basys3_pll_top.bit  Synthesized, timing-clean bitstream

basys3_pll_top.xdc     Pin/IOSTANDARD constraints for the Basys3
README.md              This file
BUILD_LOG.md           Full chronological build history
```

## Register Map

| Address | Register | Access | Purpose |
|---|---|---|---|
| `0x00` | `CONTROL` | W | write `0x01` to pulse "start" |
| `0x04` | `STATUS` | R | bit 1 = `done`, bit 0 = `busy` |
| `0x08`–`0x28` | `PIXEL00`…`PIXEL22` | RW | the 3×3 input window, one register per pixel |
| `0x2C` | `RESULT` | R | 8-bit saturated Sobel gradient magnitude |

## Verification Results

| Test | Result |
|---|---|
| `tb_sobel_core.sv` | 66,539 / 66,539 checks passed |
| `tb_controller.sv` | 32 / 32 checks passed |
| `tb_apb_slave.sv` | 37 / 37 checks passed |
| `tb_accelerator_top.sv` (full APB-level system test) | 1,568 / 1,568 checks passed |
| `tb_actual_image.sv`, real 256×256 image | 64,516 / 64,516 interior pixels bit-exact vs. golden model |
| `basys3_top`, full 256×256 image over simulated UART | 65,536 / 65,536 pixels bit-exact |

## Synthesis & Timing (Vivado 2026.1, `xc7a35tcpg236-1`)

- 0 synthesis errors, 0 critical warnings. Both image buffers correctly inferred as Block RAM (32× `RAMB36E1`).
- Native 100MHz clock failed setup timing (WNS = −1.295 ns). Fixed by adding a Clocking Wizard to run the design at 50MHz — the design is UART-throughput-bound anyway, so this costs nothing in practice.
- **Final:** WNS = +7.671 ns, WHS = +0.094 ns, 0 failing endpoints. *"All user specified timing constraints are met."*
- Verified working end-to-end on real Basys3 hardware: a real image sent over UART, processed by the FPGA, and returned as a correct edge-detected image.

## Running It

**On real hardware:**
```bash
pip install pillow pyserial --break-system-packages

python3 png_to_hex.py                 # test.png (256x256 grayscale) -> image_in.hex
python3 uart_image_transfer.py COM5   # sends the image, receives the result
python3 hex_to_png.py                 # output_image.hex -> edges_out.png
```
Program `basys3_pll_top.bit` via Vivado Hardware Manager, press the center reset button (`btnC`), then run the three scripts above from a PC connected via the board's USB-UART port. LEDs 0–4 indicate receive / clear / process / send / done.

**In simulation only:**
```powershell
python png_to_hex.py
iverilog -g2012 -o sim accelerator_top.sv apb_slave.sv controller.sv sobel_core.sv tb_actual_image.sv
vvp sim
python hex_to_png.py
```

## Toolchain

- **HDL:** SystemVerilog
- **Simulation:** Icarus Verilog
- **Synthesis / Implementation:** AMD Vivado 2026.1
- **Target board:** Digilent Basys3 (Xilinx Artix-7, `xc7a35tcpg236-1`)
- **Host interface:** USB-UART @ 115200 baud, 8N1
- **Host scripting:** Python (Pillow, pyserial)

## Status

RTL design and verification are complete, from the arithmetic core through a full production-scale image pipeline, all checked against independently derived golden results. The bitstream closes timing cleanly with margin to spare, and the full PC → FPGA → PC image pipeline has been run successfully on real Basys3 hardware.

For the complete build history — the dropped streaming-architecture idea, every stage of development, and every bug found (RTL bugs, testbench bugs, and spec ambiguities, each called out separately) — see **[BUILD_LOG.md](./BUILD_LOG.md)**.
