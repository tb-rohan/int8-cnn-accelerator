# Step E: Timing Optimization Report

**Project:** Standalone INT8 CNN Hardware Accelerator  
**Target Module:** `accel_top` (`mem_ctrl.sv`)  
**Target FPGA Device:** AMD Xilinx Artix-7 200T (`xc7a200tfbg676-2`)  
**Clock Target:** 100.0 MHz ($T_{\text{clk}} = 10.000\text{ ns}$)  
**Tool Version:** AMD Vivado v2026.1 (win64) Build 6511674  
**Date:** October 21, 2026  
**Status:** Optimization Implemented, Fully Verified, and Characterized  

---

## 1. Executive Summary & Problem Diagnosis

Following the Step D Block RAM inference overhaul, a severe timing violation was uncovered in the post-route timing analysis:
- **Prior WNS:** $-11.019\text{ ns}$ (Data path delay: $20.809\text{ ns}$)
- **Prior TNS:** $-9,320.995\text{ ns}$ across 4,293 failing setup endpoints
- **Prior Critical Path Depth:** 33 logic levels
- **Prior Estimated $F_{\text{max}}$:** $\approx 47.57\text{ MHz}$

### Root Cause Analysis
The critical path originated at `control/cfg_reg[kernel][2]/C` and terminated at `memory/ky_count_reg[*]/CE` and `memory/chunk_count_reg[*]/CE`.
In `rtl/mem_ctrl.sv`, layer configuration parameters were evaluated inside an unpipelined combinational block (`always_comb`):
```verilog
out_h      = (cfg.in_h + 2*cfg.pad - cfg.kernel) / (cfg.stride == 0 ? 1 : cfg.stride) + 1;
out_w      = (cfg.in_w + 2*cfg.pad - cfg.kernel) / (cfg.stride == 0 ? 1 : cfg.stride) + 1;
out_pixels = out_h * out_w;
chunks     = cfg.kernel * cfg.kernel * (cfg.in_c / N);
groups     = cfg.out_c / N;
tiles      = (out_pixels + TILE_P - 1) / TILE_P;
```
Because `cfg.stride`, `cfg.kernel`, and layer dimensions were dynamic inputs from `ctrl_unit`, Vivado synthesized:
1. Dynamic integer division logic for `out_h` and `out_w`.
2. A $12\times 12$ DSP48 multiplier for `out_pixels`.
3. Multipliers and dividers for `chunks` and `tiles`.
4. Comparators for loop boundaries (`chunk_count == chunks - 1`, `chunk_count + 1 < chunks`, `tile_count + 1 < tiles`).

All of this was chained into the clock-enable (CE) gating of nested loop counters (`ky_count`, `kx_count`, `icg_count`, `chunk_count`) within a single clock cycle, producing a 33-logic-level, 20.8 ns delay.

---

## 2. Timing Optimizations Performed

### 2.1 Pipelined Layer Configuration State Machine
Because layer descriptors are static throughout the execution of each layer (thousands of clock cycles), a dedicated 4-stage configuration pipeline was introduced in `mem_ctrl.sv`:
`IDLE -> CONF_1 -> CONF_2 -> CONF_3 -> CONF_4 -> (WRITE_POOL / CHECK_ZERO / PLAN)`.

- **`CONF_1` (Stage 1 - Linear Arithmetic & Shifts):**
  - Registered `in_h_padded`, `in_w_padded`, `stride_val`.
  - Registered `in_c_groups_reg <= cfg.in_c / N` (2-bit shift).
  - Registered `groups_reg <= cfg.out_c / N` (2-bit shift).
  - Registered `kernel_sq <= cfg.kernel * cfg.kernel`.
  - Registered `pool_out_w_reg <= cfg.in_w >> 1` and `pool_out_h_reg <= cfg.in_h >> 1`.
  - Registered `in_c_groups_minus_1_reg` and `kernel_minus_1_reg`.
  - Registered geometry precomputations: `row_pitch <= cfg.in_w * (cfg.in_c / N)` and `col_step <= stride_val * (cfg.in_c / N)`.
- **`CONF_2` (Stage 2 - Spatial Dimension Shift Logic):**
  - Replaced non-restoring subtractive division with power-of-2 shifting:
    ```verilog
    out_h_reg <= (stride_val == 4'd2) ? (in_h_padded >> 1) : in_h_padded;
    out_w_reg <= (stride_val == 4'd2) ? (in_w_padded >> 1) : in_w_padded;
    ```
    This eliminated 24 logic levels of dynamic division in synthesis.
  - Registered `chunks_reg <= kernel_sq * in_c_groups_reg;`.
  - Registered `pool_out_pixels_reg <= pool_out_w_reg * pool_out_h_reg;`.
  - Precalculated `row_step <= stride_val * row_pitch;`.
- **`CONF_3` (Stage 3 - Pixel Count & Terminal Counts):**
  - Isolated multiplication: `out_pixels_reg <= out_h_reg * out_w_reg;`.
  - Registered terminal counts: `chunks_minus_1_reg <= chunks_reg - 1'b1;`, `groups_minus_1_reg <= groups_reg - 1'b1;`, `out_w_minus_1_reg <= out_w_reg - 1'b1;`, `pool_out_w_minus_1_reg <= pool_out_w_reg - 1'b1;`, `pool_out_pixels_minus_1_reg <= pool_out_pixels_reg - 1'b1;`.
- **`CONF_4` (Stage 4 - Tile Bounds & Execution Dispatch):**
  - Registered `tiles_reg <= (out_pixels_reg + TILE_P - 1) / TILE_P;`.
  - Registered `tiles_minus_1_reg <= ((out_pixels_reg + TILE_P - 1) / TILE_P) - 1'b1;`.
  - Reset `group_chunk_base <= '0;`.
  - Dispatches execution cleanly into `WRITE_POOL`, `CHECK_ZERO`, or `PLAN`.

### 2.2 Incremental Feature Row/Col Address Generation
In convolution streaming, the 2D feature address originally chained two DSP multipliers (`stream_y * stride * in_w * in_c_groups`). This combinational chain directly drove Block RAM read address ports.
This was overhauled using incremental row and column accumulation:
- In `PLAN`: Precomputes initial `cur_row_base` and `cur_x_offset` in parallel DSP slices.
- In `LOAD_W` & `STREAM`: Address generation collapses to an incremental 12-bit adder:
  ```verilog
  feature_read_addr = cur_row_base + cur_x_offset;
  ```
  Whenever `stream_x` advances, `cur_x_offset <= cur_x_offset + col_step`. Whenever `stream_x` wraps, `cur_row_base <= cur_row_base + row_step`.
  This completely removed both DSP multipliers from the Block RAM streaming read address path.

### 2.3 Terminal Count Registering & Comparator Simplification
All nested loop comparisons in `LOAD_W`, `STREAM`, `DRAIN`, and `WRITE_POOL` were converted from combinational arithmetic against variable expressions to single-level comparisons against static registers:
- `chunk_count == chunks - 1` $\rightarrow$ `chunk_count == chunks_minus_1_reg`
- `chunk_count + 1 < chunks` $\rightarrow$ `chunk_count < chunks_minus_1_reg`
- `group_count + 1 < groups` $\rightarrow$ `group_count < groups_minus_1_reg`
- `tile_count + 1 < tiles` $\rightarrow$ `tile_count < tiles_minus_1_reg`
- `stream_x + 1 >= out_w` $\rightarrow$ `stream_x >= out_w_minus_1_reg`
- `calc_tile_x + 1 >= out_w` $\rightarrow$ `calc_tile_x >= out_w_minus_1_reg`
- `icg_count + 1 >= cfg.in_c/N` $\rightarrow$ `icg_count >= in_c_groups_minus_1_reg`
- `kx_count + 1 >= cfg.kernel` $\rightarrow$ `kx_count >= kernel_minus_1_reg`
- `pool_group + 1 < cfg.in_c/N` $\rightarrow$ `pool_group < in_c_groups_minus_1_reg`
- `pool_pixel + 1 < pool_out_pixels` $\rightarrow$ `pool_pixel < pool_out_pixels_minus_1_reg`
- `pool_x_count + 1 >= pool_out_w` $\rightarrow$ `pool_x_count >= pool_out_w_minus_1_reg`

### 2.4 Incremental Weight Address Accumulation
In `mem_ctrl.sv`, `weight_read_addr` originally computed:
```verilog
weight_read_addr = cfg.w_base + ((group_count * chunks + chunk_count) * N + load_count);
```
The multiplier `group_count * chunks` was eliminated by maintaining `group_chunk_base` as an accumulator:
- Initialized to 0 at layer start and tile transitions.
- Incremented by `group_chunk_base <= group_chunk_base + chunks_reg;` whenever `group_count` increments.
- Address calculation reduced to: `cfg.w_base + ((group_chunk_base + chunk_count) * N + load_count)`.

### 2.5 Max-Pooling Address Pointer Optimization & Stride Shift Multiplexing
Following the initial configuration pipelining, post-route timing analysis identified two remaining cascaded DSP multiplier paths:
1. **Max-Pooling Address Calculation in `WRITE_POOL`:**
   Originally computed combinationally:
   ```verilog
   pool_read_addr = ((pool_y * 2 + dy) * in_w + (pool_x * 2 + dx)) * in_c_groups + pool_group;
   ```
   This chained two DSP48 multipliers into the Block RAM read port.
   **Solution:** Replaced with precomputed pitch constants (`row_pitch`, `row_pitch_plus_icg` registered during configuration) and incremental pointer stepping (`pool_row_base`, `pool_col_base`, `pool_base_addr`). Feature writes use a sequential counter `pool_write_addr <= pool_write_addr + 1'b1`. This completely removed both DSP multipliers from the pooling read and write datapath.
2. **Stride Multiplier in `PLAN`:**
   Originally computed:
   ```verilog
   tile_origin_y * stride_val
   ```
   vivado inferred a 3.35 ns DSP multiplier chained with spatial base multipliers.
   **Solution:** Replaced with a power-of-2 shift multiplexer:
   ```verilog
   (stride_val == 4'd2) ? (tile_origin_y << 1) : ...
   ```
   This eliminated the DSP multiplier entirely, reducing total DSP count from 20 down to 16.

---

## 3. Implementation and Timing Results Comparison

| Metric | Step C Baseline | Step D (BRAM Inferred) | Step E (100 MHz Timing Closure) | Delta vs. Step D |
| :--- | :---: | :---: | :---: | :---: |
| **Worst Negative Slack (WNS)** | $-12.971\text{ ns}$ | $-11.019\text{ ns}$ | **+0.621 ns** | **+11.640 ns (TIMING CLOSED!)** |
| **Total Negative Slack (TNS)** | $-814,951.938\text{ ns}$ | $-9,320.995\text{ ns}$ | **0.000 ns** | **-9,320.995 ns (Zero Violations)** |
| **Failing Setup Endpoints** | 219,987 | 4,293 | **0** | **-4,293 endpoints (0 failing)** |
| **Worst Hold Slack (WHS)** | $+0.139\text{ ns}$ | $+0.141\text{ ns}$ | **+0.102 ns** | **MET (PASS, 0 violations)** |
| **Total Hold Slack (THS)** | $0.000\text{ ns}$ | $0.000\text{ ns}$ | **0.000 ns** | **MET (PASS)** |
| **Worst Pulse Width Slack (WPWS)**| $+4.146\text{ ns}$ | $+4.146\text{ ns}$ | **+4.146 ns** | **MET (PASS)** |
| **Critical Path Depth** | — | 33 logic levels | **0 logic levels** | **-33 logic levels (Pure wire routing)** |
| **Critical Path Delay** | — | $20.809\text{ ns}$ | **9.091 ns** | **-11.718 ns (56.31% reduction)** |
| **Estimated $F_{\text{max}}$** | $\approx 43.5\text{ MHz}$ | $\approx 47.57\text{ MHz}$ | **106.62 MHz** | **+59.05 MHz (+124.13% increase)** |
| **Slice LUTs** | 40,674 | 6,096 | **6,199** | +103 LUTs (+1.69%) |
| ├─ LUT as Logic | 12,487 | 6,069 | **6,172** | +103 LUTs |
| └── LUT as Distributed RAM | 28,160 | 0 | **0** | Preserved (0) |
| **Slice Registers (FFs)** | 10,702 | 10,004 | **10,316** | +312 FFs (pipeline & geometry registers) |
| **Block RAM Tiles** | 80 | 88 | **88** | Preserved (8 RAMB36 + 160 RAMB18) |
| **DSP48E1 Slices** | 19 | 18 | **16** | **-2 DSPs (-11.11% via shift mux)** |

---

## 4. Final Critical Path Analysis

With all combinational arithmetic multipliers removed from runtime address paths, the top post-route setup path in `fpga/reports/a200t/post_route_timing_max_paths.rpt` is:
- **Source:** `dma_wr_data_reg[0]/C` (FDCE)
- **Destination:** `memory/weights_reg_8/DIADI[0]` (RAMB18E1)
- **Logic Levels:** **0** (pure wire routing delay)
- **Data Path Delay:** 9.091 ns (Logic: 0.379 ns / 4.17%, Routing: 8.712 ns / 95.83%)
- **Worst Slack:** **+0.621 ns** (TIMING MET at 100.0 MHz constraint)
- **Total Failing Endpoints:** **0** across all 24,292 design endpoints.

---

## 5. Functional Regression Impact

1. **Test Suite:** All 10 testbenches passed with 100% pass rate (`scripts/verify.ps1`).
2. **Cycle Overhead:**
   - The 4 configuration states add exactly 4 cycles per layer.
   - Across the 5-layer CNN, total inference cycles increased from 53,816 to **53,836 cycles** ($+20\text{ cycles}$ or $+0.037\%$).
3. **Bit-Exact Accuracy:** Confirmed 100% bit-exact output match with Python integer golden model and manual image inference (Predicted digit: 7, 12/12 output bytes matched).
4. **Bus Watchdog Compatibility:** The RISC-V SoC adapter (`accel_adapter.sv`) enforces a 65,535-cycle watchdog on individual AXI4-Lite bus transactions. Because status register polling handshakes complete in 1–2 cycles each, resetting the counter on every read, there is zero risk of timeout during the 53,836-cycle compute phase. (The bus watchdog limit must not be directly compared with full inference latency to claim an inference safety margin).
