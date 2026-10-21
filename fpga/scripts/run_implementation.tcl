# Vivado Batch Implementation Script for Standalone INT8 CNN Hardware Accelerator
# Target Device: xc7a100tcsg324-1 (Artix-7 100T)
# Top Module: accel_top

set SCRIPT_DIR [file normalize [file dirname [info script]]]
set FPGA_DIR   [file normalize [file join $SCRIPT_DIR ".."]]
set REP_DIR    [file normalize [file join $FPGA_DIR "reports"]]
set LOG_DIR    [file normalize [file join $FPGA_DIR "logs"]]
set CKPT_DIR   [file normalize [file join $FPGA_DIR "checkpoints"]]

set SYNTH_DCP  [file join $CKPT_DIR "post_synth.dcp"]
if {![file exists $SYNTH_DCP]} {
    puts "ERROR: Synthesized checkpoint not found: $SYNTH_DCP"
    puts "Please run run_synthesis.tcl first."
    exit 1
}

puts "================================================================================"
puts "  ATHENA / INT8 CNN ACCELERATOR VIVADO IMPLEMENTATION"
puts "  Synthesized Checkpoint: $SYNTH_DCP"
puts "================================================================================"

open_checkpoint $SYNTH_DCP

puts "INFO: Running opt_design..."
opt_design

puts "INFO: Running place_design..."
place_design

puts "INFO: Generating post-place reports..."
report_utilization -file [file join $REP_DIR "post_place_utilization.rpt"]
report_timing_summary -file [file join $REP_DIR "post_place_timing_summary.rpt"]

puts "INFO: Running phys_opt_design..."
phys_opt_design

puts "INFO: Running route_design..."
route_design

write_checkpoint -force [file join $CKPT_DIR "post_route.dcp"]

puts "INFO: Generating post-route reports..."
report_utilization -file [file join $REP_DIR "post_route_utilization.rpt"]
report_timing_summary -file [file join $REP_DIR "post_route_timing_summary.rpt"]
report_timing -max_paths 10 -file [file join $REP_DIR "post_route_timing_max_paths.rpt"]
report_drc -file [file join $REP_DIR "post_route_drc.rpt"]
report_clock_utilization -file [file join $REP_DIR "post_route_clock_utilization.rpt"]

puts "================================================================================"
puts "  IMPLEMENTATION COMPLETE"
puts "  Reports saved in: $REP_DIR"
puts "================================================================================"

exit 0
