# asip-neural-processor
Custom application-specific processor for neural-network inference: MIPS-like ISA, Verilog datapath, assembler written from scratch, 450 MHz on Spartan-7.

# ASIP for Neural-Network Inference

A custom application-specific instruction-set processor for accelerating
fully-connected neural-network layers, designed from the instruction set
upward and implemented on a Xilinx Spartan-7 XC7S50.

**Datapath timing closed at 2.22 ns (≈450 MHz).** The fused multiply–accumulate
instruction executes `rd = rd + rs × rt` in a single cycle, roughly halving the
cycle count per neuron against a separate multiply-then-add sequence.

![Datapath](docs/img/datapath.png)

## What this is

Most of a fully-connected layer is one operation repeated: multiply a weight by
an activation and accumulate. A general-purpose core spends two instructions an
an intermediate register on each of those. This processor spends one.

The project covers the full stack from encoding to silicon-adjacent:

- **Instruction set** - a MIPS-like ISA with R-, I- and J-type encodings,
extended with a fused MAC instruction and a ReLU instruction. Encoding tables
in [docs/isa.md](docs/isa.md).
- **Microarchitecture** - datapath, register file and control unit in Verilog,
each with its own testbench. Design notes in
[docs/architecture.md](docs/architecture.md).
- **Assembler** - written from scratch in Python; parses the assembly syntax,
resolves labels, and emits memory images the processor loads directly.
See [asm/](asm/).
- **Quantisation** - an INT8 flow that takes trained Keras weights and maps the
to processor memory images. See [quantisation/](quantisation/).

## Results
| Metric | Value |
|---|---|
| Datapath critical path | 2.22 ns (≈450 MHz) |
| Target device | Xilinx Spartan-7 XC7S50 |
| Toolchain | AMD Vivado |
| Cycles per MAC | 1 (fused) |

Raw Vivado timing and utilisation reports are in [results/](results/) rather
than summarised here, so the numbers above can be checked rather than taken on
trust.

## Running it
Simulation (Vivado, behavioural):

`vivado -mode batch -source scripts/sim.tcl`

Assembling a program:

`python asm/assembler.py asm/examples/fc_layer.asm -o build/fc_layer.mem`

Quantising a trained model:

`python quantisation/keras_to_int8.py model.h5 -o build/weights.mem`

## Scope and attribution

Sole-authored. I defined the instruction set, designed and implemented the
datapath, register file and control unit, wrote the assembler, handled timing
closure, and wrote the quantisation flow. Built as a project during the BSc
Electrical Engineering programme at the University of Twente.

## What I would change

The datapath is single-cycle, which is what made timing closure tractable and
what makes the 2.22 ns figure a fair one - but it means the clock is set by
the
slowest instruction, and memory access is that instruction. A two- or three
stage
pipeline with a hazard-detection unit would let the MAC path run considerably
faster than the load path allows today, at the cost of forwarding logic I did
not have time to verify properly.

I would also revisit the quantisation flow. It currently uses a single scale
factor per layer, which is simple and worked for the networks I tested, but
per-channel scaling is standard practice for a reason and the accuracy cost
of
the simplification is something I asserted rather than measured.

## Licence

MIT — see [LICENSE](LICENSE).
