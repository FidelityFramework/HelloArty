#!/usr/bin/env bash
# HelloArty FPGA Build & Deploy Pipeline
#
# Stages:
#   compile   — Composer: .clef → MLIR → circt-opt → SystemVerilog
#   synth     — Vivado:   SystemVerilog → bitstream (.bit)
#   program   — openFPGALoader: bitstream → FPGA SRAM (volatile, for dev)
#   flash     — openFPGALoader: bitstream → SPI flash (persistent)
#
# Usage:
#   ./build.sh                 # compile only
#   ./build.sh --synth         # compile + synthesize
#   ./build.sh --program       # compile + synth + JTAG program (volatile)
#   ./build.sh --flash         # compile + synth + flash program (persistent)
#   ./build.sh --synth-only    # synthesize only (skip compile)
#   ./build.sh --program-only  # JTAG program only (skip compile + synth)
#   ./build.sh --flash-only    # flash program only (skip compile + synth)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGETS_DIR="$SCRIPT_DIR"

# Composer compiler
COMPOSER="${COMPOSER:-/home/hhh/repos/Composer/src/bin/Debug/net10.0/Composer}"

# Clef compiler (for .clef sources)
CLEF="${CLEF:-/home/hhh/repos/clef/src/Compiler/bin/Debug/net10.0/clef}"

# Board
BOARD="arty_a7_100t"
TOP_MODULE="Program_helloArtyTop"
PART="xc7a100tcsg324-1"
BIT_FILE="$TARGETS_DIR/${TOP_MODULE}.bit"

# Parse flags
DO_COMPILE=true
DO_SYNTH=false
DO_PROGRAM=false
DO_FLASH=false

for arg in "$@"; do
    case "$arg" in
        --synth)        DO_SYNTH=true ;;
        --program)      DO_SYNTH=true; DO_PROGRAM=true ;;
        --flash)        DO_SYNTH=true; DO_FLASH=true ;;
        --synth-only)   DO_COMPILE=false; DO_SYNTH=true ;;
        --program-only) DO_COMPILE=false; DO_PROGRAM=true ;;
        --flash-only)   DO_COMPILE=false; DO_FLASH=true ;;
        --help|-h)
            sed -n '2,17p' "${BASH_SOURCE[0]}"
            exit 0 ;;
        *)
            echo "Unknown option: $arg (try --help)"
            exit 1 ;;
    esac
done

# ── Compile ──────────────────────────────────────────────────────
if $DO_COMPILE; then
    echo "================================================================"
    echo "Stage 1: Compile (.clef → SystemVerilog)"
    echo "================================================================"
    cd "$PROJECT_DIR"
    "$CLEF" compile HelloArty.fidproj -k
    echo "  Output: $TARGETS_DIR/intermediates/"
    echo ""
fi

# ── Synthesize ───────────────────────────────────────────────────
if $DO_SYNTH; then
    echo "================================================================"
    echo "Stage 2: Synthesize (Vivado → bitstream)"
    echo "================================================================"
    cd "$TARGETS_DIR"
    vivado -mode batch -source synth.tcl \
        -tclargs intermediates "$TOP_MODULE" "$PART"
    echo ""

    if [[ ! -f "$BIT_FILE" ]]; then
        echo "ERROR: Bitstream not generated: $BIT_FILE"
        exit 1
    fi
    echo "  Bitstream: $BIT_FILE ($(du -h "$BIT_FILE" | cut -f1))"
    echo ""
fi

# ── JTAG Program (volatile) ─────────────────────────────────────
if $DO_PROGRAM; then
    echo "================================================================"
    echo "Stage 3: JTAG Program (volatile — lost on power cycle)"
    echo "================================================================"

    if [[ ! -f "$BIT_FILE" ]]; then
        echo "ERROR: No bitstream found. Run with --synth first."
        exit 1
    fi

    # Release FTDI from Vivado
    killall -q hw_server cs_server 2>/dev/null || true
    sleep 1

    openFPGALoader --board "$BOARD" -m "$BIT_FILE"
    echo ""
fi

# ── Flash Program (persistent) ──────────────────────────────────
if $DO_FLASH; then
    echo "================================================================"
    echo "Stage 4: Flash Program (persistent — survives power cycle)"
    echo "================================================================"
    echo ""
    echo "  BOARD SETUP REQUIRED:"
    echo "    - Remove JP1 jumper (JTAG mode)"
    echo "    - Board powered via USB"
    echo ""

    if [[ ! -f "$BIT_FILE" ]]; then
        echo "ERROR: No bitstream found. Run with --synth first."
        exit 1
    fi

    # Release FTDI from Vivado
    killall -q hw_server cs_server 2>/dev/null || true
    sleep 1

    openFPGALoader --board "$BOARD" -f "$BIT_FILE"

    echo ""
    echo "  AFTER PROGRAMMING:"
    echo "    1. Install JP1 jumper (SPI boot mode)"
    echo "    2. Press PROG or power cycle"
    echo "    Design loads automatically on power-up — no USB required."
    echo ""
fi

echo "================================================================"
echo "Done."
echo "================================================================"
