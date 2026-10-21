# Final Three Targeted Verification Checks: Pre-Publication Audit

**Audit Date:** 2026-10-21  
**Project:** Standalone INT8 CNN Hardware Accelerator  
**Workspace:** `C:\Users\FLEX\OneDrive\Desktop\PP\INT8`  
**Protected SoC Workspace:** `C:\Users\FLEX\OneDrive\Desktop\PP\RISC-V` (Read-Only)  
**Report Document:** `docs/FINAL_THREE_CHECKS.md`  

---

## Executive Summary of the Three Targeted Checks

| Check Item | Target Subsystem | Status | Primary Grounded Finding |
| :--- | :--- | :---: | :--- |
| **CHECK 1** | Critical-Path Timing & Post-Route Physics | **PASS** | $10.0\text{ ns}$ (100.0 MHz) constraint met; $WNS = \mathbf{+0.621\text{ ns}}$, $TNS = 0.000\text{ ns}$, 0 failing endpoints; 0 logic levels; $\mathbf{95.83\%}$ routing delay on monolithic Artix-7 fabric ($F_{\text{max}} = 106.62\text{ MHz}$). Inaccurate "cross-die" terminology corrected. |
| **CHECK 2** | RISC-V SoC Adapter Watchdog Behavior | **PASS** | Watchdog counter in `accel_adapter.sv` monitors **individual AXI4-Lite bus transactions** (1–2 cycles), NOT full inference compute (53,836 cyc) or total SoC latency (80,874 cyc). Resets to 0 on every status poll. No timeout risk. Conflation corrected across docs. |
| **CHECK 3** | Rounding & Quantization Rules | **PASS** | Both synthesizable RTL (`post_proc.sv`) and Python golden reference (`golden.py`) implement bit-exact **Round-Half-Up** (`(val + (1 << (shift - 1))) >> shift`), NOT round-to-nearest-even. Exact halfway ties ($+0.5, -0.5, -1.5$) round towards $+\infty$. Fictitious RNE code removed. |

---

## CHECK 1: Critical-Path Timing and Post-Route Physics

### Verdict
**`PASS`**

### Exact Files Inspected
1. `fpga/reports/a200t/post_route_timing_summary.rpt` (Lines 134–170)
2. `fpga/reports/a200t/post_route_timing_max_paths.rpt` (Lines 15–60)
3. `fpga/reports/a200t/post_route_utilization.rpt` (Lines 30–125)
4. `fpga/reports/a200t/post_route_drc.rpt` (Lines 20–40)
5. `README.md` (Lines 90–115)
6. `docs/FPGA_RESULTS.md` (Lines 15–85)
7. `docs/FINAL_VIVADO_REPORT.md` (Lines 15–25)
8. `docs/FINAL_ENGINEERING_SIGNOFF.md` (Lines 40–55)

### Verification of Specific Technical Requirements
1. **Clock Period:**
   - **Target Constraint:** $10.000\text{ ns}$ ($100.000\text{ MHz}$, 50% duty cycle).
   - Confirmed in `post_route_timing_summary.rpt` (lines 152–154):
     ```
     Clock  Waveform(ns)       Period(ns)      Frequency(MHz)
     -----  ------------       ----------      --------------
     clk    {0.000 5.000}      10.000          100.000
     ```
2. **Worst Negative Slack (WNS) and Slack Metrics:**
   - **Worst Negative Slack (WNS):** **`+0.621 ns`** (positive setup slack; zero setup violations).
   - **Total Negative Slack (TNS):** **`0.000 ns`**.
   - **Failing Setup Endpoints:** **0** out of 24,292 design endpoints.
   - **Worst Hold Slack (WHS):** **`+0.102 ns`** ($THS = 0.000\text{ ns}$, 0 hold violations out of 24,292 endpoints).
   - **Worst Pulse Width Slack (WPWS):** **`+4.146 ns`** ($TPWS = 0.000\text{ ns}$, 0 violations across 10,687 endpoints).
3. **Critical Path Startpoint and Endpoint:**
   - **Startpoint:** `dma_wr_data_reg[0]/C` (rising edge-triggered cell `FDCE` located at `SLICE_X107Y65`, clocked by `clk`).
   - **Endpoint:** `memory/weights_reg_8/DIADI[0]` (rising edge-triggered cell `RAMB18E1` located at `RAMB18_X1Y21`, clocked by `clk`).
   - **Path Type:** Setup (Max at Slow Process Corner).
4. **Cell Delay vs. Routing Delay:**
   - **Total Data Path Delay:** `9.091 ns`.
   - **Cell (Logic) Delay:** `0.379 ns` (`4.169%`).
   - **Net (Routing) Delay:** `8.712 ns` (`95.831%`).
   - **Clock Skew:** `-0.039 ns` (Source Clock Delay: 0.787 ns, Destination Clock Delay: 0.748 ns).
   - **Clock Uncertainty:** `0.035 ns`.
   - **Setup Requirement:** `0.214 ns`.
   - **Slack Derivation:**
     $$\text{Slack} = \text{Required Time } (10.498\text{ ns}) - \text{Arrival Time } (9.878\text{ ns}) = \mathbf{+0.621\text{ ns}}$$
5. **Number of Logic Levels:**
   - **Logic Levels:** **`0`**.
   - There are zero LUTs or combinational gates on the critical path. The signal travels directly from the Q output of register `dma_wr_data_reg[0]` through physical routing net `memory/weights_reg_7_0[0]` (fanout = 28) into Block RAM data input port `DIADI[0]`.
6. **Routing-Dominated Path Nature:**
   - **Confirmed: 95.83% of data path delay is physical wire routing (8.712 ns out of 9.091 ns).**
   - The path spans from slice coordinate $X=107, Y=65$ on the right side of the device to Block RAM column coordinate $X=1, Y=21$ on the left side.
7. **Maximum Operating Frequency ($F_{\text{max}}$) Calculation:**
   - Minimum achievable clock period:
     $$T_{\text{min}} = T_{\text{target}} - \text{WNS} = 10.000\text{ ns} - 0.621\text{ ns} = 9.379\text{ ns}$$
   - Maximum operating frequency:
     $$F_{\text{max}} = \frac{1000}{T_{\text{min}}} = \frac{1000}{9.379\text{ ns}} = \mathbf{106.621\text{ MHz}} \approx \mathbf{106.62\text{ MHz}}$$
   - The calculation is mathematically exact and grounded in standard timing analysis.
8. **Accurate FPGA Terminology Correction:**
   - The target FPGA is an **AMD Xilinx Artix-7 200T (`xc7a200tfbg676-2`)**, which is a **monolithic silicon die**. It does NOT contain stacked silicon dies (SSIT) or interposer micro-bumps (which exist only on large Virtex-7 parts like 2000T).
   - Earlier documentation using the phrase "cross-die routing" was technically inaccurate.
   - The path is correctly documented as an **on-chip long-distance routing path across the monolithic FPGA fabric**.

### Documentation Updates Made
- In `docs/FINAL_ENGINEERING_SIGNOFF.md` (line 46) and `docs/FINAL_VIVADO_REPORT.md` (line 21), replaced `"pure cross-die wire routing"` with `"pure on-chip routing delay of 9.091 ns across the Artix-7 monolithic fabric"`.

---

## CHECK 2: RISC-V SoC Accelerator Adapter Watchdog Behavior

### Verdict
**`PASS`**

### Exact Files Inspected
1. `C:\Users\FLEX\OneDrive\Desktop\PP\RISC-V/rtl/accelerator/accel_adapter.sv` (Lines 38–144)
2. `C:\Users\FLEX\OneDrive\Desktop\PP\RISC-V/software/asm/soc_cnn_inference.s` (Lines 153–162 and 215–224)
3. `C:\Users\FLEX\OneDrive\Desktop\PP\INT8/README.md` (Lines 160–180)
4. `C:\Users\FLEX\OneDrive\Desktop\PP\INT8/docs/SOC_INTEGRATION.md` (Lines 90–115)
5. `C:\Users\FLEX\OneDrive\Desktop\PP\INT8/docs/FINAL_INTEGRATION_COMPATIBILITY.md` (Lines 100–120)
6. `C:\Users\FLEX\OneDrive\Desktop\PP\INT8/docs/FINAL_ENGINEERING_SIGNOFF.md` (Lines 28, 49–54)
7. `C:\Users\FLEX\OneDrive\Desktop\PP\INT8/docs/FINAL_PREPUBLICATION_AUDIT.md` (Lines 21, 394–402, 478)

### Detailed RTL Logic Inspection (`accel_adapter.sv`)
In `accel_adapter.sv`:
```systemverilog
  localparam int WATCHDOG_LIMIT = 65535;
  ...
  state_e state;
  logic [15:0] watchdog_cnt;
  logic        timeout_err;
```
Counter transitions within the adapter FSM:
```systemverilog
  case (state)
    ST_IDLE: begin
      watchdog_cnt <= 16'd0;
      if (req) begin
        if (addr[7:0] == 8'h08 && !we) begin
          rdata_latched <= ADAPTER_VERSION;
          state         <= ST_DONE;
        end else if (we) begin
          state          <= ST_WRITE;
          m_axil_awvalid <= 1'b1;
          m_axil_wvalid  <= 1'b1;
          m_axil_awaddr  <= addr[7:0];
          m_axil_wdata   <= wdata;
          m_axil_wstrb   <= wstrb;
          m_axil_bready  <= 1'b1;
        end else begin
          state          <= ST_READ;
          m_axil_arvalid <= 1'b1;
          m_axil_araddr  <= addr[7:0];
          m_axil_rready  <= 1'b1;
        end
      end
    end

    ST_WRITE: begin
      watchdog_cnt <= watchdog_cnt + 16'd1;
      if (m_axil_awvalid && m_axil_awready) m_axil_awvalid <= 1'b0;
      if (m_axil_wvalid && m_axil_wready)   m_axil_wvalid  <= 1'b0;
      if (m_axil_bvalid && m_axil_bready) begin
        m_axil_bready <= 1'b0;
        state         <= ST_DONE;
      end else if (watchdog_cnt >= WATCHDOG_LIMIT) begin
        m_axil_awvalid <= 1'b0;
        m_axil_wvalid  <= 1'b0;
        m_axil_bready  <= 1'b0;
        timeout_err    <= 1'b1;
        state          <= ST_DONE;
      end
    end

    ST_READ: begin
      watchdog_cnt <= watchdog_cnt + 16'd1;
      if (m_axil_arvalid && m_axil_arready) m_axil_arvalid <= 1'b0;
      if (m_axil_rvalid && m_axil_rready) begin
        rdata_latched <= m_axil_rdata;
        m_axil_rready <= 1'b0;
        state         <= ST_DONE;
      end else if (watchdog_cnt >= WATCHDOG_LIMIT) begin
        m_axil_arvalid <= 1'b0;
        m_axil_rready  <= 1'b0;
        rdata_latched  <= 32'hDEAD_DEAD;
        timeout_err    <= 1'b1;
        state          <= ST_DONE;
      end
    end

    ST_DONE: begin
      state <= ST_IDLE;
    end
  endcase
```

### Critical Findings on Watchdog Scope
1. **What the Watchdog Actually Measures:**
   - **Neither (A) accelerator execution alone NOR (B) the complete multi-layer inference transaction.**
   - It exclusively measures the **duration of an individual AXI4-Lite bus transaction (a single CPU read or write transfer)** across the adapter.
2. **Start Condition:**
   - Begins incrementing from 0 when the CPU issues `req = 1` and the adapter enters `ST_WRITE` or `ST_READ`.
3. **Reset / Stop Condition:**
   - When the AXI4-Lite slave responds with `bvalid` (for write) or `rvalid` (for read), the adapter transitions `ST_WRITE/ST_READ -> ST_DONE -> ST_IDLE`.
   - On entering `ST_IDLE`, line 73 explicitly executes:
     ```systemverilog
     watchdog_cnt <= 16'd0;
     ```
4. **Behavior During Accelerator Compute (53,836 Cycles):**
   - In `software/asm/soc_cnn_inference.s`, the RISC-V core triggers the accelerator by writing `1` to `ACCEL_CTRL` (one 2-cycle write transaction).
   - The CPU then polls the accelerator status register in a tight loop:
     ```asm
     poll_mnist_done:
         lw   t1, 0(t0)     # Read ACCEL_STATUS (MMIO 0x80001004)
         andi t2, t1, 2     # Test DONE bit
         beqz t2, poll_mnist_done
     ```
   - Each `lw` is an **independent AXI4-Lite read transaction**.
   - `accel_top.sv` responds immediately ($1\text{ to }2\text{ clock cycles}$) with `busy=1, done=0`.
   - The adapter returns to `ST_IDLE` after every single read instruction, **resetting `watchdog_cnt` to 0 every 2 clock cycles**.
   - Consequently, `watchdog_cnt` never exceeds 2 cycles during the entire 53,836 cycles of hardware execution.
5. **Resolution of the "11,699-Cycle Margin" Myth:**
   - Previous documentation compared `WATCHDOG_LIMIT = 65,535` against `53,836 cycles` and computed $65,535 - 53,836 = 11,699\text{ cycles}$ (17.85% margin).
   - This comparison arose from a conceptual misunderstanding that the adapter's watchdog was an end-to-end compute timeout that incremented while `accel_busy` was high.
   - In reality:
     - Total SoC run time is **80,874 cycles**.
     - If an end-to-end 65,535-cycle watchdog had existed, the SoC test **would have tripped and failed** at cycle 65,535.
     - Instead, the simulation **passed completely with zero errors** precisely because the watchdog resets on every bus transaction.
   - **Crucial Architectural Distinction:**
     - Accelerator standalone compute latency is reported separately: **53,836 cycles**.
     - Total SoC latency is reported separately: **80,874 cycles**.
     - The watchdog protects individual bus transactions, according to the inspected adapter implementation.
     - The watchdog limit must not be directly compared with full inference latency to claim an inference safety margin.

### Verification via Co-Simulation
Executed the compiled co-simulation binary from `C:\Users\FLEX\OneDrive\Desktop\PP\RISC-V`:
```powershell
cd C:\Users\FLEX\OneDrive\Desktop\PP\RISC-V
vvp bin_riscv_cnn_soc.vvp +CMD=2
vvp bin_riscv_cnn_soc.vvp +CMD=1
```
- **Command 2 (Small CNN):** Completed in 1,073 cycles. Result `0x50084607` matched. Exit code: 0.
- **Command 1 (MNIST Sample 0):** Accelerator compute latency $= 53,836\text{ cycles}$. Total SoC latency $= 80,874\text{ cycles}$. Predicted Class 2 (Score 3). Exit code: 0.
- **RISC-V Workspace State:** Git working tree remained 100% clean (`nothing to commit, working tree clean`). Zero files modified.

### Documentation Updates Made
- In `README.md` (lines 160–175), `docs/SOC_INTEGRATION.md` (Section 5), `docs/FINAL_INTEGRATION_COMPATIBILITY.md` (Section 5), `docs/FINAL_ENGINEERING_SIGNOFF.md` (lines 28, 49–54), `docs/STEP_E_TIMING_OPTIMIZATION.md` (line 174), and `docs/FINAL_PREPUBLICATION_AUDIT.md` (lines 21, 394–402, 478):
  - Removed all claims that the watchdog provides an 11,699-cycle inference headroom.
  - Clarified that the watchdog protects individual AXI4-Lite bus transactions and resets on every status read.
  - Explicitly separated standalone compute latency (53,836 cycles) from total SoC latency (80,874 cycles).

---

## CHECK 3: Rounding and Quantization Rules

### Verdict
**`PASS`**

### Exact Files Inspected
1. `rtl/post_proc.sv` (Lines 76–111)
2. `python/golden.py` (Lines 7–16)
3. `python/quantize.py` (Lines 4–31)
4. `python/quantized_model.py` (Lines 1–70)
5. `tb/tb_directed_arith.sv` (Lines 88–136, 215–250)
6. `docs/QUANTIZATION.md` (Lines 60–95)
7. `README.md` (Lines 50, 70, 84)

### Detailed Source Code & Mathematical Inspection

#### 1. Synthesizable RTL Implementation (`rtl/post_proc.sv`)
Lines 78–110 of `post_proc.sv`:
```systemverilog
// Stage 0 -> 1: 33-bit Signed Biased Sum
if (valid_stage[0]) begin
  for (j = 0; j < N; j = j + 1)
    biased_stage[j] <= $signed({sum_stage[j][ACC_W-1], sum_stage[j]}) +
        $signed(bias_stage[j]);
end

// Stage 1 -> 2: 49-bit Scaled Product
if (valid_stage[1]) begin
  for (j = 0; j < N; j = j + 1)
    product_stage[j] <= $signed({{16{biased_stage[j][ACC_W]}}, biased_stage[j]}) *
        $signed({32'b0, cfg.quant_mult});
  shift_stage[1] <= shift_stage[0];
  relu_stage[1] <= relu_stage[0];
end

// Stage 2 -> 3: Requantization Rounding
if (valid_stage[2]) begin
  for (j = 0; j < N; j = j + 1) begin
    if (shift_stage[1] != 0)
      shifted_stage[j] <= ($signed({product_stage[j][48], product_stage[j]}) +
          (50'sd1 <<< (shift_stage[1] - 1'b1))) >>> shift_stage[1];
    else
      shifted_stage[j] <= $signed({product_stage[j][48], product_stage[j]});
  end
  shift_stage[2] <= shift_stage[1];
  relu_stage[2] <= relu_stage[1];
end

// Stage 3 -> 4: Saturation Clamping & ReLU
if (valid_stage[3]) begin
  out_wr_en <= 1'b1;
  for (j = 0; j < N; j = j + 1) begin
    if (relu_stage[2] && shifted_stage[j] < 0)
      out_wr_data[j*DATA_W +: DATA_W] <= 8'sd0;
    else if (shifted_stage[j] > 127)
      out_wr_data[j*DATA_W +: DATA_W] <= 8'sd127;
    else if (shifted_stage[j] < -128)
      out_wr_data[j*DATA_W +: DATA_W] <= -8'sd128;
    else
      out_wr_data[j*DATA_W +: DATA_W] <= shifted_stage[j][DATA_W-1:0];
  end
end
```

#### 2. Python Golden Reference Implementation (`python/golden.py`)
Lines 7–16 of `golden.py`:
```python
def requantize(accumulator, bias, multiplier, shift, relu=False):
    accumulator = np.asarray(accumulator, dtype=np.int64)
    bias = np.asarray(bias, dtype=np.int64)
    value = (accumulator + bias) * int(multiplier)
    if shift:
        value = (value + (1 << (shift - 1))) >> shift
    if relu:
        value = np.maximum(value, 0)
    return np.clip(value, -128, 127).astype(np.int8)
```

#### 3. Exact Rounding Rule Determination
When $S = \text{shift} \neq 0$, the mathematical rounding formula is:
$$\text{Rounded}(P) = (P + 2^{S-1}) \ggg S$$
where $P$ is the 49-bit signed product and $\ggg$ is arithmetic right shift.

This formula corresponds to **Round-Half-Up (Round half towards $+\infty$, or Add-Half-and-Floor)**:
- At any exact halfway tie, adding $2^{S-1}$ shifts the tie value exactly onto the next higher integer boundary, and the arithmetic right shift floors the result.
- Because it always rounds towards $+\infty$, it is **NOT** Round-to-Nearest-Even (which rounds ties to the even integer).

#### 4. Detailed Boundary & Corner Case Analysis
Evaluated at shift $S = 3$ (where $2^{S-1} = 4$ represents fixed-point $+0.5$, divisor is $2^3 = 8$):

| Product ($P$) | Real Value ($P / 8$) | $(P + 4) \ggg 3$ (RTL & Py) | Round-to-Nearest-Even | Analysis / Tie Resolution |
| :---: | :---: | :---: | :---: | :--- |
| **$+3$** | $+0.375$ | **`0`** | `0` | Immediately below halfway $\rightarrow$ rounds to 0 |
| **$+4$** | **$+0.500$** | **`1`** | **`0`** | **Exact halfway tie: Round-Half-Up rounds to 1 (RNE rounds to 0)** |
| **$+5$** | $+0.625$ | **`1`** | `1` | Immediately above halfway $\rightarrow$ rounds to 1 |
| **$+11$** | $+1.375$ | **`1`** | `1` | Immediately below halfway $\rightarrow$ rounds to 1 |
| **$+12$** | **$+1.500$** | **`2`** | `2` | **Exact halfway tie: Round-Half-Up rounds to 2 (even)** |
| **$+13$** | $+1.625$ | **`2`** | `2` | Immediately above halfway $\rightarrow$ rounds to 2 |
| **$-3$** | $-0.375$ | **`0`** | `0` | Immediately above halfway $\rightarrow$ rounds to 0 |
| **$-4$** | **$-0.500$** | **`0`** | `0` | **Exact halfway tie: Round-Half-Up rounds to 0 (towards $+\infty$)** |
| **$-5$** | $-0.625$ | **`-1`** | `-1` | Immediately below halfway $\rightarrow$ rounds to -1 |
| **$-11$** | $-1.375$ | **`-1`** | `-1` | Immediately above halfway $\rightarrow$ rounds to -1 |
| **$-12$** | **$-1.500$** | **`-1`** | **`-2`** | **Exact halfway tie: Round-Half-Up rounds to -1 (towards $+\infty$; RNE rounds to -2)** |
| **$-13$** | $-1.625$ | **`-2`** | `-2` | Immediately below halfway $\rightarrow$ rounds to -2 |

**Key Mathematical Insights:**
- At $P = +4$ ($+0.5$), the hardware yields `1`, whereas RNE would yield `0`.
- At $P = -12$ ($-1.5$), the hardware yields `-1`, whereas RNE would yield `-2`.
- Both RTL and Python `golden.py:requantize` produce identical outputs for 100% of cases.

#### 5. Signed Right Shifts, Zero Shift, Multiplier, and Saturation Behavior
- **Signed Shifts:** SystemVerilog's arithmetic right shift (`>>>`) preserves the two's complement sign bit. In Python, the `>>` operator on signed integers implements arithmetic right shift (floor division by $2^{\text{shift}}$), which matches bit-for-bit.
- **Zero Shift ($S = 0$):** When `shift == 0`, both implementations bypass the addition of half and right shift, outputting the scaled product directly.
- **Requantization Multiplier & Shift:** Multipliers $M \in [0, 65535]$ and shifts $S \in [0, 31]$ are calibrated offline.
- **Overflow Protection (33-bit Signed Sum):**
  - In `post_proc.sv`, line 78 adds 32-bit partial sum and 32-bit bias into a 33-bit signed accumulator (`biased_stage`).
  - Standard 32-bit signed addition of extreme negative numbers (e.g. $-2,000,000,000 + -2,000,000,000 = -4,000,000,000$) overflows to positive $+294,967,296$.
  - The 33-bit intermediate preserves the negative sign and clamps properly to $-128$.
- **Saturation Clamping:** Saturated to standard 8-bit two's complement range: values $> 127$ clamp to $+127$, values $< -128$ clamp to $-128$.
- **ReLU:** Clamps all negative values to $0$.

#### 6. Disambiguation of Offline vs. Runtime Quantization
- **Offline Model Quantization (`python/quantize.py`):**
  - Functions `quantize_tensor`, `quantize_bias`, and `quantize_activation` use `np.rint(values / scale)`.
  - `np.rint` in NumPy implements floating-point round-to-nearest-even. This is used solely during offline tensor conversion from PyTorch FP32 weights to integer weights/biases.
- **Runtime Inference (`rtl/post_proc.sv` and `python/golden.py`):**
  - Operates purely on integers and uses **Round-Half-Up**.

### Focused Test Evidence
1. **Targeted Python Corner Test Suite (`python/test_arithmetic_corners.py`):**
   Executed:
   ```powershell
   python python\test_arithmetic_corners.py
   ```
   **Output:**
   ```
   === 1. RTL vs Python Golden Model Bit-Exact Cross-Check ===
   PASS: Baseline RTL model matches Python golden.py:requantize bit-exact.

   === 2. Rounding Rule Discrimination (Halfway & Boundary Analysis) ===
   Case Description                 | RTL/Golden | Round-Half-Up | Nearest-Even
   ---------------------------------------------------------------------------
   P=3  (+0.375, below half)        | 0          | 0             | 0
   P=4  (+0.500, exact halfway tie) | 1          | 1             | 0
   P=5  (+0.625, above half)        | 1          | 1             | 1
   P=11 (+1.375, below half)        | 1          | 1             | 1
   P=12 (+1.500, exact halfway tie) | 2          | 2             | 2
   P=13 (+1.625, above half)        | 2          | 2             | 2
   P=-3 (-0.375, above half)        | 0          | 0             | 0
   P=-4 (-0.500, exact halfway tie) | 0          | 0             | 0
   P=-5 (-0.625, below half)        | -1         | -1            | -1
   P=-11 (-1.375, above half)       | -1         | -1            | -1
   P=-12 (-1.500, exact halfway tie) | -1         | -1            | -2
   P=-13 (-1.625, below half)       | -2         | -2            | -2

   CONCLUSION:
   - At P=4 (+0.5): Actual RTL rounds to 1 (RNE would round to 0).
   - At P=-12 (-1.5): Actual RTL rounds to -1 (RNE would round to -2).
   => The actual hardware and golden model implement ROUND-HALF-UP (round half towards +infinity).
   => They do NOT implement round-to-nearest-even.

   === 3. 33-bit Signed Bias Overflow Immunity ===
   PASS: Extreme sum (-2000000000) + bias (-2000000000) clamped to -128 (no positive overflow wrap).

   === 4. Shift Range & Saturation Sweep ===
   PASS: Exhaustive sweep of values across shifts 0..30 matches bit-exact between RTL and Python.

   ALL TARGETED ARITHMETIC CHECKS PASSED SUCCESSFULLY!
   ```
   **Exit Code:** 0.

2. **SystemVerilog Directed Arithmetic Regression (`tb/tb_directed_arith.sv`):**
   Executed via Icarus Verilog:
   ```powershell
   iverilog -g2012 -s tb_directed_arith -o build/tb_directed_arith.vvp rtl/cnn_pkg.sv rtl/pe.sv rtl/post_proc.sv tb/tb_directed_arith.sv
   vvp build/tb_directed_arith.vvp
   ```
   **Output:**
   ```
   === STARTING DIRECTED ARITHMETIC & CORNER-CASE TESTS ===
   [TEST] A. PE Signed Multiplication Corners
   [TEST] B. 33-bit Bias Addition Intermediate (Extreme Sums)
   [TEST] C. Fixed-Point Requantization Rounding Thresholds
   [TEST] D. Saturation Boundaries & Zero Shift
   [TEST] E. ReLU Activation Behavior
   [TEST] F. Max-Pooling with Strict Signed Comparisons
   === ALL DIRECTED ARITHMETIC & CORNER-CASE TESTS PASSED ===
   ```
   **Exit Code:** 0.

3. **Full SystemVerilog 10-Testbench Regression (`scripts/verify.ps1`):**
   Executed:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\scripts\verify.ps1
   ```
   - `tb_pe`: PASS
   - `tb_pe_array`: PASS
   - `tb_post_proc`: PASS
   - `tb_directed_arith`: PASS
   - `tb_mem_ctrl_random`: PASS
   - `tb_mem_ctrl_zero_scan`: PASS
   - `tb_ctrl_unit`: PASS
   - `tb_top`: PASS
   - `tb_full_cnn`: PASS (9,812 outputs matched bit-exact, 53,836 cycles)
   - `tb_repeated_inference`: PASS (2 consecutive runs bit-exact)
   **Exit Code:** 0.

### Documentation Updates Made
- In `docs/QUANTIZATION.md` (Section 3), replaced fictitious pseudo-code (`round_bit`, `fraction_bits`, `lsb_bit`) with actual `post_proc.sv` RTL code (lines 90–94) and documented Round-Half-Up arithmetic.
- In `README.md` (lines 50, 70, 84), `docs/ARCHITECTURE.md` (line 92), and `docs/VERIFICATION.md` (lines 51–52), replaced references to "round-to-nearest-even" with "round-half-up (add half and arithmetic right shift / round half towards $+\infty$)".

---

## Synthesizable RTL & RISC-V Integrity Certification

### Synthesizable RTL Hashes in `INT8/rtl` (Unchanged)
| Module | File Size | SHA-256 Checksum | Status |
| :--- | :---: | :--- | :---: |
| `accel_top.sv` | 7,826 B | `2f39a97573234fb4a018099056a9aeec14f8dbb4392fd6d71c11cadfcdde2ff9` | **FROZEN** |
| `cnn_pkg.sv` | 736 B | `bed67eeb3aa8f912ac3e5854f29a410cb27186baaa6c18bed8938bb1d792d717` | **FROZEN** |
| `ctrl_unit.sv` | 3,390 B | `0368b3e73d7f244ea1b2f9ff46457a042f0f1236139c5350ab28fd553b430dc1` | **FROZEN** |
| `mem_ctrl.sv` | 24,226 B | `228fd166cf360f2a5eae368c9cdee5b26d68df4c2da6d6388ac0e34fea690c73` | **FROZEN** |
| `pe.sv` | 897 B | `9def071cea5db581b36965aa9e9147a3068551cbc581d89f7aa06d87c0bdaae9` | **FROZEN** |
| `pe_array.sv` | 3,872 B | `42017565c468522d41260911e97a1ba5aa6a07c09238cf0312c7e352fb41029a` | **FROZEN** |
| `post_proc.sv` | 4,735 B | `63590797103e135f50dcca93094ec668c8e520076f40735e01e11ee3f3fabcc7` | **FROZEN** |

### RISC-V Repository Status (`C:\Users\FLEX\OneDrive\Desktop\PP\RISC-V`)
```
On branch main
Your branch is up to date with 'origin/main'.

nothing to commit, working tree clean
```
Zero files modified, deleted, or staged. 100% read-only integrity preserved.

---

## Summary of Disclosed Engineering Limitations

To maintain strict academic and professional credibility, the following limitations are explicitly disclosed:
1. **Out-of-Context Implementation:** The accelerator core was synthesized, placed, and routed in AMD Vivado 2026.1 in Out-of-Context (`-mode out_of_context`) mode without pin constraints (`PACKAGE_PIN`). No bitstream was generated (`write_bitstream` was not run).
2. **Simulation-Grade Verification:** Verification was performed using Icarus Verilog simulation and Python integer golden models. No physical FPGA development board (e.g. Digilent Nexys Video) was connected or tested.
3. **Dataset Scope:** Full 10,000-image accuracy ($96.44\%$) was measured using the Python integer golden model. RTL simulation verified bit-exact numerical agreement ($0\text{ mismatches}$ across 9,812 intermediate and final layer words) for deterministic test vectors.
4. **Adapter Watchdog Role:** The 65,535-cycle watchdog in `accel_adapter.sv` monitors individual AXI4-Lite bus handshakes, not multi-thousand-cycle inference execution.

---

## Final Publication Verdict

### **`READY TO PUBLISH WITH DISCLOSED LIMITATIONS`**

**Grounds for Verdict:**
- All three targeted checks (Critical-Path Timing, Watchdog Behavior, Rounding & Quantization) pass with direct, reproducible tool evidence.
- Public documentation has been reconciled and purged of historical inaccuracies (fictitious RNE code, 11,699-cycle watchdog margin myth, and cross-die terminology).
- Synthesizable RTL and the companion RISC-V repository are completely untouched and verified.
- The project is technically sound, reproducible, and ready for public GitHub release.

---

## Remaining Manual Steps for Repository Owner

Execute the following commands in PowerShell from `C:\Users\FLEX\OneDrive\Desktop\PP\INT8` when ready to publish:

```powershell
cd C:\Users\FLEX\OneDrive\Desktop\PP\INT8

# 1. Initialize local Git repository
git init

# 2. Stage all tracked files (.gitignore excludes simulation binaries, .vvp, .log)
git add .

# 3. Check git status to confirm no temporary files are staged
git status

# 4. Commit the initial public release
git commit -m "feat: initial public release of 100 MHz INT8 CNN accelerator IP core"

# 5. Set default branch to main
git branch -M main

# 6. Add your GitHub remote repository URL
git remote add origin https://github.com/<your-username>/athena-int8-cnn-accelerator.git

# 7. Push to GitHub
git push -u origin main
```
