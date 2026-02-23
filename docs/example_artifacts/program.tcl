# Vivado batch programming for HelloArty
# Programs the bitstream onto the connected FPGA via JTAG/USB
#
# Usage: vivado -mode batch -source program.tcl
# Or:    vivado -mode batch -source program.tcl -tclargs <bitstream>

set bit_file [expr {$argc >= 1 ? [lindex $argv 0] : "Program_helloArtyTop.bit"}]

if {![file exists $bit_file]} {
    puts "ERROR: Bitstream not found: $bit_file"
    puts "Run synth.tcl first to generate the bitstream."
    exit 1
}

puts "================================================================"
puts "Composer → Vivado FPGA Programming"
puts "================================================================"
puts "  Bitstream: $bit_file"
puts "================================================================"

open_hw_manager
connect_hw_server -allow_non_jtag

# Find the target device
open_hw_target

set device [lindex [get_hw_devices] 0]
if {$device eq ""} {
    puts "ERROR: No hardware device found. Check USB connection."
    close_hw_manager
    exit 1
}

puts "  Device:    $device"

# Program
set_property PROGRAM.FILE $bit_file $device
program_hw_devices $device

puts ""
puts "================================================================"
puts "FPGA programmed successfully"
puts "================================================================"

close_hw_manager
