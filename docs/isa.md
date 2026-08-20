# Instruction set

A MIPS-like 32-bit ISA with three encoding formats, extended with three
instructions aimed at INT8 fully-connected inference.

All opcode and funct values below are taken from `asm/assembler.py` (the
`opcodes` and `functs` dictionaries), `ALU.v` and `ControlUnit.v`. If you change
any of them, change all three - one of the bugs in this project was an
instruction registered in the wrong dictionary, and a documentation table that
disagrees with the assembler is worse than no table.

---

## Encoding formats

### R-type - register arithmetic

```
 31      26 25   21 20   16 15   11 10    6 5      0
+----------+-------+-------+-------+-------+--------+
|  opcode  |  rs   |  rt   |  rd   | shamt | funct  |
|    6     |   5   |   5   |   5   |   5   |   6    |
+----------+-------+-------+-------+-------+--------+
```

Opcode is `000000`; the operation is selected by `funct`.

### I-type - immediate, load/store, branch

```
 31      26 25   21 20   16 15                     0
+----------+-------+-------+------------------------+
|  opcode  |  rs   |  rt   |     immediate (16)     |
+----------+-------+-------+------------------------+
```

The immediate is sign-extended.

### J-type - jump

```
 31      26 25                                     0
+----------+----------------------------------------+
|  opcode  |            target (26)                 |
+----------+----------------------------------------+
```

---

## Register conventions

| Register | Use |
|---|---|
| `R0` | Hardwired zero. Writes are discarded, so it doubles as a scratch destination when a result is not wanted. |
| `R1`–`R31` | General purpose. No hardware-enforced calling convention - there are no subroutine calls in these programs. |

The inference programs use a fixed allocation by convention, documented in the
header of `asm/dnn_mac4.asm`. Summarised:

| Register | Role |
|---|---|
| `R1`, `R2` | packed activation word, packed weight word |
| `R3`, `R4` | scratch address, packed output pointer |
| `R5`, `R6` | bias, accumulator |
| `R7`, `R9` | x pointer, w pointer (word addresses) |
| `R10`, `R11` | neuron index `j`, `n_out` |
| `R12`–`R15` | `x_base`, `w_base`, `b_base`, `y_base` |
| `R16`–`R18` | weight row offset, group counter, row stride |
| `R19`–`R22` | argmax index, argmax best, scratch |
| `R23`–`R25` | requant shift, rounding offset, shift countdown |
| `R26`, `R27` | activation pack word, pack counter |

---

## Instruction table

### Arithmetic and logic (R-type, opcode `000000`)

| Mnemonic | Funct | Operation |
|---|---|---|
| `ADD` | `000000` | `rd ← rs + rt` (signed, overflow flagged) |
| `SUB` | `000001` | `rd ← rs − rt` |
| `AND` | `000010` | `rd ← rs & rt` |
| `OR` | `000011` | `rd ← rs \| rt` |
| `XOR` | `000100` | `rd ← rs ^ rt` |
| `SLL` | `000101` | `rd ← rt << shamt` |
| `SRL` | `000110` | `rd ← rt >> shamt`, logical |
| `NOT` | `001001` | `rd ← ~rs` |
| `MULT` | `001010` | `rd ← rs × rt` (low 32 bits) - behind `ENABLE_MULT` |
| `SRA` | `001011` | `rd ← rt >>> shamt`, arithmetic |

There is no `SLT`. Comparisons are done with `SUB` followed by
`SRL rd, rd, 31` to extract the sign bit - see the argmax and clip sequences in
`dnn_mac4.asm`.

### Memory and control flow

| Mnemonic | Format | Opcode | Operation |
|---|---|---|---|
| `ADDI` | I | `000100` | `rt ← rs + sext(imm)` |
| `LW` | I | `000101` | `rt ← DMEM[rs + imm]` |
| `SW` | I | `000110` | `DMEM[rs + imm] ← rt` |
| `BEQ` | I | `000111` | if `rs == rt`, `PC ← PC + 4 + (imm << 2)` |
| `BNE` | I | `001000` | if `rs != rt`, `PC ← PC + 4 + (imm << 2)` |
| `J` | J | `000010` | `PC ← {PC[31:28], target, 2'b00}` |
| `NOP` | - | `111111` | no operation |

Note that `BEQ`'s opcode (`000111`) and `MAC`'s funct (`000111`) share a bit
pattern. They occupy different fields and never conflict, but it is worth
knowing when reading raw machine words.

### Custom instructions

These three are the reason this is an ASIP rather than a small MIPS clone.

| Mnemonic | Funct | Operation | Parameter |
|---|---|---|---|
| `MAC` | `000111` | `rd ← rd + sext(rs[7:0]) × sext(rt[7:0])` | `ENABLE_MAC` |
| `MAC4` | `001100` | `rd ← rd + Σᵢ₌₀³ sext(rs[8i+7:8i]) × sext(rt[8i+7:8i])` | `ENABLE_MAC4` |
| `RELU` | `001000` | `rd ← (rs[31] == 1) ? 0 : rs` | always present |

#### `MAC` - fused multiply-accumulate

`rd` is both a source and the destination, which is what makes this a single
instruction rather than two, and why the register file needs a third read port.
It reads the **low byte** of each operand, sign-extended.

Reading only the low byte is deliberate. A packed weight word holds four INT8
values, and `SRL` by 8 slides the next lane down into position - so no masking
and no unpacking into separate registers is needed. In the baseline program the
activations are *not* packed (one INT8 per 32-bit word), so the loop loads each
activation separately:

```
LW   R2, 0(R9)     # four packed weights
LW   R1, 0(R7)     # x[i], one per word
MAC  R6, R1, R2    # lane 0
SRL  R2, R2, 8
LW   R1, 1(R7)     # x[i+1]
MAC  R6, R1, R2    # lane 1
SRL  R2, R2, 8
LW   R1, 2(R7)
MAC  R6, R1, R2    # lane 2
SRL  R2, R2, 8
LW   R1, 3(R7)
MAC  R6, R1, R2    # lane 3
ADDI R7, R7, 4
ADDI R9, R9, 1
ADDI R17, R17, 1
BNE  R17, R18, LOOP
```

16 instructions per four MACs - 4.00 per MAC. Composed of 5×`LW` (one weight
word plus four separate activations), 4×`MAC`, 3×`SRL`, 3×`ADDI` and 1×`BNE`.
The activations are loaded one at a time because in this build they are **not**
packed; only the weights are.

A general-purpose core without `MAC` would need `MULT` into a temporary plus
`ADD` for each product, taking this to roughly 5 per MAC.

#### `MAC4` - four-way SIMD multiply-accumulate

Takes all four lanes of both operands at once, forms four signed 8×8 products,
sums them through a balanced adder tree, and accumulates into `rd`.

This requires the **activations to be packed too**, four per 32-bit word, so
that lane *k* of the activation word pairs with lane *k* of the weight word.
Both are indexed by the input number *i*. Once that holds, the entire `SRL`
lane-sliding sequence and three of the four loads disappear:

```
LW   R2, 0(R9)     # four packed weights
LW   R1, 0(R7)     # four packed activations
MAC4 R6, R1, R2
ADDI R7, R7, 1     # ONE word per four inputs
ADDI R9, R9, 1
ADDI R17, R17, 1
BNE  R17, R18, LOOP
```

7 instructions per four MACs - 1.75 per MAC: 2×`LW`, 1×`MAC4`, 3×`ADDI`,
1×`BNE`. The arithmetic-and-memory core alone goes 12 → 3 (4.00×); the whole
loop body goes 16 → 7 (2.29×); the whole program goes **2.20×**
(447,785 → 203,615 instructions), the remaining gap being bias, requantisation,
`RELU`, activation re-packing and argmax, none of which `MAC4` touches.

The saving is in memory traffic and loop bookkeeping, not arithmetic: `MAC` and
`MAC4` are each a single instruction, and both take three cycles.

**Lane order is little-endian** - lane 0 is bits `[7:0]`. It must match
`tools/pack_data_mem_v3.py` exactly. A lane-order mismatch computes a
valid-looking dot product over the wrong pairs and raises no error of any kind.

**Cost.** The adder tree *defines* the routed critical path in the MAC4 build:
`IMEM BRAM out → register-file read mux → ALU → register-file write port`,
19.446 ns over 23 logic levels, eleven of them CARRY4. The baseline build's
worst path ends at the data-memory address port instead - 17.804 ns, 19 levels,
five CARRY4 - so enabling `MAC4` costs 1.24 ns of slack at 50 MHz. That is why
it sits behind `ENABLE_MAC4`: an enabled arm lengthens the ALU on every
instruction, executed or not. Numbers in
[../results/benchmark.md](../results/benchmark.md).

#### `RELU`

`max(0, rs)`, which for a two's-complement value is a sign-bit test. Every
hidden activation needs it, so folding it into one instruction removes a compare
*and* a branch from the inner loop - and a branch costs three cycles here like
everything else.

#### A note on `SRA`

`SRA` is standard MIPS, not a custom instruction, and the current programs do
not use it. Requantisation between layers uses `SRL`, which is safe **because
`RELU` runs immediately before it** and guarantees the accumulator is
non-negative.

If you ever remove that `RELU`, or requantise a signed value, you must switch to
`SRA`. A logical shift turns small negative accumulators into large positives,
and the network still runs and still classifies - just wrongly. See
[quantisation.md](quantisation.md).

---

## Addressing

**Data memory is word-addressed.** `LW r5, 3(r10)` reads the word at
`r10 + 3`, not `r10 + 3` bytes. This differs from stock MIPS and was chosen
because the packed network is naturally an array of 32-bit words with no
sub-word access anywhere in the program.

**The program counter is byte-oriented**, as in MIPS: `PC + 4` per instruction,
and branch immediates are instruction counts that the hardware shifts left by 2
(`{{14{imm16[15]}}, imm16, 2'b00}`).

The two conventions differ, which is exactly as confusing as it sounds and
produced one of the longer debugging sessions in this project. Confusing them
gives offsets wrong by a factor of four, which in a dense weight array still
lands on a plausible-looking weight - the loads succeed and the arithmetic is
silently wrong. See [debugging.md](debugging.md).

---

## Assembler

`asm/assembler.py` accepts this syntax, resolves labels in two passes, and emits
a `$readmemb` binary image.

```
label:                  # labels on their own line or preceding an instruction
    ADD  R1, R2, R3     # R-type: rd, rs, rt
    LW   R5, 4(R10)     # I-type load/store; offset is in WORDS
    BNE  R1, R2, loop
    J    done
                        # comments begin with #
```

Usage:

```
python assembler.py dnn_mac4.asm instruction_mac4.mem
```

Two positional arguments, input and output. There is no `-o` flag.

**A dead branch still to remove.** `assembler.py` also accepts a four-argument
form (`asm out data.mem params.txt`). Its `generate_data_mem` routines are
commented out, so it now writes no data image - but the branch still runs a
quantisation pass with the requantisation shift **hardcoded to `S = 7`**, which
is precisely the wrong value from bug 2 in [debugging.md](debugging.md); the
correct layer-1 shift is 11. It is a fossil of a fixed bug sitting in live code,
and the next person to call it will get plausible, wrong scales. Delete the
branch and the commented routines together. Only `pack_data_mem_v3.py` may write
a `.mem` data image.

### Adding an instruction

Register it in the **correct dictionary**: R-type operations take opcode
`000000` in `opcodes` and their real code in `functs`. Putting the funct code in
the opcode dictionary - which happened here with `SRA` and `MAC4` - makes the
assembler emit opcodes `001011` and `001100`. Neither is a defined opcode in
this ISA (the highest in use is `BNE` at `001000`), so both fall through
`ControlUnit.v`'s default branch and execute as no-ops: no error, no trap, just
an instruction that silently does nothing. Every requantisation shift and every
inner-loop dot product would have quietly evaporated.

Both are now correct in `assembler.py`: `SRA` and `MAC4` carry opcode `000000`
in `opcodes` and functs `001011` and `001100`, matching `ALU.v`.
