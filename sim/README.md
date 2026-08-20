# ISA simulator - the golden model

An independent implementation of the processor's instruction set in Python, used
as a reference to verify the hardware bit-exactly.

## Why this exists

A custom processor running a network you quantised yourself has no trustworthy
component. If the output is wrong, the fault could be in the RTL, the assembler,
the quantisation scales, the memory packing, or the assembly program - and a
wrong classification points at none of them.

An independent implementation collapses that search space. When the hardware and
the model disagree, the divergence is at a specific instruction on a specific
cycle, and the bug lies between there and the last point they agreed.

Every bug in this project except the resource overflow was found this way.

## Files

| File | Purpose |
|---|---|
| `isa_sim_core.py` | The interpreter. Decodes and executes each instruction against a register file and a 32,768-word memory image, mirroring the RTL's semantics: sign extension, `R0` hardwired to zero, word-addressed loads and stores, byte-oriented PC with word branch offsets, little-endian lane order in `MAC4`, and a self-jump as halt. Shared by both drivers so the simulator exists in exactly one place - a previous version had a copy in each file, and they drifted. |
| `sim_isa.py` | Single-case driver. Runs one real network in detail and reports instruction count, cycles at CPI 3, milliseconds, the hardware logits, the golden logits and the float reference. |
| `verify_final.py` | Regression harness. Runs the **same** assembled binary against four networks - the real one plus three synthetic ones at different weight magnitudes - and reports pass/fail per case. |

## Usage

```bash
# one real case, in detail
python sim/sim_isa.py instruction_mac4.mem data_mac4.mem

# four cases, pass/fail each
python sim/verify_final.py instruction_mac4.mem pack_data_mem_v3.py
```

Both arguments to `sim_isa.py` are optional and default to `instruction_mac4.mem`
and `data_mac4.mem`, so bare `python sim/sim_isa.py` runs the SIMD build.
`--mhz` defaults to 50, which is the core clock, not the 100 MHz board clock.

**`verify_final.py`'s second argument is the packer, not a data image.** It
imports the packer as a module and generates its own memory images into
`_v.mem`. Pointing it at a real `.mem` file will fail, and pointing anything
else at `_v.mem` is meaningless. This is the one script in the repository that
writes a `.mem` file on purpose and is not a packer.

Expected output from `sim_isa.py`:

```
instructions 203,615   cycles@CPI3 610,845   @50MHz 12.22 ms
hw     : [-23156, -3442, -11215, 16736, -14205, 6306, -17383, -10368, 1316, -1613]
hw argmax 3   golden 3   float 3
true label 3   -> CORRECT
MATCH
```

The 447,785 and 203,615 instruction counts quoted in the top-level README come
from these runs.

## What each harness is actually testing

They are not redundant, and the distinction matters.

`sim_isa.py` proves the **hardware and the model agree on the real network**. It
reads the real `$readmemb` images - the same files the RTL loads - as-is, and
checks the image's word count against what the packer expects before executing
anything, which catches a v2/v3 layout mismatch immediately.

`verify_final.py` proves the **assembly is not overfitted to one set of
weights**. Cases 1 to 3 are deliberately synthetic: pseudo-random networks at
three weight magnitudes, generated fresh each run. Because this ISA has no
variable-shift instruction, requantisation is a countdown loop of single-bit
`SRL`s reading the shift out of header word +7 - so a network with different
weight magnitudes gets a different shift, and the same binary has to adapt to it
at runtime. Synthetic data is the point of this harness, not a shortcut.

## Rules it follows

**It mirrors semantics, not implementation.** The model is written independently
of the Verilog rather than transliterated from it. A model derived from the RTL
reproduces the RTL's bugs and agrees with it perfectly.

**Agreement must be exact.** Not close, not within rounding. In fixed-point
integer arithmetic every operation is exactly defined, so any divergence is a
real disagreement about semantics. Approximate agreement is the most dangerous
of the three outcomes, because it looks like rounding and is usually a scale
error.

**One simulator, two drivers.** Anything that changes instruction semantics
changes `isa_sim_core.py` and nothing else.

## Known gaps

Stated rather than discovered later:

- **`SRA` takes the wrong source operand.** `isa_sim_core.py` computes
  `rs >>> shamt`; `ALU.v` computes `rt >>> shamt`, matching `SLL` and `SRL`.
  Latent only because neither program executes `SRA` - both requantise with
  `SRL` after `RELU`. Fix the simulator before any program uses `SRA`.
- **The simulator does not model the ALU parameters.** It always executes `MAC`
  and `MAC4`, whereas hardware built with `ENABLE_MAC4(0)` returns zero for
  `MAC4`. Harmless today because each program only issues the instruction its
  build enables, but the model will not catch a parameter/program mismatch.
- **Overflow flags are not modelled.** `ALU.v` computes signed-overflow flags
  for `ADD` and `MULT`; the simulator does not. Nothing downstream consumes
  them, in either implementation.

## Extending it

When adding an instruction, add it here **first**, run the program in the model,
and confirm the instruction count and output change as expected. Then implement
it in RTL. Building the reference before the hardware means the hardware has
something to be wrong against from its first simulation - which is how `MAC4`
was brought up.
