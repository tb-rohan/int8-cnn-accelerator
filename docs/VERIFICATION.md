# Verification Methodology & Regression Suite

**Project:** Standalone INT8 CNN Hardware Accelerator  
**Top Module:** `accel_top`  
**EDA Simulation Tool:** Icarus Verilog (`iverilog` v12.0+) / `vvp`  
**Golden Model:** Python 3.12 (PyTorch integer-exact reference model)  
**Regression Status:** **10/10 Tests PASS (100% Pass Rate)**  

---

## 1. Verification Strategy & Coverage

The accelerator verification environment utilizes a multi-tiered strategy spanning unit arithmetic blocks, systolic spatial timing, memory bank hazard tests, end-to-end multi-layer network validation, and repeated inference state integrity:

```
                  ┌─────────────────────────────────────┐
                  │    Host RISC-V SoC Co-Simulation    │
                  └──────────────────┬──────────────────┘
                                     │
                  ┌──────────────────▼──────────────────┐
                  │    Full 5-Layer CNN & Repeated      │
                  │   (tb_full_cnn, tb_repeated_inf)    │
                  └──────────────────┬──────────────────┘
                                     │
                  ┌──────────────────▼──────────────────┐
                  │   Subsystem & Protocol Integration  │
                  │        (tb_top, tb_ctrl_unit)       │
                  └──────────────────┬──────────────────┘
                                     │
                  ┌──────────────────▼──────────────────┐
                  │   Unit Datapath & Arithmetic Tests  │
                  │ (tb_pe, tb_pe_array, tb_post_proc)  │
                  └─────────────────────────────────────┘
```

---

## 2. Testbench Directory & Execution Catalog

The complete deterministic regression suite is executed via:
```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\verify.ps1 -PythonExe python
```

### 2.1 Complete Test Suite Matrix

| # | Testbench File | Target Module | Scope & Verification Criteria | Simulation Time | Result |
| :-: | :--- | :--- | :--- | :---: | :---: |
| 1 | `tb/tb_pe.sv` | `pe.sv` | Signed INT8 MAC arithmetic, zero multiplication, sign-extension into 32-bit accumulator, weight latching. | 36 ns | **PASS** |
| 2 | `tb/tb_pe_array.sv` | `pe_array.sv` | $4 \times 4$ 2D systolic array timing, diagonal input skewing ($D_i = i$), output deskewing ($3 - j$), valid tag framing. | 126 ns | **PASS** |
| 3 | `tb/tb_post_proc.sv` | `post_proc.sv` | 33-bit bias addition, fixed-point requantization (`round_shift`), round-half-up nearest integer rounding, ReLU activation, INT8 saturation clamp, $2 \times 2$ max-pooling. | 271 ns | **PASS** |
| 4 | `tb/tb_directed_arith.sv` | Math Datapath | Corner-case test: extreme negative sums (-128 clamp), positive saturation (+127), round-half-up boundaries, negative pooling comparisons. | Instant | **PASS** |
| 5 | `tb/tb_mem_ctrl_random.sv` | `mem_ctrl.sv` | 600 random DMA byte writes, 200 random reads across BRAM banks (seed `0x51a7c0de`). Confirms byte-lane write integrity and address decoding. | 8,020 ns | **PASS** |
| 6 | `tb/tb_mem_ctrl_zero_scan.sv` | `mem_ctrl.sv` | Zero-channel detection and DMA acceleration logic for 28x28 4-lane convolution descriptors. | 15,940 ns | **PASS** |
| 7 | `tb/tb_ctrl_unit.sv` | `ctrl_unit.sv` | Instruction memory loading, 90-bit descriptor decoding, legal/illegal configuration validation, FSM state sequencing, interrupt assertion. | 65 ns | **PASS** |
| 8 | `tb/tb_top.sv` | `accel_top.sv` | AXI4-Lite slave register MMIO (`0x00`–`0x30`), DMA streaming handshakes, status register polling, interrupt generation. | 3,135 ns | **PASS** |
| 9 | `tb/tb_full_cnn.sv` | `accel_top.sv` | Complete 5-layer MNIST network (Conv1 $\rightarrow$ Pool1 $\rightarrow$ Conv2 $\rightarrow$ Pool2 $\rightarrow$ FC) verified bit-exact against Python integer golden reference. | **53,836 cycles** | **PASS** |
| 10| `tb/tb_repeated_inference.sv` | `accel_top.sv` | 2 consecutive complete MNIST inference passes without hardware reset; proves buffer isolation and absence of state leakage. | **107,672 cycles** | **PASS** |

---

## 3. End-to-End Golden Model Verification (`tb_full_cnn.sv`)

### 3.1 Network Topology & Comparison
The full network represents an end-to-end MNIST classifier:
- **Layer 0 (Conv2D):** $28 \times 28 \times 1 \rightarrow 28 \times 28 \times 8$ ($3 \times 3$ kernel, stride 1, pad 1).
- **Layer 1 (MaxPool2D):** $28 \times 28 \times 8 \rightarrow 14 \times 14 \times 8$ ($2 \times 2$ pool, stride 2).
- **Layer 2 (Conv2D):** $14 \times 14 \times 8 \rightarrow 14 \times 14 \times 8$ ($3 \times 3$ kernel, stride 1, pad 1).
- **Layer 3 (MaxPool2D):** $14 \times 14 \times 8 \rightarrow 7 \times 7 \times 8$ ($2 \times 2$ pool, stride 2).
- **Layer 4 (Fully Connected):** $392 \rightarrow 12$ outputs (10 valid digit classes + 2 padding lanes).

### 3.2 Verification Results Across Layer Boundaries
The testbench dumps intermediate feature maps and verifies them against the Python integer model:

| Layer Boundary | Output Elements Compared | Mismatches | Max Absolute Error | Status |
| :--- | :---: | :---: | :---: | :---: |
| **Layer 0 (Conv1)** | 6,272 bytes | 0 | 0 | **Bit-Exact Match** |
| **Layer 1 (Pool1)** | 1,568 bytes | 0 | 0 | **Bit-Exact Match** |
| **Layer 2 (Conv2)** | 1,568 bytes | 0 | 0 | **Bit-Exact Match** |
| **Layer 3 (Pool2)** | 392 bytes | 0 | 0 | **Bit-Exact Match** |
| **Layer 4 (FC Output)** | 12 bytes | 0 | 0 | **Bit-Exact Match** |
| **Total Values Compared** | **9,812 bytes** | **0** | **0** | **100% BIT-EXACT** |

- **Golden Output Scores:** `[87, 91, 95, 96, 75, 79, 83, 74, 78, 82]`
- **Measured Latency:** **53,836 clock cycles** (inclusive of 4-cycle per-layer configuration stages).

---

## 4. Multi-Inference Stability Verification (`tb_repeated_inference.sv`)

A critical requirement for hardware accelerators in SoC environments is that repeated inference passes must not leak stale state from prior runs:
1. **Pass 1:** Executed full inference on digit 7 in 53,836 cycles. Finished with `done=1`, `irq=1`. Output matched golden model bit-for-bit.
2. **Intermediate Check:** Confirmed `busy` cleared to 0 and interrupt fired.
3. **Pass 2 (Re-start without Reset):** Host issued a write to `CTRL` (`0x00`) with value `0x01`.
   - Accelerator cleared its internal pointers cleanly.
   - Finished in exactly 53,836 cycles.
   - Output matched golden model bit-for-bit with 0 mismatches.
4. **Conclusion:** Zero state pollution, deterministic cycle execution, full buffer re-initialization.

---

## 5. Single-Image Manual Runner (`run_rtl_manual.py`)

To verify real-world inference on an arbitrary input image:
```powershell
python python\run_rtl_manual.py --raw artifacts\manual\20261020_233616_666807_preprocessed_28x28\preprocessed_28x28.npy
```
- **Prediction:** Digit 7 (Confidence score: 47).
- **Logits (Classes 0–9):** `[-17, -36, -3, 8, -53, -13, -65, 47, -16, 1]`
- **Python Golden Logits:** `[-17, -36, -3, 8, -53, -13, -65, 47, -16, 1]`
- **Output Comparison:** **MATCH (12/12 bytes matched, 0 mismatches)**.
- **Hardware Latency:** **53,836 clock cycles**.

---

## 6. How to Diagnose Test Failures

If any test fails during development:
1. **Compilation Errors:** Ensure `iverilog -g2012` is used; verify all source files in `rtl/` are passed in correct dependency order (`cnn_pkg.sv` must be first).
2. **Arithmetic Mismatches:** Inspect `tb/tb_directed_arith.sv` logs to pinpoint whether failure is in multiplier sign extension, requantization rounding, or saturation clamping.
3. **Latency or Timeout Errors:** Ensure the testbench timeout limit is set to $>60,000$ cycles for full CNN inference (default is 100,000 cycles in `tb_full_cnn.sv`).
