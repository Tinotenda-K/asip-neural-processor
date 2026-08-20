# Benchmark: MAC versus MAC4

Two builds of the same processor running the same 784→128→64→10 INT8 network on
the same MNIST image, at the same 50 MHz core clock, differing in which
multiply-accumulate instruction the ALU implements and which assembly program is
loaded.

```verilog
// baseline  — dnn_final_packed.asm, MAC with SRL lane-sliding
ALU #(.ENABLE_MAC4(0), .ENABLE_MAC(1), .ENABLE_MULT(0)) alu (...);

// SIMD      — dnn_mac4.asm, MAC4 with packed activations
ALU #(.ENABLE_MAC4(1), .ENABLE_MAC(0), .ENABLE_MULT(0)) alu (...);
```

Both parameters change, not one. `ENABLE_MAC(0)` in the SIMD build is not
cosmetic: that program issues zero plain `MAC` instructions, and the arm carried
its own 32-bit adder and a mux input on every instruction.

The logits are bit-identical between the two builds — same ten values, same
argmax. The speedup buys nothing at the cost of accuracy, because the arithmetic
is the same arithmetic issued four lanes at a time.

---

## Instruction and cycle counts

| | MAC only | MAC4 | Ratio |
|---|---|---|---|
| Instructions per inference | 447,785 | 203,615 | 2.20× |
| Cycles (CPI = 3) | 1,343,355 | 610,845 | 2.20× |
| Inference @ 50 MHz | 26.87 ms | 12.22 ms | 2.20× |

CPI is a flat 3 for every instruction on this three-state FSM, so the
instruction-count ratio and the time ratio are identical. That is what makes the
comparison clean: no cache, no branch prediction, no variable latency, nothing
that could make a shorter instruction stream take longer.

## Where the saving comes from

The inner loop processes four inputs per iteration in both builds. Counted from
the loop bodies in [../docs/isa.md](../docs/isa.md):

| | MAC only | MAC4 |
|---|---|---|
| `LW` | 5 | 2 |
| `MAC` / `MAC4` | 4 | 1 |
| `SRL` (lane slide) | 3 | 0 |
| **Arithmetic and memory** | **12** | **3** |
| `ADDI` (pointer/counter) | 3 | 3 |
| `BNE` | 1 | 1 |
| **Loop body total** | **16** | **7** |

Five loads, not two. In the baseline the weights are packed four to a word but
the **activations are not** — one INT8 per 32-bit word — so the loop loads one
weight word and then four separate activations, sliding the weight word down by
eight bits between lanes. `MAC4` requires activations packed as well, which
collapses four activation loads into one and removes the lane slides entirely.

Three ratios, and it matters which one is quoted:

| Scope | Ratio |
|---|---|
| Arithmetic and memory only (12 → 3) | 4.00× |
| Whole loop body (16 → 7) | 2.29× |
| Whole program, measured | **2.20×** |

The loop body already predicts 2.29×; the measured 2.20× is that minus the
per-neuron and per-layer work — bias load, requantisation, `RELU`, activation
re-packing, argmax — which `MAC4` does not touch.

Requantisation is the largest single piece of that residue and it is worth
naming, because it is an ISA gap rather than an inefficiency. This processor has
no variable-shift instruction, so a shift by `S` is a countdown loop of
single-bit `SRL`s:

```
L1_SHIFT_LOOP:
    BEQ  R25, R0,  L1_SHIFT_DONE
    SRL  R6,  R6,  1
    ADDI R25, R25, -1
    J    L1_SHIFT_LOOP
```

Four instructions per bit, per neuron, in both builds, with `S1 = 11` and
`S2 = 8`. A `SRLV`-style register-shift instruction would collapse each of those
loops to one instruction and cost far less silicon than `MAC4` did — the obvious
next thing to add, and a cleaner win per gate than widening the SIMD.

The honest headline remains 2.20×, and the gap to 4.00× is ordinary Amdahl.

## Cost of the instruction

Both utilisation reports are post-placement (`report_utilization` on a fully
placed design), so this is like-for-like.

| | MAC only | MAC4 | Delta |
|---|---|---|---|
| WNS @ 50 MHz, as reported | +1.270 ns | +0.029 ns | −1.241 ns |
| Clock uncertainty applied | 0.035 ns | 0.535 ns | +0.500 ns |
| WNS at equal uncertainty | +1.270 ns | ≈ +0.529 ns | **≈ −0.74 ns** |
| WHS | +0.152 ns | +0.034 ns | −0.118 ns |
| Failing endpoints | 0 of 3,632 | 0 of 3,694 | — |
| Slice LUTs | 1,661 (5.10%) | 2,005 (6.15%) | **+344 (+20.7%)** |
| Slice registers | 1,024 (1.57%) | 1,054 (1.62%) | +30 (+2.9%) |
| CARRY4 | 50 | 103 | **+53 (+106%)** |
| F7 / F8 muxes | 384 / 66 | 388 / 65 | +4 / −1 |
| Occupied slices | 713 | 660 | −53 (−7.4%) |
| Unique control sets | 36 | 38 | +2 |
| DSP48E1 | 0 of 120 | 0 of 120 | **0** |
| BRAM tiles | 33 of 75 | 33 of 75 | **0** |

**344 LUTs and roughly 0.74 ns of slack bought 2.20×.** That is the whole ASIP
argument in one row: about a fifth more logic on a device that is 94% empty,
spent on the one operation the workload is made of.

The slack row needs the qualification above it. The two builds were **not signed
off under the same constraint**: the MAC4 build carries an explicit
`set_clock_uncertainty 0.500 [get_clocks core_clk]` and the baseline does not.
Vivado reports 0.535 ns of clock uncertainty on the MAC4 path (0.035 ns jitter
plus 0.500 ns user uncertainty) against 0.035 ns on the baseline path, and that
500 ps comes off the requirement before slack is computed. Removing it would
return the MAC4 build to roughly +0.529 ns.

So the raw −1.241 ns overstates the cost by about 40%. The like-for-like figure
is ≈ 0.74 ns, and the SIMD build has around **half a nanosecond** of genuine
margin at 50 MHz — not 29 picoseconds. The baseline should be rebuilt with the
same uncertainty constraint before the two numbers are printed adjacent to each
other; until then the ≈ row is an arithmetic adjustment, not a measurement.

Three things in that table are worth more than the headline:

**No DSPs, either way.** The 8×8 products are built from LUTs. An unpipelined
DSP48E1 multiply costs roughly 3.5–4 ns against 1.5–2 ns for an 8×8 LUT
multiply, and this FSM has no state in which to register a pipelined one — so
the DSP columns are a deliberate zero, not an oversight. 120 DSP48E1 slices sit
unused on the die.

**BRAM is identical.** `MAC4` changes how the packed network is consumed, not how
it is stored. Both builds hold the same 27,777-word image in the same 33 tiles.

**CARRY4 doubles.** The adder tree and its accumulate are carry logic, and they
are the clearest single signature of the instruction in the utilisation report.

Occupied slices *fall* despite more LUTs — the placer packed the SIMD build
more densely (660 slices holding 2,005 LUTs against 713 holding 1,661). Slice
count is a packing artefact and should not be read as an area result; LUT count
is the number to quote.

### Power

Vectorless estimates at 25 °C, medium confidence — no switching activity file
was supplied, so treat these as ranking information rather than measurements.

| | MAC only | MAC4 | Delta |
|---|---|---|---|
| Total on-chip | 0.156 W | 0.166 W | +0.010 W |
| Dynamic | 0.081 W | 0.092 W | +0.011 W |
| Device static | 0.075 W | 0.073 W | −0.002 W |
| Block RAM | 0.033 W | 0.033 W | 0 |
| Signals | 0.022 W | 0.031 W | +0.009 W |
| Slice logic | 0.011 W | 0.015 W | +0.004 W |

By hierarchy, the MAC4 build reports datapath 0.081 W, of which DMEM 0.033 W,
IMEM 0.028 W, RF 0.018 W and **alu 0.002 W**. The ALU — the entire subject of
this project — is about 2% of dynamic power. Memory and the register file are
roughly fifteen times larger. This is the standard result for a small
accelerator and it is worth stating plainly: the instruction saved time, and the
time saved energy, but the arithmetic was never where the power went.

Energy per inference follows from power × runtime:

| | MAC only | MAC4 | Ratio |
|---|---|---|---|
| Total energy | 4.19 mJ | 2.03 mJ | 2.07× |
| Dynamic only | 2.18 mJ | 1.12 mJ | 1.94× |

The instruction draws 6% more power for 55% less time. Energy improves slightly
*more* than 2.20× on the total figure because device static power — which is
fixed — is amortised over a shorter run.

## The critical path

The two builds fail in different places, which is the more interesting result.

**Baseline (MAC), routed, WNS +1.270 ns:**

```
datapath/IMEM/instruction_reg/CLKARDCLK
    -> register-file read mux -> ALU -> datapath/DMEM/mem_reg_0_5/ADDRARDADDR[9]

17.804 ns, 19 logic levels
  (CARRY4=5, LUT2=3, LUT3=1, LUT4=1, LUT5=2, LUT6=5, MUXF7=1, MUXF8=1)
logic 7.243 ns (40.7%), route 10.561 ns (59.3%)
```

**MAC4, post-route physopt, WNS +0.029 ns:**

```
datapath/IMEM/instruction_reg/CLKARDCLK
    -> register-file read mux -> ALU -> datapath/RF/regs_reg[15][29]/D

19.446 ns, 23 logic levels
  (CARRY4=11, LUT2=3, LUT3=1, LUT4=2, LUT6=4, MUXF7=1, MUXF8=1)
logic 9.164 ns (47.1%), route 10.282 ns (52.9%)
```

Both start at the instruction-memory BRAM output register, which is the shape of
a multi-cycle machine: the instruction word is available late, and everything
decode-dependent stacks up behind it. Route delay dominates in the baseline and
is close to half in the SIMD build.

Where they differ is the **endpoint**. The baseline's worst path terminates at
the data-memory address port — that is `LW`/`SW` address arithmetic, and the
five CARRY4s are the address adder. The SIMD build's worst path terminates at
the **register-file write port**, which is the accumulator writeback, and it
carries eleven CARRY4s. Six extra levels of carry logic on a path that ends
where `MAC4` deposits its result is the dot-product tree and its 32-bit
accumulate.

So in this build `MAC4` **does** define the critical path. Rebalancing the tree
from a three-deep chain to two levels —

```verilog
wire signed [16:0] s01 = p0 + p1;   // parallel
wire signed [16:0] s23 = p2 + p3;   // parallel
assign dot4 = s01 + s23;            // combine
```

— bought back enough to close at 50 MHz, but it did not move the bottleneck
somewhere else. The design passes with 29 picoseconds of margin at the slow
corner, and that is the true statement.

Both `MAC4` and `MULT` sit in the same combinational case statement as every
other operation, so an **enabled but unused** arm still lengthens the path and
widens the result mux on every instruction — including the `LW`/`MAC`/`SRL`
sequence the baseline actually executes. That is why the baseline compiles them
out rather than simply not executing them, and it is the concrete lesson of the
project: in an ASIP, an instruction you never execute is not free.

### What +0.029 ns actually means

Less than it appears to, and in the reassuring direction. The 29 ps sits on top
of 500 ps of user-specified clock uncertainty, so the design is passing a
requirement half a nanosecond tighter than the one the hardware actually
imposes. Strip that and it is ≈ +0.529 ns. On top of *that*, the corner Vivado
signs off against assumes worst-case process, 0.95 V and 85 °C, while the board
runs at room temperature and nominal voltage.

The remaining caution is placement variance: WNS at this margin moves with the
seed, and an added debug port can cost more than it looks. 50 MHz is close to
the edge of what this datapath does without pipelining the ALU, and
[../docs/architecture.md](../docs/architecture.md) records what a 45 MHz MMCM
build costs if more margin is wanted.

## Reproducing

Verified against `asm/assembler.py` and `sim/sim_isa.py`.

```bash
# ---- baseline:  ALU #(.ENABLE_MAC4(0), .ENABLE_MAC(1), .ENABLE_MULT(0))
python asm/assembler.py asm/dnn_final_packed.asm build/instruction.mem
python tools/pack_data_mem_v3.py dnn_parameters_final.txt build/data.mem \
       mnist_image.mem 127.0
python sim/sim_isa.py build/instruction.mem build/data.mem

# ---- SIMD:      ALU #(.ENABLE_MAC4(1), .ENABLE_MAC(0), .ENABLE_MULT(0))
python asm/assembler.py asm/dnn_mac4.asm build/instruction_mac4.mem
python sim/sim_isa.py build/instruction_mac4.mem build/data_mac4.mem

# ---- regression sweep: same binary, four networks, different weight scales
python sim/verify_final.py build/instruction_mac4.mem tools/pack_data_mem_v3.py
```

`assembler.py` takes **two positional arguments**, input and output. There is no
`-o`. Run with no arguments for the usage line.

`sim_isa.py` defaults to `instruction_mac4.mem` and `data_mac4.mem`, so bare
`python sim/sim_isa.py` runs the SIMD build. It reads the data image as-is and
checks its length against what the packer expects; pass `--regen` only to
deliberately rebuild it. `--mhz` defaults to 50, which is the core clock, not
the 100 MHz board clock.

It prints instruction count, cycles at CPI 3, milliseconds, the hardware logits,
the golden-model logits and the float reference, and exits non-zero on any
divergence. Expect:

```
instructions 203,615   cycles@CPI3 610,845   @50MHz 12.22 ms
hw     : [-23156, -3442, -11215, 16736, -14205, 6306, -17383, -10368, 1316, -1613]
hw argmax 3   golden 3   float 3
true label 3   -> CORRECT
MATCH
```

`verify_final.py` takes the binary and the **packer** as its two arguments — not
a data image. It generates its own images into `_v.mem` and must never be
pointed at a real `.mem` file.

Only `pack_data_mem_v*.py` may write a `.mem` data image. Running the v2 packer
against v3 assembly produces a design that simulates cleanly and computes
nonsense — see [../docs/debugging.md](../docs/debugging.md).

---

## Provenance of the numbers

Every figure above comes from a named Vivado report; none is from memory.

| Build | Reports | Date | Design state |
|---|---|---|---|
| Baseline MAC | utilisation, timing summary, power, clock utilisation, control sets, I/O | 15 Aug 2026 | Routed |
| MAC4 | utilisation, timing summary, power, clock utilisation | 19 Aug 2026 | Physopt postRoute |

Three caveats a reader is entitled to:

1. **The two runs are not at identical stages or constraints.** The baseline
   stopped at Routed because Vivado skipped physical-synthesis setup
   optimisation once WNS was already positive; the MAC4 build ran physopt. Only
   the MAC4 build carries `set_clock_uncertainty 0.500`. Utilisation for both is
   post-placement, so the area rows are comparable; the timing rows need the
   adjustment described above.
2. **The top levels differ.** The baseline exposes 23 bonded I/O
   (`clk`, `rst`, `done`, `pc_out[15:0]`, `result_out[3:0]`); the MAC4 build
   exposes 18. Some small part of the +30 register and +344 LUT delta is the
   changed port list, not `MAC4`. The direction and rough size of the deltas are
   safe; the last few percent is not.
3. **Power is vectorless.** Medium confidence, no simulation activity file, more
   than 5% of input activity unspecified. Use it for ranking, not for a
   datasheet.