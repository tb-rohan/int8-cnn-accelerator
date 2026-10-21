# INT8 Accelerator Baseline Report & Technical Audit (Step A)

**Document:** `docs/INT8_BASELINE.md`  
**Date:** October 20, 2026  
**Auditor / Engineer:** Senior RTL Design Engineer / Computer Architecture & AI Accelerator Engineer  
**Scope:** Standalone INT8 CNN AI Accelerator (`C:\Users\FLEX\OneDrive\Desktop\PP\INT8`) with Future RISC-V Integration Contract (`C:\Users\FLEX\OneDrive\Desktop\PP\RISC-V`)  
**Status:** Step A Baseline Established (Read-Only Dynamic & Static Inspection Completed)

---

## 1. Safety, Toolchain, and Repository Environment

### 1.1 Git Status & Source Safety
- **Workspace Path:** `C:\Users\FLEX\OneDrive\Desktop\PP\INT8`
- **Git Version Control:** No `.git` repository exists in `INT8` or parent workspace `PP`.
- **Source Safety Protocol:** No source files modified. No files deleted. Baseline preserved before any architectural changes.

### 1.2 Host Toolchain & EDA Versions
- **RTL Simulator:** Icarus Verilog v12.0 (`iverilog.exe` and `vvp.exe` located at `C:\iverilog\bin\`).
- **Python Environment:** Python 3.12.3 (Miniconda) with:
  - `numpy`: 2.4.4
  - `torch`: 2.14.1+cpu
  - `torchvision`: 0.29.1+cpu
  - `Pillow`: Available via TorchVision
- **FPGA Synthesis & Implementation:** AMD Vivado Design Suite v2026.1 (Build 6511674) verified at `Z:\2026.1\Vivado\bin\vivado.bat`.
- **Lint / Verilator:** Verilator v5.050 installed in MSYS2 UCRT64 (`C:\msys64\ucrt64\bin\`).

---

## 2. Baseline Test Results (Actually Reproduced Now)

The test suite was executed dynamically using Icarus Verilog v12.0 via `scripts/verify.ps1 -PythonExe python -UseExistingVectors`. All 8 testbenches passed bit-for-bit:

| Testbench | Scope | Clocks / Sim Time | Verification Result | Status |
| :--- | :--- | :---: | :--- | :---: |
| `tb/tb_pe.sv` | Unit: Processing Element signed MAC & activation propagation | 36 ns | `PASS: signed PE multiply-accumulate and activation register` | **PASS** |
| `tb/tb_pe_array.sv` | Unit: 4x4 Systolic Array skew, deskew & pipeline tags | 126 ns | `PASS: systolic array alignment, tags, and signed lane results` | **PASS** |
| `tb/tb_post_proc.sv` | Unit: Bias addition, requantization, rounding, ReLU, saturation, pooling | 271 ns | `PASS: requantization, shift-zero, rounding, ReLU, saturation, accumulation, bias, and pooling` | **PASS** |
| `tb/tb_mem_ctrl_random.sv` | Unit: Randomized DMA byte writes (600) & reads (200), seed `0x51a7c0de` | 8,020 ns | `PASS: randomized mem_ctrl DMA and result reads, seed=0x51a7c0de, writes=600, reads=200` | **PASS** |
| `tb/tb_mem_ctrl_zero_scan.sv`| Unit: First-layer zero-channel detection & row load skipping | 15,840 ns | `PASS: zero-lane scan skips redundant rows and retains all rows for nonzero lanes` | **PASS** |
| `tb/tb_ctrl_unit.sv` | Unit: Instruction decode, FSM progression & illegal descriptor rejection | 65 ns | `PASS: instruction decode and illegal channel descriptor rejection` | **PASS** |
| `tb/tb_top.sv` | Integration: AXI4-Lite register writes, byte DMA, instruction commit, buffer swaps | 3,135 ns | `PASS: AXI-Lite, convolution, pooling, FC, buffer swapping, and byte results` | **PASS** |
| `tb/tb_full_cnn.sv` | Full-Shape Smoke: 28x28 CONV/POOL/CONV/POOL/FC network schedule | **53,815 clocks** | `PASS: full 28x28 CONV/POOL/CONV/POOL/FC schedule matches Python integer vectors, cycles=53815` | **PASS** |

### Single-Image Trained AXI End-to-End Verification
- Script: `python/run_rtl_manual.py`
- Test Input: `artifacts/manual/20261016_214025_016250_preprocessed_28x28/preprocessed_28x28.npy` (MNIST Test Sample Index 0, Label 7).
- RTL Output Bytes: `[239, 220, 253, 8, 203, 243, 191, 47, 240, 1, 0, 0]`
- Python INT8 Scores: `[-17, -36, -3, 8, -53, -13, -65, 47, -16, 1]` (Argmax = Class 7).
- Result: **0 byte mismatches**, 53,815 accelerator clock cycles. Bit-exact match.

---

## 3. Historical vs. Unverified Results

1. **5,000-Image AXI Top-Level Regression:**
   - Recorded in `artifacts/rtl_5000/summary.json`: 5,000 images, 60,000 output bytes matched with 0 mismatches, 55,677 clocks/image, 95.12% accuracy.
   - **Verification Status:** **Historical / Outdated.** This run was executed on an earlier RTL revision before the zero-channel optimization (which reduced runtime to 53,815 clocks/image). Full rerun requires ~9.8 hours of CPU time in Icarus Verilog and was not repeated during this audit.
2. **10,000-Image RTL Regression:**
   - Recorded in `artifacts/rtl_10000/summary.json`: Halted after 200 images with `regression_status: IN_PROGRESS`.
   - **Verification Status:** **Unverified / Incomplete.**
3. **Python Reference Model Accuracy:**
   - Evaluated on 10,000 MNIST test images (`artifacts/mnist_int8_evaluation.json`):
     - FP32 PyTorch Model: 96.39% accuracy (9,639 / 10,000).
     - Fixed-Scale INT8 Integer Model: 96.44% accuracy (9,644 / 10,000).

---

## 4. Current FPGA Synthesis & Timing Baseline

Based on the verified Vivado 2026.1 implementation on **AMD Artix-7 200T (`xc7a200tfbg676-2`)** in `fpga/reports/a200t/`:

### 4.1 Resource Utilization (`post_route_utilization.rpt`)
- **Slice LUTs:** 40,674 / 133,800 (30.40%)
  - *Logic LUTs:* 12,487 (9.33%)
  - *Distributed RAM (LUTRAM):* **28,160 / 46,200 (61.01%)** (7,040 `RAM64M` primitives)
- **Slice Registers (FFs):** 10,702 / 267,600 (4.00%)
- **Block RAM:** 80 Tiles (160 `RAMB18E1` primitives) / 365 (21.92%)
  - *Weights RAM:* 64 KB mapped to dedicated BRAM
  - *Bias RAM:* Mapped to dedicated BRAM
- **DSP48E1 Slices:** 19 / 740 (2.57%)
  - 8 DSPs in `post_proc` for requantization scaling
  - 11 DSPs in `mem_ctrl` for address offset arithmetic

### 4.2 Timing Summary (`post_route_timing_summary.rpt`)
- **Target Clock:** 100 MHz ($T = 10.0\text{ ns}$) on port `clk` (`fpga/constraints/clock.xdc`).
- **Worst Negative Slack (WNS):** **-12.971 ns** (TIMING VIOLATED).
- **Total Negative Slack (TNS):** -814,951.938 ns.
- **Failing Endpoints:** 219,987 out of 242,320.
- **Worst Hold Slack (WHS):** +0.139 ns (MET).
- **Real Achievable Clock Frequency ($F_{max}$):**
  $$F_{max} = \frac{1}{10.0\text{ ns} + 12.971\text{ ns}} = \frac{1}{22.971\text{ ns}} \approx \mathbf{43.53\text{ MHz}}$$

### 4.3 Confirmed Implementation Bottlenecks
1. **Combinational Read Port on Feature Memories:** `feature_a` and `feature_b` in `rtl/mem_ctrl.sv` use asynchronous combinational read multiplexing (`input_word = input_select ? feature_b[...] : feature_a[...]`). Xilinx Block RAM requires synchronous registered reads (1-cycle read latency). This caused 28,160 LUTs to be synthesized as Distributed RAM, causing synthesis to overmap on Artix-7 100T.
2. **20-Level Logic Critical Path:** The critical path originates at `control/cfg_reg[stride][3]/C` and terminates at `memory/zero_input_channels_reg/D` (22.926 ns data delay, 20 logic levels: 4 CARRY4, 2 DSP48E1, 10 LUTs, 3 MUXF7/F8, 1 RAMD64E). Address computation, Distributed RAM lookup, and zero-channel comparator are all chained in a single clock cycle.

---

## 5. Known Architectural Restrictions

1. **Channel Multiples:** Input and output channels must be positive multiples of 4 ($C_{in} \pmod 4 = 0$, $C_{out} \pmod 4 = 0$).
2. **Pooling Topology:** Max pooling is strictly hardcoded to $2 \times 2$ kernel, stride 2, pad 0, with even spatial input dimensions.
3. **Memory Capacity:** Feature buffers are capped at 4,096 32-bit words (16 KB per ping-pong buffer). Feature maps exceeding $28 \times 28 \times 8$ cannot fit.
4. **Host Communication:** The host interface is byte-serial slave AXI4-Lite MMIO with no autonomous burst DMA.

---

## 6. Current Interface & RISC-V Integration Requirements

A read-only inspection of the companion project `C:\Users\FLEX\OneDrive\Desktop\PP\RISC-V` reveals:

### 6.1 Existing Integration Structure in RISC-V SoC
In `RISC-V/rtl/soc/riscv_cnn_soc_top.sv` (lines 261–282):
- The SoC top module instantiates `accel_top u_accel` with the **exact** port interface currently defined in `INT8/rtl/accel_top.sv`.
- The SoC incorporates `accel_adapter u_adapter` (`RISC-V/rtl/accelerator/accel_adapter.sv`), which bridges the native single-cycle CPU synchronous bus (`accel_req`, `accel_we`, `accel_addr`, `accel_wdata`, `accel_wstrb`, `accel_rdata`, `accel_stall`) to the AXI4-Lite master interface driving `accel_top`.

### 6.2 Address Mapping in RISC-V Memory Interconnect
In `RISC-V/rtl/interconnect/bus_interconnect.sv` (lines 76–77):
- Accelerator MMIO range: `0x8000_1000` to `0x8000_10FF`.
- Register mapping:
  - `0x8000_1000`: `CTRL` (start, IRQ enable)
  - `0x8000_1004`: `STATUS` (busy, done, err)
  - `0x8000_1008`: `VERSION` (`32'h01040408`)
  - `0x8000_1010`: `DMA_ADDR`
  - `0x8000_1014`: `DMA_DATA`
  - `0x8000_1018`: `RES_ADDR`
  - `0x8000_101C`: `RES_DATA`
  - `0x8000_1020`–`0x8000_102C`: `INSTR_W0`–`INSTR_W3`
  - `0x8000_1030`: `INSTR_ADDR`

### 6.3 Non-Negotiable Contract Requirements
1. **Port Interface Preservation:** `accel_top` module name, port names, signal widths, and AXI4-Lite slave protocol must not be modified.
2. **Register Map Preservation:** Register addresses `0x00` through `0x30` and bit positions must remain strictly unchanged.
3. **Clock and Reset:** Accelerator must remain synchronous to rising-edge `clk` with active-low synchronous/asynchronous `rst_n`.
4. **Standalone Testability:** All improvements to `INT8` must be validated independently using `scripts/verify.ps1` before any SoC integration.
