# APB-Controlled FPGA Sobel Edge Detection Accelerator

**A synthesizable SystemVerilog hardware accelerator that performs Sobel edge detection, controlled over an APB register interface, verified in simulation from the arithmetic core up to a full 256×256 image, and finally brought up on a real Digilent Basys3 (Artix-7 `xc7a35tcpg236-1`) FPGA with a working PC ↔ FPGA UART image pipeline.**

This README is written as a **build log**, in the actual order things happened — including the idea that got dropped, the bugs that were found (and which ones were real RTL bugs vs. testbench bugs vs. spec ambiguities), and the decisions made at each fork in the road. If you only want the finished product, skip to [Section 12 — Final Repository](#12-final-repository) and [Section 15 — Running It](#15-running-it-end-to-end).

---

## Table of Contents

1. [Origin idea (dropped): a streaming line-buffer Sobel pipeline](#1-origin-idea-dropped-a-streaming-line-buffer-sobel-pipeline)
2. [The pivot: an APB-controlled, single-window accelerator](#2-the-pivot-an-apb-controlled-single-window-accelerator)
3. [Stage 1 — Specification before code](#3-stage-1--specification-before-code)
4. [Stage 2 — Sobel core RTL and first verification](#4-stage-2--sobel-core-rtl-and-first-verification)
5. [Stage 3 — APB slave, controller FSM, integration (Bug #1)](#5-stage-3--apb-slave-controller-fsm-integration-bug-1)
6. [Stage 4 — Reference model, scoreboard, randomized testing (Bug #2)](#6-stage-4--reference-model-scoreboard-randomized-testing-bug-2)
7. [Stage 5 — Assertions and coverage](#7-stage-5--assertions-and-coverage)
8. [Stage 6 — FPGA-flow scaffolding (pre-Vivado)](#8-stage-6--fpga-flow-scaffolding-pre-vivado)
9. [Stage 7 — Full re-verification pass: system testbench + real image (Bug #3)](#9-stage-7--full-re-verification-pass-system-testbench--real-image-bug-3)
10. [Stage 8 — First hardware bring-up review (nothing coded yet)](#10-stage-8--first-hardware-bring-up-review-nothing-coded-yet)
11. [Stage 9 — Acting on the review: XDC, bus narrowing, Bug #4, two demo paths](#11-stage-9--acting-on-the-review-xdc-bus-narrowing-bug-4-two-demo-paths)
12. [Stage 10 — Consolidating into `basys3_top.sv` and finding Bug #5](#12-stage-10--consolidating-into-basys3_topsv-and-finding-bug-5)
13. [Stage 11 — Synthesis and timing closure](#13-stage-11--synthesis-and-timing-closure)
14. [Stage 12 — Hardware bring-up: the COM-port hurdle, then a working chip](#14-stage-12--hardware-bring-up-the-com-port-hurdle-then-a-working-chip)
15. [Final Repository](#15-final-repository)
16. [Running It, End-to-End](#16-running-it-end-to-end)
17. [Full Bug Log](#17-full-bug-log)
18. [Architecture Reference](#18-architecture-reference)
19. [Register Map](#19-register-map)
20. [Toolchain](#20-toolchain)
21. [Lessons / Key Engineering Concepts Demonstrated](#21-lessons--key-engineering-concepts-demonstrated)
22. [Possible Future Extensions](#22-possible-future-extensions)

---

## 1. Origin idea (dropped): a streaming line-buffer Sobel pipeline

The project didn't start as an APB peripheral. It started as a **real-time streaming video accelerator**: accept a raster-scan stream of 8-bit grayscale pixels and emit a stream of Sobel edge-magnitude pixels at **one output pixel per clock**, using line buffers and a sliding 3×3 window — the way a real video-pipeline IP block would be built, with no CPU and no frame buffer in the datapath.

The planned architecture looked like this:

```
Input Pixel Stream
        │
        ▼
   Line Buffers            (store previous 2 rows, built from BRAM)
        │
        ▼
3×3 Window Generator       (shift registers + line buffer taps → 9 pixels/cycle)
        │
        ▼
Sobel X and Sobel Y        (weighted sums: Gx, Gy)
        │
        ▼
Gradient Magnitude Approx  (|Gx| + |Gy|, saturated to 8 bits)
        │
        ▼
Output Pixel Stream
```

A 5-milestone plan was written for this: (1) a combinational Sobel math core operating on a pre-formed 3×3 window, (1b) a registered/pipelined version of the same math, (2) a 3×3 window generator built from shift registers, (3) BRAM-based line buffers with border handling, (4) full streaming integration at 1 pixel/cycle, and (5, stretch) an image-file-based testbench checked against a Python/OpenCV reference.

The key ideas already fixed at this stage — because they carried through to the final project unchanged — were:

- **Why Sobel:** it's a fixed 3×3 local operator with no data-dependent control flow, so it maps cleanly onto pipelined hardware, and its arithmetic is cheap (small-integer multiplies of ±1/±2, adds, subtracts, abs, saturate — no dividers, no floating point).
- **Bit-width reasoning:** `Gx`/`Gy` ∈ [-1020, +1020] → 11-bit signed; magnitude needs saturation to 8 bits, not wraparound, or the edge map gets corrupted.
- **Signed-vs-unsigned care:** pixels are unsigned 8-bit; gradients are signed; the two must not be mixed carelessly.
- **Design priority order:** *Understanding → Correct Simulation → Modular Design → Optimization.* No code would be used without being understood signal-by-signal, cycle-by-cycle. This principle was carried through every later stage.

Work stopped at **"Milestone 1 design review, prior to first code generation"** — i.e. before Milestone 1 was ever coded. This version of the project was never built.

## 2. The pivot: an APB-controlled, single-window accelerator

Instead of the streaming/line-buffer architecture, the project was re-scoped to something smaller and more interview/portfolio-shaped: a **register-mapped hardware IP block**, controlled over an **APB (Advanced Peripheral Bus)** interface, that computes Sobel on **one 3×3 window per invocation** rather than a continuous pixel stream. A host (in simulation, a testbench; later, real hardware) would:

1. Write nine 8-bit pixel values into nine registers,
2. Pulse a START bit,
3. Poll a STATUS register for DONE,
4. Read back one 8-bit RESULT byte.

This traded away the "1 pixel/clock streaming" goal (line buffers, sliding window generator) in exchange for a project whose full scope — spec → RTL → verification methodology (reference model, scoreboard, randomization, assertions, coverage) → synthesis → real FPGA bring-up — could actually be completed end-to-end. Everything from this point on refers to **this** architecture; the streaming version was not resumed.

The new top-level looked like this:

```
                 Software / APB Master
                         |
                         | APB Transactions
                         v
                 +---------------+
                 |   APB Slave   |
                 +-------+-------+
                         |
                         v
                 +---------------+
                 | Register Bank |
                 | CONTROL       |
                 | STATUS        |
                 | PIXEL00-22    |
                 | RESULT        |
                 +-------+-------+
                         |
                         v
                 +---------------+
                 | Controller FSM|
                 +-------+-------+
                         |
                         v
                 +---------------+
                 |   Sobel Core  |
                 +-------+-------+
                         |
                         v
                  Edge Magnitude
```

AXI, DMA, PCIe, Ethernet, and a full CPU were explicitly ruled out — the goal was a **small, properly specified, and properly verified** IP block, not a system.

## 3. Stage 1 — Specification before code

Before any RTL was written:

- **Hardware-friendly Sobel formulation.** The Sobel kernels only use coefficients `{-2, -1, 0, +1, +2}`, so every term can be built from wiring (×0 = omit), direct connection (×1), negation/subtraction (×-1), and a left-shift (×2 / ×-2) — **no multiplier is needed anywhere in the datapath**:

  ```
  Gx = (p02 - p00) + 2·(p12 - p10) + (p22 - p20)
  Gy = (p20 - p00) + 2·(p21 - p01) + (p22 - p02)
  ```

- **Bit-width derivation from first principles**, not guessed:

  | Signal | Width | Why |
  |---|---|---|
  | Pixel | 8-bit unsigned | Standard grayscale range 0–255 |
  | `Gx`, `Gy` | 11-bit signed | Max magnitude `255 + 2(255) + 255 = 1020` → needs signed range beyond ±1023? Actually fits in `[-1024, 1023]`, i.e. 11-bit signed |
  | `abs(Gx)`, `abs(Gy)` | 12-bit unsigned | Absolute value of an 11-bit signed number can need one extra bit |
  | Sum (`abs(Gx)+abs(Gy)`) | 13-bit unsigned | Max combined value 2040 |
  | Result | 8-bit, **saturated** | Anything over 255 is clamped to 255, never wrapped |

- **Why `|Gx| + |Gy|` instead of `sqrt(Gx² + Gy²)`:** the exact gradient magnitude needs a multiplier and a square-root circuit; the L1 approximation needs only abs + add + saturate. This is an explicit, acknowledged hardware/software algorithm tradeoff, not an oversight.

- **A register map** — one APB register per pixel, deliberately chosen over packed/indexed addressing for verification simplicity while learning APB, even though it costs more register-bank area than necessary.

- **Ten testable requirements (REQ-001 … REQ-010)** covering reset behavior, START/BUSY/DONE semantics, and edge cases like a START arriving while the core is already busy.

- **The module breakdown** — `sobel_core`, `apb_slave`, `controller`, `accelerator_top` — and a verification plan (directed → reference model → scoreboard → randomized → assertions → coverage) were all decided **before a single line of RTL existed.**

No RTL was written in this stage.

## 4. Stage 2 — Sobel core RTL and first verification

`sobel_core.sv` was built: a **purely combinational** module taking the nine 8-bit pixels and outputting an 8-bit saturated gradient magnitude. Signed arithmetic was handled with explicit SystemVerilog sizing casts to sign-extend each unsigned pixel into an 11-bit signed value before doing gradient math — avoiding the classic "mixing unsigned and signed operands silently reinterprets everything as unsigned" trap.

The core datapath, as finally settled:

```systemverilog
assign gx = (s_p02 - s_p00) + ((s_p12 - s_p10) <<< 1) + (s_p22 - s_p20);
assign gy = (s_p20 - s_p00) + ((s_p21 - s_p01) <<< 1) + (s_p22 - s_p02);

assign abs_gx = gx[10] ? 12'(-gx) : 12'(gx);
assign abs_gy = gy[10] ? 12'(-gy) : 12'(gy);

assign sum = abs_gx + abs_gy;
assign magnitude_o = (sum > 13'd255) ? 8'd255 : sum[7:0];
```

(`p11`, the center pixel, is intentionally an unused input — it mathematically drops out of both Sobel kernels. This is correct, not a bug, and Vivado's synthesis warnings about it later had to be explained rather than "fixed" — see [Stage 9](#11-stage-9--acting-on-the-review-xdc-bus-narrowing-bug-4-two-demo-paths).)

**Verification:** six hand-computed directed vectors first (all-zero, uniform field, saturating vertical edge, saturating horizontal edge, isolated positive/negative Gx) — every expected value worked out by hand *before* looking at the simulator, then compared. All passed. The datapath was deliberately verified in isolation, before any bus or controller complexity was added, so a later failure could never be blamed on ambiguous arithmetic.

At this point the project's status was: Sobel math model done, hardware-friendly formulation done, bit-width analysis done, `sobel_core.sv` written and directed-tested, waveform infrastructure working. APB slave, register bank, controller FSM, and full integration were still "in progress."

## 5. Stage 3 — APB slave, controller, integration (Bug #1)

`apb_slave.sv` (register bank, address decode, zero-wait-state `PREADY`) and `controller.sv` (a 2-state FSM — originally planned as 3 states, collapsed once it was clear the third had no distinct behavior) were built and wired together in `accelerator_top.sv`.

**Bug #1 — a spec ambiguity, not an RTL bug.** A directed test tried to poll `STATUS.BUSY` immediately after issuing START and read back `0` instead of `1`. Root cause: the compute pipeline is combinational and only **one clock cycle deep** — `BUSY` is high for exactly one `PCLK` edge — but a full APB read transaction (setup phase + access phase, `PSEL`/`PENABLE` sequencing) takes multiple cycles. Software polling `BUSY` over the bus is therefore **inherently racy**; it can legitimately observe `DONE=1` having already missed the one-cycle `BUSY` window. That is correct hardware behavior, not a defect.

**Fix (spec-level, not RTL):** the requirement (REQ-004) was clarified so software polls the **sticky `DONE`** flag instead — `DONE` stays asserted until reset or the next accepted START — rather than trying to catch `BUSY`. No RTL changed; the interface contract changed. This is documented as the first entry in the [bug log](#17-full-bug-log) because it was found the same way a real bug is found: by testing, not by inspection.

## 6. Stage 4 — Reference model, scoreboard, randomized testing (Bug #2)

An independent software reference model (`sobel_ref`) was written in plain 32-bit integer arithmetic — deliberately in a *different style* from the RTL's bit-width-optimized implementation, so a mistake in one is unlikely to be replicated in the other. This was wired into an automatic scoreboard: drive a vector through real APB transactions, compute the expected value independently, compare.

**200 constrained-random vectors** were run through the scoreboard (weighted toward pixel extremes 0/255 to bias toward saturation and sign-boundary cases) — all passed, alongside re-running the earlier hand-verified vectors through the same automated path as a cross-check. Targeted (non-random) tests were added for three requirements that don't fit a random-math scoreboard: REQ-005 (exact BUSY duration), REQ-008 (a second START while BUSY must be ignored — forced at the signal level since it can't be reliably hit via bus timing), and REQ-010 (a pixel write during BUSY must not corrupt the in-flight computation).

**Bug #2 — a testbench race, not a DUT bug.** The first REQ-005 check (measuring how long `BUSY` stays high by polling it once per clock edge) reported **2 cycles instead of the expected 1**. Root cause: sampling a signal via `@(posedge PCLK)` reads it in simulation's *active* region — **before** that same edge's non-blocking (`<=`) assignments land in the *NBA* region — so the check was reading the FSM's *previous* state, one cycle stale. **Fix:** measure the gap between the signal's own rising and falling edges directly, instead of polling it against the clock. This is a distinct bug category from Bug #1: a simulation-semantics race in the testbench, not a design race in the DUT.

## 7. Stage 5 — Assertions and coverage

Real SystemVerilog concurrent assertions (`controller_assertions.sv`, attached via `bind` so the synthesizable RTL itself never contains verification-only code) were written, covering: reset behavior, BUSY duration, DONE stickiness, pixel-snapshot stability during compute, and START-while-BUSY — checked continuously as properties, not as one-shot test points. A real functional coverage model (`sobel_coverage.sv`) was also written, tracking Gx-sign × Gy-sign cross coverage and saturation hits.

**Discovery:** Icarus Verilog (the simulator used for all day-to-day iteration) does **not support** `property` / `assert property` or `covergroup` constructs at all. This was confirmed with a minimal test case *before* writing hundreds of lines of SVA that would never compile. Rather than drop the concept, an **Icarus-compatible stand-in** was built — immediate assertions plus manual coverage counters checking the exact same properties and bins — so there was real, executable, passing evidence *now*, while the genuine SVA/covergroup files were kept ready to run later under Vivado's XSIM.

**Result:** 300+ vectors through the assertion monitor, **0 violations**. Coverage check: 6 of 9 Gx-sign × Gy-sign quadrants hit by random testing; the 3 empty ones (an exact zero on one axis with a nonzero on the other) are a low-probability coincidence for independent random pixels, not a design gap. Three targeted directed vectors (using the same row/column symmetry trick from Stage 2) were added to deliberately construct each missing quadrant, closing coverage to **100%** — the "coverage found a real gap, and the plan responded to it" story the original verification plan was written to produce.

## 8. Stage 6 — FPGA-flow scaffolding (pre-Vivado)

Vivado was **not available** in the environment used for this stage, so this stage produced the scaffolding to run synthesis later, rather than synthesis results:

- `constraints/accelerator_top.xdc` — a 100 MHz clock constraint plus realistic (non-zero) I/O delay budgets, on the assumption the block would eventually sit behind a bus interconnect rather than driving package pins directly.
- `scripts/synth.tcl` — a scripted, non-project-mode Vivado flow (synthesis through place-and-route, with utilization/timing/power reports), chosen deliberately over GUI clicking so the build would be reproducible from source control.
- `scripts/sim_xsim.tcl` — to run the *real* SVA/covergroup files from Stage 5 under Vivado's simulator for the first time, with the small step of wiring `sobel_coverage`'s `sample()` call into the existing testbench intentionally left as a short manual follow-up rather than automated away.
- Packaging: a project-facing `README.md`, `docs/verification.md` (full requirement-traceability table), and `docs/resume_bullets.md`.

At the end of this stage the design was fully verified in simulation but had never touched real Vivado synthesis or real hardware.

## 9. Stage 7 — Full re-verification pass: system testbench + real image (Bug #3)

A later pass revisited the design with two goals: build a true **system-level** testbench (everything so far tested modules individually or via internal signals), and run a **real image** through the accelerator instead of only synthetic vectors.

**Bug #3 — stale port names in `tb_controller.sv`.** `controller.sv`'s outputs toward `sobel_core` had at some point been renamed from `p00_o…p22_o` to `cp00_o…cp22_o` (visible from the fact that `accelerator_top.sv` already correctly used the `cp*` names), but `tb_controller.sv` was never updated to match, so it failed to compile:

```
tb_controller.sv:25: error: port ``p00_o'' is not a port of dut.
... (x9)
```

**Fix:** the testbench's DUT instantiation was updated to use the correct port names (`.cp00_o(p00_o)`, …), keeping the testbench's own internal signal names unchanged. No RTL was touched — the bug was purely in a stale testbench, and once fixed the controller's logic was confirmed correct.

**New system-level testbench — `tb_accelerator_top.sv`.** Until this point, only per-block testbenches existed (`tb_apb_slave.sv`, `tb_controller.sv`, `tb_sobel_core.sv`) — nothing exercised the system end-to-end through the *actual APB pins*, which is exactly what would have caught an integration bug like the one above sooner. This testbench drives **only** `PSEL`/`PENABLE`/`PWRITE`/`PADDR`/`PWDATA`/`PRDATA`/`PREADY` — the same interface a real bus master would use — and checks: register-map behavior (reset values, RW pixel registers, write-only CONTROL, read-only STATUS/RESULT, unmapped addresses read 0), end-to-end function (load a window, START, poll DONE, read RESULT, compare against the independent golden model — directed cases plus 100 randomized windows), and sequencing (a second START while BUSY is ignored without corrupting the in-flight job, DONE stays sticky, back-to-back jobs work, async reset mid-computation clears everything correctly), plus a `#100000`-cycle watchdog so a genuine hang can't run forever. Two checks that specifically need to catch the one-cycle `BUSY` window sample `dut.u_controller.busy_r` directly at the right edge instead of going through the slower APB read task — the one deliberate, documented exception to "test the interface, not internals."

**Result: 1,568 / 1,568 checks pass.**

**Real-image test flow.** SystemVerilog has no way to decode a `.png` (a compressed, filtered, chunked binary format), so the flow was split across two Python steps and one simulation:

```
test.png --[png_to_hex.py]--> image_in.hex --[tb_actual_image.sv]--> output_image.hex --[hex_to_png.py]--> edges_out.png
```

`image_in.hex`/`output_image.hex` are plain text, one 8-bit hex byte per line, row-major, 65,536 lines for a 256×256 image. `tb_actual_image.sv` loads the image with `$readmemh`, slides a 3×3 window over every **interior** pixel (254×254 = 64,516 of them, since the outer 1-pixel border has no full neighborhood and is written as 0 — a standard convention for accelerators with no image-padding logic), drives each window through `accelerator_top` exactly like a real APB master, and checks every result against the same golden model used in `tb_accelerator_top.sv` (mismatches capped at the first 20 printed in detail, full pass/fail count reported at the end).

Since no real test image was available yet at this point, a synthetic 256×256 image (diagonal gradients plus a striped box) was used to prove the flow end-to-end: **all 64,516 interior pixels matched the golden model exactly**, and the output image visibly showed the correct diagonal and box/stripe edges.

## 10. Stage 8 — First hardware bring-up review (nothing coded yet)

With Vivado now available, `accelerator_top.sv`/`apb_slave.sv`/`controller.sv`/`sobel_core.sv` were reviewed specifically for real-hardware readiness. This stage was **review only** — nothing was modified yet — and surfaced three issues:

**Issue 1 — Vivado "Critical Methodology Violations."** Both `apb_slave.sv` and `controller.sv` used `PRESETn` directly as an asynchronous reset:
```systemverilog
always_ff @(posedge PCLK or negedge PRESETn) begin
    if (!PRESETn) ...
```
Because `PRESETn` can deassert at any point relative to `PCLK`, this violates recovery/removal timing on the reset pin of every flop it drives — different flops can legitimately come out of reset on different edges. This is a real functional risk on hardware, not just a report nag, and is exactly the class of thing Vivado's methodology checks flag as critical. **Recommended fix:** a 2-flop reset synchronizer per module (assert async/instant, **deassert synchronously** to `PCLK`) — not yet applied to the files at this point. (Minor secondary note: `sobel_core.sv`'s unused `p11` port might also get flagged by lint, even though it's mathematically correct to be unused.)

**Issue 2 — DRC `NSTD-1`/`UCIO-1` blocking `write_bitstream`.** No `.xdc` constraints file existed yet, so all 54 top-level ports had neither an I/O standard nor a package-pin location, and no clock was defined. Purely a physical-constraints gap, irrelevant to simulation.

**Issue 3 — the design didn't fit the board.** The Basys3 has 16 switches, 16 LEDs, 5 buttons, a 4-digit 7-segment display, and 32+6 PMOD pins. `accelerator_top`'s APB bus alone — `PADDR[7:0] + PWDATA[31:0] + PRDATA[31:0]` plus control signals — was **~54 pins**, more than the board's entire usable I/O, with nothing left over to observe a result. **Recommended approach (not yet built):** don't expose the raw bus to package pins; build a small Basys3-specific wrapper using switches to enter pixel bytes, buttons to latch/start, and LEDs or the 7-segment display to show the result, clocked from the board's onboard 100 MHz oscillator.

## 11. Stage 9 — Acting on the review: XDC, bus narrowing, Bug #4, two demo paths

**Analyzing the existing Vivado warnings** confirmed two of them were benign and one was the real blocker:
- *"Port `p11[7]` in module `sobel_core` unconnected"* (56×) — benign; the classic Sobel kernels never weight the center pixel, so `p11` is correctly unused.
- *"`PRDATA[31]` driven by constant 0"* (25×) — benign at the time (only the low bits carried real data on a 32-bit bus), and moot after the fix below.
- *No user clocks/constraints* — the real root cause of the DRC errors from Stage 8.

**The fix that mattered most:** rather than build a switch-driven manual wrapper around a 54-pin bus, the **APB bus itself was narrowed** — `PADDR`, `PWDATA`, and `PRDATA` from 32 bits down to **8 bits each**. This cut total top-level I/O from 78 signals down to a clean **20 inputs + 9 outputs + 1 clock**, mapping 1:1 onto the Basys3's switches, buttons, and LEDs with nothing wasted, and incidentally made the whole bus far easier to drive by hand or over UART.

**Bug #4 — `apb_slave.sv` had an actual invalid-SystemVerilog typo:** `always_comb beginwa` (not valid syntax). **Fix:** corrected to `always_comb begin`. A second, related fix was needed in `tb_actual_image.sv`, which had originally declared `PWDATA`/`PRDATA` as 32-bit and was never updated after the DUT was narrowed to 8-bit — fixed to match, and re-verified consistent with the register map (`ADDR_STATUS` bit 1 = `done`, bit 0 = `busy`, matching `apb_slave.sv`'s `{done_i, busy_i}` packing).

Two hardware demo paths were then built in parallel:

**Demo Path A — manual switch/LED control** (`basys3_wrapper.sv` + `basys3_demo.xdc`): maps the 8-bit APB bus 1:1 onto board I/O — `sw[7:0]`→`PADDR`, `sw[15:8]`→`PWDATA`, `btnC`→`PRESETn` (inverted), `btnU`→`PSEL`, `btnL`→`PENABLE`, `btnR`→`PWRITE`, `led[7:0]`→`PRDATA`, `led[8]`→`PREADY`. Constraints were checked against Digilent's official Basys3 master XDC. This path was completed and lets a single APB register access be exercised by hand, one switch/button press at a time, with no PC software at all.

**Demo Path B — a full image through real hardware, PC-driven** (started here): the real goal — stream an entire 256×256 image through the accelerator on the board and get a real edge-detected image back, over the board's own USB-UART link. `uart_rx.sv`/`uart_tx.sv` (115200-baud, 8N1) were written, along with an `image_sequencer.sv` state machine designed as the hardware equivalent of `tb_actual_image.sv`: receive 65,536 bytes into an on-chip buffer, process every pixel (border → 0; interior → the real 9-write/start/poll/read APB sequence), send 65,536 result bytes back — wired up in `basys3_image_top.sv`.

Two timing traps specific to APB-style buses were deliberately designed around here, and are worth understanding if this is extended further:
1. **Registered vs. combinational bus outputs.** `PSEL`/`PENABLE`/`PADDR`/`PWDATA` must be driven **combinationally** off the FSM's *current* state, not with `<=` inside the state-transition block — non-blocking assignments only take effect on the *next* edge, so a registered version would never actually present `PSEL` and `PENABLE` both high in the same cycle, and no transaction would ever complete.
2. **Read-data capture timing.** `PRDATA` in `apb_slave.sv` is purely combinational (it reflects whatever `PADDR` currently points to, no register delay), so `STATUS` and `RESULT` reads must be captured in the **exact same cycle** `PADDR` is still driving that address — one cycle later `PADDR` has reset to 0, which aliases `CONTROL` (also `0x00`) and would silently produce a wrong read.

At the end of this stage, Demo Path A was complete; Demo Path B had UART RX/TX, the sequencer FSM, and a top wrapper written, but still needed an updated `.xdc` for the UART/clock/reset/LED pins and a PC-side Python script — and simulating `basys3_image_top`/`image_sequencer` before trusting it on the board was flagged as the recommended next step.

## 12. Stage 10 — Consolidating into `basys3_top.sv` and finding Bug #5

Demo Path B was carried forward as the primary hardware target (Demo Path A's manual wrapper does not appear in the final repository — it served its purpose as an early, low-risk hardware sanity check). The UART-driven sequencer and its top wrapper were consolidated into a single synthesizable master, `basys3_top.sv`: two 64KB Block-RAM image buffers (`image_mem`, `output_mem` — comfortably inside the Artix-7 35T's ~225KB of Block RAM) plus one FSM that replaces every testbench-only construct (`$readmemh`, `$fwrite`, tasks, `@(posedge)` waits) with real registered logic performing the identical sequence: receive image over UART → for every interior pixel, nine pixel writes → START pulse → poll STATUS → read RESULT → store it → stream the output image back over UART.

This was verified in **simulation, at increasing scale, before touching hardware**:

| Test | Result |
|---|---|
| `basys3_top`, 8×8 random image over simulated UART | 13/64 pixels **mismatched** (bug found) |
| `basys3_top`, 8×8, after fix | 64 / 64 pixels matched golden model |
| `basys3_top`, 16×16 random image | 256 / 256 pixels matched golden model |
| `basys3_top`, full 256×256 production image, same RTL as the bitstream | 65,536 / 65,536 pixels bit-exact vs. golden output |

**Bug #5 — off-by-one in the pixel-window loader.** The FSM reading the nine neighboring pixels out of Block RAM advanced its read address using `naddr[neigh_idx]` instead of `naddr[neigh_idx+1]`. Every neighbor read landed one position early: `p00` was read **twice**, every other pixel was shifted back one slot, and `p22` was **never read at all**. This is a real RTL bug in synthesizable logic (unlike Bugs #1–#4, which were spec ambiguities or testbench-only defects) — caught by simulating the full `basys3_top` design at small scale (8×8) against a golden model before ever generating a bitstream, exactly the kind of bug an 8×8 quick-look test exists to catch cheaply. Fixed, then re-verified at 8×8, 16×16, and finally the full production 256×256 size — the last row of the table above is the literal RTL that was later synthesized into the bitstream, checked byte-for-byte against an independently generated reference image.

**Bug (testbench-only) — `tb_apb_slave.sv` port/signal mismatch**, found in the same verification pass: the DUT instantiation connected `.cp00_o(p00_o)` instead of `.p00_o(p00_o)`, and nine `check_byte` calls referenced an undeclared `cp00_o…cp22_o` instead of the testbench's own `p00_o…p22_o`. `apb_slave.sv` itself was never wrong — the testbench simply didn't compile. Fixed by correcting the port connection and the nine signal names.

**Full simulation results at this point, everything passing:**

| Test | Result |
|---|---|
| `tb_sobel_core.sv` | 66,539 / 66,539 checks passed |
| `tb_controller.sv` | 32 / 32 checks passed |
| `tb_apb_slave.sv` (post-fix) | 37 / 37 checks passed |
| `tb_accelerator_top.sv` | 1,568 / 1,568 checks passed |
| `tb_actual_image.sv`, real 256×256 image | 64,516 / 64,516 interior pixels bit-exact vs. golden model |
| `basys3_top`, 8×8 over simulated UART (post-fix) | 64 / 64 pixels matched |
| `basys3_top`, 16×16 over simulated UART | 256 / 256 pixels matched |
| `basys3_top`, full 256×256 over simulated UART | 65,536 / 65,536 pixels bit-exact |

Also confirmed at this stage: the reset-synchronizer fix recommended back in [Stage 8](#10-stage-8--first-hardware-bring-up-review-nothing-coded-yet) *was* implemented — both `apb_slave.sv` and `controller.sv` now use a 2-flop synchronizer (`presetn_sync1` → `presetn_sync_n`) so reset asserts asynchronously but deasserts synchronously to `PCLK`, and `basys3_top.sv` independently double-flops the physical reset button (`rst_n_meta` → `rst_n`) for the same reason at the board-I/O boundary.

## 13. Stage 11 — Synthesis and timing closure

Synthesized and implemented in **Vivado 2026.1**, targeting `xc7a35tcpg236-1`.

- **Synthesis:** 0 errors, 0 critical warnings. Both image buffers correctly inferred as Block RAM (32 `RAMB36E1` primitives total, matching two independent 64KB memories). Remaining warnings reviewed and confirmed benign: the intentionally-unused center-pixel port on `sobel_core` (see Stage 9), a small register array that can't map to RAM because of its async reset and falls back to flip-flops as intended, and standard FSM coding-style advisories.
- **First implementation attempt, native 100 MHz clock:** failed setup timing — **WNS = −1.295 ns** across 8 of 2,437 endpoints.
- **Fix:** a Clocking Wizard (MMCM), wrapped as `basys3_pll_top.sv`, deriving a **50 MHz** clock from the board's 100 MHz onboard oscillator — doubling the timing budget per cycle. Since the design's real-world throughput is UART-bound (whole seconds per image) regardless of internal clock speed, halving the clock costs nothing in practice.
- **Final result:** **WNS = +7.671 ns**, **WHS = +0.094 ns**, **0 failing endpoints** across setup, hold, and pulse-width checks. Vivado's own summary: *"All user specified timing constraints are met."* A bitstream, `basys3_pll_top.bit`, was generated from this implementation.

## 14. Stage 12 — Hardware bring-up: the COM-port hurdle, then a working chip

With RTL fully verified and the bitstream timing-clean, the board was programmed (`basys3_pll_top.bit`, via Vivado Hardware Manager) and the PC-side scripts (`png_to_hex.py` → `uart_image_transfer.py` → `hex_to_png.py`) were prepared to drive it.

The first bring-up attempt hit a **host-PC connectivity issue, not a design defect**: the Basys3's onboard USB-UART bridge wasn't yet enumerating as a COM port on the test machine, which blocked `uart_image_transfer.py` from opening a serial connection at all. This was diagnosed as a driver/setup problem on the PC side (the design and bitstream themselves had already been proven correct at full 256×256 scale in simulation against the exact same synthesized RTL) and resolved by getting the correct FTDI/USB-UART driver installed and the board's serial port recognized.

Once the COM port was available, the full pipeline was exercised end-to-end on real silicon: `png_to_hex.py` converted a real grayscale test image into `image_in.hex`, `uart_image_transfer.py` streamed it to the board over the enumerated COM port and captured the reply as `output_image.hex`, and `hex_to_png.py` reconstructed `edges_out.png`. LEDs 0–4 tracked the FSM's receive/clear/process/send/done phases live as the transfer progressed. The image returned by the FPGA matched the expected Sobel edge map — **the accelerator's full journey, from a 3×3 combinational math block through a 256×256-image, UART-streamed, timing-closed FPGA design, was confirmed working on real Basys3 hardware.**

## 15. Final Repository

```
APB-Controlled FPGA Sobel Edge Detection Accelerator/
│
├── System Verilog Files/
│   ├── sobel_core.sv          — combinational Gx/Gy/abs/saturate datapath
│   ├── apb_slave.sv           — APB register interface (CONTROL/STATUS/PIXELxx/RESULT)
│   ├── controller.sv          — 2-state FSM: latch pixels on START, capture result next cycle
│   ├── accelerator_top.sv     — wires apb_slave + controller + sobel_core behind one APB port
│   ├── uart_rx.sv / uart_tx.sv— 115200-baud 8N1 UART
│   ├── basys3_top.sv          — board-level master FSM: 2× 64KB BRAM image buffers,
│   │                            UART receive → per-pixel APB sequencing → UART send
│   └── basys3_pll_top.sv      — wraps basys3_top with a Clocking Wizard (100MHz → 50MHz)
│
├── Test_becnhes/
│   ├── tb_sobel_core.sv       — 66,539 directed + exhaustive + random checks
│   ├── tb_controller.sv       — 32 checks (post port-name fix)
│   ├── tb_apb_slave.sv        — 37 checks (post port-name fix)
│   ├── tb_accelerator_top.sv  — 1,568 checks, full APB-pin-level system test
│   └── tb_basys3_top.sv       — simulated-UART verification of the board-level FSM
│
├── Actual Image/
│   ├── png_to_hex.py          — PNG → image_in.hex
│   ├── tb_actual_image.sv     — real 256×256 image through accelerator_top over APB
│   ├── uart_image_transfer.py — sends image_in.hex over UART, saves output_image.hex
│   ├── hex_to_png.py          — output_image.hex → edges_out.png
│   └── test.png               — sample input image
│
├── Bitstream/
│   └── basys3_pll_top.bit     — synthesized, timing-clean bitstream
│
├── basys3_pll_top.xdc         — Basys3 pin/IOSTANDARD constraints (100MHz clk, btnC reset,
│                                 USB-UART, status LEDs)
├── README.md                  — top-level project README
└── BUILD_LOG.md               — this file
```

## 16. Running It, End-to-End

```bash
pip install pillow pyserial --break-system-packages

python3 png_to_hex.py                 # test.png (256x256 grayscale) -> image_in.hex
python3 uart_image_transfer.py COM5   # sends the image, receives the result
python3 hex_to_png.py                 # output_image.hex -> edges_out.png
```

On the board: program `basys3_pll_top.bit` via Vivado Hardware Manager, press the center reset button (`btnC`), then run the three scripts above from a PC connected via the board's USB-UART port (use whichever of `python`, `python3`, or `py` resolves on your system, and the actual COM/tty port your board enumerates as). LEDs 0–4 indicate receive / clear / process / send / done as the transfer progresses.

**To run pure simulation instead (no board needed):**
```powershell
python png_to_hex.py
iverilog -g2012 -o sim accelerator_top.sv apb_slave.sv controller.sv sobel_core.sv tb_actual_image.sv
vvp sim
python hex_to_png.py
```
Before moving past each step, confirm the file that step should have produced actually exists and is non-empty — an empty or missing intermediate `.hex` file silently propagates as all-zero or all-`X` data rather than raising an obvious error.

## 17. Full Bug Log

| # | Where | Category | Symptom | Root Cause | Fix |
|---|---|---|---|---|---|
| 1 | HW/SW interface spec | Spec ambiguity | Polling `BUSY` over APB read back 0 unexpectedly | `BUSY` is a single-cycle pulse; a full APB read takes several cycles, so polling `BUSY` is inherently racy | Clarified REQ-004: software must poll sticky `DONE`, not `BUSY`. No RTL changed. |
| 2 | Testbench (`tb_*` BUSY-duration check) | Testbench race | REQ-005 duration check reported 2 cycles instead of 1 | Sampling via `@(posedge PCLK)` reads the *active* region, before that edge's NBA updates land — read the FSM's previous state | Measured the signal's own rising/falling edges directly instead of polling against the clock |
| 3 | `tb_controller.sv` | Testbench-only, stale ports | Compile error: `port "p00_o" is not a port of dut` (×9) | `controller.sv`'s ports were renamed `p00_o..` → `cp00_o..` but the testbench instantiation was never updated | Updated the DUT instantiation's port names to `cp00_o..cp22_o` |
| 4 | `apb_slave.sv` | Real RTL bug (syntax) | Design failed to compile | `always_comb beginwa` — invalid SystemVerilog typo | Corrected to `always_comb begin` |
| 4b | `tb_actual_image.sv` | Testbench-only, stale widths | Testbench out of sync with narrowed bus | `PWDATA`/`PRDATA` still declared 32-bit after the DUT's bus was narrowed to 8-bit | Updated to 8-bit, re-verified against the register map |
| 5 | `basys3_top.sv` | Real RTL bug (logic) | 13/64 pixels wrong in an 8×8 simulated-UART test | Pixel-window loader FSM advanced Block-RAM read address using `naddr[neigh_idx]` instead of `naddr[neigh_idx+1]` — `p00` read twice, every other pixel shifted one slot early, `p22` never read | Corrected the address index; re-verified at 8×8, 16×16, and full 256×256 |
| 6 | `tb_apb_slave.sv` | Testbench-only, port/signal typo | Testbench didn't compile / referenced undeclared signals | Instantiation used `.cp00_o(p00_o)` instead of `.p00_o(p00_o)`; 9× `check_byte` calls referenced undeclared `cp00_o..cp22_o` | Corrected the port connection and the nine signal names — `apb_slave.sv` itself was never wrong |
| 7 | Host PC | Environment/setup, not RTL | `uart_image_transfer.py` couldn't open a serial connection | Basys3's USB-UART bridge wasn't enumerating as a COM port on the test machine | Correct USB-UART driver installed; port enumerated and full image pipeline ran successfully on hardware |

Two additional items were **caught by review, not by simulation**, and fixed proactively before they could bite on hardware: the missing reset synchronizer (`PRESETn` used raw as an async reset in `apb_slave.sv`/`controller.sv` — a genuine recovery/removal timing risk) and the missing/incomplete `.xdc` constraints causing `NSTD-1`/`UCIO-1` DRC errors. Both were resolved in [Stage 9](#11-stage-9--acting-on-the-review-xdc-bus-narrowing-bug-4-two-demo-paths).

## 18. Architecture Reference

**Core RTL (identical between simulation and the FPGA — this is the point of the verification effort):**

| Module | Role |
|---|---|
| `sobel_core.sv` | Combinational: takes a 3×3 window of 8-bit pixels, computes `Gx`/`Gy` via shift-and-add, sums absolute values, saturates to 8 bits. |
| `apb_slave.sv` | APB register interface — CONTROL (start pulse), STATUS (busy/done), nine write-only pixel registers, read-only RESULT. `PREADY` tied high (zero-wait-state). 2-flop reset synchronizer on `PRESETn`. |
| `controller.sv` | 2-state sequencing FSM: latches the nine pixel registers on START, drives `sobel_core`, asserts a sticky DONE alongside a single-cycle BUSY. Same reset synchronizer as `apb_slave.sv`. |
| `accelerator_top.sv` | Wires `apb_slave` ↔ `controller` ↔ `sobel_core` behind one APB port. |

**Board-specific hardware (added only for real-silicon bring-up):**

| Module | Role |
|---|---|
| `uart_rx.sv` / `uart_tx.sv` | 115200-baud, 8N1 UART receiver/transmitter for all image transfer to/from the host PC. |
| `basys3_top.sv` | Two 64KB Block-RAM image buffers (input/output) plus a synthesizable master FSM replacing every testbench-only construct: receives a full image over UART, slides the 3×3 window across every interior pixel, drives `accelerator_top` over APB, stores each result, streams the output image back over UART. Independently double-synchronizes the physical reset button. |
| `basys3_pll_top.sv` | Wraps `basys3_top` with a Clocking Wizard (MMCM) deriving 50MHz from the board's 100MHz oscillator, to close setup timing (see [Stage 11](#13-stage-11--synthesis-and-timing-closure)). |
| `basys3_pll_top.xdc` | Pin/IOSTANDARD constraints — 100MHz clock, `btnC` reset, USB-UART pins, status LEDs. |

**Host-side Python:**

| Script | Role |
|---|---|
| `png_to_hex.py` | Grayscale PNG → row-major `image_in.hex` (one 8-bit hex byte per line). |
| `uart_image_transfer.py` | Streams `image_in.hex` to the FPGA over UART, saves the reply as `output_image.hex`. |
| `hex_to_png.py` | `output_image.hex` → viewable `edges_out.png`. |

## 19. Register Map

| Address | Register | Access | Purpose |
|---|---|---|---|
| `0x00` | `CONTROL` | W | write `0x01` to pulse "start" (write-only; reads back 0) |
| `0x04` | `STATUS` | R | bit 1 = `done`, bit 0 = `busy` |
| `0x08` | `PIXEL00` | RW | top-left of the 3×3 window |
| `0x0C` | `PIXEL01` | RW | top-middle |
| `0x10` | `PIXEL02` | RW | top-right |
| `0x14` | `PIXEL10` | RW | middle-left |
| `0x18` | `PIXEL11` | RW | center (unused by the Sobel math, but still writable) |
| `0x1C` | `PIXEL12` | RW | middle-right |
| `0x20` | `PIXEL20` | RW | bottom-left |
| `0x24` | `PIXEL21` | RW | bottom-middle |
| `0x28` | `PIXEL22` | RW | bottom-right |
| `0x2C` | `RESULT` | R | Sobel gradient magnitude, read-only |

Software interaction, conceptually:
```
1. Write p00 .. p22 (9 writes)
2. Write CONTROL = 1 (start)
3. Poll STATUS until DONE = 1   (poll DONE, never BUSY — see Bug #1)
4. Read RESULT
```

## 20. Toolchain

- **HDL:** SystemVerilog
- **Simulation:** Icarus Verilog (no `property`/`covergroup` support — see [Stage 5](#7-stage-5--assertions-and-coverage))
- **Synthesis / Implementation:** AMD Vivado 2026.1
- **Target board:** Digilent Basys3 (Xilinx Artix-7, `xc7a35tcpg236-1`)
- **Host interface:** USB-UART @ 115200 baud, 8N1
- **Waveform debugging:** GTKWave / VCD
- **Host scripting:** Python (Pillow, pyserial)

## 21. Lessons / Key Engineering Concepts Demonstrated

- Deriving RTL bit widths from an algorithm's actual numeric range, not guessing them.
- Treating signedness as an explicit design decision when mixing unsigned pixel data with signed gradient arithmetic.
- Distinguishing **three different bug categories** encountered in this project: real RTL bugs (Bugs #4, #5), testbench-only bugs (Bugs #2, #3, #6), and spec ambiguities that need a requirement fix rather than a code fix (Bug #1) — and handling each correctly rather than reflexively "fixing the RTL" for all of them.
- Verifying interface-observable behavior (an APB STATUS read) rather than only internal implementation signals, with one narrow, deliberate, documented exception where internal signals were the only way to catch a genuinely racy external observation.
- Building an independent reference model in a *different coding style* from the RTL specifically so correlated mistakes are less likely.
- Confirming a simulator's actual language support (`property`/`covergroup` in Icarus) before investing in code that depends on it, and building an equivalent-coverage stand-in rather than skipping the verification goal.
- Reset-domain-crossing discipline: recognizing an async-assert/async-deassert reset as a real timing hazard, not just a lint nag, and applying a 2-flop synchronizer at every relevant clock domain boundary (register bank, controller, and the board's physical reset button).
- I/O budget-driven architectural decisions: narrowing a 32-bit bus to 8-bit specifically to fit a target board's real pin budget, rather than building an oversized manual-switch interface around a bus that was never sized for a small FPGA dev board.
- APB-specific combinational-vs-registered timing traps (bus outputs must be combinational off current state; `PRDATA` capture must happen in the exact cycle `PADDR` still points at the target address).
- Escalating hardware verification scale deliberately (8×8 → 16×16 → 256×256) so a bug like the pixel-loader off-by-one is caught and debugged cheaply, long before it would show up as a garbled full-size image on real silicon.
- Distinguishing a genuine design defect from a PC-side setup/driver issue during hardware bring-up, and resolving the actual cause rather than mistrusting already-verified RTL.

## 22. Possible Future Extensions

The current architecture intentionally processes one 3×3 window at a time via UART, which is why it can only manage seconds-per-image throughput. The original streaming architecture from [Section 1](#1-origin-idea-dropped-a-streaming-line-buffer-sobel-pipeline) — line buffers, a sliding-window generator, and a pipelined `sobel_core`, aiming at 1 output pixel per clock — remains a natural, larger follow-on project built on the same verified Sobel math. Other possible extensions: an AXI-Stream wrapper, a DMA engine for image transfer instead of UART, additional convolution kernels beyond Sobel, and porting the verification environment's real SVA/covergroup files (already written, currently unused under Icarus) onto Vivado's XSIM.
