# Vivado Batch Synthesis Script for Standalone INT8 CNN Hardware Accelerator
# Target Device: xc7a100tcsg324-1 (Artix-7 100T)
# Top Module: accel_top

set SCRIPT_DIR [file normalize [file dirname [info script]]]
set FPGA_DIR   [file normalize [file join $SCRIPT_DIR ".."]]
set INT8_DIR   [file normalize [file join $FPGA_DIR ".."]]
set RTL_DIR    [file normalize [file join $INT8_DIR "rtl"]]
set CONST_DIR  [file normalize [file join $FPGA_DIR "constraints"]]
set REP_DIR    [file normalize [file join $FPGA_DIR "reports"]]
set LOG_DIR    [file normalize [file join $FPGA_DIR "logs"]]
set CKPT_DIR   [file normalize [file join $FPGA_DIR "checkpoints"]]

file mkdir $REP_DIR
file mkdir $LOG_DIR
file mkdir $CKPT_DIR

set PART_NAME "xc7a100tcsg324-1"
set TOP_MODULE "accel_top"

puts "================================================================================"
puts "  ATHENA / INT8 CNN ACCELERATOR VIVADO SYNTHESIS"
puts "  Target Part:   $PART_NAME"
puts "  Top Module:    $TOP_MODULE"
puts "  RTL Directory: $RTL_DIR"
puts "================================================================================"

# Read SystemVerilog sources in dependency order
read_verilog -sv [list \
    [file join $RTL_DIR "cnn_pkg.sv"] \
    [file join $RTL_DIR "pe.sv"] \
    [file join $RTL_DIR "pe_array.sv"] \
    [file join $RTL_DIR "post_proc.sv"] \
    [file join $RTL_DIR "mem_ctrl.sv"] \
    [file join $RTL_DIR "ctrl_unit.sv"] \
    [file join $RTL_DIR "accel_top.sv"] \
]

# Read clock constraints
read_xdc [file join $CONST_DIR "clock.xdc"]

# Run Synthesis
puts "INFO: Starting synthesis of $TOP_MODULE on $PART_NAME..."
set start_time [clock seconds]

synth_design -top $TOP_MODULE -part $PART_NAME -flatten_hierarchy rebuilt

set end_time [clock seconds]
set elapsed [expr {$end_time - $start_time}]
puts "INFO: Synthesis completed in $elapsed seconds."

# Write Checkpoint
write_checkpoint -force [file join $CKPT_DIR "post_synth.dcp"]

# Generate Comprehensive Synthesis Reports
puts "INFO: Generating synthesis reports in $REP_DIR..."

report_utilization -file [file join $REP_DIR "synth_utilization.rpt"] -pb [file join $REP_DIR "synth_utilization.pb"]
report_utilization -hierarchical -file [file join $REP_DIR "synth_utilization_hierarchical.rpt"]
report_timing_summary -file [file join $REP_DIR "synth_timing_summary.rpt"]
report_timing -max_paths 10 -file [file join $REP_DIR "synth_timing_max_paths.rpt"]
report_drc -file [file join $REP_DIR "synth_drc.rpt"]

# Check for latches and unconstrained paths
set latches [all_latches]
set latch_count [llength $latches]
set latch_file [open [file join $REP_DIR "synth_latches.rpt"] "w"]
puts $latch_file "=== INFERRED LATCH REPORT ==="
puts $latch_file "Total Inferred Latches: $latch_count"
if {$latch_count > 0} {
    puts $latch_file "WARNING: Latches detected in design:"
    foreach l $latches {
        puts $latch_file "  $l"
    }
} else {
    puts $latch_file "Clean design: Zero inferred latches."
}
close $latch_file

puts "================================================================================"
puts "  SYNTHESIS REPORT SUMMARY"
puts "  Inferred Latches: $latch_count"
puts "  Reports saved in: $REP_DIR"
puts "================================================================================"

exit 0
