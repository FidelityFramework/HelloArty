# Vivado batch synthesis for HelloArty
# Generated artifacts from Composer compiler
#
# Usage: vivado -mode batch -source synth.tcl
# Or:    vivado -mode batch -source synth.tcl -tclargs <sv_dir> <top_module> <part>

# Defaults — override via -tclargs
set sv_dir    [expr {$argc >= 1 ? [lindex $argv 0] : "intermediates"}]
set top       [expr {$argc >= 2 ? [lindex $argv 1] : "Program_helloArtyTop"}]
set part      [expr {$argc >= 3 ? [lindex $argv 2] : "xc7a100tcsg324-1"}]

set sv_file   [file join $sv_dir "output.sv"]
set xdc_file  [file join $sv_dir "output.xdc"]
set bit_file  "${top}.bit"

puts "================================================================"
puts "Composer → Vivado Synthesis"
puts "================================================================"
puts "  SV source:   $sv_file"
puts "  Constraints: $xdc_file"
puts "  Top module:  $top"
puts "  Device:      $part"
puts "  Bitstream:   $bit_file"
puts "================================================================"

# Read sources
read_verilog -sv $sv_file
read_xdc $xdc_file

# Synthesize
synth_design -top $top -part $part

# Configure SPI flash boot — must be set BEFORE implementation.
# CFGBVS/CONFIG_VOLTAGE: Arty A7 uses 3.3V configuration banks.
# CONFIG_MODE/SPI_BUSWIDTH: Quad SPI boot from on-board flash (Micron N25Q128 or
# Spansion S25FL127S/128S depending on board revision).
# Settings per Digilent Arty Programming Guide.
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 33 [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]

report_utilization -file ${top}_utilization.rpt
report_timing_summary -file ${top}_timing.rpt

# Implement
opt_design
place_design
route_design

# Write bitstream
write_bitstream -force $bit_file

puts ""
puts "================================================================"
puts "Synthesis complete: $bit_file"
puts "================================================================"
