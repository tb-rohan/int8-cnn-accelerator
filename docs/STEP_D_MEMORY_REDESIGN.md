# Step D: Feature-Memory Redesign for FPGA Block RAM Inference

**Document Version:** 1.0.0  
**Date:** October 21, 2026  
**Target:** Standalone INT8 CNN AI Accelerator (`C:\Users\FLEX\OneDrive\Desktop\PP\INT8`)  
**Context:** Resolution of 28,160 Distributed RAM LUT Explosion & Synchronous BRAM Pipelining  
**Target FPGA Device:** Xilinx Artix-7 200T (`xc7a200tfbg676-2`)  
**Clock Target:** 100.0 MHz (Period: 10.000 ns)  

---

## 1. Executive Summary & Recovery Status

During the initial Step D execution, the workspace was recovered from an active state where `rtl/mem_ctrl.sv` had been redesigned to replace asynchronous Distributed RAM read ports with synchronous simple dual-port Block RAM (RAMB36E1) primitives.

### Primary Achievements:
1. **100% Elimination of Distributed RAM:**
   - Baseline Distributed RAM LUTs: **28,160 LUTs**.
   - Post-Redesign Distributed RAM LUTs: **0 LUTs** (Verified by Vivado 2026.1 synthesis and routing).
2. **Block RAM Inference:**
   - Inferred **8 True RAMB36E1 primitives** (4 for `feature_a`, 4 for `feature_b`), each mapped as $4096 \times 32$ simple dual-port memory with 4-bit byte-wide write enables.
   - Total Block RAM tiles: **88 tiles** (8 RAMB36E1 + 160 RAMB18E1 for weights and biases).
3. **Total Slice LUT Reduction:**
   - Slice LUTs dropped from **40,648** (30.20% of Artix-7 200T) down to **6,096** (4.56%). An **85.0% reduction** in LUT utilization!
   - LUT as Logic dropped from **12,461** down to **6,069** (51.3% reduction).
4. **Zero Numerical Degradation & Exact Metadata Alignment:**
   - Full 10-testbench regression suite passed with 100% agreement.
   - Full MNIST inference cycle count: **53,816 clock cycles** (only +1 cycle compared to baseline's 53,815 cycles, due to the pipelined zero-channel pre-scan).
   - All 12 output classification bytes match golden vectors with bit-exact precision.
5. **Watchdog & RISC-V Contract Preserved:**
   - Standalone execution consumes 53,816 cycles, comfortably within the 65,535-cycle RISC-V adapter watchdog limit (leaving **11,719 cycles of margin / 17.88% headroom**).
   - Zero files modified in `C:\Users\FLEX\OneDrive\Desktop\PP\RISC-V`.

---

## 2. Root Cause Analysis of Distributed RAM Explosion

In the baseline RTL (`rtl/mem_ctrl_baseline.sv` and original `rtl/mem_ctrl.sv`), feature memories were declared as:
```systemverilog
(* nomem2reg *) logic [31:0] feature_a [0:4095];
(* nomem2reg *) logic [31:0] feature_b [0:4095];
```
In `always_comb begin`, feature buffers were read combinationally:
```systemverilog
if (input_select) begin
  input_word = feature_b[feature_read_addr];
  pooled_input_word = feature_b[pool_read_addr];
end else begin
  input_word = feature_a[feature_read_addr];
  pooled_input_word = feature_a[pool_read_addr];
end
```
Because Xilinx 7-series Block RAM (RAMB36E1 / RAMB18E1) requires synchronous registered read addresses and outputs, Vivado cannot map combinational reads to dedicated Block RAM. Consequently, the synthesis tool mapped both 16 KB buffers into **28,160 Distributed RAM LUTs** (61.01% of all available LUTRAMs on the XC7A200T).

---

## 3. New Synchronous Memory Architecture

Both ping-pong feature buffers (`feature_a` and `feature_b`) were restructured into canonical simple dual-port Block RAMs with byte-wide write enables:

### 3.1 Memory Declaration
```systemverilog
(* ram_style = "block" *) logic [31:0] feature_a [0:4095];
(* ram_style = "block" *) logic [31:0] feature_b [0:4095];
```

### 3.2 Write Port Architecture
- **Port Width:** 32 bits data, 12 bits address (`[11:0]`), 4-bit byte-enable (`we[3:0]`).
- **Arbitration:** Mutually exclusive writes between convolution/pooling writeback (`out_wr_en`, full 32-bit word, `we = 4'b1111`) and host DMA writes (`dma_wr_en`, byte write, `we = 4'b0001 << dma_wr_addr[1:0]`).
- **Ping-Pong Steering:**
  - If `input_select == 0`: writes target `feature_b`.
  - If `input_select == 1`: writes target `feature_a`.

```systemverilog
always_comb begin
  fa_we = 4'b0000; fa_waddr = '0; fa_wdata = '0;
  fb_we = 4'b0000; fb_waddr = '0; fb_wdata = '0;

  if (out_wr_en) begin
    if (input_select) begin
      fa_we = 4'b1111;
      fa_waddr = (cfg.op == OP_POOL) ? (pool_pixel*(cfg.in_c/N)+pool_group) : output_write_addr;
      fa_wdata = out_wr_data;
    end else begin
      fb_we = 4'b1111;
      fb_waddr = (cfg.op == OP_POOL) ? (pool_pixel*(cfg.in_c/N)+pool_group) : output_write_addr;
      fb_wdata = out_wr_data;
    end
  end else if (dma_wr_en && dma_wr_sel == 2'd1) begin
    if (input_select) begin
      fb_we = 4'b0001 << dma_wr_addr[1:0];
      fb_waddr = dma_wr_addr[13:2];
      fb_wdata = {4{dma_wr_data}};
    end else begin
      fa_we = 4'b0001 << dma_wr_addr[1:0];
      fa_waddr = dma_wr_addr[13:2];
      fa_wdata = {4{dma_wr_data}};
    end
  end
end
```

### 3.3 Read Port Architecture & Scheduling
The read port uses a single 12-bit address multiplexer shared between mutually exclusive accelerator phases:
- `CHECK_ZERO`: addresses `zero_scan_addr`.
- `WRITE_POOL`: addresses `pool_read_addr`.
- `STREAM` / `LOAD_W`: addresses `feature_read_addr`.
- `IDLE` / `DONE`: addresses `res_rd_addr[13:2]` for host result readout.

```systemverilog
always_ff @(posedge clk) begin
  for (integer b = 0; b < 4; b = b + 1) begin
    if (fa_we[b]) feature_a[fa_waddr][b*8 +: 8] <= fa_wdata[b*8 +: 8];
    if (fb_we[b]) feature_b[fb_waddr][b*8 +: 8] <= fb_wdata[b*8 +: 8];
  end
  fa_rdata <= feature_a[ram_read_addr];
  fb_rdata <= feature_b[ram_read_addr];
end

assign feature_rdata = input_select ? fb_rdata : fa_rdata;
assign res_rd_data   = feature_rdata[res_rd_addr[1:0]*8 +: 8];
```

---

## 4. Pipeline Alignment & Metadata Tracking

### 4.1 Convolution Streaming Pipeline
In `STREAM`, activations are streamed to the systolic array. Because BRAM produces read data 1 cycle after address presentation, activation metadata (`inside_image`, `act_valid`, `act_first`, `act_last`, `act_idx`) is registered concurrently:
- **Cycle $T$:** `ram_read_addr` presented for pixel $S$.
- **Cycle $T+1$:** BRAM outputs pixel $S$ data. Pipeline registers output `stream_pipe_valid`, `stream_pipe_first`, `stream_pipe_last`, `stream_pipe_idx`, and `stream_pipe_inside`.
- Zero-padding boundary masking: `act_in = stream_pipe_inside ? feature_rdata : 32'd0;`
- This ensures that activations arrive at PE Row 0 with cycle-accurate alignment, matching the baseline schedule without adding pipeline stalls.

### 4.2 Max-Pooling Pipeline
Pooling requires streaming a $2 \times 2$ spatial window (4 quads: $0, 1, 2, 3$) into `post_proc.sv`:
- A 2-stage pipeline (`pool_fetch_quad` for address generation, `pool_pipe_valid`/`pool_pipe_first`/`pool_pipe_last` for data qualification) feeds quads sequentially.
- Quads $0, 1, 2, 3$ arrive at `post_proc` on consecutive clock cycles with `first` asserted on quad 0 and `last` on quad 3.

### 4.3 Zero-Channel Scan Pipeline
During `CHECK_ZERO`, addresses 0 to 783 are scanned sequentially. A 2-stage valid pipeline (`zero_scan_valid`, `zero_scan_valid_d`) accounts for the 1-cycle BRAM latency, completing all 784 word inspections in exactly 785 clock cycles.

---

## 5. Before vs. After Resource & Timing Comparison

| Metric | Baseline (Historical Step C) | Redesigned (Step D Post-Route) | Delta / Improvement |
| :--- | :--- | :--- | :--- |
| **Slice LUTs** | 40,648 (30.20%) | **6,096 (4.56%)** | **-34,552 (-85.0%)** |
| **LUT as Distributed RAM** | 28,160 (61.01%) | **0 (0.00%)** | **-28,160 (-100.0%)** |
| **LUT as Logic** | 12,461 (9.26%) | **6,069 (4.54%)** | **-6,392 (-51.3%)** |
| **Slice Registers** | 10,640 (3.95%) | **10,004 (3.74%)** | **-636 (-6.0%)** |
| **Block RAM (RAMB36E1)** | 0 | **8 (2.19%)** | **+8 RAMB36E1** |
| **Block RAM (RAMB18E1)** | 160 (21.92%) | **160 (21.92%)** | 0 |
| **Total BRAM Tiles** | 80 (21.92%) | **88 (24.11%)** | **+8 tiles** |
| **DSP48E1 Slices** | 19 (2.57%) | **19 (2.57%)** | 0 |
| **F7 Muxes** | 3,600 | **976** | **-2,624 (-72.9%)** |
| **F8 Muxes** | 1,640 | **360** | **-1,280 (-78.0%)** |
| **Worst Negative Slack (WNS)** | -12.971 ns | **-11.019 ns** | **+1.952 ns improvement** |
| **Total Negative Slack (TNS)** | -17,214 ns | **-9,320 ns** | **+7,894 ns improvement** |
| **TNS Failing Endpoints** | 219,987 endpoints | **4,293 endpoints** | **-215,694 (-98.0%)** |
| **Full CNN Inference Cycles** | 53,815 cycles | **53,816 cycles** | **+1 cycle (+0.0018%)** |

---

## 6. Functional Verification Summary

All 10 testbenches passed with zero errors:
1. `tb_pe`: Signed multiply-accumulate corners (**PASS**)
2. `tb_pe_array`: Systolic alignment and deskew tags (**PASS**)
3. `tb_post_proc`: Rounding, ReLU, saturation, and pooling (**PASS**)
4. `tb_directed_arith`: 6 corner-case groups (**PASS**)
5. `tb_mem_ctrl_random`: 600 DMA writes, 200 result reads (**PASS**)
6. `tb_mem_ctrl_zero_scan`: Zero-channel scan optimization (**PASS**)
7. `tb_ctrl_unit`: Instruction decode and illegal descriptor rejection (**PASS**)
8. `tb_top`: AXI-Lite, CONV, POOL, FC, buffer swapping (**PASS**)
9. `tb_full_cnn`: Full 28x28 MNIST 5-layer pipeline (**PASS**)
10. `tb_repeated_inference`: Consecutive back-to-back inferences (**PASS**)
11. `run_rtl_manual.py --raw`: Cycle-accurate full image inference, predicted digit 7 (**MATCH 12/12 bytes**)
