# Build State

## Current checkpoint (2026-10-06)

- The workspace has no `.git` directory; Git status, diff, history, and local commits are unavailable. The pasted recovery instructions and current source files were read in full. No repository rollback was performed.
- `post_proc` keeps the public interface and now registers sum, bias, multiply, round/shift, and ReLU/saturation work. Directed cases cover signed rounding, shift zero, ReLU, saturation, bias, multi-chunk accumulation, and pooling.
- Fixed the `tb_full_cnn` reset-edge race: reset is deasserted on the falling edge before the instruction memory is initialized. The previous observed descriptor rejection was caused by testbench reset ordering; after the correction, every packed layer word matches its generated Python vector.
- The pipeline requires the memory controller to wait until final-chunk output writes are accepted before advancing. This wait is retained and verified at full-network scale.
- Added simulation-only assertions for mutually exclusive post-processing inputs, memory-controller dispatch/write lifecycle, and the supported descriptor guard on zero-channel skipping. Assertions are enabled in Icarus runs.
- Added `tb/tb_mem_ctrl_random.sv`: seed `0x51a7c0de`, 600 randomized DMA byte writes across weights, feature buffers, and biases, plus 200 randomized result-byte reads. The storage model and each returned byte are checked.
- Added `tb/tb_mem_ctrl_zero_scan.sv`: checks the zero-lane detector selects the one-row path for all-zero upper bytes and the four-row path when an upper byte is nonzero.
- Implemented one optimization: when a 28x28, four-lane, 3x3 MNIST convolution is dispatched, scan all 784 input words and skip three of four weight-row loads only if all upper three bytes are zero. Other descriptors or nonzero lanes use the baseline row-load path. The flag clears at layer completion.
- Before/after full smoke: 55,677 clocks (pipeline-only run before the optimization) versus 53,815 clocks after it, a reduction of 1,862 clocks or 3.34%. Current trained AXI/DMA sample: indices 0-9, 10/10 passed, 120/120 output bytes matched, 0 mismatches, 53,815 clocks/image. This is a small smoke sample, not a 5,000-image rerun.
- Current regression command: `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/verify.ps1 -PythonExe 'C:\Users\FLEX\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'`. It passes eight testbenches: PE, PE array, post_proc, randomized mem_ctrl, zero-scan fallback, control, AXI integration, and full-network layer comparison. The synthetic-vector run now backs up and restores an existing `vectors/smoke` directory; the trained-vector weights hash was verified unchanged across the run.
- Current Yosys 0.66 generic coarse result: 2,075 cells, four `$mem_v2` blocks retaining 425,984 bits, 63 `$adff`, 243 `$adffe`, 41 `$macc_v2`; `check` reports zero problems. The report is `synth/reports/yosys_current_coarse.log`; resumable RTLIL is `synth/reports/current_coarse.rtlil`.
- Generic memory mapping expands the storage to 12,544 wide DFF cells and extensive mux logic. The iCE40 FPGA mapping attempt exceeded the practical memory limit before final statistics; it provides no target resource or timing result. No part or timing constraints are available, so LUT, distributed RAM, BRAM, FPGA FF/DSP, Fmax, and critical path remain unavailable.
- Build helpers are in `Makefile` (`test`, `sim`, `synth`, `clean`). Python on this host must be overridden to the bundled runtime because PATH's MSYS2 Python lacks NumPy.
- Final rerun on 2026-10-06: `make test PYTHON='C:\Users\FLEX\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'`, `make sim`, and `make synth` all exited 0. The suite reports eight passing benches; the full synthetic run matched every layer boundary in 53,815 clocks. Icarus emits known constant-select notices in `always_comb`.
- Current coarse Yosys synthesis reports 2,075 generic cells, four `$mem_v2` blocks containing 425,984 bits, and zero `check` problems. A current FPGA mapping trial did not reach final target statistics before the process memory limit; temporary large outputs were removed.
- Current Verilator 5.050 lint exits 0 with `-Wno-fatal`; width conversions, unused descriptor bits, unnamed generate blocks, and reset-usage warnings remain. Icarus prints constant-select limitation notices. No broad width refactor was made because the established address arithmetic is covered by the passing regression.
- `make clean` removes generated contents of `build/`. `make synth` recreates the output directories and retains the coarse report and checkpoint under `synth/reports/`.
- The previous 5,000-image RTL run predates current RTL changes and must not be presented as current verification. A full 5,000-image rerun is not practical in this session; strongest current end-to-end check is 10 trained images plus the full-shape, every-layer synthetic comparison.

## Completed phases

- Source review: read the 30-page accelerator guide, the supplied SystemVerilog public interface, and the pasted implementation brief.
- RTL implementation: created and connected the package, PE, PE array, post-processor, memory controller, instruction controller, and AXI-Lite top.
- Python implementation: created integer golden operations, quantization helpers, a PyTorch MNIST training model, and the model exporter.
- Final verification phase: component and system simulations pass; full-shape deterministic output matches the Python integer model.

## Files created

- `.gitignore`
- `README.md`
- `docs/ARCHITECTURE.md`
- `docs/BUILD_STATE.md`
- `python/export_vectors.py`
- `python/evaluate_mnist.py`
- `python/generate_full_smoke.py`
- `python/golden.py`
- `python/quantize.py`
- `python/quantized_model.py`
- `python/requirements.txt`
- `python/train.py`
- `rtl/accel_top.sv`
- `rtl/cnn_pkg.sv`
- `rtl/ctrl_unit.sv`
- `rtl/mem_ctrl.sv`
- `rtl/pe.sv`
- `rtl/pe_array.sv`
- `rtl/post_proc.sv`
- `scripts/verify.ps1`
- `tb/tb_ctrl_unit.sv`
- `tb/tb_full_cnn.sv`
- `tb/tb_pe.sv`
- `tb/tb_pe_array.sv`
- `tb/tb_post_proc.sv`
- `tb/tb_top.sv`
- `vectors/smoke/weights.hex`, `biases.hex`, `instructions.hex`, `input.hex`, and per-layer golden files (generated by the smoke-vector script)

## Files modified

- `rtl/post_proc.sv`: made the widened accumulator operand signed before adding the signed INT32 bias.
- `tb/tb_full_cnn.sv`: compares every packed word at each layer boundary.
- `python/golden.py`, `python/quantized_model.py`, `python/export_vectors.py`, and `python/evaluate_mnist.py`: share fixed calibration, quantized parameter generation, HWC FC weight order, and the integer model used for evaluation/export.
- `docs/BUILD_STATE.md` and `README.md`: recorded the root cause and rerun results.
- `tb/tb_top.sv`: added an optional AXI/DMA batch mode that compares all twelve result bytes per image.
- `python/run_rtl_5000.py`: added batched top-level execution, exact integer golden-vector generation, durable per-image progress, checkpoint files, aggregate results, and timeout resume support for a fixed 5,000-image target.
- `python/run_rtl_manual.py`: added one-image raster/NumPy input, fixed-scale integer golden generation, AXI/DMA top-level execution, score decoding, and per-run debug artifacts under `artifacts/manual/`.

## Pre-change baseline status

Fixed-scale INT8 evaluation is complete on all 10,000 MNIST test images. The final RTL regression target is exactly 5,000 MNIST test images, indices 0-4,999. The complete AXI/DMA-driven top-level run passed all 5,000 images with zero output-byte mismatches against the Python integer golden model; image 5,000 and higher were not run. Ten stratified RTL vectors, one per class, also match at every layer boundary and final output. For hardware characterization, the source RTL was converted only in `build/generated/accel_top.v` using sv2v v0.0.13. Yosys coarse synthesis completed from a saved process-lowered RTLIL checkpoint while retaining the four large memories as `$mem_v2` cells. Full fine mapping did not complete; the previous run stopped during ABC extraction for `post_proc`.

## Last successful compile command

`iverilog -g2012 -s tb_full_cnn -o %TEMP%\\tb_full_cnn.vvp rtl\\cnn_pkg.sv rtl\\pe.sv rtl\\pe_array.sv rtl\\post_proc.sv rtl\\mem_ctrl.sv rtl\\ctrl_unit.sv rtl\\accel_top.sv tb\\tb_full_cnn.sv`

Exit code: 0. The test completed at 55,677 counted clocks and matched the 12 Python-generated final output bytes.

## Current known issues

- The full-shape regression uses a deterministic sparse integer network; it is not a trained MNIST checkpoint run.
- The trained checkpoint is `artifacts/mnist_cnn.pt`, produced with PyTorch 2.14.1 and TorchVision 0.29.1 using the documented three epochs. Mean training losses were 0.60524, 0.19867, and 0.14438.
- FP32 accuracy is 9,639/10,000 (96.39%), with 361 errors, on the standard MNIST test set.
- Fixed-scale INT8 accuracy is 9,644/10,000 (96.44%), with 356 errors, on the same test set. Calibration used a deterministic 1,024-image subset of MNIST training data selected with NumPy `default_rng(2027)`.
- Fixed input scale is 1/127. Fixed activation scales are 0.026722975603238806, 0.09152670732633335, and 0.2574637105145792. The derived `(quant_mult, quant_shift)` values for CONV1, CONV2, and FC are `(46477,25)`, `(42739,25)`, and `(46610,25)`. The exporter and evaluator load the same `artifacts/mnist_int8_calibration.json` manifest and use the shared parameter builder and integer model.
- The FC exporter permutes trained PyTorch CHW flatten weights to the HWC feature order read by the accelerator before quantization. This is required for the integer model to represent the trained network's feature ordering.
- Trained-vector export produced 1,392 weight words, 7 bias words, and 6 instructions. At layer-0 output word 1, HWC pixel `(0,0)` channels 4-7 occupy little-endian lanes 0-3. The input word was `0x00000000`, weight words for output group 1/chunk 0 were `0x3e5e55de`, `0x22eb0c0f`, `0xe5230aec`, and `0x16e504e8`, and the PE/accumulated sums for this pixel were zero. Bias lane 0 was `-3768`; `quant_mult=49406` (unsigned 16-bit), `quant_shift=25`. Python post-bias/scaled/rounded/ReLU output was `-3768`, `-186161808`, `-6`, and `0`.
- Root cause: the concatenated accumulator operand in `post_proc.sv` was unsigned. In the bias addition this caused negative signed INT32 bias `-3768` to zero-extend to `4294963528`; the result then requantized positive and saturated to `127`. Explicitly casting the widened accumulator operand to signed fixed the addition without changing architecture. The first divergence was post-bias, not input/weight packing, PE arithmetic, accumulation, quantization, ReLU, or saturation.
- Ten RTL vectors, one per class, passed every layer-word and final-byte comparison: 24,530 packed layer words and 120 final bytes compared, zero mismatches. Each accelerator run used 55,677 counted execution clocks/image; total for the subset was 556,770 counted clocks. The testbench preloads memories, so this excludes host DMA and result-read overhead.
- Representative test indices were 0, 1, 2, 3, 4, 7, 8, 11, 18, and 61, covering labels 7, 2, 1, 0, 4, 9, 5, 6, 3, and 8. Their packed vectors are retained in `vectors/mnist_rtl_subset/<index>`; `vectors/smoke` holds the fixed-scale index-0 vector set.
- The measured accuracy report is `artifacts/mnist_int8_evaluation.json`; its calibration manifest is `artifacts/mnist_int8_calibration.json`. The original checkpoint remains unchanged.
- The final RTL verification target is images 0-4,999 (5,000 images). All 5,000 completed; all 60,000 final output bytes matched Python, and no image at index 5,000 or above was run.
- The full-shape testbench preloads internal memories for simulation speed. The separate AXI-driven integration test covers host writes, instruction commits, result reads, and buffer swaps.
- Verilator launch diagnosis: `Get-Command verilator` and `where.exe verilator` resolve unambiguously to `C:\msys64\ucrt64\bin\verilator`. That path is a 32,095-byte Perl script with a `#!/usr/bin/env perl` shebang, not a Windows executable. Its companion `verilator_bin.exe` exists, and the MSYS2 UCRT64 package is installed. Direct PowerShell process creation of the extensionless script fails with `Access is denied`; the Windows ACL grants the user read/execute, so this is not an ACL/executable-permissions problem. The companion `verilator_bin.exe --version` runs directly from PowerShell, as does `yosys.exe -V`, so system-wide executable blocking is not indicated. There is no PATH ambiguity: the issue is invoking the Unix Perl wrapper as a Windows process rather than through its MSYS2 shell. Explicitly launching through `C:\msys64\usr\bin\bash.exe` with `/ucrt64/bin` prepended to PATH runs the standard Verilator wrapper 5.050 successfully. The first-run MSYS2 setup cannot create `/home/CodexSandboxOffline`, falls back to `/tmp`, and still launches the tools.
- `wsl --status` and `wsl -l -q` fail with `Wsl/EnumerateDistros/Service/E_ACCESSDENIED`, so the documented WSL/Linux fallback is currently unavailable in this Windows session.
- Yosys 0.66 was installed from the existing MSYS2 UCRT64 package repository (`mingw-w64-ucrt-x86_64-yosys`). `read_verilog -sv` rejects package imports, and `help read_slang` confirms no `read_slang` command. A local sv2v v0.0.13 executable is stored in `synth/tools/sv2v-v0.0.13/`. It converted all RTL into `build/generated/accel_top.v`; the four `mem_ctrl` arrays have `nomem2reg` attributes in this generated-only copy to preserve memory inference. Source RTL was not modified. A Yosys-Slang plugin build reached linking but failed with MinGW `export ordinal too large: 85560`; no plugin was produced.
- A Verilator lint run using `--lint-only -Wall -Wno-fatal --top-module accel_top` exits 0. Warnings include unnamed generate blocks, width expansion/truncation, unused signal bits, and inferred latches in `post_proc.sv`; therefore lint is not warning-free. The Yosys coarse-stage `check` found zero problems. The later memory-mapped `check` did not finish before the resource cap; no target timing or critical-path report is available.
- N=4 remains the baseline (`cnn_pkg.sv` sets `N=4`). Yosys generic `coarse` synthesis completed and `check` reported zero problems. Its hierarchical statistics report 1,992 cells, including 62 `$adff`, 215 `$adffe`, 155 `$alu`, 41 `$macc_v2`, 4 `$mem_v2`, 505 `$mux`, and the other generic cell types recorded in `synth/reports/yosys_coarse_synth.log`. These are generic coarse-stage cells, not technology-mapped FPGA resources. Before synthesis lowering, 4 inferred memories totaling 425,984 bits were reported. No FPGA target/device, timing constraints, or target cell library were provided/used. LUTs, target FF/DSP counts, Fmax, and critical path are unavailable. Consequently images/second (`Fmax/55,677` with consistent frequency units) and peak GOPS (`32*Fmax_MHz/1000`) cannot be calculated from measured values.
- The design targets the documented MNIST dimensions and fits their feature maps into the specified 4096-word buffers. Larger layer capacity and irregular channel counts are not verified.

## Architectural decisions

- Preserved the public package configuration fields and all accelerator module interfaces from the supplied skeleton.
- Kept generated source files free of comments.
- Used a synchronous registered read stage for activation, weight, bias, pooling, and result memory access.
- Used explicit stream and pooling x/y counters for feature-map address generation.
- Used explicit input skew and output deskew around registered PE cells, with a seven-cycle tag path for N=4.
- Used signed INT8 products, INT32 accumulators, and a 49-bit multiply result with a 50-bit rounding/shift path.
- Kept training in PyTorch and inference/reference arithmetic in deterministic integer Python.

## Synthesis resume record for pre-change RTL

The following detailed synthesis notes describe earlier characterization and checkpoints. The current RTL coarse result is recorded in the current checkpoint at the top of this file.

- Previous full generic run was incomplete during ABC extraction of `post_proc`. Its 69,646,024-byte partial log was removed during generated-file cleanup; it contained no final design statistics or completed resource result.
- No Yosys process remained running. No prior `.il`, `.rtlil`, JSON, BLIF, mapped netlist, or database was present. The previous in-memory state could not be resumed.
- Existing generated input: `build/generated/accel_top.v`, 33,630 bytes, modified 2026-10-04 19:32:23 local time. Existing frontend/process log: `synth/reports/yosys_frontend_stat.log`, 128,992 bytes, modified 19:32:31. It reports 81 processes before `proc`, 544 cells before lowering, then zero processes and 3,248 cells after lowering. Both stages report four memories totaling 425,984 bits.
- The previous full generic command was `read_verilog build/generated/accel_top.v; hierarchy -check -top accel_top; stat -top accel_top; proc; stat -top accel_top; synth -top accel_top; stat -top accel_top`.
- Resumed with the minimum necessary re-elaboration because the earlier Yosys in-memory state was lost: `read_verilog build/generated/accel_top.v; hierarchy -check -top accel_top; proc; write_rtlil synth/reports/process_lowered.rtlil; stat -top accel_top`. This produced the reusable 1,506,078-byte checkpoint `synth/reports/process_lowered.rtlil`.
- Continued without repeating frontend or process lowering using `read_rtlil synth/reports/process_lowered.rtlil; synth -top accel_top -run coarse; stat -top accel_top; write_rtlil synth/reports/coarse_synth.rtlil; check`. Exit code 0; `check` found and reported 0 problems. The coarse result is 1,992 generic cells, 2,530 wires/38,701 wire bits, four `$mem_v2` cells, and no process cells. The report has 62 `$adff`, 215 `$adffe`, 155 `$alu`, 41 `$macc_v2`, and 505 `$mux` cells. See `synth/reports/yosys_coarse_synth.log` or the separate stats log for every cell type. Coarse mapping does not provide technology-specific LUTs/DSPs or meaningful mapped cell totals.
- A trial invocation used `check -top accel_top`, unsupported by Yosys 0.66; it exited at that option after synthesis. The corrected `check` command passed. That failed trial log was overwritten by the successful complete log; its command syntax error was not a design warning.
- Captured standalone final coarse statistics with `read_rtlil synth/reports/coarse_synth.rtlil; stat -top accel_top; check` in `synth/reports/yosys_coarse_stat.log`; it also exited 0 and reported zero check problems.
- Installed target-flow probe found no Vivado, Quartus, or nextpnr executable. There is no selected FPGA part or timing constraint file. Thus Fmax, critical path, mapped resource utilization, images/sec, and peak GOPS remain unavailable. Do not treat partial ABC module statistics from the interrupted mapping run as completed results.
- Bounded memory-mapping experiment started directly from `synth/reports/coarse_synth.rtlil` with Yosys 0.66 command `read_rtlil synth/reports/coarse_synth.rtlil; memory_map; stat -top accel_top; write_rtlil synth/reports/memory_mapped.rtlil; check`. It did not repeat conversion, hierarchy, or process lowering. The `memory_map` pass completed: weights became 4,096 width-32 `$dff` cells, biases 256 width-128 `$dff` cells, and each feature memory 4,096 width-32 `$dff` cells, representing 425,984 storage bits total. The four memories were expanded into logic and no `$mem_v2` cells remained. Pre-check stats in `synth/reports/memory_map_experiment.log` report 908,630 hierarchical generic cells, 950,636 wires/3,655,845 wire bits, 12,544 `$dff` cells for the wide memory entries, 62 `$adff`, 217 `$adffe`, 155 `$alu`, 41 `$macc_v2`, 439,121 `$and`, and 455,409 `$mux` cells. No FPGA resource interpretation is implied.
- The memory-map experiment ran 14.54 seconds and was sampled every 0.5 seconds. Its configured boundary was 120 seconds or 2 GiB private memory. The measured peak was 2,087.4 MiB private memory and 1,988.9 MiB working set (the private-memory limit was crossed between samples). Yosys had written `synth/reports/memory_mapped.rtlil` (377,663,126 bytes, ending with an RTLIL `end`) after completing mapping/statistics, then entered `check`; the process was terminated at the memory limit before `check` could report. Thus mapping statistics and the generated experiment artifact exist, but post-map `check` is unverified. A first PowerShell invocation failed before loading the design because argument quoting was wrong; its 116-byte error is preserved in `synth/reports/memory_map_experiment.err`. The actual run's stderr is empty.
- The memory-mapped representation expanded from 1,992 coarse cells to 908,630 generic cells and a 377,663,126-byte RTLIL file. The expanded RTLIL was removed during cleanup after its statistics were recorded above. Keep the coarse RTLIL as the useful checkpoint.

## Current synthesis limits

- A second iCE40 mapping attempt used the current converted RTL and stopped before final statistics when memory mapping reached about 1.84 GiB private memory. Its 43 MB partial log was removed during cleanup. The Yosys flow mapped feature memory into individually enabled DFFs; it did not produce LUT/FF/DSP/BRAM counts or timing.
- The most recent complete resource-like report is generic coarse synthesis from the current RTL, not FPGA mapping. No selected device or timing constraints are available, and a completed place-and-route tool is absent.
- The former 5,000-image verification applies to the pre-change RTL. Current verification is documented in the checkpoint at the top of this file.

## Baseline verification status (before 2026-10-06 RTL changes)

- PE signed MAC test: passed.
- PE-array signed lane and tag alignment test: passed.
- Post-processing requantization, shift-zero, rounding, ReLU, saturation, bias, multi-chunk, and pooling test: passed.
- Control descriptor rejection test: passed.
- AXI-driven tiny CONV/POOL/FC and result-byte test: passed.
- Full 28x28 CONV/POOL/CONV/POOL/FC deterministic comparison against Python: passed, 55,677 clocks.
- Icarus full-top elaboration: exit code 0.
- Verilator 5.050 `--lint-only -Wall -Wno-fatal --top-module accel_top`: exit code 0 when launched through MSYS2 Bash; warnings remain as recorded above.
- Fixed-calibration Python evaluation: passed on all 10,000 MNIST test images; FP32 9,639 correct, INT8 9,644 correct.
- Fixed-calibration RTL representative subset: passed on 10 images covering all ten labels; 24,530 layer words and 120 final bytes matched, zero mismatches; 55,677 counted clocks/image.
- 5,000-image RTL target: passed on exactly indices 0-4,999 through the AXI/DMA top-level path. All 5,000 images passed bit-for-bit output comparison (60,000 bytes, zero mismatches). RTL and Python INT8 each classified 4,756/5,000 correctly (95.12%). No full 10,000-image RTL verification is claimed. The separate ten-image stratified per-layer set remains the layer-boundary comparison result.
- Synthesis: Yosys 0.66 `coarse` stage completed from the saved RTLIL checkpoint. It reports 1,992 generic cells including four `$mem_v2`, and `check` found zero problems. One bounded `memory_map` experiment from that checkpoint completed mapping and reported 908,630 generic cells, but crossed the 2 GiB private-memory cap during post-map `check`; the expanded output is an experiment artifact, not the resume checkpoint. Full fine/ABC mapping did not finish; the earlier run stopped while mapping `post_proc`. No device-specific resource, timing, critical-path, or throughput result is available.

## Pre-change 5,000-Image AXI Top-Level MNIST Evaluation

- The batch runner uses the existing trained checkpoint and fixed calibration manifest, recomputes each image's integer Python golden outputs, programs the accelerator through AXI/DMA, and reads and compares all twelve returned bytes. It does not preload internal accelerator memories.
- Repeated inference was exercised within every 100-image simulator batch: the testbench writes weights, biases, and instructions once per batch, resets the DMA byte address before each new image, issues START between inferences, checks STATUS for idle + DONE with no error, and reads back all twelve result bytes. Every repeated image matched its fresh Python golden output, providing an end-to-end check against stale input/result or ping-pong state.
- Final run status: PASS on exactly 5,000 images, indices 0-4,999. All 5,000 AXI/DMA inferences passed; all 60,000 output bytes matched, with zero failed images and zero mismatched bytes. No image 5,000 or higher was started.
- Python INT8 and RTL accuracy on the same first 5,000 MNIST test images were both 4,756/5,000 (95.12%), with 244 incorrect classifications for each. Bit-exact RTL/Python output equivalence is distinct from classification accuracy: all outputs matched even where the model classified an image incorrectly.
- Execution measured 55,677 accelerator clocks/image and 278,385,000 total clocks. `summary.json` records 35,537.35 seconds cumulative runner runtime. An interrupted partial attempt before the durable resume point was not checkpointed, so exact end-to-end wall-clock runtime is unavailable; the recorded runtime excludes that unrecorded attempt and downtime.
- The audit found 5,000 contiguous rows in `artifacts/rtl_5000/results.csv`, spanning 0-4,999, plus 50 contiguous 100-image batch checkpoints. The final `batch_04900_04999.json` records 100 attempted, 100 passed, 0 failed, 0 mismatches, 5,567,700 clocks, and last completed image 4,999. `summary.json`, `results.csv`, `failures.txt`, per-batch CSVs, and logs are retained in `artifacts/rtl_5000/`. The earlier verified 0-199 records were preserved; resumed execution began with the first unfinished index and did not rerun completed passing images.
- The runner remains resumable: `python python/run_rtl_5000.py --backend iverilog --batch-size 100 --max-batches 1` advances one batch from the next durable checkpoint; omit `--max-batches 1` to continue until index 4,999. Per-image progress is flushed during each batch.
- Verilator 5.050 was retried but its generated C++ failed to link with unresolved `std::__cxx11::basic_string` move-constructor symbols using MSYS2 GCC 16.2; a Clang 22.1.8 retry failed because installed C++ headers reference unavailable coroutine builtins. The completed 5,000-image run therefore used Icarus.

## Manual Single-Image Inference

- `python/run_rtl_manual.py` runs exactly one supplied image through the fixed trained checkpoint and fixed calibration manifest, then invokes the same AXI/DMA batch mode in `tb/tb_top.sv` with an image count of one. It uses the existing accelerator RTL and does not change or invoke the 5,000-image regression.
- The trained model's exact input transform is `torchvision.transforms.ToTensor()` on MNIST's 28x28 grayscale PIL image. There is no training-time resize, crop, inversion, or normalization beyond conversion of grayscale byte pixels to `[0,1]`. Raster inputs are therefore required to be 28x28 and are converted to grayscale before applying `ToTensor()`; the runner deliberately does not invent a resize or polarity correction.
- `--raw input.npy` accepts a 28x28 numeric array. Values in `[0,255]` with a maximum above 1 are divided by 255; arrays already in `[0,1]` are used directly. Both modes use `run_integer_batch`, fixed input and activation scales, `pack_feature_map`, and the existing little-endian HWC input format.
- The runner reuses the trained parameter loader and validates its checkpoint digest against `artifacts/mnist_int8_calibration.json`; it also checks the parameters against the existing `vectors/smoke` weights, biases, and instructions before simulation. The testbench reads those stored vectors, writes them to the accelerator over AXI/DMA, starts the design, waits for DONE/error with the existing timeout/status checks, and reads all twelve result bytes.
- Each invocation writes a separate directory under `artifacts/manual/` with `inputs.hex`, `golden.hex`, `rtl_result.hex`, `rtl_result.csv`, `manual_result.json`, the normalized 28x28 array, and simulator/build logs. It prints the RTL's first ten signed scores and argmax separately from the Python INT8 golden scores/prediction, plus exact byte comparison status and measured cycles.
- Validation used MNIST test indices 0-4 with known labels 7, 2, 1, 0, and 4. Each PNG invocation matched the known label, Python INT8 prediction, and all twelve golden output bytes; a JPEG and raw NPY representation of index 0 produced the same prediction and output bytes. Each RTL run measured 55,677 accelerator clocks. Pillow was available through the existing TorchVision environment; no dependency or RTL changes were needed. The 5,000-image regression was not rerun or modified.
