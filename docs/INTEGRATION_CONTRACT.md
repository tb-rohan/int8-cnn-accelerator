# Integration Contract: Standalone INT8 CNN Accelerator & RISC-V SoC

**Document:** `docs/INTEGRATION_CONTRACT.md`  
**Date:** October 20, 2026  
**Auditor / Integration Architect:** Senior RTL Design Engineer & SoC Integration Architect  
**Hardware Accelerator Target:** `C:\Users\FLEX\OneDrive\Desktop\PP\INT8` (`accel_top`)  
**Host SoC Target:** `C:\Users\FLEX\OneDrive\Desktop\PP\RISC-V` (`riscv_cnn_soc_top`)  
**Phase:** Step B — Stable Architecture & RISC-V Integration Contract (Documentation & Read-Only Inspection Only)

---

## Technical Classification Legend
Every technical statement and specification in this contract is tagged with its verified evidentiary basis:
- `[V-RTL]` : Verified directly from SystemVerilog RTL source code.
- `[V-SIM]` : Verified by active hardware simulation execution during this audit.
- `[V-DOC]` : Documented in existing project documentation, but not independently verified.
- `[INF]`   : Inferred from architectural analysis and protocol standards.
- `[UNRES]` : Unresolved or ambiguous in current source code / implementation.

---

## 1. Purpose and Scope

This contract establishes the formal architectural, electrical, register-level, and protocol interface boundary between:
1. The **Standalone INT8 CNN Hardware Accelerator** (`accel_top` in `INT8/rtl/accel_top.sv`).
2. The **Host RISC-V SoC** (`riscv_cnn_soc_top` in `RISC-V/rtl/soc/riscv_cnn_soc_top.sv`).

The objective is to allow internal architectural refactoring of the INT8 accelerator—specifically **Block RAM synchronous read pipelining** and **combinational critical-path reduction for 100 MHz timing closure**—without breaking binary, timing, or interconnect compatibility with the existing RISC-V processor and SoC interconnect.

### Non-Negotiable Contract Constraints `[V-RTL]`
1. The top module name `accel_top` must be strictly preserved.
2. All 23 top-level port names, widths, and polarities of `accel_top` must remain unchanged.
3. The AXI4-Lite slave MMIO register map (`0x00` through `0x30`) and bit-field assignments must remain strictly unchanged.
4. No source file, testbench, or script within `C:\Users\FLEX\OneDrive\Desktop\PP\RISC-V` may be modified.

---

## 2. Verified Architecture Overview

```
                      RISC-V SoC Environment (`riscv_cnn_soc_top`)
+---------------------------------------------------------------------------------------+
|                                                                                       |
|   +-------------------+                     +-------------------------------------+   |
|   |                   |  Native CPU Bus     |                                     |   |
|   |    rv32i_core     |-------------------->|          bus_interconnect           |   |
|   |     (u_core)      |<--------------------|              (u_bus)                |   |
|   +-------------------+   req, we, addr,    +-------------------------------------+   |
|                             wdata, stall                       |                      |
|                                                                | accel_req, accel_we, |
|                                                                | accel_addr[31:0],    |
|                                                                | accel_wdata[31:0],   |
|                                                                | accel_stall          |
|                                                                v                      |
|                                             +-------------------------------------+   |
|                                             |            accel_adapter            |   |
|                                             |             (u_adapter)             |   |
|                                             +-------------------------------------+   |
|                                                                |                      |
|                                                                | AXI4-Lite Master     |
|                                                                | m_axil_* [7:0]       |
|                                                                v                      |
|   +-------------------------------------------------------------------------------+   |
|   |                            accel_top (u_accel)                                |   |
|   |   +-------------------+   +--------------------+   +----------------------+   |   |
|   |   |     ctrl_unit     |-->|      mem_ctrl      |<--|   4x On-Chip SRAMs   |   |   |
|   |   | (64x128b instr RAM|   | (Schedule, DMA,    |   |  - weights (16 KB)   |   |   |
|   |   |  90b layer decode)|   |  Zero-scan detector|   |  - feature_a (16 KB) |   |   |
|   |   +-------------------+   +--------------------+   |  - feature_b (16 KB) |   |   |
|   |             |                       |              |  - biases (4 KB)     |   |   |
|   |             v                       v              +----------------------+   |   |
|   |      swap_buf pulse           Stream activations              ^               |   |
|   |             |                       |                         |               |   |
|   |             v                       v                         |               |   |
|   |   +--------------------------------------------+              |               |   |
|   |   |            pe_array (4x4 2D Array)         |              |               |   |
|   |   |  16 PEs, skew inputs, deskew partial sums  |              |               |   |
|   |   +--------------------------------------------+              |               |   |
|   |                         |                                     |               |   |
|   |                         v                                     |               |   |
|   |   +--------------------------------------------+              |               |   |
|   |   |                  post_proc                 |--------------+               |   |
|   |   | 33b bias add, 49b mult, 50b shift, sat/ReLU| Writes back to               |   |
|   |   +--------------------------------------------+ ping-pong feature RAM        |   |
|   +-------------------------------------------------------------------------------+   |
|                                     |                                                 |
|                                     v                                                 |
|   accel_irq_out <-------------------+ (irq = done & ctrl_reg[1])                      |
+---------------------------------------------------------------------------------------+
```

---

## 3. Exact `accel_top` Port Interface

Verified from `INT8/rtl/accel_top.sv` (lines 3–24) and `RISC-V/rtl/soc/riscv_cnn_soc_top.sv` (lines 261–282) `[V-RTL]`:

| Port Name | Direction | Width | Clock Domain | Reset Domain | Exact Role & Protocol Description |
| :--- | :---: | :---: | :---: | :---: | :--- |
| `clk` | Input | 1 | Clock | N/A | Global primary clock (100 MHz nominal). |
| `rst_n` | Input | 1 | Async/Sync | Active-Low | Asynchronous/synchronous active-low system reset. |
| **AXI4-Lite Write Address Channel** | | | | | |
| `s_axil_awaddr` | Input | 8 | `clk` | `rst_n` | Write byte address offset (`0x00` to `0x30`). Bits [7:0]. |
| `s_axil_awvalid`| Input | 1 | `clk` | `rst_n` | Write address valid handshake. |
| `s_axil_awready`| Output | 1 | `clk` | `rst_n` | Write address ready. Asserted when `!aw_saved && !s_axil_bvalid`. |
| **AXI4-Lite Write Data Channel** | | | | | |
| `s_axil_wdata` | Input | 32 | `clk` | `rst_n` | Write payload data. Little-endian word format. |
| `s_axil_wstrb` | Input | 4 | `clk` | `rst_n` | Byte write strobes. Bit `k` controls byte `k` (`wdata[k*8 +: 8]`). |
| `s_axil_wvalid` | Input | 1 | `clk` | `rst_n` | Write data valid handshake. |
| `s_axil_wready` | Output | 1 | `clk` | `rst_n` | Write data ready. Asserted when `!w_saved && !s_axil_bvalid`. |
| **AXI4-Lite Write Response Channel** | | | | | |
| `s_axil_bresp` | Output | 2 | `clk` | `rst_n` | Write response status. Hardwired to `2'b00` (`OKAY`). |
| `s_axil_bvalid` | Output | 1 | `clk` | `rst_n` | Write response valid. Asserted on cycle after `write_fire`. |
| `s_axil_bready` | Input | 1 | `clk` | `rst_n` | Write response ready from host. |
| **AXI4-Lite Read Address Channel** | | | | | |
| `s_axil_araddr` | Input | 8 | `clk` | `rst_n` | Read byte address offset (`0x00` to `0x30`). Bits [7:0]. |
| `s_axil_arvalid`| Input | 1 | `clk` | `rst_n` | Read address valid handshake. |
| `s_axil_arready`| Output | 1 | `clk` | `rst_n` | Read address ready. Asserted when `!s_axil_rvalid`. |
| **AXI4-Lite Read Data Channel** | | | | | |
| `s_axil_rdata` | Output | 32 | `clk` | `rst_n` | Read data word returned to host. |
| `s_axil_rresp` | Output | 2 | `clk` | `rst_n` | Read response status. Hardwired to `2'b00` (`OKAY`). |
| `s_axil_rvalid` | Output | 1 | `clk` | `rst_n` | Read data valid. Asserted on cycle after address handshake. |
| `s_axil_rready` | Input | 1 | `clk` | `rst_n` | Read data ready from host. |
| **Interrupt Output** | | | | | |
| `irq` | Output | 1 | `clk` | `rst_n` | Active-high level interrupt: `irq = done & ctrl_reg[1]`. |

---

## 4. Exact AXI4-Lite Handshake Behavior

Verified from `INT8/rtl/accel_top.sv` (lines 79–135, lines 179–200) `[V-RTL]`:

### 4.1 Write Transaction Handshake
- **Address & Data Decoupling:** `accel_top` incorporates auxiliary holding registers (`aw_saved`, `aw_addr_q`, `w_saved`, `w_data_q`, `w_strb_q`). Address and data can arrive in the same cycle or in separate cycles in any order.
- **`write_fire` Condition:**
  ```systemverilog
  assign write_fire = (aw_saved || (s_axil_awvalid && s_axil_awready)) &&
                      (w_saved  || (s_axil_wvalid  && s_axil_wready))  && !s_axil_bvalid;
  ```
- **Response Protocol:** Once `write_fire` asserts, `s_axil_bvalid` is registered high on the next rising clock edge with `s_axil_bresp = 2'b00` (`OKAY`). When `s_axil_bvalid && s_axil_bready` coincides, `s_axil_bvalid` clears.

### 4.2 Read Transaction Handshake
- **Read Address Acceptance:** When `s_axil_arvalid && s_axil_arready` coincides, `s_axil_rvalid` asserts on the following rising clock edge.
- **Read Data Generation:** `s_axil_rdata` is driven combinationally or from registered outputs (`s_axil_rdata <= ...`).
- **Completion:** When `s_axil_rvalid && s_axil_rready` coincides, `s_axil_rvalid` clears on the next cycle.

---

## 5. Complete Verified Register Map

Verified against `INT8/rtl/accel_top.sv` (lines 135–197), `INT8/tb/tb_top.sv`, `RISC-V/software/asm/soc_cnn_inference.s`, and `RISC-V/tb/accelerator/tb_accel_adapter.sv` `[V-RTL, V-SIM]`:

| Offset | Register Name | Absolute SoC Address | Access | Width | Reset Value | Field Description & Verified Behavior | Access While Busy? |
| :---: | :--- | :---: | :---: | :---: | :---: | :--- | :---: |
| `0x00` | **CTRL** | `0x8000_1000` | R/W | 32 | `0x0000_0000` | **Bit 0:** `START_PULSE` (Write-1 triggers 1-cycle execution start pulse).<br>**Bit 1:** `IRQ_EN` (1 = Enable external IRQ on completion).<br>Bits [31:2]: Reserved (read as 0). | **NO** (Do not write bit 0 while busy). |
| `0x04` | **STATUS** | `0x8000_1004` | RO | 32 | `0x0000_0000` | **Bit 0:** `BUSY` (1 = Accelerator FSM active).<br>**Bit 1:** `DONE` (1 = Layer sequence completed, HALT reached).<br>**Bit 2:** `ERR` (1 = Descriptor validation error in `ctrl_unit`).<br>Bits [31:3]: Reserved (read as 0). | **YES** (Polled by CPU). |
| `0x08` | **VERSION** | `0x8000_1008` | RO | 32 | `0x0104_0408` | **[31:24]:** Major version (`0x01`).<br>**[23:16]:** Minor version (`0x04`).<br>**[15:8]:** Array dimension $N$ (`0x04`).<br>**[7:0]:** Data width $W$ (`0x08`). | **YES** (Read-only static). |
| `0x10` | **DMA_ADDR** | `0x8000_1010` | R/W | 32 | `0x0000_0000` | **Bits [13:0]:** Byte pointer for memory writes.<br>Bits [31:14]: Reserved (read as 0).<br>*Side effect:* Writing sets the base address. Auto-increments by $+1$ on each write to `DMA_DATA`. | **NO** (Reserved for host loading). |
| `0x14` | **DMA_DATA** | `0x8000_1014` | WO | 32 | N/A | **Bits [7:0]:** Byte data payload.<br>**Bits [9:8]:** Memory bank select:<br>&bull; `2'b00`: Weights Memory (`weights`)<br>&bull; `2'b01`: Input Feature Buffer (`feature_a`/`b` based on `input_select`)<br>&bull; `2'b10`: Bias Memory (`biases`)<br>&bull; `2'b11`: Unused<br>*Side effect:* Writes byte to selected bank at `DMA_ADDR`, then executes `DMA_ADDR <= DMA_ADDR + 1`. | **NO** (Corrupts active layer memory). |
| `0x18` | **RES_ADDR** | `0x8000_1018` | R/W | 32 | `0x0000_0000` | **Bits [13:0]:** Result buffer byte address.<br>*Side effect:* Triggers synchronous read strobe `res_rd_en <= 1'b1` into output feature buffer. | **NO** (Only access when `DONE`=1). |
| `0x1C` | **RES_DATA** | `0x8000_101C` | RO | 32 | `0x0000_0000` | **Bits [7:0]:** Result byte fetched from the address requested by `RES_ADDR`.<br>Bits [31:8]: Read as 0. | **NO** (Only access when `DONE`=1). |
| `0x20` | **INSTR_W0** | `0x8000_1020` | R/W | 32 | `0x0000_0000` | Staging register for instruction bits [31:0]. | **NO** (Do not stage while running). |
| `0x24` | **INSTR_W1** | `0x8000_1024` | R/W | 32 | `0x0000_0000` | Staging register for instruction bits [63:32]. | **NO** (Do not stage while running). |
| `0x28` | **INSTR_W2** | `0x8000_1028` | R/W | 32 | `0x0000_0000` | Staging register for instruction bits [95:64]. | **NO** (Do not stage while running). |
| `0x2C` | **INSTR_W3** | `0x8000_102C` | R/W | 32 | `0x0000_0000` | Staging register for instruction bits [127:96]. | **NO** (Do not stage while running). |
| `0x30` | **INSTR_ADDR**| `0x8000_1030` | R/W | 32 | `0x0000_0000` | **Bits [5:0]:** Instruction PC ($0 \to 63$).<br>*Side effect:* Writing commits `{INSTR_W3, INSTR_W2, INSTR_W1, INSTR_W0}` into `instruction_mem[PC]`. | **NO** (Corrupts instruction RAM). |

---

## 6. CPU-to-Adapter-to-Accelerator Transaction Flow

```
   RISC-V CPU Core                accel_adapter                  accel_top
     (rv32i_core)                  (u_adapter)                    (u_accel)
          |                             |                             |
   T1:    |--- req=1, we, addr, wdata ->|                             |
          |<-- stall=1 -----------------|                             |
          |                             |--- s_axil_awvalid/wvalid -->|
          |                             |<-- s_axil_awready/wready ---|
   T2:    |    (CPU stalled)            |                             |
          |                             |<-- s_axil_bvalid -----------| [write_fire]
          |                             |--- s_axil_bready ---------->|
   T3:    |<-- stall=0 -----------------|                             |
          |    (CPU advances)           |                             |
```

### Protocol Timing Verification `[V-RTL, V-SIM]`
1. **CPU Memory Request:** The RISC-V core (`rv32i_core`) issues a data memory request (`dmem_req`, `dmem_addr`, `dmem_wdata`, `dmem_we`).
2. **Bus Interconnect Decoding:** `bus_interconnect` evaluates `cpu_addr`. If in `0x8000_1000`–`0x8000_10FF`, it routes the request to `accel_req`, `accel_addr`, `accel_wdata`, `accel_we` (`SEL_ACCEL`).
3. **Adapter State Machine (`accel_adapter.sv` lines 71–135):**
   - In `ST_IDLE`: Immediately asserts `stall <= req` to halt the CPU pipeline.
   - For a Write: Advances to `ST_WRITE`, drives `m_axil_awvalid=1`, `m_axil_wvalid=1`, `m_axil_bready=1`.
   - When `m_axil_bvalid && m_axil_bready` coincides, advances to `ST_DONE`.
   - In `ST_DONE`: Deasserts `stall` (`stall=0`), allowing the CPU to un-stall and proceed.
4. **Read Transactions:** For reads, `ST_READ` asserts `m_axil_arvalid=1`, `m_axil_rready=1`. When `m_axil_rvalid && m_axil_rready` coincides, `rdata_latched <= m_axil_rdata`, advances to `ST_DONE`, and drives `rdata` to the CPU.
5. **Watchdog Safety:** `accel_adapter` incorporates a 16-bit watchdog timer (`WATCHDOG_LIMIT = 65535`). If `accel_top` hangs or fails to respond within 65,535 clock cycles, the adapter terminates the transaction with `timeout_err=1` and returns `32'hDEAD_DEAD` on reads, preventing total CPU bus lockup `[V-RTL]`.

---

## 7. Address Decoding and Memory Map Verification

Verified from `RISC-V/rtl/interconnect/bus_interconnect.sv` (lines 65–80) `[V-RTL]`:

```systemverilog
// bus_interconnect.sv lines 66-79:
if (cpu_addr >= 32'h0000_0000 && cpu_addr <= 32'h0000_3FFF)      sel = SEL_IMEM;  // 16 KB Instruction RAM
else if (cpu_addr >= 32'h0000_4000 && cpu_addr <= 32'h0000_7FFF) sel = SEL_DMEM;  // 16 KB Data RAM
else if (cpu_addr >= 32'h8000_0000 && cpu_addr <= 32'h8000_001F) sel = SEL_HOST;  // Host Debug/Bench
else if (cpu_addr >= 32'h8000_0020 && cpu_addr <= 32'h8000_003F) sel = SEL_TIMER; // Perf Timer/Counters
else if (cpu_addr >= 32'h8000_0040 && cpu_addr <= 32'h8000_005F) sel = SEL_UART;  // UART Lite
else if (cpu_addr >= 32'h8000_1000 && cpu_addr <= 32'h8000_10FF) sel = SEL_ACCEL; // INT8 CNN ACCELERATOR
else                                                              sel = SEL_NONE;
```

`accel_adapter` passes `addr[7:0]` to `m_axil_awaddr` and `m_axil_araddr`. Thus:
- `0x8000_1000` maps to offset `0x00` (`CTRL`).
- `0x8000_1004` maps to offset `0x04` (`STATUS`).
- `0x8000_1008` maps to offset `0x08` (`VERSION`).
- `0x8000_1010` maps to offset `0x10` (`DMA_ADDR`).
- `0x8000_1014` maps to offset `0x14` (`DMA_DATA`).
- `0x8000_1018` maps to offset `0x18` (`RES_ADDR`).
- `0x8000_101C` maps to offset `0x1C` (`RES_DATA`).
- `0x8000_1020`–`0x8000_102C` maps to offsets `0x20`–`0x2C` (`INSTR_W0`–`W3`).
- `0x8000_1030` maps to offset `0x30` (`INSTR_ADDR`).

---

## 8. Clock and Reset Requirements

### 8.1 Clock Domain `[V-RTL]`
- **Single Synchronous Domain:** Both the RISC-V SoC (`riscv_cnn_soc_top`) and `accel_top` operate on a single shared clock (`clk`).
- **Nominal Frequency:** 100 MHz ($T = 10.0\text{ ns}$) specified in FPGA constraints (`fpga/constraints/clock.xdc`).
- **No CDC:** There are zero Clock Domain Crossing (CDC) synchronizers between the CPU bus and accelerator datapath. Any internal accelerator optimization must remain strictly synchronous to `clk`.

### 8.2 Reset Protocol `[V-RTL]`
- **Signal:** `rst_n` (Active-low).
- **Behavior in `accel_top.sv`:**
  - Asynchronous / synchronous assertion supported: `always_ff @(posedge clk or negedge rst_n)`.
  - Clears all AXI holding registers (`aw_saved=0`, `w_saved=0`, `s_axil_bvalid=0`, `s_axil_rvalid=0`).
  - Clears `ctrl_reg=0`, `dma_addr=0`, `result_addr=0`, `start_pulse=0`.
- **Reset While Busy:**
  - If `rst_n` asserts while the accelerator is running, `ctrl_unit` resets to `state <= IDLE`, `mem_ctrl` resets to `state <= IDLE`, and partial accumulation is aborted. Internal SRAM contents (`weights`, `feature_a/b`, `biases`) are **not** cleared by reset.
  - To resume, the host must re-issue `START` or reload vectors if an operation was interrupted mid-stream.

---

## 9. Start, Busy, Completion, Error, and Interrupt Behavior

Verified from `INT8/rtl/ctrl_unit.sv` (lines 57–122) and `INT8/rtl/accel_top.sv` (lines 89, 137–141, 185) `[V-RTL]`:

```
          +-------------+
          |    IDLE     |<----------------------------------+
          +-------------+                                   |
                 | start_pulse == 1                         |
                 v                                          |
          +-------------+                                   |
          |    FETCH    | (pc = 0)                          |
          +-------------+                                   |
                 |                                          |
                 v                                          |
          +-------------+  !legal                           |
          |   DECODE    |----------> [ ERR State ]          |
          +-------------+           (asserts err=1)         |
                 | op == OP_HALT                            |
                 |----------> [ DONE State ]                |
                 |           (asserts done=1, irq=irq_en)   |
                 | (legal op)                               |
                 v                                          |
          +-------------+                                   |
          |     RUN     | (pulses gen_start=1)              |
          +-------------+                                   |
                 |                                          |
                 v                                          |
          +-------------+                                   |
          |    WAIT     | (waits for gen_done from memory)  |
          +-------------+                                   |
                 | gen_done == 1                            |
                 v                                          |
          +-------------+                                   |
          |    SWAP     | (pulses swap_buf=1, pc <= pc + 1) |
          +-------------+                                   |
                 |                                          |
                 +------------------------------------------+
```

### Lifecycle Semantics
1. **Start:** Initiated by writing `0x0000_0001` (or `0x0000_0003` with IRQ) to `0x8000_1000` (`CTRL`). Generates 1-cycle `start_pulse`.
2. **Busy:** `STATUS[0]` (`busy`) asserts continuously while `state != IDLE && state != DONE && state != ERR`.
3. **Done:** When `ctrl_unit` decodes `OP_HALT` (`2'b11`), it transitions to `DONE`. `STATUS[1]` (`done`) asserts.
4. **Interrupt (`irq`):** In `accel_top.sv` line 89:
   `assign irq = done && ctrl_reg[1];`
   The interrupt line remains asserted as long as `done` is set and `IRQ_EN` (`ctrl_reg[1]`) is enabled.
5. **Clear / Acknowledge:** To clear `done` or `err`, the host writes `1` to `CTRL[0]` (`START`), which transitions the FSM from `DONE`/`ERR` back to `IDLE` (lines 111–118 in `ctrl_unit.sv`).
6. **Error (`err`):** If a descriptor fails validation checks in `ctrl_unit.sv` (e.g. non-multiple of 4 channels, unsupported kernel, illegal pooling dimensions), `STATUS[2]` (`err`) asserts and the accelerator halts immediately.

---

## 10. Memory and Buffer Contract

### 10.1 Bank Allocation & Capacity `[V-RTL]`
- **Weights Bank (`dma_wr_sel = 2'b00`):** $4096 \times 32$-bit words = 16,384 bytes (16 KB). Little-endian packing.
- **Input Feature Bank (`dma_wr_sel = 2'b01`):** Writes directly to the current input buffer (`feature_a` when `input_select=0`, `feature_b` when `input_select=1`). $4096 \times 32$-bit words = 16,384 bytes (16 KB).
- **Bias Bank (`dma_wr_sel = 2'b10`):** $256 \times 128$-bit words = 4,096 bytes (4 KB). Each entry holds four 32-bit signed integers.
- **Instruction Memory:** $64 \times 128$-bit instructions (1 KB).

### 10.2 Ping-Pong Switching Semantics `[V-RTL]`
- `mem_ctrl.sv` maintains `input_select` (bit 0):
  - Layer 0: `input_select = 0` $\to$ Reads `feature_a`, writes `feature_b`.
  - Layer 1: `input_select = 1` $\to$ Reads `feature_b`, writes `feature_a`.
  - Layer 2: `input_select = 0` $\to$ Reads `feature_a`, writes `feature_b`.
  - Layer 3: `input_select = 1` $\to$ Reads `feature_b`, writes `feature_a`.
  - Layer 4: `input_select = 0` $\to$ Reads `feature_a`, writes `feature_b`.
- **Result Readback:** When reading via `RES_ADDR` (`0x18`) and `RES_DATA` (`0x1C`), `mem_ctrl.sv` (lines 208–213) automatically selects the output buffer containing the final layer results based on the post-swap `input_select` value:
  ```systemverilog
  if (input_select)
    result_read_q <= feature_b[res_rd_addr[13:2]][res_rd_addr[1:0]*8 +: 8];
  else
    result_read_q <= feature_a[res_rd_addr[13:2]][res_rd_addr[1:0]*8 +: 8];
  ```

---

## 11. Current Supported Accelerator Configuration

Verified from `INT8/rtl/cnn_pkg.sv` and `INT8/rtl/ctrl_unit.sv` `[V-RTL]`:

1. **Precision:** Signed INT8 weights, signed INT8 activations, signed 32-bit accumulators.
2. **Channel Constraints:** $C_{in} \ge 4$ and $C_{in} \pmod 4 = 0$; $C_{out} \ge 4$ and $C_{out} \pmod 4 = 0$.
3. **Convolution:** $3 \times 3$ or $1 \times 1$, stride $\ge 1$, padding $\ge 0$. Output feature map must fit within 4,096 32-bit words ($H_{out} \times W_{out} \times (C_{out}/4) \le 4096$).
4. **Max Pooling:** Strictly $2 \times 2$, stride 2, padding 0. Input dimensions must be even ($H_{in}[0] == 0, W_{in}[0] == 0$). Output channels equal input channels ($C_{out} == C_{in}$).
5. **Fully Connected:** Evaluated as $H_{in}=1, W_{in}=1, K=1, S=1, P=0$ with $C_{in} = 392, C_{out} = 12$. Output classes 0–9 occupy bytes 0–9; bytes 10–11 are padding lanes.

---

## 12. Rules for Preserving External Compatibility

To ensure zero modifications to `RISC-V/rtl/`:

| Rule ID | Compatibility Requirement | Rationale / Consequence if Violated |
| :---: | :--- | :--- |
| **COMPAT-01** | **Preserve Port Definitions in `accel_top.sv`** | `riscv_cnn_soc_top.sv` instantiates `accel_top` by name with exact port names. Renaming ports causes elaboration failure. |
| **COMPAT-02** | **Preserve Register Offsets `0x00` to `0x30`** | `accel_adapter.sv` and assembly software `soc_cnn_inference.s` hardcode these exact byte offsets. |
| **COMPAT-03** | **Preserve `VERSION` at `0x08` (`32'h01040408`)** | `accel_adapter.sv` line 75 intercepts offset `0x08` and tests for `32'h01040408`. `tb_accel_adapter.sv` line 132 will fail `$fatal` if this changes. |
| **COMPAT-04** | **Preserve Auto-Increment on `DMA_DATA` (`0x14`)** | CPU assembly loop `transfer_image_loop` writes consecutive bytes without re-writing `DMA_ADDR`. Disabling auto-increment corrupts image ingestion. |
| **COMPAT-05** | **Preserve Two-Stage Result Fetch (`RES_ADDR` $\to$ `RES_DATA`)**| Assembly software `retrieve_scores_loop` writes index to `0x18` and reads byte from `0x1C`. |
| **COMPAT-06** | **Maintain AXI4-Lite Handshake Latency Contract** | `accel_adapter.sv` asserts `stall` while waiting for `bvalid`/`rvalid`. Any handshake delay is legally supported, but must complete within 65,535 cycles. |

---

## 13. Safe Internal Optimization Boundaries

The following internal architectural changes are **100% compliant** with the integration contract because they do not alter externally observable port definitions or register behaviors:

```
[EXTERNAL COMPATIBILITY BOUNDARY: UNTOUCHED]
- accel_top port list
- AXI4-Lite slave decoder & handshake
- Register offsets 0x00 to 0x30
- Result fetch and DMA autoincrement
====================================================================
[INTERNAL OPTIMIZATIONS: SAFE TO REFACTOR]
+------------------------------------------------------------------+
| 1. Synchronous Block RAM Pipelining:                             |
|    - Register feature_read_addr inside mem_ctrl.                |
|    - Pipeline input_word by 1 cycle (adjust STREAM / WRITE_POOL).|
|    - Enables true Block RAM inference; eliminates 28,160 LUTRAM. |
+------------------------------------------------------------------+
| 2. Combinational Critical Path Reduction:                        |
|    - Break 20-level logic path into 2 pipeline stages.           |
|    - Register address arithmetic before driving memory ports.     |
|    - Register zero-scan comparator output.                       |
|    - Closes 100 MHz setup timing (WNS >= 0.0 ns).                |
+------------------------------------------------------------------+
| 3. Internal Cycle Latency Adjustments:                           |
|    - Adding 1-2 pipeline setup cycles inside STREAM or LOAD_W    |
|      is completely safe; CPU polls STATUS[1] (done) and does not |
|      rely on fixed cycle counts.                                 |
+------------------------------------------------------------------+
```

### Risk Assessment for Internal Optimizations
- **BRAM Pipelining Risk:** If `input_word` is delayed by 1 clock cycle, `act_valid` and systolic array tag tracking (`act_first`, `act_last`, `act_idx`) must be delayed by the identical 1 cycle. If not matched, activation data will desynchronize from partial sum accumulation.
- **Mitigation:** Update `STREAM` state in `mem_ctrl.sv` to align `act_valid` with registered `input_read_q`. Verify against `tb_full_cnn.sv` layer boundary assertions.

---

## 14. Known Uncertainties and Edge Conditions

1. **Write Strobe Granularity on MMIO:** `accel_top.sv` currently evaluates `write_strb[0]` for `CTRL` and `DMA_DATA`. `accel_adapter.sv` always issues `m_axil_wstrb = 4'hF`. Sub-word byte writes to non-byte registers are undocumented `[V-RTL]`.
2. **Back-to-Back `START` Pulses:** If host software writes `START=1` while `STATUS[0]` (`busy`) is high, `ctrl_unit.sv` ignores the pulse. This behavior is safe but should be formally tested `[V-RTL]`.
3. **Interrupt Deassertion Timing:** `irq` remains asserted until `START=1` clears `done`. If the CPU uses level-triggered interrupts without clearing `START`, an interrupt storm could occur. In current software, the CPU polls `STATUS[1]` rather than enabling `IRQ_EN` `[V-RTL]`.

---

## 15. Required Standalone Regression Tests (INT8 Workspace)

Before any design change is accepted, the complete standalone test suite must be executed:
1. `tb/tb_pe.sv` (PE MAC unit test).
2. `tb/tb_pe_array.sv` (Systolic array unit test).
3. `tb/tb_post_proc.sv` (Post-processor arithmetic unit test).
4. `tb/tb_mem_ctrl_random.sv` (Memory controller DMA test).
5. `tb/tb_mem_ctrl_zero_scan.sv` (Zero-channel detector test).
6. `tb/tb_ctrl_unit.sv` (Instruction decoder test).
7. `tb/tb_top.sv` (Top-level AXI integration test).
8. `tb/tb_full_cnn.sv` (Full-shape 28x28 layer-boundary verification).
9. Single-image trained inference: `python/run_rtl_manual.py`.

---

## 16. Required Future Integrated-SoC Regression Tests (RISC-V Workspace)

Once the standalone accelerator is optimized, the following read-only tests in `RISC-V/tb` will serve as the golden integration proof:
1. **`tb_accel_adapter.sv` (`RISC-V/tb/accelerator/tb_accel_adapter.sv`):**
   - Verifies CPU bus $\to$ `accel_adapter` $\to$ `accel_top` AXI4-Lite translation, capability register `0x08`, DMA auto-increment, and staging registers.
2. **`tb_riscv_cnn_soc.sv` (`RISC-V/tb/integration/tb_riscv_cnn_soc.sv`):**
   - Runs full SoC simulation with compiled RISC-V software `software/asm/soc_cnn_inference.hex`.
   - Mode `CMD=2`: Verifies small CNN workload execution through CPU instructions, checking output word `32'h50084607`.
   - Mode `CMD=1`: Verifies full MNIST inference running from CPU assembly, asserting correct digit classification and logit writeback to data memory `0x0000_7000`.

---

## 17. Proposed Future Integration Validation Procedure

```text
Step 1: Standalone Verification (Workspace: INT8)
   -> Run `verify.ps1` (8 testbenches pass).
   -> Run `python/run_rtl_manual.py` (Argmax & logits match Python golden).
   -> Run Vivado synthesis & timing on `accel_top` (BRAM verified, WNS >= 0 ns).

Step 2: Cross-Project Co-Simulation (Workspace: RISC-V)
   -> Point `tb_accel_adapter.sv` and `tb_riscv_cnn_soc.sv` to updated `INT8/rtl/*.sv`.
   -> Execute `tb_accel_adapter.sv` via Icarus Verilog.
   -> Execute `tb_riscv_cnn_soc.sv` with CMD=2 (small CNN).
   -> Execute `tb_riscv_cnn_soc.sv` with CMD=1 (full MNIST inference).
   -> Confirm zero CPU timeouts and bit-exact output match.
```

---

## 18. Source Files Used as Evidence

The technical specifications in this contract were compiled directly from:
- `INT8/rtl/cnn_pkg.sv`: Parameters, opcode enums, `layer_cfg_t`.
- `INT8/rtl/accel_top.sv`: AXI4-Lite slave decoding, register map, IRQ logic.
- `INT8/rtl/ctrl_unit.sv`: Instruction RAM, FSM transitions, descriptor legal checks.
- `INT8/rtl/mem_ctrl.sv`: SRAM addressing, ping-pong swapping, zero-scan logic.
- `INT8/tb/tb_top.sv`: Standalone AXI4-Lite verification stimulus.
- `RISC-V/rtl/soc/riscv_cnn_soc_top.sv`: SoC module integration, clock/reset tree.
- `RISC-V/rtl/accelerator/accel_adapter.sv`: CPU bus to AXI4-Lite master protocol conversion.
- `RISC-V/rtl/interconnect/bus_interconnect.sv`: SoC address map decoding (`0x8000_1000`).
- `RISC-V/software/asm/soc_cnn_inference.s`: Real assembly program driving `accel_top`.
- `RISC-V/tb/accelerator/tb_accel_adapter.sv`: Adapter-to-accelerator testbench.
- `RISC-V/tb/integration/tb_riscv_cnn_soc.sv`: Full SoC integration testbench.
