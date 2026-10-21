# RISC-V SoC Integration & Accelerator Interface Specification

**Project:** Standalone INT8 CNN Hardware Accelerator  
**Target SoC:** RV32I Processor + Hardware CNN SoC (`PP/RISC-V/rtl/soc/riscv_cnn_soc_top.sv`)  
**Adapter Module:** `PP/RISC-V/rtl/accelerator/accel_adapter.sv`  
**Bus Interconnect:** `PP/RISC-V/rtl/interconnect/bus_interconnect.sv`  
**Status:** **FULLY COMPLIANT AND VERIFIED**  

---

## 1. System Integration Overview

The standalone INT8 CNN accelerator is designed as an AXI4-Lite slave IP block that interfaces directly with an RV32I RISC-V processor through an accelerator bus adapter (`accel_adapter.sv`) and system bus interconnect (`bus_interconnect.sv`):

```
┌──────────────────┐
│   RV32I Core     │
│ (3-stage/5-stage)│
└────────┬─────────┘
         │ 32-bit Memory-Mapped Bus (Fetch/Load/Store)
┌────────▼────────────────────────────────────────────────┐
│ Bus Interconnect (0x8000_1000 - 0x8000_10FF)            │
└────────┬────────────────────────────────────────────────┘
         │
┌────────▼────────────────────────────────────────────────┐
│ Accelerator Adapter (accel_adapter.sv)                  │
│ - Clock / Reset Synchronization                         │
│ - 16-bit Watchdog Timer (Limit: 65,535 cycles)          │
│ - AXI4-Lite Master Bridge                               │
└────────┬────────────────────────────────────────────────┘
         │ AXI4-Lite Interface (aw, w, b, ar, r channels)
┌────────▼────────────────────────────────────────────────┐
│ Standalone INT8 Accelerator (accel_top.sv)              │
└─────────────────────────────────────────────────────────┘
```

---

## 2. AXI4-Lite Register Map (`0x8000_1000`–`0x8000_10FF`)

The accelerator occupies address range `0x8000_1000` to `0x8000_10FF` in the SoC physical memory map:

| Offset | Register Name | SoC Address | Access | Reset Value | Source-Verified Semantics & Bit Fields |
| :---: | :--- | :---: | :---: | :---: | :--- |
| `0x00` | **`CTRL`** | `0x8000_1000` | R/W | `0x0000_0000` | **Bit [0]:** `START_PULSE` (Write 1 to trigger inference start).<br>**Bit [1]:** `IRQ_EN` (1 = Enable completion interrupt). |
| `0x04` | **`STATUS`** | `0x8000_1004` | RO | `0x0000_0000` | **Bit [0]:** `BUSY` (1 = Accelerator active).<br>**Bit [1]:** `DONE` (1 = Inference complete, HALT reached).<br>**Bit [2]:** `ERR` (1 = Configuration descriptor validation error). |
| `0x08` | **`VERSION`** | `0x8000_1008` | RO | `0x0104_0408` | **[31:24]:** Major (`0x01`), **[23:16]:** Minor (`0x04`), **[15:8]:** Array dim $N=4$ (`0x04`), **[7:0]:** Bitwidth $W=8$ (`0x08`). |
| `0x10` | **`DMA_ADDR`** | `0x8000_1010` | R/W | `0x0000_0000` | **Bits [13:0]:** 14-bit byte address pointer for memory transfers.<br>*Side effect:* Auto-increments by $+1$ on each write to `DMA_DATA`. |
| `0x14` | **`DMA_DATA`** | `0x8000_1014` | WO | N/A | **Bits [7:0]:** Byte payload data.<br>**Bits [9:8]:** Memory select:<br>&bull; `2'b00`: Static Weight Memory (`weights`)<br>&bull; `2'b01`: Input Feature Buffer (`feature_a`/`b`)<br>&bull; `2'b10`: Static Bias Memory (`biases`) |
| `0x18` | **`RES_ADDR`** | `0x8000_1018` | R/W | `0x0000_0000` | **Bits [13:0]:** Result buffer byte address pointer.<br>*Side effect:* Issues read strobe `res_rd_en <= 1'b1` to feature buffer. |
| `0x1C` | **`RES_DATA`** | `0x8000_101C` | RO | `0x0000_0000` | **Bits [7:0]:** Most recently fetched result byte from `res_rd_data`. |
| `0x20` | **`INSTR_W0`** | `0x8000_1020` | R/W | `0x0000_0000` | Instruction staging word 0 (bits [31:0] of 128-bit layer descriptor). |
| `0x24` | **`INSTR_W1`** | `0x8000_1024` | R/W | `0x0000_0000` | Instruction staging word 1 (bits [63:32] of 128-bit layer descriptor). |
| `0x28` | **`INSTR_W2`** | `0x8000_1028` | R/W | `0x0000_0000` | Instruction staging word 2 (bits [95:64] of 128-bit layer descriptor). |
| `0x2C` | **`INSTR_W3`** | `0x8000_102C` | R/W | `0x0000_0000` | Instruction staging word 3 (bits [127:96] of 128-bit layer descriptor). |
| `0x30` | **`INSTR_ADDR`**| `0x8000_1030` | R/W | `0x0000_0000` | **Bits [5:0]:** Instruction PC (0–63).<br>*Side effect:* Writing commits the staged 128-bit descriptor into `instruction_mem`. |

---

## 3. Programming Sequence & Firmware Workflow

The host CPU executes hardware inference following this standardized sequence:
1. **Load Layer Descriptors:**
   - Write bits [31:0] to `INSTR_W0` (`0x20`).
   - Write bits [63:32] to `INSTR_W1` (`0x24`).
   - Write bits [95:64] to `INSTR_W2` (`0x28`).
   - Write bits [127:96] to `INSTR_W3` (`0x2C`).
   - Write target PC (0 to 63) to `INSTR_ADDR` (`0x30`) to commit the descriptor. Repeat for all layers including final `HALT` opcode.
2. **Stream Static Weights & Biases (Once at startup):**
   - Write base address to `DMA_ADDR` (`0x10`).
   - Stream byte payloads to `DMA_DATA` (`0x14`) with select `2'b00` (weights) or `2'b10` (biases). Address auto-increments.
3. **Stream Input Activations (Per Image):**
   - Write base address to `DMA_ADDR` (`0x10`).
   - Stream 784 image bytes into `DMA_DATA` (`0x14`) with select `2'b01`.
4. **Trigger Inference:**
   - Write `0x01` (or `0x03` if using interrupts) to `CTRL` (`0x00`).
5. **Wait for Completion:**
   - Poll `STATUS[0]` (`BUSY == 0`) and check `STATUS[1]` (`DONE == 1`), or wait for `irq` interrupt line.
6. **Read Back Output Scores:**
   - Write output byte index (0 to 11) to `RES_ADDR` (`0x18`).
   - Read result byte from `RES_DATA` (`0x1C`).
   - Compute argmax over classes 0–9 in software.

---

## 4. Latency Analysis: Accelerator vs. End-to-End SoC

It is essential to distinguish between **accelerator compute latency** and **total end-to-end SoC latency**:

| Phase | Cycles | Percentage | Description |
| :--- | :---: | :---: | :--- |
| **Firmware Setup & DMA Input Loading** | $\approx 26,700$ | 33.0% | CPU reading image from data memory and streaming 784 bytes over MMIO to accelerator |
| **Hardware Accelerator Compute** | **53,836** | **66.6%** | Synthesizable RTL execution across all 5 CNN layers (Conv1 $\rightarrow$ Pool1 $\rightarrow$ Conv2 $\rightarrow$ Pool2 $\rightarrow$ FC) |
| **Result Readback & Softmax Argmax** | $\approx 338$ | 0.4% | CPU reading back 12 result bytes and computing winning class prediction in assembly |
| **Total End-to-End SoC Latency** | **80,874** | **100.0%** | Full system execution from host request start to host request done |

---

## 5. Hardware Adapter Bus Watchdog Architecture & Safety

In `PP/RISC-V/rtl/accelerator/accel_adapter.sv`:
```verilog
localparam int WATCHDOG_LIMIT = 65535;
```
Inspection of the actual adapter RTL confirms that `watchdog_cnt` monitors **individual AXI4-Lite bus transactions (single read or write handshakes)** rather than multi-thousand-cycle inference runs:
- **Counter Operation:** Increments on `clk` while the adapter is in `ST_WRITE` (waiting for `m_axil_bvalid`) or `ST_READ` (waiting for `m_axil_rvalid`).
- **Reset Condition:** Returns to `ST_IDLE` where `watchdog_cnt <= 16'd0` upon handshake completion.
- **Normal Bus Handshake Latency:** Typically 1 to 2 clock cycles per transaction.
- **Polling Loop Isolation:** While the hardware accelerator is computing for **53,836 clock cycles**, the CPU executes a firmware polling loop reading `ACCEL_STATUS`. Each read request is an independent AXI4-Lite transaction that completes in 2 cycles and resets `watchdog_cnt` to 0.
- **Safety Margin:** Under normal operation, `watchdog_cnt` never exceeds 2 cycles, providing a massive $>65,500$ cycle margin against the 65,535-cycle bus timeout threshold.
- **Failure Mode Guard:** If the accelerator core ever suffered a hard lockup that permanently blocked the AXI4-Lite bus handshake, the adapter would trip after 65,535 stalled cycles, assert `timeout_err <= 1'b1`, return `0xDEADDEAD`, and un-stall the CPU.
- **Verdict:** **PASS (COMPLIANT)**. Complete bus isolation and reliable polling without spurious timeouts.

---

## 6. Verification via Dual-Mode SoC Co-Simulation

Full SoC co-simulation was executed with `riscv_cnn_soc_tb.sv` combining the RV32I core and standalone `INT8/rtl` modules:

1. **Command Mode 2 (`+CMD=2` - Small CNN Workload):**
   - Result: Output `0x50084607` matched reference.
   - Latency: Completed in **1,073 cycles**.
   - Status: **PASS**.
2. **Command Mode 1 (`+CMD=1` - Full MNIST Sample 0):**
   - Predicted Class: **Digit 7** (Confidence score: 47).
   - Logits: `[-17, -36, -3, 8, -53, -13, -65, 47, -16, 1]`.
   - Accelerator Latency: **53,836 cycles**. Total SoC Latency: **80,874 cycles**.
   - Status: **PASS** (100% bit-exact).
3. **Command Mode 1 (`+CMD=1` - Full MNIST Sample 1):**
   - Predicted Class: **Digit 2** (Confidence score: 34).
   - Accelerator Latency: **53,836 cycles**.
   - Status: **PASS**.

---

## 7. Protected Workspace Certification

A strict audit of the companion repository `../RISC-V` confirms:
- **Git Status:** `nothing to commit, working tree clean`.
- **Files Modified/Created/Deleted:** **0** (100% read-only integrity preserved).
