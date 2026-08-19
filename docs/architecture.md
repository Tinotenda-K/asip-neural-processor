# Architecture

## Contents
- [Why multi-cycle](#why-multi-cycle)
- [State machine](#state-machine)
- [Datapath](#datapath)
- [Memory system](#memory-system)
- [Memory map](#memory-map)
- [Clocking](#clocking)
- [Build parameters](#build-parameters)

---

## Why multi-cycle

The first version of this processor was single-cycle: fetch, decode, execute and
writeback all resolved combinationally within one clock edge. That requires both
memories to answer *asynchronously* - the instruction word has to be available
in the same cycle the PC presents its address.

Vivado cannot map an asynchronous-read array to Block RAM, because BRAM
primitives register their read port. So it built the memories from distributed
LUTRAM plus a mux tree, and the arithmetic is unforgiving:

```
64K x 32 async array  =  (65536 / 64) x 32  =  32,768 RAM64X1S primitives
two such arrays                             =  65,536
XC7S50 LUTRAM-capable LUTs                  =  ~9,600
```

Synthesis passed, because synthesis only estimates. Placement failed with seven
DRC resource errors, plus F7/F8 mux overflow on top.

Two things had to change: **depth** (the arrays were declared full-width when
the programs need far less) and **read style** (asynchronous → registered).
Registered reads need a cycle boundary between issuing an address and consuming
the data, which is precisely what a multi-cycle FSM provides for free.

## State machine

![Control FSM](img/fsm.png)

Three states, unconditional sequence, **CPI = 3 for every instruction**:

| State | What happens |
|---|---|
| `S_FETCH` | The instruction memory read is issued at the current PC. The BRAM output register captures the instruction word at the end of the cycle. |
| `S_EXEC` | The register file is read (`rs`, `rt`), the ALU evaluates, and for `LW` / `SW` the data memory is addressed with `alu_result`. |
| `S_WB` | The register file write port commits, and the PC advances to the branch target, jump target or PC+4. |

CPI = 3 is flat and predictable, which is what makes the instruction-count
comparison between builds meaningful: 203,615 instructions × 3 = 610,845 cycles
= 12.22 ms at 50 MHz.

The obvious criticism is that most instructions do not need three cycles. That
is true, and the trade is discussed in the README's closing section - the short
version is that the alternatives either raise CPI further or need a clock this
design cannot reach with the MAC4 ALU in the path.

## Datapath

![Datapath](img/datapath.png)

Structural summary:

- **ProgramCounter** - holds PC, updated only in `S_WB`. Sources: PC+4, branch
  target, jump target.
- **InstructionMemory** - registered-read BRAM, word-addressed internally.
- **RegisterFile** - 32 × 32-bit, two read ports, one write port. Written only
  in `S_WB`. Register 0 hardwired to zero.
- **ALU** - parameterised. Always present: ADD, SUB, AND, OR, SLT, SLL, SRL,
  SRA, MAC, RELU. Behind parameters: MAC4, MULT.
- **DataMemory** - registered-read BRAM holding the packed network.
- **ControlUnit** - the three-state FSM above, producing `pc_enable`,
  `reg_write`, `mem_write`, `dmem_en`, `ir_write` and the mux selects.

**A note on the diagram.** If you are looking for the classic textbook
multi-cycle datapath with `IorD`, `IRWrite`, `ALUOut` and `A`/`B` temporaries -
this is not that machine. It has three states rather than ten, no shared
instruction/data memory, and no ALUOut register. The similarity is in the idea
(a state machine sequencing a shared datapath), not the structure.

## Memory system

Both memories are inferred as true Block RAM. The conditions Vivado requires,
all of which this design meets:

1. The read must be registered - clocked into a flop on the same edge.
2. The array must be indexed by a bounded address, not a full 32-bit word.
3. No asynchronous reset on the output register.

Verify this after synthesis by checking that **LUT-as-memory is zero** and BRAM
tile count is non-zero. If LUTRAM is non-zero, something reverted to
distributed memory and the design will not place.

### Why the network had to be packed

| | Size |
|---|---|
| Network, one INT8 value per 32-bit word | ~3,450 Kb |
| XC7S50 total BRAM | 2,700 Kb |

It did not fit - not marginally, structurally. Packing four INT8 values into
each 32-bit word reduced data memory from **110,390 words to 28,509 words**,
which fits with room for activations and scratch.

The packing has a second benefit, which is the whole reason `MAC4` exists: four
weights arrive in one word, aligned, so a single instruction can consume all
four. Unpacking them one at a time with shifts and masks would have thrown away
most of the saving.

## Memory map

Data memory layout, word-addressed:

| Region | Contents |
|---|---|
| Header | Layer dimensions, scale factors, requantisation shifts |
| Layer 1 | 784 × 128 weights, packed 4/word; biases at accumulator scale |
| Layer 2 | 128 × 64 weights, packed 4/word; biases |
| Layer 3 | 64 × 10 weights, packed 4/word; biases |
| Input | 784 INT8 pixel values, packed 4/word |
| Activations | Scratch buffers for hidden layers |
| Result | Argmax output word (word 28508) |

## MEMORY MAP word addresses
`
header      0 ..    23     8 words per layer
image      24 ..   219     196 words, PACKED
L1 w      220 .. 25307     25088 words   b 25308..25435   y 25436..25467 (32 packed)
L2 w    25468 .. 27515      2048 words   b 27516..27579   y 27580..27595 (16 packed)
L3 w    27596 .. 27755       160 words   b 27756..27765   y 27766..27775 (10 int32)
result  27776
`

**Addressing is word-based, not byte-based.** This differs from stock MIPS and
is the source of one of the more time-consuming bugs in this project; see
[debugging.md](debugging.md).

## Clocking

The board supplies 100 MHz. A single flop divides it by two, giving a 50 MHz
core clock:

```tcl
create_clock -period 10.000 -name sys_clk [get_ports clk]
create_generated_clock -name core_clk \
    -source [get_ports clk] -divide_by 2 [get_pins clk_div_reg/Q]
```

The `create_generated_clock` constraint *describes* the divider; it does not
configure it. Changing `-divide_by` without changing the RTL would make Vivado
analyse a clock that does not exist and the design would fail silently on
hardware.

At 50 MHz the MAC4 build closes at **WNS +0.066 ns**, TNS 0.000, WHS +0.101 ns,
with zero failing endpoints of 3,697. That is a genuine pass but a thin one; the
slow corner Vivado analyses already assumes worst-case process, 0.95 V and
85 °C, so a bench board at room temperature has real margin beyond it.

## Build parameters

```verilog
ALU #(.ENABLE_MAC4(0), .ENABLE_MULT(0)) alu (...);
```

Both instruction arms sit in the same combinational case statement, so an
enabled-but-unused arm lengthens the critical path and widens the result mux on
**every** instruction - including the `LW` / `MAC` / `SRL` sequence the baseline
program actually executes. The routed critical path with MAC4 enabled runs

```
IMEM BRAM out -> register-file read mux -> ALU -> DMEM address
```

with 13 of its 24 logic levels inside the MAC4 adder tree.

Turn each on only when the assembled program uses it. The area and timing delta
between configurations is a small but real ASIP result, and it is recorded in
[../results/benchmark.md](../results/benchmark.md).
