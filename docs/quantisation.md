# INT8 quantisation and memory packing

How a float32 Keras model becomes a `$readmemb` image the processor can execute.

---

## Why quantise at all

Two reasons, and the second is the binding one.

**Arithmetic.** The FPGA has no floating-point unit worth using here. INT8
multiply-accumulate maps onto DSP48E1 slices and LUT logic directly.

**Capacity.** This is the real constraint. The network is 784 → 128 → 64 → 10:

| Layer | Weights |
|---|---|
| 1 | 784 × 128 = 100,352 |
| 2 | 128 × 64 = 8,192 |
| 3 | 64 × 10 = 640 |
| **Total** | **109,184** plus biases |

At float32 that is roughly 3,500 Kb of weights alone. The XC7S50 has **2,700 Kb**
of Block RAM in total. Float was never an option; INT8 is what makes the network
fit at all.

---

## The quantisation scheme

Symmetric, per-tensor, power-of-two scales.

For a tensor `W` with float values, the scale is chosen so the largest magnitude
maps to ±127:

```
S_w  = 2^k  such that  max|W| * S_w  <=  127
W_q  = round(W * S_w)      clipped to [-128, 127]
```

Activations are scaled the same way, with their own `S_a`.

**Per-tensor, not per-channel.** Per-channel scaling gives better accuracy and is
standard practice in production INT8 pipelines. This implementation uses one
scale per layer because it keeps the requantisation to a single shift. The
accuracy cost was asserted rather than measured, which is a fair criticism of the
project.

---

## Requantisation — the part that is easy to get wrong

A layer computes, in integer arithmetic:

```
acc = Σ (W_q * A_q) + B_q
```

`W_q` carries scale `S_w`. `A_q` carries scale `S_a`. Their **product** carries
scale `S_w · S_a` — this is the accumulator scale. To feed `acc` into the next
layer as an INT8 activation at scale `S_a`, it must be brought back down:

```
A_next = acc >> S      where   S = log2(S_w) + log2(S_a) - log2(S_a_next)
```

**The shift depends on both scales, not just the weight scale.** Deriving `S`
from the weight scale alone is arithmetically wrong by exactly `log2(S_a)`. In
this project that produced `S1 = 7` where the correct value was `S1 = 11` — a
factor of 16 error in every layer-1 activation.

What makes this bug expensive is that nothing crashes. The processor executes
correctly, every instruction retires, the pipeline is clean, and the network
produces confident, wrong answers. It is only findable by comparing against a
reference implementation — which is why the golden model in [../sim/](../sim/)
exists.

### Biases

Biases are added to the accumulator, so they must be quantised **at the
accumulator scale**, not at the weight scale:

```
B_q = round(B * S_w * S_a)        correct
B_q = round(B * S_w)              wrong by a factor of S_a
```

Same failure mode: it runs, and it is wrong.

### Input normalisation

The model was trained on inputs in **[0, 1]**. The export path must match. An
early version of the export script normalised to [-1, 1], which shifts every
input by half a range — again, silent, and again only visible against a
reference.

The general lesson, which cost three separate bugs in this project: **in a
quantised pipeline, a scale error is not a crash. It is a wrong answer that
looks like a right one.** Every scale boundary needs a test.

---

## Packing

After quantisation, each weight is one byte. Storing one byte per 32-bit word
wastes 75% of the memory, and the network does not fit at that density.

Four INT8 values are packed per 32-bit word, little-endian by lane:

```
 31      24 23      16 15       8 7        0
+----------+----------+----------+----------+
|  lane 3  |  lane 2  |  lane 1  |  lane 0  |
+----------+----------+----------+----------+
```

| | Words |
|---|---|
| Unpacked, one value per word | 110,390 |
| Packed, four per word | **28,509** |

That is what makes the design placeable — and it is also what makes `MAC4`
worth having, because four operands arrive already aligned in one word.

### Lane alignment

Packing must respect row boundaries. If a weight row's length is not a multiple
of four, the row must be padded rather than allowed to spill into the next row's
first lane — otherwise `MAC4` silently accumulates across a boundary. The packer
handles this; the padding is why the packed word count is not exactly
`ceil(110390 / 4)`.

---

## The flow

```
Keras .h5
    |
    |  tools/export_weights.py
    |    - extract weights and biases per layer
    |    - compute per-tensor power-of-two scales
    |    - quantise to INT8, biases at accumulator scale
    |    - emit dnn_parameters_final.txt
    v
dnn_parameters_final.txt
    |
    |  tools/pack_data_mem_v3.py
    |    - pack 4 INT8 per 32-bit word, lane-aligned
    |    - lay out header, weights, biases, input, scratch, result
    |    - emit $readmemb image
    v
data.mem  ->  DataMemory.v
```

**Use `pack_data_mem_v3.py`.** Earlier versions produced a different memory
layout, and running v2's packer against v3's assembly gives a design that
simulates cleanly and computes nonsense. Only v3 is in this repository, for
exactly that reason.

---

## Verifying the flow

Do not trust it. Check it:

```bash
python sim/verify_final.py build/instruction.mem build/data.mem
```

The golden model executes the same program against the same memory image and
prints the ten output logits. They should match the hardware simulation
bit-exactly — not approximately. Any divergence at all means a scale, a shift,
or a lane alignment is wrong, and approximate agreement is the most dangerous
result of the three because it looks like rounding.
