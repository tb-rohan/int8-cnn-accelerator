# Vivado Batch Synthesis and Implementation for Artix-7 200T (xc7a200tfbg676-2)
# Provides post-route timing and placement verification for the full accelerator

set SCRIPT_DIR [file normalize [file dirname [info script]]]
set FPGA_DIR   [file normalize [file join $SCRIPT_DIR ".."]]
set INT8_DIR   [file normalize [file join $FPGA_DIR ".."]]
set RTL_DIR    [file normalize [file join $INT8_DIR "rtl"]]
set CONST_DIR  [file normalize [file join $FPGA_DIR "constraints"]]
set REP_DIR    [file normalize [file join $FPGA_DIR "reports" "a200t"]]
set CKPT_DIR   [file normalize [file join $FPGA_DIR "checkpoints" "a200t"]]

file mkdir $REP_DIR
file mkdir $CKPT_DIR

set PART_NAME "xc7a200tfbg676-2"
set TOP_MODULE "accel_top"

puts "================================================================================"
puts "  ATHENA / INT8 CNN ACCELERATOR: FULL IMPLEMENTATION ON $PART_NAME"
puts "================================================================================"

read_verilog -sv [list \
    [file join $RTL_DIR "cnn_pkg.sv"] \
    [file join $RTL_DIR "pe.sv"] \
    [file join $RTL_DIR "pe_array.sv"] \
    [file join $RTL_DIR "post_proc.sv"] \
    [file join $RTL_DIR "mem_ctrl.sv"] \
    [file join $RTL_DIR "ctrl_unit.sv"] \
    [file join $RTL_DIR "accel_top.sv"] \
]

read_xdc [file join $CONST_DIR "clock.xdc"]

puts "INFO: Running synthesis..."
synth_design -top $TOP_MODULE -part $PART_NAME -mode out_of_context -flatten_hierarchy rebuilt

write_checkpoint -force [file join $CKPT_DIR "post_synth.dcp"]
report_utilization -file [file join $REP_DIR "synth_utilization.rpt"]
report_timing_summary -file [file join $REP_DIR "synth_timing_summary.rpt"]

puts "INFO: Running opt_design..."
opt_design

puts "INFO: Running place_design..."
place_design

write_checkpoint -force [file join $CKPT_DIR "post_place.dcp"]
report_utilization -file [file join $REP_DIR "post_place_utilization.rpt"]
report_timing_summary -file [file join $REP_DIR "post_place_timing_summary.rpt"]

puts "INFO: Running route_design..."
route_design

write_checkpoint -force [file join $CKPT_DIR "post_route.dcp"]
report_utilization -file [file join $REP_DIR "post_route_utilization.rpt"]
report_timing_summary -file [file join $REP_DIR "post_route_timing_summary.rpt"]
report_timing -max_paths 10 -file [file join $REP_DIR "post_route_timing_max_paths.rpt"]
report_drc -file [file join $REP_DIR "post_route_drc.rpt"]

puts "================================================================================"
puts "  FULL IMPLEMENTATION COMPLETE ON $PART_NAME"
puts "================================================================================"
exit 0
