# FPGA Synthesis & Implementation Guide: INT8 CNN Accelerator

This directory contains the automated AMD/Xilinx Vivado synthesis and implementation workflows for the **ATHENA INT8 CNN Hardware Accelerator** (`accel_top`).

---

## 1. Directory Structure

```text
INT8/fpga/
├── constraints/
│   └── clock.xdc                # 100 MHz primary clock timing constraint (period: 10.0 ns)
├── scripts/
│   ├── run_synthesis.tcl        # Non-project batch synthesis flow (xc7a100tcsg324-1)
│   ├── run_implementation.tcl   # Non-project placement & routing flow (xc7a100tcsg324-1)
│   ├── run_a200t.tcl            # Full synthesis + place & route flow (xc7a200tfbg676-2)
│   └── create_project.tcl       # Interactive GUI project generator (creates athena_int8_cnn.xpr)
├── manifest/
│   └── manifest.json            # Target parts, HDL source lists, and parameters
├── checkpoints/                 # Synthesized and routed design checkpoints (.dcp)
├── reports/                     # Generated utilization, timing, DRC, and latch reports
├── run_synthesis.bat            # One-click Windows Command Prompt runner
└── run_synthesis.ps1            # One-click Windows PowerShell runner
```

---

## 2. Prerequisites & Vivado Setup

1. **Toolchain**: AMD Vivado Design Suite 2020.2 or newer (tested on **Vivado v2026.1 Build 6511674**).
2. **License**: Standard WebPACK / Vivado Basic license is fully supported for Artix-7 parts.
3. **Executable Path**: By default, the batch scripts search for `Z:\2026.1\Vivado\bin\vivado.bat` or standard installations in `C:\Xilinx\Vivado\...`. If installed in another directory, simply edit the `VIVADO_BIN` variable in `run_synthesis.bat`.

---

## 3. How to Run (Zero Experience Required)

### Option A: One-Click Windows Batch Run
In File Explorer or Command Prompt:
```cmd
cd fpga
run_synthesis.bat
```

### Option B: PowerShell Execution
```powershell
cd fpga
.\run_synthesis.ps1
```

### Option C: Generate a GUI Project to Open in Vivado IDE
To open the project in the visual Vivado IDE:
```cmd
vivado -mode batch -source scripts\create_project.tcl
```
Then launch Vivado, click **Open Project**, and select:
`fpga\vivado_proj\athena_int8_cnn.xpr`.

---

## 4. Synthesis Results Summary

### Primary Target: Artix-7 100T (`xc7a100tcsg324-1`)
- **Top Module**: `accel_top`
- **Synthesis Status**: Passed cleanly (0 Errors, 0 Critical Warnings, 0 Inferred Latches)
- **Slice LUTs**: 41,092 / 63,400 (64.81% total device utilization)
  - **Logic LUTs**: 12,905 (20.35%)
  - **Distributed RAM (LUTRAM)**: 28,160 LUTs (7,040 `RAM64M` primitives)
- **Slice Registers (FFs)**: 10,610 / 126,800 (8.37%)
- **Block RAM**: 80 Tiles (160 `RAMB18E1` primitives) / 135 Tiles (59.26%)
  - *Weights RAM*: 64 KB mapped to dedicated Block RAM
  - *Bias RAM*: Dedicated Block RAM
- **DSP48E1 Slices**: 19 / 240 (7.92%)
  - 8 DSPs in `post_proc` for requantization scaling
  - 11 DSPs in `mem_ctrl` for address offset arithmetic

---

## 5. Architectural Findings & Hardware Trade-Offs

### A. Why Distributed RAM is Inferred for Feature Buffers
In `rtl/mem_ctrl.sv`, `feature_a` and `feature_b` use combinational asynchronous read ports:
```systemverilog
assign input_word = (ping_pong == 0) ? feature_a[feature_read_addr] : feature_b[feature_read_addr];
```
Xilinx 7-series Block RAMs (`RAMB18E1` / `RAMB36E1`) require a synchronous registered read port (1-cycle read latency). Because the current RTL reads data combinationally within the same cycle, Vivado correctly infers **Distributed RAM** (`RAM64M` primitives using SLICEM LUTs).
- On the **Artix-7 100T**, SLICEM capacity is 19,000 LUTs, while 28,160 are demanded by the dual 16 KB ping-pong buffers.
- On the **Artix-7 200T** (`xc7a200tfbg676-2`), >40,000 SLICEM LUTs are available, allowing complete place & route.
- **Architectural Recommendation for Next Revision**: Add a 1-cycle pipeline register to the feature buffer read path to allow 100% inference of `feature_a` and `feature_b` as Block RAM. This will reduce LUT utilization by over 28,000 LUTs.

### B. Critical Path & Timing Bottleneck
- The design exhibits an unrolled combinational tile origin progression in `advance_tile_origin` inside `ctrl_unit.sv` / `mem_ctrl.sv`.
- The data path cascades through 118 logic levels (CARRY4 chains and LUTs), producing ~75 ns of combinational delay.
- Estimated maximum frequency without pipelining: **~12.5 MHz**.
- **Architectural Recommendation**: Register the intermediate tile coordinate counters (`tile_x`, `tile_y`, `stride` accumulation) across 2–3 pipeline stages.
