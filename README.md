# HelloArty

HelloArty is a Clef FPGA program targeting the Digilent Arty A7-100T. It demonstrates
a deterministic "hello blinky" design: switches select color and mode, buttons adjust
blink cadence, and the board reports its state back to the host over the USB-UART.

## Architecture

HelloArty is structured as two programs that share a BAREWire contract:

```
src/
├── HelloArty.fidsln            # (future) Solution — ties FPGA + Monitor + Shared
├── Shared/
│   └── Contract.clef           # [<BAREWireSchema>] ArtyReport — owned by neither program
├── FPGA/
│   ├── HelloArty.fidproj       # FPGA build manifest  (output_kind = "fpga")
│   ├── Behavior.clef           # Application logic (switch/button decoding, cadence)
│   └── Program.clef            # [<HardwareModule>] — the FPGA design
└── Monitor/                    # (future) CPU console monitor
    ├── ArtyMonitor.fidproj     #   output_kind = "console"
    └── Program.clef            #   reads /dev/ttyUSB1, decodes ArtyReport, renders
```

`Shared/Contract.clef` carries the BAREWire schema. Both programs reference it;
neither owns it. `Color` and `Mode` come from the Arty A7 Prelude (board facts);
`ArtyReport` is the application wire format.

## FPGA Design Model

The hardware design is a **Mealy machine**: `State × Inputs → State × Outputs`.

- `BlinkState` fields become `seq.compreg` flip-flops (synthesised by the compiler).
- The `step` function body becomes `comb` combinational logic evaluated each clock edge.
- `[<HardwareModule>]` signals declaration semantics — this binding IS the design.

## Platform Library

Board-level facts live in `Fidelity.Platform/FPGA/Xilinx/Artix7/ArtyA7_100T/`:

- `ArtyA7_100T.Bindings.clef` — physical pin descriptors and XDC constraint data
- `ArtyA7_100T.Prelude.clef`  — `Color`, `Mode`, `colorToRgbBits`, `isLedOn`,
                                  `ArtyReport`, `Inputs`, `Outputs<'R>`, `Design<'S,'R>`

Application code opens the Prelude and writes idiomatic ML-style functions.
No HDL boilerplate; no hardware-specific syntax in user files.

## Interactive Contract

**Switches:**
| SW2 SW1 SW0 | Color   |
|-------------|---------|
| 0 0 0       | Off     |
| 0 0 1       | Red     |
| 0 1 0       | Green   |
| 0 1 1       | Yellow  |
| 1 0 0       | Blue    |
| 1 0 1       | Magenta |
| 1 1 0       | Cyan    |
| 1 1 1       | White   |

- `SW3 = 0` → Solid; `SW3 = 1` → Blink

**Buttons:**
- `BTN0` — faster (−100 ms, floor 100 ms)
- `BTN1` — slower (+100 ms, cap 2000 ms)
- `BTN2` — reserved (pattern select, future)
- `BTN3` — reset cadence to default (500 ms)

## Build Intent

```
Clef source
  → CCS front-end
  → Composer (FPGA lowering path)
  → CIRCT hw/comb/seq MLIR
  → Verilog + XDC
  → Vivado synthesis and implementation
  → Arty A7-100T bitstream
```

The FPGA lowering path (`[<HardwareModule>]` → CIRCT) is the next compiler milestone.
The source is correct Clef now; compilation will fail with a clear
"FPGA lowering path not implemented" error — which is the right signal.
