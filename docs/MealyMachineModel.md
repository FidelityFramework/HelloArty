# The Mealy Machine Model — For Developers Coming from CPU/Software

HelloArty is an FPGA program. If you come from CPU software — F#, C#, OCaml, any imperative
or functional language — the mental model is different in one precise way. This document names
that difference, shows where your existing ML reflexes still apply, and explains the blink
timing behaviour concretely.

---

## The one thing that is different

A CPU program has a lifecycle: start → execute → finish. You write commands. Control flows
through them. `[<EntryPoint>]` says "begin here."

A hardware module has no lifecycle. From the moment power is applied, it is evaluating —
every clock edge, forever. There is no start. There is no finish. The circuit **is** the
computation, running perpetually.

`[<HardwareModule>]` is not "start here." It is "this description **is** the circuit."
The compiler synthesises an `hw.module` from it. Vivado places and routes it into silicon.
The result runs without further instruction until power is removed.

---

## The Mealy machine

HelloArty is a **Mealy machine**: a circuit whose outputs depend on both current state
and current inputs. The formal rule is:

```
δ(state, inputs) → (next_state, outputs)
```

Every clock edge (every 10 ns at 100 MHz):

```
                ┌──────────────────────────────┐
                │      Combinational Logic      │
  Inputs ──────►│   (the `step` function body)  ├──────► Outputs (LEDs, UART)
                │                              │
                └────────────┬─────────────────┘
                             │ next_state captured on clock edge
                             ▼
                       ┌──────────┐
                       │  State   │  ← BlinkState fields
                       │Registers │    synthesised as seq.compreg flip-flops
                       │ Counter  │
                       │ PeriodMs │
                       └────┬─────┘
                            │ current_state fed back into combinational logic
                            └──────────────────────────────────────────────►
                       ▲
                    Clock (100 MHz)
```

The `step` function **is** the combinational logic block. The compiler lowers its body to
`comb` operations in CIRCT. `BlinkState` fields **are** the registers — two flip-flop banks:
a 29-bit counter and an 11-bit period value.

---

## What `Program.clef` actually declares

```fsharp
[<HardwareModule>]
let helloArtyTop : Design<BlinkState, ArtyReport> = {
    InitialState = { Counter = 0; PeriodMs = defaultPeriodMs }
    Step = step
    Clock = Endpoints.clock
}
```

Three fields. Three complete specifications:

| Field | What it specifies | Hardware meaning |
|---|---|---|
| `InitialState` | Reset values | What the flip-flops hold at power-on |
| `Step` | Transition function | The entire combinational logic block |
| `Clock` | Clock domain | Which clock signal drives the registers |

This is the complete formal description of the circuit. There is nothing passive about it —
these three choices fully determine the hardware. The `[<HardwareModule>]` attribute is what
elevates this record from "an F# value" to "a hardware module to synthesise."

---

## Where your ML reflexes still apply

| Location | Mental model |
|---|---|
| `step` function body | Pure ML — transform data, pattern match, let bindings |
| `BlinkState` fields | "These must remember their value across clock edges" |
| `helloArtyTop` binding | "This **is** the circuit" — declaration, not invocation |

Your ML reflexes are entirely correct inside `step`. It is a pure function. It is a data
transformation. That is precisely why functional languages (Haskell/Clash, Lava, Clef) are
well-suited for hardware description — the Mealy machine maps cleanly onto pure functions.

The shift is only at the boundary: `[<HardwareModule>]` is where you stop writing code that
runs and start writing a declaration that gets synthesised.

---

## Concrete timing: the 500 ms blink

With `defaultPeriodMs = 500` and the clock at 100 MHz:

- `ticksPerMs = 100_000`
- Half-period = 500 × 100,000 = **50,000,000 clock cycles**
- `step` runs **50 million times** while the LED is on. Each time, `bright = true`.
- On cycle 50,000,001, `(counter % 100_000_000) < 50_000_000` becomes false.
  `bright` goes low. The LED turns off.
- No event fires. No interrupt triggers. The combinational comparator simply produces
  a different result when the threshold is crossed.

---

## Changing colour mid-blink

`Color` has **no register**. Every clock cycle, `colorFromSwitches inputs.Sw0 inputs.Sw1
inputs.Sw2` evaluates against the live pin values. No previous colour is stored.

If you flip a slide switch while the LED is on:

- At the next clock edge (10 ns later), the switch input is sampled.
- `colorFromSwitches` produces the new colour.
- `colorToRgbBits` drives the new RGB output.
- The LED changes colour immediately.

The blink cycle has no opinion about colour. The ON/OFF phase and the colour are independent
combinational computations running in parallel every cycle.

The same applies to `Mode` (SW3): switching between Solid and Blink takes effect at the
very next clock edge, wherever in the current blink cycle the counter happens to be.

---

## Forward-looking: change-only UART reporting

`UartReport` is currently `ValueNone` — the UART wiring point exists but reporting waits
until the Monitor program is added.

When reporting is enabled, the correct pattern is **emit only on change** — not every cycle
(that would be 100 million packets per second). This maps naturally onto the Mealy model:
add a `LastReport: ArtyReport` field to `BlinkState`. Each cycle, compare the current
report to `LastReport`. If different, emit `ValueSome` and update `LastReport`. If the same,
emit `ValueNone`.

```fsharp
type BlinkState = {
    Counter: int
    PeriodMs: int
    LastReport: ArtyReport   // flip-flop holding last-emitted state
}
```

`LastReport` is a flip-flop. The equality check is a combinational comparator. This is
the FPGA implementation of `Incremental<'T>`: the computation always runs (combinational
logic cannot be skipped), but the output is gated by a comparison to the previous value.

In software `Incremental<'T>`, you skip the computation when inputs are unchanged.
In hardware, you skip the **emission** — computation is free, outputs are not.
The user-visible contract is identical: no new data, no report.

When `Incremental<'T>` is available in CCS, the FPGA lowering path can synthesise the
`LastReport` register and comparator automatically from the type annotation — making the
pattern implicit rather than explicit.
