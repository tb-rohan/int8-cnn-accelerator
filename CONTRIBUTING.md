# Contributing to the INT8 CNN Hardware Accelerator

Thank you for your interest in contributing to this open-source hardware accelerator project! We welcome contributions that enhance verification, expand layer support, or optimize PPA (power, performance, and area).

---

## 1. Development & Code Conventions

1. **Synthesizable SystemVerilog:**
   - All modules in `rtl/` must be strictly synthesizable and follow standard SystemVerilog-2012 constructs.
   - Use non-blocking assignments (`<=`) for sequential logic (`always_ff @(posedge clk)`) and blocking assignments (`=`) for combinational logic (`always_comb`).
   - Explicitly annotate FPGA memory arrays with attributes (e.g., `(* ram_style = "block" *)`) to prevent unintended distributed RAM inference.
   - Avoid unpipelined dynamic arithmetic (division, runtime multiplication) on critical paths.
2. **Public Interface Invariance:**
   - The top-level module `accel_top.sv` serves as an IP core for the companion RISC-V SoC.
   - Do not alter port names, bit widths, or AXI4-Lite register offsets (`0x00`–`0x30`) without maintaining backward compatibility.

---

## 2. Verification & Pull Request Expectations

Before opening a pull request, ensure the complete test suite passes without errors:
1. **Automated Regression:**
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\scripts\verify.ps1 -PythonExe python
   ```
   All 10 testbenches (`tb_pe`, `tb_pe_array`, `tb_post_proc`, `tb_directed_arith`, `tb_mem_ctrl_random`, `tb_mem_ctrl_zero_scan`, `tb_ctrl_unit`, `tb_top`, `tb_full_cnn`, `tb_repeated_inference`) must report `PASS`.
2. **Bit-Exact Agreement:**
   Any changes to arithmetic logic or layer scheduling must preserve bit-exact agreement against the Python integer golden model (`tb_full_cnn` max error = 0).
3. **No Uncommitted Workspace Leaks:**
   Do not commit temporary simulation waveforms (`*.vcd`, `*.vvp`), Vivado journal files (`*.jou`, `*.log`), or personal local machine paths.

---

## 3. Reporting Issues

If you find a bug or discrepancy, please open an issue describing:
- Target simulator or Vivado version.
- Exact commands executed.
- Observed vs. expected output log.
