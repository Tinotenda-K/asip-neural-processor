# Four bugs worth writing down

Nine distinct bugs were found and fixed while getting this design working. Four
are worth documenting, either because the diagnosis was interesting or because
the failure mode was one that hides.

The pattern across all of them: **none of these produced a crash.** Three of the
four produced a design that ran perfectly and gave wrong answers.

---

## 1. Resource overflow: 65,536 primitives against 9,600 available

**Symptom.** Synthesis completed cleanly. Implementation failed immediately with
seven DRC resource errors, plus F7 and F8 mux overflow.

**Diagnosis.** The error counts were exact, not approximate, which is what gave
it away:

```
RAMS64E required : 65,536
F7 muxes         : ~35,359
F8 muxes         : ~17,490
```

`DataMemory` was declared `reg [31:0] mem [0:131071]`. A 128K × 32 array with an
asynchronous read costs `(131072 / 64) × 32 = 65,536` RAM64X1S primitives - the
reported figure exactly, from one array. `InstructionMemory` was only 1,024
words and read-only, so it inferred as ROM and contributed almost nothing. The
F7/F8 counts follow from the mux tree needed to select one row per bit out of
that array.

So both memories had been declared full-depth with combinational reads. Vivado
cannot map an asynchronous read to Block RAM, because BRAM registers its output.
It fell back to distributed LUTRAM and built a mux tree, and the device has
roughly 9,600 LUTRAM-capable LUTs.

**Why synthesis passed.** Synthesis estimates resources; placement is where the
device's actual composition is enforced. A clean synthesis run says very little.

**Fix.** Two changes, in order. First, bound the depth - the programs need
around 1K instructions, not 64K. That alone cleared all seven DRC errors and let
implementation complete. Then, the proper fix: make both reads registered so
Vivado infers real BRAM, which required restructuring the control into a
multi-cycle FSM so there is a cycle boundary between addressing and consuming.

**Check it worked:** LUT-as-memory should read **zero** after synthesis.

---

## 2. Requantisation shift derived from the wrong scale

**Symptom.** Everything ran. The processor retired every instruction, the
simulation was clean, and the network produced confident and wrong
classifications.

**Diagnosis.** The accumulator in a quantised layer holds products of a weight
and an activation, so it carries the **product** of the two scales. The shift
used to bring it back to INT8 was derived from the weight scale alone, ignoring
`S_a` entirely - off by `log2(S_a)`, which here meant `S1 = 7` where it should
have been `S1 = 11`. A factor of 16 on every layer-1 activation.

**Fix.** Derive the shift from `S_w · S_a`. Details in
[quantisation.md](quantisation.md).

**Why it took so long.** There is no symptom to chase. A crash points at a line;
a wrong number points nowhere. This bug is the reason the golden model in
[../sim/](../sim/) exists - once there is a reference implementation, a scale
error shows up as a specific layer's output diverging, and the search space
collapses from the whole pipeline to one boundary.

Two sibling bugs had the same shape and were found the same way: biases
quantised at the weight scale instead of the accumulator scale, and an export
script normalising inputs to [-1, 1] when the model was trained on [0, 1].

---

## 3. Byte versus word addressing

**Symptom.** Loads returned data from the wrong place, but *plausibly* wrong -
values that looked like weights, just not the right weights.

**Diagnosis.** Stock MIPS is byte-addressed: `LW r5, 4(r10)` moves one 32-bit
word. This processor's data memory is word-addressed, because the packed network
is an array of 32-bit words with no sub-word access anywhere.

Both conventions were live at once. The PC increments by 4 and branch offsets
shift left by 2 (byte convention), while data memory indexes directly (word
convention). Assembly written against one convention and executed against the
other produces offsets wrong by exactly 4× - and 4× into a dense weight array
still lands on a valid-looking weight.

**Fix.** Word addressing for data memory throughout, byte convention retained
for the PC, and both stated explicitly in [isa.md](isa.md) and in the header of
the packer. A convention that lives only in someone's head is not a convention.

---

## 4. An instruction in the wrong dictionary

**Symptom.** Found before it caused damage, by reading the assembler while
adding `MAC4`.

**Diagnosis.** `SRA` and `MAC4` had been registered in the assembler's **opcode**
dictionary rather than its **funct** dictionary. Both are R-type: their opcode
field is the R-type marker and the operation lives in `funct`.

Registered as opcodes, their funct values would have been emitted in the
**opcode** field: `001011` for `SRA` and `001100` for `MAC4`. Neither is a
defined opcode in this ISA - the highest in use is `BNE` at `001000` - so both
would have fallen through `ControlUnit.v`'s default branch.

**Consequence had it shipped.** Not a crash and not a wrong control flow: a
silent no-op. Every `SRA` in a requantisation sequence and every `MAC4` in the
inner loop would have assembled, executed, retired, and done nothing. The
accumulator would never have been written, the network would have classified off
uninitialised state, and nothing in the simulation transcript would have looked
wrong. This is the same failure family as bugs 2 and 3 above - it runs, and it
is wrong - which is why it was found by reading the assembler rather than by
running anything.

**Fix.** Move both to the funct table with opcode `000000`, and add an assertion
that no R-type mnemonic carries a non-zero opcode. Both are now correct in
`assembler.py` and match `ALU.v`. The instruction table in [isa.md](isa.md) is
generated from the same source for the same reason: documentation that can
silently disagree with the tool is a bug waiting to be written.

---

## The general lesson

Three of these four ran correctly and computed the wrong thing. On a processor
you designed yourself, running a network you quantised yourself, there is no
component you can assume is right - the bug is as likely to be in the
requantisation arithmetic as in the RTL.

The single highest-value thing built in this project was not a hardware feature.
It was the ISA simulator: an independent implementation of the same instruction
set, in a different language, against which the hardware can be checked
bit-exactly. Every bug above except the first was found by divergence from it.
