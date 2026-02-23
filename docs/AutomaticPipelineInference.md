# Timing Analysis — From HelloArty to Compiler Feature

HelloArty's wave chase design exposed a timing violation that width inference alone cannot
fix. This document describes the problem, what the compiler can and cannot know about it,
and the two-layer architecture for catching timing violations across CCS and Composer.

---

## The problem

The wave chase breathing pattern computes smoothstep brightness for 4 LEDs using Hermite
interpolation (`3p² - 2p³`). Each LED's brightness path chains through multiple DSP48E1
operations:

```
Phase → triangle ramp → p × p → p × p × p → scale → subtract → PWM compare → LED
```

At 100 MHz (10 ns clock period), the critical path through this chain takes 12.635 ns —
a timing violation of **WNS = -2.635 ns**.

Width inference is working correctly. The registers are narrowed to 31/20/11/13 bits.
The issue is not how *wide* the computation is, but how *deep* — too many chained
operations between register boundaries for single-cycle evaluation.

---

## Why width inference is necessary but not sufficient

Width inference is the **spatial** dimension: how many bits does each value need?
Narrower values mean shorter carry chains, smaller multipliers, and faster paths.

Combinational depth is the **temporal** dimension: how many chained operations sit
between register boundaries? Deep chains exceed the clock period budget regardless
of how narrow the values are.

Both derive from analysis of the same program semantic graph. Together they determine
whether a design meets its timing budget.

| Dimension | What the compiler controls | What it fixes |
|-----------|---------------------------|---------------|
| Spatial | Width inference (bit narrowing) | 64-bit counter → 31-bit (shorter carry chains) |
| Temporal | Structural depth analysis | Identifies deep chains; Vivado confirms violation |

---

## What the compiler can and cannot know

### Can know with certainty
1. **Combinational operation depth** between register boundaries — structural graph fact
2. **Source mapping** from PSG nodes back to Clef expressions — mechanical via source spans
3. **Path classification** — feedforward (State→Output) vs. feedback (State→State)

### Cannot know
1. **Actual delay in nanoseconds** — depends on Vivado synthesis decisions (DSP48E1 vs. LUT
   mapping), physical placement, and routing delay
2. **Whether N pipeline stages would be sufficient** — same grounding problem
3. **What optimizations Vivado will apply** — retiming, constant folding, sharing

### Why not estimate delay?

Total path delay = logic delay (~60%) + routing delay (~40%). The compiler can reason about
operation types but has zero information about routing — that requires physical placement.
Vivado's own pre-route estimates use connectivity heuristics and are not authoritative;
formal timing signoff only happens post-route.

Building a delay model in Composer would mean modeling a downstream tool's optimization
decisions. This is the same problem as using `-O3` in LLVM lowering: the compiler would
be guessing, and guessing wrong isn't "slightly off" — it can be qualitatively wrong
(warning on a path Vivado handles fine, or missing a path Vivado can't close).

Clash (Haskell→FPGA) takes the same position: the compiler generates clean RTL, the
synthesis tool does timing. Composer should not try to outguess Vivado.

---

## Path classification

For a Mealy machine `State × Input → State × Output`:

```
              ┌──────────────────────────────┐
              │      Combinational Logic      │
Inputs ──────►│   (the `step` function body)  ├──────► Outputs
              │                              │
              └────────────┬─────────────────┘
                           │
                    ┌──────┴──────┐
                    │    State    │
                    │  Registers  │
                    └─────────────┘
```

| Path | Direction | Pipelining impact |
|------|-----------|-------------------|
| State → Output | Feedforward | Adds output latency only — invisible at observable rates |
| Input → State | Feedforward | Adds input-to-latch latency (one extra clock cycle) |
| State → State | Feedback | Changes effective iteration rate — alters semantics |

The HelloArty smoothstep is entirely **feedforward**: state flows out to LED outputs
and never feeds back into the state update. The state update path (`Counter + 1`,
`StepTick + 1`, `Phase + 1`) is simple single-cycle arithmetic — no timing issue.

Path classification is a structural fact the compiler knows with certainty.

---

## Architecture: two layers

The design uses two layers, each grounded in what it actually knows.

### Layer 1 — Early (CCS, PSG catamorphism)

A `foldPostOrder` catamorphism in CCS (the Clef compiler service) walks the PSG
bottom-up, computing combinational operation depth at each node. XParsec combinators
define the per-node logic, following the four pillars pattern used throughout CCS's
Baker layer.

The analysis lives in `src/Compiler/PSGSaturation/SemanticGraph/DepthAnalysis.fs`
in the clef repo — it is a compiler service responsibility, not a Composer middle-end
concern.

Each operation type carries a unitless structural weight:

| Operation | Weight | Rationale |
|-----------|--------|-----------|
| Add, subtract, compare | 1 | Single LUT/carry level |
| Multiply, divide | 2 | DSP slice or multi-LUT chain |
| Mux (if/else) | 1 | Selection logic |
| VarRef, Binding, FieldGet | 0 | Transparent wrappers |

The depth at each node is `max(children depths) + weight`. Paths exceeding an
empirical per-platform threshold generate diagnostics in `CheckResult`:

```
[INFO] Feedforward path depth 8 (threshold: 6) at Behavior.clef:42-47
  Chain: phase0 → multiply → multiply → multiply → divide → subtract → compare → mux
```

This is an **opening heuristic**. The weights and thresholds are starting points,
calibrated over time against Layer 2 ground truth. The compiler reports structural
complexity — it does not predict nanoseconds or claim to know how many pipeline
stages would fix a violation.

### Layer 2 — Late (Backend trap, Vivado TCL)

After `route_design`, before `write_bitstream`, query actual timing from Vivado — the
only source of ground truth:

```tcl
# ── Timing gate (generated by Composer based on developer policy) ──
set WNS [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "Post-route WNS: ${WNS} ns"

if {$WNS < $timing_threshold} {
    puts "ERROR: Timing violation (WNS=${WNS} ns) — bitstream blocked by policy"
    # Halt: no bitstream generated, no flash possible
    return -code error "Blocked by timing policy"
}
```

Vivado is the oracle. It has placement, routing, and characterized fabric data. The
compiler doesn't try to replicate that analysis — it controls whether a violation
**stops the build** by generating the appropriate TCL gate.

### Policy flows top-to-bottom

The developer sets timing policy in the Clef project configuration. Composer passes it
through to the generated `synth.tcl`:

| Policy | Layer 1 (compiler) | Layer 2 (Vivado TCL) |
|--------|---------------------|----------------------|
| `warn` (default) | Report structural depth | Report WNS, write bitstream anyway |
| `error` | Report structural depth | WNS < 0 → block bitstream, stop flash |
| `strict` | Report structural depth | WNS < configurable margin → block bitstream |

The compiler provides structural awareness early. Vivado provides timing authority late.
The developer controls the policy that connects them.

---

## Severity and industry context

There is no formal standard for acceptable timing violation percentages. Any negative
slack is technically a violation. Vivado's conservative process/voltage/temperature
modeling means very small violations (< 200 ps) often work in practice, but this is
not guaranteed.

The margin for `strict` mode is a **platform property** — appropriate slack margins
differ between a 100 MHz Artix-7 development board and a 300 MHz Kintex production
target.

---

## ClefAutoComplete integration (future)

At design time, ClefAutoComplete surfaces Layer 1 structural analysis as IDE diagnostics:

- Squiggles on expressions that form deep combinational chains
- Informational hover showing operation depth per path
- Path classification (feedforward vs. feedback) visible in editor

This is structural information the compiler knows with certainty. It does not claim to
predict timing — it flags complexity and lets the developer decide.

---

## Calibration strategy

Layer 1 is an opening heuristic. Its accuracy is evaluated against Layer 2 ground
truth when the Vivado TCL trap is implemented:

- If Layer 1 flags a path that Layer 2 confirms violates timing → heuristic works
- If Layer 1 misses a real violation → weights or thresholds need adjustment
- If Layer 1 false-positives (flags a path that meets timing) → weights too aggressive

The feedback loop from real Vivado runs back-annotates the compiler model over time.
HelloArty provides the first calibration data point: a path with weighted depth ~8
that violates timing by 2.635 ns at 100 MHz on Artix-7.

## Automatic pipeline insertion (future, requires grounded estimation)

Automatic pipelining — where the compiler inserts pipeline registers without developer
intervention — requires knowing *how many* stages to insert. That requires delay
estimation, which has the same grounding problem described above. This is deferred until
the calibration loop provides enough data to make reliable stage-count predictions.

For now, the two-layer model (structural heuristic + Vivado trap) is the grounded
approach. The developer writes the pipeline stages when needed; the tooling tells them
where and catches violations they miss.

---

## HelloArty as test case

This design is the canonical first test case, tagged `timing-violation-baseline`:

| Property | Value |
|----------|-------|
| Violation | WNS = -2.635 ns (26% over budget) |
| Cause | Chained DSP operations in smoothstep (4 DSPs/LED × 4 LEDs) |
| Path type | Purely feedforward (State → Output) |
| Structural depth | 6 chained operations (3 multiply, 1 divide, 1 subtract, 1 compare) |
| Weighted depth | ~8 (3×2 for multiply + 1×2 for divide + 1 subtract + 1 compare) |
| Layer 1 catches it? | Yes — weighted depth 8 exceeds threshold 6 |
| Layer 2 catches it? | Yes — WNS is unambiguously negative |
| Fix | Developer-inserted pipeline stages (2-3 cycles, ~20-30 ns latency) |
| Latency impact | Invisible at 4-second breathing cycle |
