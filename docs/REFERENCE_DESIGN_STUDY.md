# Reference Design Study

**Project:** Standalone INT8 CNN Hardware Accelerator  
**Date:** October 21, 2026  
**Document:** `INT8/docs/REFERENCE_DESIGN_STUDY.md`  

---

## 1. Executive Summary

To guide the timing closure, memory architecture, verification, and RISC-V SoC integration of the standalone INT8 CNN hardware accelerator, three open-source reference implementations were cloned and analyzed:
1. **Primary CNN Reference:** [`sharatchandra-ts/systolic-TPU-CNN-accelerator`](https://github.com/sharatchandra-ts/systolic-TPU-CNN-accelerator)
2. **INT8 Systolic Array & Verification Reference:** [`dcgursoy/systolic-mnist`](https://github.com/dcgursoy/systolic-mnist)
3. **FPGA Timing & Implementation Reference:** [`taitashaw/fpga-ai-accelerator`](https://github.com/taitashaw/fpga-ai-accelerator)

All three repositories were cloned into a local `references/` directory outside both `INT8` and `RISC-V` and evaluated as read-only architectural benchmarks.

---

## 2. Comparative Analysis of Reference Architectures

| Architectural Feature | Primary CNN Reference (`systolic-TPU-CNN-accelerator`) | Systolic MNIST Reference (`systolic-mnist`) | FPGA AI Accelerator (`fpga-ai-accelerator`) | Standalone INT8 CNN Accelerator (Our Project) |
| :--- | :--- | :--- | :--- | :--- |
| **Workload Scope** | Full 2D CNN (Conv 1, MaxPool, Flatten, FC) | 3-Layer MLP (784 -> 32 -> 16 -> 10) | Generalized GEMM / Linear Layer Engine | Full 5-Layer CNN (Conv1, Pool1, Conv2, Pool2, FC) |
| **Compute Core** | 9x4 WS Array (Conv) + 9x4 OS Array (FC) | 4x4 Weight-Stationary Systolic Array | 8x8 Weight-Stationary Systolic Array | 4x4 Weight-Stationary Systolic Array ($N=4$) |
| **Data Precision** | Q8.8 Fixed-Point (16-bit operands) | Signed INT8 inputs/weights, INT32 psums | Signed INT8 inputs/weights, INT32 psums | Signed INT8 inputs/weights, INT32 psums |
| **Activation Buffering** | Feature Map BRAMs (dedicated per stage) | Ping-pong interleaved activation banks | Dual-bank ping-pong SRAM (1024x64) | Ping-pong dual-port Block RAM (`feature_a` / `b`) |
| **Address Generation** | 4 nested counters (`out_r`, `out_c`, `kr`, `kc`) | Single incrementing pointer for offline-packed data | Hardware tiling FSM with base-pointer stepping | Incremental row/col stepping + precomputed pitches |
| **Requantization & Saturation** | Fixed shift (>> 8) | Pipelined `(acc*M + 2^(s-1)) >> s`, clamp [0, 127] | ReLU -> arithmetic right shift -> zero-point -> clamp | Bias add -> `round_shift` -> ReLU -> [-128, 127] clamp |
| **FPGA Target & Fmax** | Xilinx Artix-7 (functional simulation) | Lattice ECP5-85k (43.2 MHz) | Xilinx Artix-7 100T (100.0 MHz, $WNS = +0.10\text{ ns}$) | AMD Artix-7 200T (Target: 100.0 MHz) |

---

## 3. Deep-Dive Study by Reference Project

### 3.1 Primary CNN Reference: `systolic-TPU-CNN-accelerator`
- **Architecture & Dataflow:** Implements an end-to-end CNN pipeline. Employs a weight-stationary 9x4 array for 3x3 convolution and switches to an output-stationary 9x4 array for the fully connected layer.
- **Address Generation:** The `img2col` module maps 2D images to 1D streams using four explicit nested counters (`out_r`, `out_c`, `kr`, `kc`). Combinational multiplication `(out_r + kr) * IMG_W + (out_c + kc)` is performed.
- **Key Takeaways & Applicability:**
  - *Adoptable:* The structured separation of convolution traversal from pooling and fully-connected states.
  - *Unsuitable:* The combinational `img2col` multiplier creates long routing delay if not registered. In our design, incremental stepping (`cur_row_base + cur_x_offset`) avoids multi-cycle multiplications during streaming.

### 3.2 INT8 Systolic Array & Verification Reference: `systolic-mnist`
- **Architecture & Dataflow:** Weight-stationary systolic array with double-buffered shadow registers and a wavefront swap token. Activations stream through a skew buffer with per-row delay matching systolic diagonal propagation.
- **Memory & Requantization:** Activation memory is organized in ping-pong banks. Requantization implements symmetric fixed-point rounding: `clamp((acc * M + round_const) >> shift, 0, 127)`.
- **Verification Methodology:** Comprehensive self-checking testbench comparing all hidden activations and logits against an executable Python integer reference. Functional coverage bins cover arithmetic stress corners.
- **Key Takeaways & Applicability:**
  - *Adoptable:* Strict bit-exact intermediate verification at every layer boundary and non-resetting multi-inference regression.
  - *Unsuitable:* The wavefront swap token adds substantial shadow register overhead for multi-channel 2D convolutions where feature-data reuse spans spatial tiles.

### 3.3 FPGA Timing Reference: `fpga-ai-accelerator`
- **Architecture & Implementation:** 8x8 INT8 systolic array achieving 100 MHz timing closure on Artix-7 ($WNS = +0.100\text{ ns}$).
- **BRAM Timing Methodology:**
  - Employs synchronous Block RAM inference (`(* ram_style = "block" *)`) with 1-to-2 cycle registered read latency.
  - Crucially separates address generation logic from BRAM write/read strobe generation. Address arithmetic is never chained directly with BRAM address pins within the same clock cycle.
- **Requantization:** 4-stage pipelined post-processing unit preventing accumulator sign-extension from impacting output memory setup slack.
- **Key Takeaways & Applicability:**
  - *Adoptable:* **Address-path pipelining.** In our accelerator, the remaining critical path is in `WRITE_POOL` address generation. Inserting a registered address pipeline stage directly mirrors this timing-closed Artix-7 architecture.

---

## 4. Specific Techniques Selected for Implementation

Based on this comparative study, the following reference-guided techniques are applied to close timing at 100 MHz:
1. **Registered Address Calculation for Max-Pooling (`WRITE_POOL`):**
   - In `mem_ctrl.sv`, `pool_read_addr` currently chains spatial multiplication through two DSP48 slices directly into `feature_b_reg_2/ADDRBWRADDR`.
   - Applying the registered address technique from `fpga-ai-accelerator` and `systolic-TPU-CNN-accelerator`: Precompute and latch the row base address and column offset across 2 pipeline sub-states in `WRITE_POOL`, ensuring the Block RAM address port is driven by a simple register or single-level adder.
2. **Intermediate Layer Boundary Verification:**
   - Adopting `systolic-mnist`'s methodology: Verify all intermediate convolution and pooling activation buffers bit-exact against the Python integer model across the complete 53,836-cycle run.
