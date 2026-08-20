# ASIP for Neural-Network Inference

A custom application-specific instruction-set processor for MNIST digit
classification, designed from the instruction set upward and implemented on a
Xilinx Spartan-7 XC7S50 (RealDigital Boolean board, Vivado 2025.1).

Runs a three-layer fully-connected network - 784 → 128 → 64 → 10 - with INT8
weights and activations. **A custom SIMD multiply-accumulate instruction cuts
inference from 447,785 to 203,615 instructions: a 2.20× speedup, or 26.87 ms
down to 12.22 ms at 50 MHz.**

![Datapath](docs/img/datapath.png)

## Results

| | MAC only | MAC4 (SIMD) |
|---|---|---|
| Instructions per inference | 447,785 | 203,615 |
| Cycles (CPI = 3) | 1,343,355 | 610,845 |
| Inference time @ 50 MHz | 26.87 ms | 12.22 ms |
| Speedup | - | **2.20×** |

| Implementation | MAC only | MAC4 (SIMD) |
|---|---|---|
| Core clock | 50 MHz (100 MHz board oscillator, /2) | 50 MHz |
| Worst negative slack | +1.270 ns | +0.029 ns |
| Clock uncertainty applied | 0.035 ns | 0.535 ns |
| Slice LUTs | 1,661 | 2,005 |
| Registers | 1,024 | 1,054 |
| CARRY4 | 50 | 103 |
| BRAM tiles | 33 of 75 | 33 of 75 |
| DSP48E1 | 0 of 120 | 0 of 120 |
| LUT-as-memory | 0 | 0 |
| Total on-chip power | 0.156 W | 0.166 W |

The SIMD build's slack is reported against a requirement tightened by an
explicit `set_clock_uncertainty 0.500`; at the baseline's uncertainty it is
≈ +0.529 ns. So `MAC4` costs roughly 0.74 ns and 344 LUTs, and buys 2.20×.

Inference times are derived from instruction counts at a flat CPI of 3. Raw
Vivado reports for both builds are in [results/](results/), and the full
comparison with critical paths and power is in
[results/benchmark.md](results/benchmark.md).

Verified against a golden model: output logits are bit-exact against the ISA
simulator across all ten classes, with argmax matching the true label.

## Architecture

**Multi-cycle, three-state FSM** - `S_FETCH` / `S_EXEC` / `S_WB`. This is a
deliberate choice rather than a simplification: separating fetch from execute
allows *synchronous* memory reads, which is what lets Vivado infer real Block
RAM. An earlier single-cycle version with asynchronous reads demanded 65,536
RAMS64E primitives against roughly 9,600 available on the device - it
synthesised and then failed placement outright.

**Custom instructions.** On top of a MIPS-like R/I/J encoding, three
instructions make this an ASIP rather than a small MIPS clone:

| Instruction | Operation | Why |
|---|---|---|
| `MAC` | `rd ← rd + sext(rs[7:0]) × sext(rt[7:0])` | One instruction where a general-purpose core spends two plus an intermediate register. Reads the low byte so `SRL` can slide the next lane of a packed word into place. |
| `MAC4` | `rd ← rd + Σ sext(rs[8i+7:8i]) × sext(rt[8i+7:8i])` | Four INT8 pairs already share a 32-bit word after packing. Multiplying them one at a time wastes the packing. |
| `RELU` | `rd ← max(0, rs)` | Every hidden activation needs it, and folding it in removes a compare *and* a branch from the inner loop. |

`SRA` is also implemented, but it is standard MIPS rather than a custom
instruction and **neither program uses it**: requantisation runs immediately
after `RELU`, so the accumulator is non-negative and `SRL` is safe. `SRA` exists
for any future path that requantises a signed value. Encodings in
[docs/isa.md](docs/isa.md).

**Memory.** The unpacked network needs about 3,450 Kb; the XC7S50 has 2,700 Kb
of BRAM. It did not fit. Packing four INT8 values per 32-bit word brought data
memory from 110,390 to **27,777 words**, and the design uses 33 BRAM tiles with
zero LUT-as-memory. The packing is also what makes `MAC4` worth having - the
operands arrive pre-aligned, four to a word.

## Verification

Hardware alone is hard to trust. This project carries a golden model:
[sim/](sim/) contains a Python implementation of the ISA that executes the same
assembled binary against the same memory image and produces reference logits.
`sim_isa.py` runs the real network in detail; `verify_final.py` runs the same
binary against four networks with different weight magnitudes and reports
pass/fail per case. Both builds are bit-exact against the model across all ten
output classes.

The quantisation flow is in [tools/](tools/). It starts from the committed
`dnn_parameters_final.txt` - float weights exported from the trained Keras model
- which `pack_data_mem_v3.py` quantises to INT8, packs four to a word and emits
as a `$readmemb` image. Training lives in `real_level_2.ipynb` and is kept as
provenance rather than as a build step; see [tools/README.md](tools/README.md).
The requantisation shift between layers is derived from the *product* of weight
and activation scales, which is worth stating because getting it wrong produces
a network that runs correctly and classifies incorrectly - see
[docs/debugging.md](docs/debugging.md).

## Building

Two configurations, selected by the `ENABLE_MAC4` and `ENABLE_MAC` parameters on
the ALU instantiation. Both change: the SIMD program issues zero plain `MAC`
instructions, and an enabled-but-unused arm lengthens the critical path on every
instruction.

**Baseline** - `ALU #(.ENABLE_MAC4(0), .ENABLE_MAC(1), .ENABLE_MULT(0))`

```bash
python asm/assembler.py asm/dnn_final_packed.asm build/instruction.mem
python tools/pack_data_mem_v3.py dnn_parameters_final.txt build/data.mem \
       mnist_image.mem 127.0
```

**SIMD** - `ALU #(.ENABLE_MAC4(1), .ENABLE_MAC(0), .ENABLE_MULT(0))`

```bash
python asm/assembler.py asm/dnn_mac4.asm build/instruction_mac4.mem
```

`assembler.py` takes two positional arguments, input and output. There is no
`-o`. Only `pack_data_mem_v3.py` may write a `.mem` data image.

Cross-check against the golden model before synthesis:

```bash
python sim/sim_isa.py build/instruction_mac4.mem build/data_mac4.mem
```

Both arguments default to `instruction_mac4.mem` and `data_mac4.mem`, so bare
`python sim/sim_isa.py` runs the SIMD build.

## Scope and attribution

A two-person university project (M5 Computer Systems, University of Twente).

**Mine, alone:** the instruction set, the processor - datapath, register file,
control unit and ALU - the multi-cycle FSM, the assembler (written from
scratch), the INT8 quantisation and memory-packing flow, the ISA simulator, and
timing closure.

**Shared roughly equally with my project partner:** UART host communication,
mapping the trained model onto the memory layout, and benchmarking.

## What I would change

**A register-shift instruction, first.** The ISA has no variable shift, so
requantisation by `S` is a countdown loop of single-bit `SRL`s - four
instructions per bit, per neuron, with `S1 = 11` and `S2 = 8`. An `SRLV`-style
instruction would collapse each loop to one instruction for a fraction of the
logic `MAC4` cost. It is the best remaining ratio of speedup to gates in this
design, and I built the harder thing first.

**Pipelining.** The three-state FSM spends a cycle on writeback that most
instructions do not need, and fetch and execute never overlap. A classic
five-stage pipeline with forwarding and hazard detection would recover most of
that, but it needs verification effort I did not have - and given the workload
is one instruction repeated hundreds of thousands of times, I would want to see
the hazard profile before assuming a pipeline pays for itself here.

**Wider SIMD.** `MAC4` gave 2.20× at four INT8 pairs per instruction; the
arithmetic scales further, and the limit is register-file read ports rather than
the multipliers. `MAC8` against a double-width accumulator is the obvious
experiment - though note that `MAC4` already defines the critical path, so `MAC8`
would likely cost the 50 MHz clock and have to be pipelined or clocked slower.

**Per-channel quantisation.** The flow uses a single scale per layer. Per-channel
scaling is standard practice for good reasons, and I asserted the accuracy cost
of the simplification rather than measuring it.

## Licence

MIT - see [LICENSE](LICENSE).
