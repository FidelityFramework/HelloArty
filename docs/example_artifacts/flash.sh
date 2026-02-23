#!/usr/bin/env bash
# Flash programming for HelloArty (Arty A7-100T)
# Uses openFPGALoader — Vivado 2025.2's indirect programming is broken for Artix-7.
#
# Usage: ./flash.sh [bitstream.bit]
#
# Before running:
#   1. Remove JP1 jumper (JTAG mode for programming)
#   2. Kill any Vivado hw_server: killall hw_server cs_server
#
# After success:
#   1. Install JP1 jumper (SPI boot mode)
#   2. Press PROG or power cycle — design loads from flash

set -euo pipefail

BIT_FILE="${1:-Program_helloArtyTop.bit}"

if [[ ! -f "$BIT_FILE" ]]; then
    echo "ERROR: Bitstream not found: $BIT_FILE"
    echo "Run synth.tcl first to generate the bitstream."
    exit 1
fi

echo "================================================================"
echo "Composer → SPI Flash Programming (openFPGALoader)"
echo "================================================================"
echo "  Bitstream: $BIT_FILE"
echo "================================================================"

# Kill Vivado hw_server if running (holds the FTDI device)
killall -q hw_server cs_server 2>/dev/null || true
sleep 1

openFPGALoader --board arty_a7_100t -f "$BIT_FILE"

echo ""
echo "================================================================"
echo "SPI flash programmed successfully"
echo "  1. Install JP1 jumper (SPI boot mode)"
echo "  2. Press PROG or power cycle"
echo "  Design will load automatically on power-up."
echo "================================================================"
