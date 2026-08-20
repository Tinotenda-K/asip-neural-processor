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

At float32 that is 109,184 × 32 bits ≈ **3,412 Kb** of weights alone, and the
full unpacked image - weights, biases, input, activations, header - comes to
110,390 words ≈ **3,450 Kb**. The XC7S50 has **2,700 Kb** of Block RAM in total.
Float was never an option; INT8 is what makes the network fit at all.

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

## Requantisation - the part that is easy to get wrong

A layer computes, in integer arithmetic:

```
acc = Σ (W_q * A_q) + B_q
```

`W_q` carries scale `S_w`. `A_q` carries scale `S_a`. Their **product** carries
scale `S_w · S_a` - this is the accumulator scale. To feed `acc` into the next
layer as an INT8 activation at scale `S_a`, it must be brought back down:

```
A_next = acc >> S      where   S = log2(S_w) + log2(S_a) - log2(S_a_next)
```

**The shift depends on both scales, not just the weight scale.** Deriving `S`
from the weight scale alone is arithmetically wrong by exactly `log2(S_a)`. In
this project that produced `S1 = 7` where the correct value was `S1 = 11` - a
factor of 16 error in every layer-1 activation.

What makes this bug expensive is that nothing crashes. The processor executes
correctly, every instruction retires, the pipeline is clean, and the network
produces confident, wrong answers. It is only findable by comparing against a
reference implementation - which is why the golden model in [../sim/](../sim/)
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
input by half a range - again, silent, and again only visible against a
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
| Packed, four per word (`pack_data_mem_v3.py`) | **27,777** |

Result word 27,776; 33 BRAM tiles. If a layout of **28,509** words with result
word 28,508 appears anywhere, that is the obsolete **v2** packer - see the
warning below.

That is what makes the design placeable - and it is also what makes `MAC4`
worth having, because four operands arrive already aligned in one word.

### Lane alignment

Packing must respect row boundaries. If a weight row's length is not a multiple
of four, the row must be padded rather than allowed to spill into the next row's
first lane - otherwise `MAC4` silently accumulates across a boundary. The packer
handles this; the padding is why the packed word count is not exactly
`ceil(110390 / 4)`.

---

## The flow

```
real_level_2.ipynb                          model training
    |
    |  export cell: writes level_2_weights.txt
    |  then, by hand:  rename to dnn_parameters_final.txt
    |                  prepend the input size to line 2  ->  784 128 64 10
    v
dnn_parameters_final.txt        COMMITTED.  Floats, not yet quantised.
    |                           This is where the reproducible pipeline starts.
    |  tools/pack_data_mem_v3.py
    |    - calibrate per-layer activation scales from the float model
    |    - quantise to INT8, biases at accumulator scale
    |    - derive the power-of-two requant shift per layer
    |    - pack 4 INT8 per 32-bit word, lane-aligned
    |    - lay out header, weights, biases, input, activations, result
    |    - emit $readmemb image
    v
data_mac4.mem  ->  DataMemory.v
```

**Quantisation happens in the packer.** Every scale, shift and INT8 conversion
is computed in `pack_data_mem_v3.calibrate()`. This is deliberate: the shifts
depend on the activation ranges of the specific input image, so they are
calibrated at pack time and written into header word +7 rather than baked into
the parameter file. Nothing upstream of the packer quantises anything.

### Where `dnn_parameters_final.txt` came from

`dnn_parameters_final.txt` is checked in, so the pipeline above reproduces from
it without re-running any training. The file's own history, recorded here for
completeness rather than as a build step:

The model was trained in `real_level_2.ipynb`, whose export cell writes
`level_2_weights.txt` - the same format, with two differences that were fixed by
hand:

1. **The file was renamed** to `dnn_parameters_final.txt`.
2. **The input size was prepended to line 2.** The notebook writes only the
   layer units (`128 64 10`); `parse_dnn_parameters` requires `num_layers + 1`
   sizes with the input size first (`784 128 64 10`) and raises otherwise. This
   is the error the packer reports as *"Line 2 must list 4 sizes (input size
   first)"*.

Two caveats if you regenerate rather than use the committed file. The notebook
as committed builds **784 → 10 → 10 → 10**, not the network this processor runs
- the final model came from a run with the `Dense` units changed to 128 / 64 /
10 that was not saved back. And a 10-unit hidden layer would be rejected by the
packer anyway, because the assembly packs activations four to a word and flushes
on every fourth neuron, so hidden layers must be a multiple of four.

Regenerating the weights therefore means retraining, and the committed
parameter file exists precisely so that nobody has to.

---

## Verifying the flow

Do not trust it. Check it:

```bash
python sim/sim_isa.py build/instruction_mac4.mem build/data_mac4.mem
```

Both arguments are optional - they default to `instruction_mac4.mem` and
`data_mac4.mem`. The script reads the data image as-is and first checks its word
count against what the packer expects, which catches a v2/v3 layout mismatch
before a single instruction executes. Pass `--regen` only when you deliberately
want the image rebuilt.

For the regression sweep across several weight magnitudes, use the other
harness - note that its second argument is the **packer**, not a data image:

```bash
python sim/verify_final.py instruction_mac4.mem pack_data_mem_v3.py
```

`verify_final.py` generates its own memory images into `_v.mem`, including three
synthetic networks, so it must never be pointed at a real `.mem` file.

The golden model executes the same program against the same memory image and
prints the ten output logits. They should match the hardware simulation
bit-exactly - not approximately. Any divergence at all means a scale, a shift,
or a lane alignment is wrong, and approximate agreement is the most dangerous
result of the three because it looks like rounding.
