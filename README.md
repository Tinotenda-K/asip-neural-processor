# ASIP for Neural-Network Inference

A custom application-specific instruction-set processor for MNIST digit
classification, designed from the instruction set upward and implemented on a
Xilinx Spartan-7 XC7S50 (RealDigital Boolean board, Vivado 2025.1).

Runs a three-layer fully-connected network - 784 → 128 → 64 → 10 - with INT8
weights and activations. **A custom SIMD multiply-accumulate instruction cuts
inference from 447,785 to 203,615 instructions: a 2.20× speedup, or 26.9 ms
down to 12.22 ms at 50 MHz.**

![Datapath](docs/img/datapath.png)

## Results

| | MAC only | MAC4 (SIMD) |
|---|---|---|
| Instructions per inference | 447,785 | 203,615 |
| Inference time @ 50 MHz | 26.9 ms | 12.22 ms |
| Speedup | - | 2.20× |

| Implementation | Value |
|---|---|
| Core clock | 50 MHz (100 MHz board oscillator, /2) |
| Worst negative slack | +0.952 ns |
| BRAM tiles | 33 |
| LUTs | 2,162 |
| Registers | 1,012 |
| LUT-as-memory | 0 |

Inference times are derived from instruction counts and cycles-per-instruction
at 50 MHz. Raw Vivado reports are in [results/](results/).

Verified against a golden model: output logits are bit-exact against the ISA
simulator across all ten classes, with argmax matching the true label.

## Architecture

**Multi-cycle, three-state FSM** - `S_FETCH` / `S_EXEC` / `S_WB`. This is a
deliberate choice rather than a simplification: separating fetch from execute
allows *synchronous* memory reads, which is what lets Vivado infer real Block
RAM. An earlier single-cycle version with asynchronous reads demanded 65,536
RAMS64E primitives against roughly 9,600 available on the device - it
synthesised and then failed placement outright.

**Custom instructions.** On top of a MIPS-like R/I/J encoding:

| Instruction | Operation | Why |
|---|---|---|
| `MAC` | `rd ← rd + rs × rt` | One instruction where a general-purpose core spends two plus an intermediate register. |
| `MAC4` | Four signed 8×8 products, accumulated | Four INT8 pairs already share a 32-bit word after packing. Multiplying them one at a time wastes the packing. |
| `RELU` | `rd ← max(0, rs)` | Every hidden activation needs it. |
| `SRA` | Arithmetic right shift | Requantisation between layers. |

Encodings in [docs/isa.md](docs/isa.md).

**Memory.** The unpacked network needs about 3,450 Kb; the XC7S50 has 2,700 Kb
of BRAM. It did not fit. Packing four INT8 values per 32-bit word brought data
memory from 110,390 to 28,509 words, and the design now uses 33 BRAM tiles with
zero LUT-as-memory. The packing is also what makes `MAC4` worth having - the
operands arrive pre-aligned.

## Verification

Hardware alone is hard to trust. This project carries a golden model:
[sim/](sim/) contains a Python simulator of the ISA that executes the same
assembly and produces reference logits. `verify_final.py` compares the
processor's output against it word by word. Both builds - MAC and MAC4 - are
bit-exact against the model across all ten output classes.

The quantisation flow is in [tools/](tools/): trained Keras weights are
exported, quantised to INT8, packed, and emitted as `$readmemb` memory images.
The requantisation shift between layers is derived from the *product* of weight
and activation scales, which is a detail worth stating because getting it wrong
produces a network that runs correctly and classifies incorrectly - see
[docs/debugging.md](docs/debugging.md).

## Building

Two configurations, selected by the `ENABLE_MAC4` parameter:

baseline

`python asm/assembler.py asm/dnn_final_packed.asm -o build/instruction.mem python tools/pack_data_mem_v3.py -o build/data.mem`

SIMD

`python asm/assembler.py asm/dnn_mac4.asm -o build/instruction.mem`


Cross-check against the golden model before synthesis:

`python sim/verify_final.py build/instruction.mem build/data.mem`


## Scope and attribution

A two-person university project (M5 Computer Systems, University of Twente).

**Mine, alone:** the instruction set, the processor - datapath, register file,
control unit and ALU - the multi-cycle FSM, the assembler (written from
scratch), the INT8 quantisation and memory-packing flow, the ISA simulator, and
timing closure.

**Shared roughly equally with my project partner:** UART host communication,
mapping the trained model onto the memory layout, and benchmarking.

## What I would change

The three-state FSM spends a cycle on writeback that most instructions do not
need, and fetch and execute never overlap. A classic five-stage pipeline with
forwarding and a hazard-detection unit would recover most of that, but it needs
verification effort I did not have time for - and given the workload is one
instruction repeated hundreds of thousands of times, I would want to see the
hazard profile before assuming a pipeline pays for itself here.

The more interesting direction is wider SIMD. `MAC4` gave 2.20× by processing
four INT8 pairs per instruction; the arithmetic scales further, and the limit is
register-file read ports rather than the multipliers. `MAC8` against a
double-width accumulator is the obvious next experiment.

The quantisation uses a single scale per layer. Per-channel scaling is standard
practice for good reasons, and I asserted the accuracy cost of the simplification
rather than measuring it.

## Licence

MIT - see [LICENSE](LICENSE).
