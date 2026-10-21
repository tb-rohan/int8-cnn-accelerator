# INT8 CNN Hardware Accelerator — Final Audit Inventory

**Date of Audit:** October 21, 2026  
**Auditor Role:** Senior FPGA Design Engineer, SystemVerilog Verification Engineer, Computer Architecture Reviewer  
**Target Repository:** `INT8` (Project Root)  
**Companion SoC Repository (Read-Only Protected):** `../RISC-V`  

---

## 1. Directory Tree & Categorization

| Path / Folder | Category | Purpose / Contents | Reproduction Requirement |
| :--- | :--- | :--- | :--- |
| `rtl/` | Synthesizable RTL | Core hardware source modules (`accel_top.sv`, `cnn_pkg.sv`, `ctrl_unit.sv`, `mem_ctrl.sv`, `pe.sv`, `pe_array.sv`, `post_proc.sv`) | **Essential Source** |
| `tb/` | Testbenches | SystemVerilog verification suite (`tb_pe.sv`, `tb_pe_array.sv`, `tb_post_proc.sv`, `tb_directed_arith.sv`, `tb_mem_ctrl_random.sv`, `tb_mem_ctrl_zero_scan.sv`, `tb_ctrl_unit.sv`, `tb_top.sv`, `tb_full_cnn.sv`, `tb_repeated_inference.sv`) | **Essential Source** |
| `python/` | Python Models & Tools | PyTorch training, calibrated symmetric INT8 quantization, vector export, golden integer reference generator, and manual runner | **Essential Source** |
| `data/` | Dataset | Local copy of MNIST dataset (`data/MNIST/raw/`) for offline model evaluation and golden vector generation | **Reproducible Dependency** |
| `artifacts/` | Model Artifacts | Trained PyTorch weights (`mnist_cnn.pt`), calibration metrics (`mnist_int8_calibration.json`), evaluation results (`mnist_int8_evaluation.json`) | **Essential / Generated** |
| `vectors/smoke/` | Golden Test Vectors | Pre-exported hex vectors (`instructions.hex`, `weights.hex`, `biases.hex`, `input.hex`, `golden_layer*.hex`) for deterministic regression | **Essential Source** |
| `fpga/constraints/` | Timing Constraints | Clock constraint file (`clock.xdc`: 10.0 ns / 100.0 MHz target) | **Essential Source** |
| `fpga/scripts/` | Tool Automation | Vivado batch Tcl scripts (`run_a200t.tcl`, `run_synthesis.tcl`, `run_implementation.tcl`) | **Essential Source** |
| `fpga/reports/a200t/` | Implementation Reports | Vivado 2026.1 post-route timing summary, utilization, max paths, and DRC reports | **Generated Artifacts** |
| `fpga/checkpoints/a200t/`| Design Checkpoints | Vivado design checkpoints (`post_synth.dcp`, `post_place.dcp`, `post_route.dcp`) | **Generated Artifacts** |
| `scripts/` | Verification Scripts | Automated PowerShell regression script (`scripts/verify.ps1`) | **Essential Source** |
| `docs/` | Technical Documentation | Architectural specifications, verification reports, FPGA implementation reports, and sign-off scorecards | **Essential Documentation** |

---

## 2. Active Synthesizable RTL File Inventory & Hashes

Verified active RTL files located in `rtl/`:

| File Name | File Size | Last Modified | SHA256 Checksum |
| :--- | :---: | :---: | :--- |
| `accel_top.sv` | 7,826 B | 2026-10-16 15:39:22 | `2f39a97573234fb4a018099056a9aeec14f8dbb4392fd6d71c11cadfcdde2ff9` |
| `cnn_pkg.sv` | 736 B | 2026-10-16 15:35:38 | `bed67eeb3aa8f912ac3e5854f29a410cb27186baaa6c18bed8938bb1d792d717` |
| `ctrl_unit.sv` | 3,390 B | 2026-10-16 15:38:29 | `0368b3e73d7f244ea1b2f9ff46457a042f0f1236139c5350ab28fd553b430dc1` |
| `mem_ctrl.sv` | 24,226 B | 2026-10-21 18:21:42 | `228fd166cf360f2a5eae368c9cdee5b26d68df4c2da6d6388ac0e34fea690c73` |
| `pe.sv` | 897 B | 2026-10-16 15:36:15 | `9def071cea5db581b36965aa9e9147a3068551cbc581d89f7aa06d87c0bdaae9` |
| `pe_array.sv` | 3,872 B | 2026-10-16 15:36:49 | `42017565c468522d41260911e97a1ba5aa6a07c09238cf0312c7e352fb41029a` |
| `post_proc.sv` | 4,735 B | 2026-10-16 15:38:11 | `63590797103e135f50dcca93094ec668c8e520076f40735e01e11ee3f3fabcc7` |

*Note on Backups:* Intermediate and baseline RTL versions are safely archived in `rtl/mem_ctrl_baseline.sv`, `rtl/mem_ctrl.sv.bak_step_c`, `rtl/mem_ctrl.sv.bak_step_d`, `rtl/mem_ctrl.sv.bak_step_e_interim`, and `backup_before_timing_closure/`.

---

## 3. Key Generated Artifacts & Verification Commands

### 3.1 FPGA Implementation (AMD Vivado 2026.1)
- **Execution Script:** `fpga/run_a200t.bat` (calls `vivado -mode batch -source fpga/scripts/run_a200t.tcl`)
- **Key Generated Outputs:**
  - `fpga/checkpoints/a200t/post_route.dcp` (6,231,696 bytes, generated 2026-10-21 18:29:00)
  - `fpga/reports/a200t/post_route_timing_summary.rpt` (WNS: +0.621 ns, TNS: 0.000 ns, 0 failing endpoints)
  - `fpga/reports/a200t/post_route_utilization.rpt` (6,199 LUTs, 10,316 FFs, 88 BRAM tiles, 16 DSPs)
  - `fpga/reports/a200t/post_route_drc.rpt` (0 errors, 0 critical warnings)

### 3.2 SystemVerilog Functional Regression (Icarus Verilog v12.0)
- **Execution Command:**
  ```powershell
  powershell -ExecutionPolicy Bypass -File .\scripts\verify.ps1 -PythonExe python
  ```
- **Tests Executed:** 10 testbenches (`tb_pe`, `tb_pe_array`, `tb_post_proc`, `tb_directed_arith`, `tb_mem_ctrl_random`, `tb_mem_ctrl_zero_scan`, `tb_ctrl_unit`, `tb_top`, `tb_full_cnn`, `tb_repeated_inference`).
- **Audit Result:** 100% pass (Exit code: 0).

### 3.3 Golden Model & Quantization Evaluation (PyTorch / NumPy)
- **Evaluation Command:**
  ```powershell
  python python\evaluate_mnist.py --checkpoint artifacts\mnist_cnn.pt --data data --samples 10000
  ```
- **Audit Result:** FP32 Accuracy: 96.39% (9,639 / 10,000), INT8 Accuracy: 96.44% (9,644 / 10,000).

### 3.4 Single-Image Manual Inference Runner
- **Command:**
  ```powershell
  python python\run_rtl_manual.py --raw artifacts\manual\20261020_233616_666807_preprocessed_28x28\preprocessed_28x28.npy
  ```
- **Audit Result:** Predicted digit 7, 12/12 output bytes matched bit-exact in 53,836 clock cycles.

### 3.5 Host RISC-V SoC Co-Simulation
- **Compilation Command:**
  ```powershell
  iverilog -g2012 -s tb_riscv_cnn_soc -o build\bin_riscv_cnn_soc.vvp <RISC-V_RTL_SOURCES> <INT8_RTL_SOURCES> <RISC-V_TB>
  ```
- **Execution Commands (Read-only execution from RISC-V directory):**
  - Command 2 (Small CNN test): `vvp build\bin_riscv_cnn_soc.vvp +CMD=2` $\rightarrow$ Result `0x50084607` matched in 1,073 cycles.
  - Command 1 (MNIST Sample 0): `vvp build\bin_riscv_cnn_soc.vvp +CMD=1 +IMAGE_HEX=...` $\rightarrow$ Predicted digit 7 (score 47), accelerator took 53,836 cycles.
  - Command 1 (MNIST Sample 1): `vvp build\bin_riscv_cnn_soc.vvp +CMD=1 +IMAGE_HEX=...` $\rightarrow$ Predicted digit 2 (score 34), accelerator took 53,836 cycles.

---

## 4. Dependencies & Prerequisites

To completely reproduce this project from scratch:
1. **EDA Simulation:** Icarus Verilog (`iverilog` v12.0+) and `vvp`.
2. **FPGA Synthesis & Implementation:** AMD Xilinx Vivado v2026.1 (or compatible Vivado 2022+ supporting Artix-7 `xc7a200tfbg676-2`).
3. **Python Environment:** Python 3.10+ with `torch`, `torchvision`, and `numpy`.
4. **Shell Environment:** PowerShell 5.1+ (Windows) or Bash (Linux).
