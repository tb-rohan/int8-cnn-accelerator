# Vivado Project Creation Script for Standalone INT8 CNN Accelerator
# Creates a managed Vivado project (.xpr)

set SCRIPT_DIR [file normalize [file dirname [info script]]]
set FPGA_DIR   [file normalize [file join $SCRIPT_DIR ".."]]
set INT8_DIR   [file normalize [file join $FPGA_DIR ".."]]
set RTL_DIR    [file normalize [file join $INT8_DIR "rtl"]]
set CONST_DIR  [file normalize [file join $FPGA_DIR "constraints"]]
set PROJ_DIR   [file normalize [file join $FPGA_DIR "project"]]

file mkdir $PROJ_DIR

set PROJ_NAME "int8_cnn_accel"
set PART_NAME "xc7a100tcsg324-1"

puts "INFO: Creating project $PROJ_NAME in $PROJ_DIR for $PART_NAME..."
create_project -force $PROJ_NAME $PROJ_DIR -part $PART_NAME

set_property target_language Verilog [current_project]

add_files -fileset sources_1 [list \
    [file join $RTL_DIR "cnn_pkg.sv"] \
    [file join $RTL_DIR "pe.sv"] \
    [file join $RTL_DIR "pe_array.sv"] \
    [file join $RTL_DIR "post_proc.sv"] \
    [file join $RTL_DIR "mem_ctrl.sv"] \
    [file join $RTL_DIR "ctrl_unit.sv"] \
    [file join $RTL_DIR "accel_top.sv"] \
]

# Set SystemVerilog filetype
set_property file_type SystemVerilog [get_files [file join $RTL_DIR "*.sv"]]

# Add constraints
add_files -fileset constrs_1 [file join $CONST_DIR "clock.xdc"]

# Set top module
set_property top accel_top [current_fileset]
update_compile_order -fileset sources_1

puts "INFO: Project created successfully at [file join $PROJ_DIR ${PROJ_NAME}.xpr]"
exit 0
