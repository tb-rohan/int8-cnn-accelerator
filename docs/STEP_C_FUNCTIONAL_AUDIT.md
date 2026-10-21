# Step C: Critical RTL, Arithmetic, Reset, and FSM Functional Audit

**Document Version:** 1.0.0
**Date:** October 20, 2026
**Target:** Standalone INT8 CNN AI Accelerator
**Context:** Preparation for Step D (Synchronous BRAM Feature-Memory Redesign)
**Author:** Antigravity Senior RTL Design & Verification Team

---

## 1. Executive Summary

Step C performed a rigorous, multi-faceted verification and functional audit of the standalone INT8 CNN hardware accelerator prior to modifying any feature memory architecture.

### Key Findings
1. **Mathematical Robustness:** The arithmetic datapath in `pe.sv`, `pe_array.sv`, and `post_proc.sv` is mathematically sound. The critical corner case $(-128) \times (-128) = +16384$ fits in signed 16-bit (`0x4000`), sign-extends correctly to 32 bits, and accumulates without overflow. Intermediate bias accumulation uses 33-bit precision, intermediate product scaling uses 49-bit precision, and requantization uses 50-bit round-half-up arithmetic.
2. **Directed Verification Success:** A new dedicated directed testbench [`tb/tb_directed_arith.sv`](../tb/tb_directed_arith.sv) was authored and executed. All corner-case tests passed with zero errors.
3. **100% Bit-Exact Match:** Baseline regression (`verify.ps1`, 8 testbenches) and full-image manual inference (`run_rtl_manual.py`) both passed with 100% bit-exact agreement against Python integer golden models (53,815 accelerator cycles, predicted digit `7`).
4. **FSM & Reset Discoveries:**
   - Active-low asynchronous reset (`rst_n`) properly resets all internal registers across all modules.
   - **Back-to-back start hazard:** In `ctrl_unit.sv`, when in `DONE` or `ERR` state, asserting `start` transitions the FSM to `IDLE` rather than restarting execution. Software must either apply a hardware reset or pulse `start` twice to trigger a second inference without reset.
   - **Ping-pong buffer state hazard:** In `mem_ctrl.sv`, `input_select` is only initialized on `!rst_n`. An inference pipeline with an odd number of layer swaps (e.g. 5 layers: CONV-POOL-CONV-POOL-FC) leaves `input_select = 1`. A second run without `rst_n` will use `feature_b` as input.
5. **Contract Preservation:** Zero modifications were made to `accel_top.sv`'s public interface, port widths, or AXI4-Lite register map (`0x00`–`0x30`). The RISC-V project remains completely untouched.

---

## 2. Baseline Test Suite Execution

All 8 existing testbenches were executed using `scripts/verify.ps1 -PythonExe python -UseExistingVectors`. Every test passed cleanly.

| Testbench | Description | Simulation Runtime / Cycles | Status |
| :--- | :--- | :--- | :--- |
| `tb_pe.sv` | Signed PE multiply-accumulate & activation register | 36 ns (36,000 ps) | **PASS** |
| `tb_pe_array.sv` | Systolic array skew alignment, tags, signed lane output | 126 ns (126,000 ps) | **PASS** |
| `tb_post_proc.sv` | Requantization, rounding, ReLU, saturation, pooling | 271 ns (271,000 ps) | **PASS** |
| `tb_mem_ctrl_random.sv` | Randomized DMA writes (600) and result reads (200) | 8,020 ns (8,020,000 ps) | **PASS** |
| `tb_mem_ctrl_zero_scan.sv` | Zero-lane optimization scan logic | 15,840 ns (15,840,000 ps) | **PASS** |
| `tb_ctrl_unit.sv` | Instruction decode & illegal descriptor rejection | 65 ns (65,000 ps) | **PASS** |
| `tb_top.sv` | AXI4-Lite interface, layer sequence, DMA & result reads | 3,135 ns (3,135,000 ps) | **PASS** |
| `tb_full_cnn.sv` | Full 28x28 MNIST inference (CONV-POOL-CONV-POOL-FC) | 53,815 clock cycles | **PASS** |

---

## 3. Deep Arithmetic Datapath Audit

### 3.1 Processing Element (`pe.sv`)
- **Inputs:** `a_in` (signed 8-bit), `b_in` (signed 8-bit), `acc_in` (signed 32-bit).
- **Multiplication:**
  ```systemverilog
  logic signed [2*DATA_W-1:0] mult; // signed [15:0]
  assign mult = $signed(a_reg) * $signed(b_reg);
  ```
  - Corner $(-128) \times (-128) = +16384 = 16\text{'h}4000$.
  - In 16-bit two's complement, `0x4000` is positive ($+16,384$), which is within $[-32768, 32767]$.
  - Sign extension to 32 bits produces `32'h0000_4000` (positive $+16,384$).
  - Corner $(-128) \times (+127) = -16256 = 16\text{'hC080} \to 32\text{'hFFFF_C080}$.
  - Corner $(+127) \times (+127) = +16129 = 16\text{'h3F01} \to 32\text{'h0000_3F01}$.
- **Accumulation:**
  ```systemverilog
  assign acc_out = acc + mult;
  ```
  Full 32-bit two's complement accumulation prevents overflow for practical CNN filter sizes ($3 \times 3 \times 16 \times 16384 \approx 2.3 \times 10^6 \ll 2^{31}-1$).

### 3.2 Systolic Array (`pe_array.sv`)
- **Dimensions:** $4 \times 4$ 2D mesh ($N=4$, 16 PEs total).
- **Dataflow:** Weight-stationary / Output-stationary hybrid:
  - Weights pre-loaded row by row via `w_load_en` and `w_load_row`.
  - Activations streamed horizontally from West to East with triangular skew registers: Row 0 delay = 0, Row 1 delay = 1, Row 2 delay = 2, Row 3 delay = 3 cycles.
  - Partial sums accumulated vertically from North to South with matching deskew registers.
  - Skew/deskew alignment is verified and cycle-accurate.

### 3.3 Post-Processing Unit (`post_proc.sv`)
- **Bias Addition:**
  ```systemverilog
  biased_stage[i] = $signed(acc_in[i*ACC_W +: ACC_W]) + $signed(bias_in[i*ACC_W +: ACC_W]);
  ```
  `biased_stage` is declared as `logic signed [ACC_W:0] biased_stage [0:N-1]` (33 bits).
  This 33-bit representation prevents two's complement wrap-around when adding large 32-bit partial sums and biases.
- **Intermediate Scaling Product:**
  ```systemverilog
  product_stage[i] = biased_stage[i] * $signed({1'b0, quant_mult});
  ```
  `quant_mult` is 16-bit unsigned, zero-extended and treated as signed 17-bit positive ($[0, 65535]$).
  $33\text{ bits} \times 17\text{ bits} = 50\text{ bits}$ maximum. `product_stage` is declared as `logic signed [48:0]` (49 bits), which accommodates all valid ranges because `biased_stage` never simultaneously saturates both extremes.
- **Round-Half-Up Fixed-Point Scaling:**
  ```systemverilog
  if (quant_shift > 0)
    scaled_stage[i] = (product_stage[i] + (49'sd1 <<< (quant_shift - 1))) >>> quant_shift;
  else
    scaled_stage[i] = product_stage[i];
  ```
  Formula mathematically mirrors Python integer reference:
  $$\text{scaled} = \left(P + 2^{\text{shift}-1}\right) \gg \text{shift}$$
- **Saturation to INT8 ($[-128, 127]$):**
  ```systemverilog
  if (scaled_stage[i] > 49'sd127)
    sat_stage[i] = 8'sd127;
  else if (scaled_stage[i] < -49'sd128)
    sat_stage[i] = -8'sd128;
  else
    sat_stage[i] = scaled_stage[i][DATA_W-1:0];
  ```
- **ReLU Activation:**
  Applied strictly after saturation: `relu_stage[i] = (relu_en && sat_stage[i] < 0) ? 8'sd0 : sat_stage[i];`
- **Max-Pooling:**
  ```systemverilog
  if ($signed(pool_data[i*DATA_W +: DATA_W]) > $signed(pool_reg[i]))
    pool_reg[i] <= pool_data[i*DATA_W +: DATA_W];
  ```
  Strict signed comparisons ensure that negative values (e.g. $-5 > -20$) are handled correctly.

---

## 4. Directed Arithmetic Testbench (`tb_directed_arith.sv`)

To eliminate any residual verification gaps, [`tb/tb_directed_arith.sv`](../tb/tb_directed_arith.sv) was created and simulated with Icarus Verilog (`iverilog -g2012`).

### Test Coverage Matrix
| Test Case | Inputs / Condition | Expected Output | Actual RTL Output | Verification Result |
| :--- | :--- | :--- | :--- | :--- |
| **PE Corner 1** | $a = 0, b = 0$ | mult = 0 | mult = 0 | **PASS** |
| **PE Corner 2** | $a = 127, b = 127$ | mult = $+16129$ (`0x3F01`) | mult = $+16129$ | **PASS** |
| **PE Corner 3** | $a = -128, b = 127$ | mult = $-16256$ (`0xFFFF_C080`) | mult = $-16256$ | **PASS** |
| **PE Corner 4** | $a = -128, b = -128$ | mult = $+16384$ (`0x0000_4000`) | mult = $+16384$ | **PASS** |
| **PE Accumulate** | $a=-128, b=-128$, acc=$-16384$ | acc_out = 0 | acc_out = 0 | **PASS** |
| **33-bit Bias Positive** | acc = $+2 \times 10^9$, bias = $+1 \times 10^9$ | sum = $+3 \times 10^9$ (no 32-bit overflow) | sum = $+3 \times 10^9$ | **PASS** |
| **33-bit Bias Negative** | acc = $-2 \times 10^9$, bias = $-1 \times 10^9$ | sum = $-3 \times 10^9$ (no 32-bit overflow) | sum = $-3 \times 10^9$ | **PASS** |
| **Rounding Threshold 1** | val = 11, mult = 1, shift = 3 (halfway = 4) | $(11 + 4) \gg 3 = 1$ | 1 | **PASS** |
| **Rounding Threshold 2** | val = 12, mult = 1, shift = 3 (halfway = 4) | $(12 + 4) \gg 3 = 2$ | 2 | **PASS** |
| **Rounding Negative 1** | val = $-12$, mult = 1, shift = 3 | $(-12 + 4) \gg 3 = -1$ | $-1$ | **PASS** |
| **Rounding Negative 2** | val = $-13$, mult = 1, shift = 3 | $(-13 + 4) \gg 3 = -2$ | $-2$ | **PASS** |
| **Positive Saturation** | scaled = $+500$ | sat = $+127$ | $+127$ | **PASS** |
| **Negative Saturation** | scaled = $-500$ | sat = $-128$ | $-128$ | **PASS** |
| **Shift Zero Passthrough** | val = 42, mult = 1, shift = 0 | out = 42 | 42 | **PASS** |
| **ReLU on Positive** | val = $+42$, relu_en = 1 | out = $+42$ | $+42$ | **PASS** |
| **ReLU on Negative** | val = $-42$, relu_en = 1 | out = 0 | 0 | **PASS** |
| **Signed Pooling** | quad = $\{-80, -20, -50, -10\}$ | max = $-10$ | $-10$ | **PASS** |

---

## 5. Trained Network Inference Verification

A complete end-to-end MNIST digit classification was executed using `run_rtl_manual.py --raw` against the preprocessed test sample:
- **Input Image:** `artifacts/manual/20261016_214025_016250_preprocessed_28x28/preprocessed_28x28.npy` (Digit 7).
- **Execution:** Full 5-layer pipeline simulated cycle-by-cycle in Icarus Verilog (`tb_full_cnn`).
- **Accelerator Cycles:** Exactly **53,815 clock cycles**.
- **Results:**
  - RTL Class Scores: `[-17, -36, -3, 8, -53, -13, -65, 47, -16, 1]`
  - Python INT8 Golden Scores: `[-17, -36, -3, 8, -53, -13, -65, 47, -16, 1]`
  - Byte-by-Byte Match: **12 / 12 bytes identical (100% bit-exact)**.
  - Predicted Digit: **7** (Top score: class 7 with score $+47$).

---

## 6. Reset, Control FSM, and Watchdog Audit

### 6.1 Reset Architecture
- **Clock:** Single synchronous clock `clk`.
- **Reset:** Active-low asynchronous reset `rst_n` (`@(posedge clk or negedge rst_n)`).
- **Coverage:** All architectural registers, control flip-flops, and AXI4-Lite handshake flags in `accel_top.sv`, `ctrl_unit.sv`, `mem_ctrl.sv`, `pe.sv`, `pe_array.sv`, and `post_proc.sv` are cleanly initialized on `!rst_n`.

### 6.2 FSM States and Transitions (`ctrl_unit.sv`)
```
IDLE -> (start) -> FETCH -> DECODE -> (legal) -> RUN -> WAIT -> (gen_done) -> SWAP -> FETCH
                                 |                                                ^
                                 +-> (OP_HALT) -> DONE                            |
                                 +-> (!legal)  -> ERR                             |
                                                                                  |
(From SWAP, increments PC; repeats until OP_HALT triggers DONE) ------------------+
```

### 6.3 FSM & State Machine Hazards Identified
1. **Back-to-Back Run Without Reset:**
   - In `ctrl_unit.sv`, when in `DONE`:
     ```systemverilog
     DONE: begin
       done <= 1'b1;
       if (start)
         state <= IDLE;
     end
     ```
   - In `accel_top.sv`, writing to `0x00` produces a **1-cycle pulse** on `start_pulse`.
   - Cycle 1: `state` is `DONE`, `start` is 1 $\to$ next state is `IDLE`.
   - Cycle 2: `state` is `IDLE`, but `start` is now 0 $\to$ stays in `IDLE`.
   - **Conclusion:** Software cannot restart a second inference from `DONE` with a single write to `0x00`. It must either apply a hardware reset (`rst_n`) or write `0x00` twice.
2. **Ping-Pong Buffer Selection (`input_select`):**
   - In `mem_ctrl.sv`, `input_select` initializes to 0 on `!rst_n` and toggles on `swap_buf`.
   - The 5-layer CNN produces 5 swaps, leaving `input_select = 1` after completion.
   - Without an active-low reset, a subsequent inference will start with `feature_b` as input rather than `feature_a`.
   - **Conclusion:** A hardware reset is required between inferences to guarantee `input_select = 0`. Both the standalone testbenches and the RISC-V SoC firmware follow this requirement.
3. **Watchdog Compatibility:**
   - Full MNIST inference requires **53,815 clock cycles**.
   - The RISC-V SoC integration testbench (`RISC-V/tb/tb_riscv_cnn_soc.sv`) enforces a watchdog timeout of **65,535 clock cycles**.
   - Headroom: $65,535 - 53,815 = 11,720\text{ cycles}$ (~18% safety margin).

---

## 7. Static Lint Analysis (Verilator v5.050)

Verilator lint was executed across all RTL sources (`rtl/cnn_pkg.sv`, `rtl/pe.sv`, `rtl/pe_array.sv`, `rtl/post_proc.sv`, `rtl/mem_ctrl.sv`, `rtl/ctrl_unit.sv`, `rtl/accel_top.sv`).
- **Fatal Errors:** 0 (Exit code: 0).
- **Warnings Identified:**
  1. `GENUNNAMED`: Unnamed generate blocks in `pe_array.sv` (cosmetic, style only).
  2. `WIDTHEXPAND`: Zero-extension of 90-bit instruction data to 128-bit instruction memory word in `ctrl_unit.sv` (intentional architectural padding).
  3. `UNUSEDSIGNAL`: Unused upper bits of configuration words and unused AXI address bits (harmless, fully masked).
  4. `SYNCASYNCNET`: False positive generated by Verilator on `rst_n` usage in always blocks.

---

## 8. Integration Contract Verification

The integration contract defined in [`docs/INTEGRATION_CONTRACT.md`](./INTEGRATION_CONTRACT.md) was strictly maintained throughout Step C:
- Module name: `accel_top` (preserved).
- Ports and widths: `clk`, `rst_n`, `s_axil_*`, `irq` (all preserved).
- Register map offsets: `0x00` to `0x30` (all preserved).
- RISC-V workspace files: Zero edits made to `../RISC-V`.
- Hardware arithmetic: Intact; no simulation or software shortcuts taken.

---

## 9. Readiness Assessment for Step D

With Step C complete:
1. **The RTL is functionally verified and bit-exact with the golden model.**
2. **All arithmetic corners are validated.**
3. **The cause of the FPGA timing failure ($WNS = -12.971\text{ ns}$) and resource explosion (28,160 Distributed RAM LUTs) is 100% understood:**
   - Combinational asynchronous reads on `feature_a` and `feature_b` in `mem_ctrl.sv` (lines 118–124) prevent Block RAM inference.
   - Long combinational path (20 logic levels, 2 DSPs + Distributed RAM + comparator) violates 10 ns clock period.
4. **Step D Scope:**
   - Redesign `feature_a` and `feature_b` memory interfaces in `mem_ctrl.sv` to support **synchronous, pipelined Block RAM reads** with 1-cycle or 2-cycle read latency.
   - Update `mem_ctrl` streaming, pooling, and DMA state machines to absorb memory read latency without breaking arithmetic throughput.
   - Retain identical external AXI4-Lite MMIO behavior and instruction set.
   - Verify that all 8 testbenches and `tb_directed_arith` pass after the redesign.
