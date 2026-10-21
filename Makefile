PYTHON ?= python
IVERILOG ?= iverilog
VVP ?= vvp
YOSYS ?= yosys
SV2V ?= synth/tools/sv2v-v0.0.13/sv2v.exe

RTL = rtl/cnn_pkg.sv rtl/pe.sv rtl/pe_array.sv rtl/post_proc.sv rtl/mem_ctrl.sv rtl/ctrl_unit.sv rtl/accel_top.sv

.PHONY: test sim synth clean

test:
	powershell -NoProfile -ExecutionPolicy Bypass -File scripts/verify.ps1 -PythonExe "$(PYTHON)"

sim:
	$(IVERILOG) -g2012 -s tb_full_cnn -o build/tb_full_cnn.vvp $(RTL) tb/tb_full_cnn.sv
	$(VVP) build/tb_full_cnn.vvp

synth:
	powershell -NoProfile -Command "New-Item -ItemType Directory -Force build/generated,synth/reports | Out-Null"
	$(SV2V) --define=SYNTHESIS $(RTL) -w build/generated/accel_top.v
	$(YOSYS) -Q -p "read_verilog build/generated/accel_top.v; hierarchy -check -top accel_top; proc; synth -top accel_top -run coarse; stat -top accel_top; write_rtlil synth/reports/current_coarse.rtlil; check" > synth/reports/yosys_current_coarse.log

clean:
	powershell -NoProfile -Command "Get-ChildItem -LiteralPath build -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force"
