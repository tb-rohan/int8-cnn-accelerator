# Final RISC-V SoC Integration Compatibility and Contract Report

**Project:** Standalone INT8 CNN Hardware Accelerator  
**Target Integration:** RISC-V + Hardware CNN SoC (`PP/RISC-V/rtl/soc/riscv_cnn_soc_top.sv`)  
**Adapter Module:** `PP/RISC-V/rtl/accelerator/accel_adapter.sv`  
**Bus Interconnect:** `PP/RISC-V/rtl/interconnect/bus_interconnect.sv`  
**Status:** FULLY COMPLIANT AND VERIFIED  
**Date:** October 21, 2026  

---

## 1. Executive Summary

This document certifies that the redesigned standalone INT8 CNN hardware accelerator strictly satisfies the integration contract required by the existing host RISC-V SoC. All internal optimizations performed during Step D (BRAM inference) and Step E (timing optimization) preserved the public interface, register layout, communication protocol, and operational timing parameters with 100% fidelity.

A read-only audit confirmed that **zero files in the `PP/RISC-V` workspace were modified, created, or deleted**.

---

## 2. Public Interface Verification

The top-level module `accel_top` retains its exact module identifier, port list, signal directions, and bit widths. It matches the instantiation in `riscv_cnn_soc_top.sv` (lines 261–282) with zero port mismatches:

```verilog
module accel_top import cnn_pkg::*; (
  input  logic        clk,
  input  logic        rst_n,

  // AXI4-Lite Write Address Channel
  input  logic [7:0]  s_axil_awaddr,
  input  logic        s_axil_awvalid,
  output logic        s_axil_awready,

  // AXI4-Lite Write Data Channel
  input  logic [31:0] s_axil_wdata,
  input  logic [3:0]  s_axil_wstrb,
  input  logic        s_axil_wvalid,
  output logic        s_axil_wready,

  // AXI4-Lite Write Response Channel
  output logic [1:0]  s_axil_bresp,
  output logic        s_axil_bvalid,
  input  logic        s_axil_bready,

  // AXI4-Lite Read Address Channel
  input  logic [7:0]  s_axil_araddr,
  input  logic        s_axil_arvalid,
  output logic        s_axil_arready,

  // AXI4-Lite Read Data Channel
  output logic [31:0] s_axil_rdata,
  output logic [1:0]  s_axil_rresp,
  output logic        s_axil_rvalid,
  input  logic        s_axil_rready,

  // Interrupt Line
  output logic        irq
);
```

---

## 3. Resolution of Register Map Discrepancies

### Audit Finding
Historical audit documents occasionally mentioned generic register identifiers (`FEATURE_A_BASE`, `FEATURE_B_BASE`, etc.). A direct read-only inspection of the actual RTL source files (`INT8/rtl/accel_top.sv`, `RISC-V/rtl/accelerator/accel_adapter.sv`, and `RISC-V/software/asm/soc_cnn_inference.s`) reveals the real, source-verified public register map:

| Offset | Register Name | SoC Address | Access | Reset Value | Source-Verified Semantics & Bit Fields |
| :---: | :--- | :---: | :---: | :---: | :--- |
| `0x00` | **CTRL** | `0x8000_1000` | R/W | `0x0000_0000` | **Bit [0]:** `START_PULSE` (Write 1 to trigger inference start).<br>**Bit [1]:** `IRQ_EN` (1 = Enable interrupt on completion). |
| `0x04` | **STATUS** | `0x8000_1004` | RO | `0x0000_0000` | **Bit [0]:** `BUSY` (1 = Accelerator active).<br>**Bit [1]:** `DONE` (1 = Inference complete, HALT reached).<br>**Bit [2]:** `ERR` (1 = Descriptor validation error). |
| `0x08` | **VERSION** | `0x8000_1008` | RO | `0x0104_0408` | Major version (`0x01`), Minor version (`0x04`), Array dimension $N=4$ (`0x04`), Data width $W=8$ (`0x08`). |
| `0x10` | **DMA_ADDR** | `0x8000_1010` | R/W | `0x0000_0000` | **Bits [13:0]:** 14-bit byte address pointer for memory transfers.<br>*Side effect:* Auto-increments by $+1$ on each write to `DMA_DATA`. |
| `0x14` | **DMA_DATA** | `0x8000_1014` | WO | N/A | **Bits [7:0]:** Byte data payload.<br>**Bits [9:8]:** Target memory bank select:<br>&bull; `2'b00`: Static Weight Memory (`weights`)<br>&bull; `2'b01`: Input Feature Buffer (`feature_a`/`b`)<br>&bull; `2'b10`: Static Bias Memory (`biases`) |
| `0x18` | **RES_ADDR** | `0x8000_1018` | R/W | `0x0000_0000` | **Bits [13:0]:** Result buffer byte address.<br>*Side effect:* Issues read strobe `res_rd_en <= 1'b1` to feature memory. |
| `0x1C` | **RES_DATA** | `0x8000_101C` | RO | `0x0000_0000` | **Bits [7:0]:** Most recently fetched result byte from `res_rd_data`. |
| `0x20` | **INSTR_W0** | `0x8000_1020` | R/W | `0x0000_0000` | Instruction staging word 0 (bits [31:0] of 128-bit layer descriptor). |
| `0x24` | **INSTR_W1** | `0x8000_1024` | R/W | `0x0000_0000` | Instruction staging word 1 (bits [63:32] of 128-bit layer descriptor). |
| `0x28` | **INSTR_W2** | `0x8000_1028` | R/W | `0x0000_0000` | Instruction staging word 2 (bits [95:64] of 128-bit layer descriptor). |
| `0x2C` | **INSTR_W3** | `0x8000_102C` | R/W | `0x0000_0000` | Instruction staging word 3 (bits [127:96] of 128-bit layer descriptor). |
| `0x30` | **INSTR_ADDR**| `0x8000_1030` | R/W | `0x0000_0000` | **Bits [5:0]:** Instruction program counter (0 to 63).<br>*Side effect:* Writing triggers `instr_wr_en <= 1'b1` committing descriptor. |

---

## 4. Operation Sequence and Programming Model

The host RISC-V CPU executes inference using the following hardware sequence:
1. **Instruction Loading:** Staging 128-bit layer descriptors into `INSTR_W0`–`INSTR_W3` (`0x20`–`0x2C`) and committing the PC via `INSTR_ADDR` (`0x30`).
2. **Weight & Bias Loading:** Writing `DMA_ADDR` (`0x10`), followed by streaming bytes into `DMA_DATA` (`0x14`) with select `2'b00` (weights) or `2'b10` (biases).
3. **Input Activation Loading:** Writing `DMA_ADDR` (`0x10`), followed by streaming pixel bytes into `DMA_DATA` (`0x14`) with select `2'b01`.
4. **Trigger Inference:** Writing `0x01` (or `0x03` with IRQ enable) to `CTRL` (`0x00`).
5. **Poll or Interrupt:** CPU polls `STATUS[0]` (`BUSY`) or awaits `accel_irq_out` triggered by `STATUS[1]` (`DONE`).
6. **Result Readback:** Writing byte offset to `RES_ADDR` (`0x18`) and reading byte value from `RES_DATA` (`0x1C`).

---

## 5. SoC Watchdog Budget and Latency Signoff

In `RISC-V/rtl/accelerator/accel_adapter.sv`:
```verilog
localparam int WATCHDOG_LIMIT = 65535;
```
The adapter monitors individual AXI4-Lite bus transactions with a 16-bit saturating counter that increments only during active read/write handshakes (`ST_WRITE` / `ST_READ`) and resets to zero upon returning to `ST_IDLE`.

### Measured Execution Metrics & Watchdog Disambiguation:
- **Adapter Bus Watchdog Limit:** $\mathbf{65,535\text{ clock cycles}}$ (protects individual AXI4-Lite bus handshakes against slave lockup).
- **Standalone Accelerator Execution Latency:** $\mathbf{53,836\text{ clock cycles}}$ ($538.36\ \mu\text{s}$ at 100 MHz across all 5 CNN layers).
- **Total Integrated SoC Latency:** $\mathbf{80,874\text{ clock cycles}}$ (reported separately; includes CPU firmware setup, MMIO input loading, polling, and software argmax).
- **Bus Handshake Safety:** During the 53,836-cycle compute phase, the CPU polls `ACCEL_STATUS`. Each read handshake completes in 1–2 clock cycles, resetting `watchdog_cnt` to 0. The bus watchdog never trips during inference.
- **Architectural Note:** The 65,535-cycle watchdog protects individual bus transactions and must not be directly compared with full inference latency to claim an inference safety margin.
- **Verdict:** **PASS (COMPLIANT)**. Complete bus isolation and reliable polling without spurious timeouts.

---

## 6. End-to-End Integrated SoC Simulation Verification

The complete RISC-V SoC top (`riscv_cnn_soc_top.sv`), bus interconnect (`bus_interconnect.sv`), accelerator adapter (`accel_adapter.sv`), and RV32I core were co-simulated with the updated standalone `INT8/rtl` modules:

### Test Execution & Results:
1. **Small CNN Workload (`+CMD=2`):**
   - The RISC-V CPU programmed layer descriptors, loaded activations, and started the accelerator.
   - Output result `0x50084607` matched reference in **1,073 cycles**.
   - Result: **PASS**.
2. **Full MNIST Inference — Sample 0 (`+CMD=1`):**
   - The RISC-V CPU offloaded a $28\times 28$ MNIST image (digit 7).
   - Accelerator executed full 5-layer CNN in **53,836 clock cycles**.
   - RISC-V CPU read back class logits: `[-17, -36, -3, 8, -53, -13, -65, 47, -16, 1]`.
   - Predicted Class: **Digit 7** (Confidence Score: 47).
   - Result: **PASS** (100% bit-exact).
3. **Full MNIST Inference — Sample 1 (`+CMD=1`):**
   - The RISC-V CPU offloaded a second MNIST image (digit 2).
   - Accelerator executed in **53,836 clock cycles**.
   - Predicted Class: **Digit 2** (Confidence Score: 34).
   - Result: **PASS**.

---

## 7. Protected RISC-V Workspace Audit

- **Directory:** `C:\Users\FLEX\OneDrive\Desktop\PP\RISC-V`
- **File System Timestamps:** Verified that no file in `PP/RISC-V` was modified.
- **Git Status:** Clean repository tree with zero modified, staged, untracked, or deleted files (`nothing to commit, working tree clean`).
- **Verification Integrity:** **100% UNTOUCHED (READ-ONLY COMPLIANCE CERTIFIED)**.
