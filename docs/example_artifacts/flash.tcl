# Vivado Batch SPI Flash Programming for Arty A7-100T
# Usage: vivado -mode batch -source flash.tcl -tclargs <bitstream.bit>

set bit_file [expr {$argc >= 1 ? [lindex $argv 0] : "Program_helloArtyTop.bit"}]
set mcs_file [file rootname $bit_file].mcs
set prm_file [file rootname $bit_file].prm

if {![file exists $bit_file]} {
    puts "ERROR: Bitstream not found: $bit_file"
    exit 1
}

puts "--- Step 1: Generating MCS (Quad SPI x4) ---"
write_cfgmem -format mcs -size 16 -interface SPIx4 \
    -loadbit "up 0x00000000 $bit_file" \
    -force -file $mcs_file

puts "--- Step 2: Connecting to Hardware ---"
open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target

# Stabilize connection
set_property PARAM.FREQUENCY 15000000 [current_hw_target]

set device [lindex [get_hw_devices] 0]
if {$device eq ""} {
    puts "ERROR: No hardware device found."
    close_hw_manager
    exit 1
}
current_hw_device $device
puts "  Targeting Device: $device"

# --- Candidate List for Arty A7 ---
# These cover Spansion S25FL128S (0 & 1), Micron N25Q128, and Micron MT25QL128
set candidates [list \
    "s25fl128sxxxxxx0-spi-x1_x2_x4" \
    "s25fl128sxxxxxx1-spi-x1_x2_x4" \
    "n25q128-3.3v-spi-x1_x2_x4" \
    "mt25ql128-spi-x1_x2_x4" \
    "s25fl127s-spi-x1_x2_x4" \
]

set programmed 0

foreach flash_part $candidates {
    set parts [get_cfgmem_parts $flash_part]
    if {[llength $parts] == 0} { continue }

    puts "--- Attempting Flash Part: $flash_part ---"

    # Clean up previous attempts
    catch {delete_hw_cfgmem [get_property PROGRAM.HW_CFGMEM $device]}

    # Create config memory object
    create_hw_cfgmem -hw_device $device -mem_dev [lindex $parts 0]
    set cfgmem [get_property PROGRAM.HW_CFGMEM $device]

    # Diagnostic: Try to read the ID to see if the bus is even alive
    if {[catch {get_property REGISTER.JEDEC_ID $cfgmem} id]} {
        puts "  Note: Could not read JEDEC ID with this part definition."
    } else {
        puts "  Detected JEDEC ID: $id"
    }

    # Set Programming Properties
    set_property PROGRAM.ADDRESS_RANGE  {use_file} $cfgmem
    set_property PROGRAM.FILES          [list $mcs_file] $cfgmem
    set_property PROGRAM.PRM_FILE       [list $prm_file] $cfgmem
    set_property PROGRAM.UNUSED_PIN_TERMINATION {pull-none} $cfgmem
    set_property PROGRAM.BLANK_CHECK    0 $cfgmem
    set_property PROGRAM.ERASE          1 $cfgmem
    set_property PROGRAM.CFG_PROGRAM    1 $cfgmem
    set_property PROGRAM.VERIFY         1 $cfgmem
    set_property PROGRAM.CHECKSUM       0 $cfgmem

    # Try to Program
    if {[catch {program_hw_cfgmem -hw_cfgmem $cfgmem} err]} {
        puts "  Result: Failed with $flash_part."
        # If we see "Failure to set flash parameters", it's usually a bus/jumper issue
    } else {
        puts "--- SUCCESS! ---"
        puts "Programmed using $flash_part"
        set programmed 1
        break
    }
}

if {!$programmed} {
    puts "----------------------------------------------------------------"
    puts "ERROR: All candidates failed."
    puts "CHECKLIST:"
    puts "1. Is Jumper JP1 set to JTAG during programming?"
    puts "2. Did you add 'set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4' to your XDC?"
    puts "3. Try pressing the red PROG button just before running this script."
    puts "----------------------------------------------------------------"
} else {
    puts "--- Programming Finished ---"
    puts "Move JP1 to 'SPI' and press PROG to boot."
}

close_hw_manager