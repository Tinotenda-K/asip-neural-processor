# Instruction set

A MIPS-like 32-bit ISA with three encoding formats, extended with four
instructions aimed at INT8 fully-connected inference.

> **Note on completeness.** The opcode and funct values below are marked
> `[FILL]` where they must be read out of `ControlUnit.v`, `ALU.v` and the
> `OPCODES` / `FUNCTS` dictionaries in `asm/assembler.py`. Fill them from the
> source rather than from memory — one of the bugs in this project was an
> instruction registered in the wrong dictionary, and a documentation table that
> disagrees with the assembler is worse than no table.

---

## Encoding formats

### R-type — register arithmetic

```
 31      26 25   21 20   16 15   11 10    6 5      0
+----------+-------+-------+-------+-------+--------+
|  opcode  |  rs   |  rt   |  rd   | shamt | funct  |
|    6     |   5   |   5   |   5   |   5   |   6    |
+----------+-------+-------+-------+-------+--------+
```

Opcode is `[FILL]` (000000 in stock MIPS); the operation is selected by `funct`.

### I-type — immediate, load/store, branch

```
 31      26 25   21 20   16 15                     0
+----------+-------+-------+------------------------+
|  opcode  |  rs   |  rt   |     immediate (16)     |
+----------+-------+-------+------------------------+
```

The immediate is sign-extended. Branch offsets are **word offsets**, not byte
offsets — see the addressing note below.

### J-type — jump

```
 31      26 25                                     0
+----------+----------------------------------------+
|  opcode  |            target (26)                  |
+----------+----------------------------------------+
```

---

## Register conventions

| Register | Use |
|---|---|
| `R0` | Hardwired zero |
| `R1`–`R31` | General purpose |

[FILL — if the assembler recognises named registers or reserves any by
convention (accumulator, loop counter, base pointers), document that here. It
matters for reading the `.asm` files.]

---

## Instruction table

### Arithmetic and logic

| Mnemonic | Format | Opcode | Funct | Operation |
|---|---|---|---|---|
| `ADD` | R | `[FILL]` | `[FILL]` | `rd ← rs + rt` (signed, overflow flagged) |
| `SUB` | R | `[FILL]` | `[FILL]` | `rd ← rs − rt` |
| `AND` | R | `[FILL]` | `[FILL]` | `rd ← rs & rt` |
| `OR` | R | `[FILL]` | `[FILL]` | `rd ← rs \| rt` |
| `SLT` | R | `[FILL]` | `[FILL]` | `rd ← (rs < rt) ? 1 : 0`, signed |
| `SLL` | R | `[FILL]` | `[FILL]` | `rd ← rt << shamt` |
| `SRL` | R | `[FILL]` | `[FILL]` | `rd ← rt >> shamt`, logical |
| `SRA` | R | `[FILL]` | `[FILL]` | `rd ← rt >>> shamt`, arithmetic |
| `MULT` | R | `[FILL]` | `[FILL]` | `rd ← rs × rt` — **behind `ENABLE_MULT`** |

### Memory and control flow

| Mnemonic | Format | Opcode | Operation |
|---|---|---|---|
| `LW` | I | `[FILL]` | `rt ← DMEM[rs + imm]` |
| `SW` | I | `[FILL]` | `DMEM[rs + imm] ← rt` |
| `BEQ` | I | `[FILL]` | if `rs == rt`, `PC ← PC + 4 + (imm << 2)` |
| `BNE` | I | `[FILL]` | if `rs != rt`, `PC ← PC + 4 + (imm << 2)` |
| `J` | J | `[FILL]` | `PC ← {PC[31:28], target, 2'b00}` |

### Custom instructions

These four are the reason this is an ASIP rather than a small MIPS clone.

| Mnemonic | Format | Opcode | Funct | Operation |
|---|---|---|---|---|
| `MAC` | R | `[FILL]` | `[FILL]` | `rd ← rd + sext(rs[7:0]) × sext(rt[7:0])` |
| `MAC4` | R | `[FILL]` | `[FILL]` | `rd ← rd + Σᵢ₌₀³ sext(rs[8i+7:8i]) × sext(rt[8i+7:8i])` |
| `RELU` | R | `[FILL]` | `[FILL]` | `rd ← (rs[31] == 1) ? 0 : rs` |

#### `MAC` — fused multiply-accumulate

`rd` is both a source and the destination, which is what makes this a single
instruction rather than two. It reads the **low byte** of each operand,
sign-extended.

Reading only the low byte is deliberate: a packed weight word holds four INT8
values, and `SRL` by 8 slides the next lane down into position. So a four-weight
inner loop is `MAC`, `SRL`, `MAC`, `SRL`, `MAC`, `SRL`, `MAC` — no masking, no
unpacking to separate registers.

A general-purpose core needs `MULT` into an intermediate register followed by
`ADD` for each of those, roughly doubling the instruction count per neuron.

#### `MAC4` — four-way SIMD multiply-accumulate

Takes all four lanes of both operands at once, forms four signed 8×8 products,
sums them through a balanced adder tree, and accumulates into `rd`.

This is where the 2.20× comes from. Once activations are packed four-per-word as
well as weights, the entire `SRL` lane-sliding sequence disappears:

```
; MAC only — four weights, four activations
LW   r5, 0(r10)     ; packed weights
LW   r6, 0(r11)     ; packed activations
MAC  r4, r5, r6
SRL  r5, r5, 8
SRL  r6, r6, 8
MAC  r4, r5, r6
SRL  r5, r5, 8
SRL  r6, r6, 8
MAC  r4, r5, r6
SRL  r5, r5, 8
SRL  r6, r6, 8
MAC  r4, r5, r6

; MAC4 — same work
LW   r5, 0(r10)
LW   r6, 0(r11)
MAC4 r4, r5, r6
```

**Cost.** The adder tree is not free: 13 of the 24 logic levels on the routed
critical path sit inside it. That is why it is behind `ENABLE_MAC4` and why the
baseline build turns it off — an enabled arm lengthens the ALU on every
instruction, executed or not.

#### `RELU`

`max(0, rs)`, which for a two's-complement value is a sign-bit test. Every
hidden activation needs it, so folding it into one instruction removes a compare
and a branch from the inner loop — and removes a *branch*, which on a
three-state FSM costs three cycles like everything else.

#### `SRA` — arithmetic shift for requantisation

Not a custom instruction as such, but load-bearing here. Accumulators are 32-bit
and activations are 8-bit, so each layer output is shifted right by a
requantisation amount derived from the scale factors. That shift must be
**arithmetic**, preserving sign — a logical shift turns small negative
accumulators into large positives, and the network still runs, just wrongly.
See [quantisation.md](quantisation.md).

---

## Addressing

**Data memory is word-addressed.** `LW r5, 3(r10)` reads the word at
`r10 + 3`, not `r10 + 3` bytes. This differs from stock MIPS and was chosen
because the packed network is naturally an array of 32-bit words with no
sub-word access anywhere in the program.

The program counter increments by 4 and branch offsets are shifted left by 2, as
in MIPS. **The two conventions differ**, which is exactly as confusing as it
sounds and produced one of the longer debugging sessions in this project — see
[debugging.md](debugging.md).

---

## Assembler

`asm/assembler.py` accepts this syntax, resolves labels in two passes, and emits
a `$readmemb` binary image.

```
label:              ; labels on their own line or preceding an instruction
    ADD  r1, r2, r3 ; R-type: rd, rs, rt
    LW   r5, 4(r10) ; I-type load/store
    BNE  r1, r2, loop
    J    done
    ; comments after a semicolon
```

When adding an instruction, register it in the **correct dictionary**: R-type
operations go in the funct table, everything else in the opcode table. Putting
an R-type in the opcode table produces an encoding that silently collides with a
real opcode — in this project, with `BNE`.
