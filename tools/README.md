# Toolchain — weights to memory image

Everything between the committed float weights and the `$readmemb` file
`DataMemory.v` loads at elaboration.

## The chain

```
dnn_parameters_final.txt   (committed)  ----+
                                            |  pack_data_mem_v3.py
export_mnist_image.py  ->  mnist_image.mem -+
                           mnist_image.scale |
                           mnist_label.txt   v
                                        data_mac4.mem
```

The pipeline starts at `dnn_parameters_final.txt`, which is checked in. Nothing
here retrains or re-exports a model; see *Provenance* at the bottom for where
that file came from.

## Files

| File | Purpose |
|---|---|
| `pack_data_mem_v3.py` | All of it. Calibrates per-layer activation scales against the float model, quantises weights to INT8 and biases to int32 at accumulator scale, derives the power-of-two requantisation shift per layer, packs four INT8 per 32-bit word, lays out the memory map, and writes the image. Also carries the golden and float models used by [../sim/](../sim/). |
| `export_mnist_image.py` | One MNIST test digit → `mnist_image.mem`, `mnist_image.scale` and `mnist_label.txt`. See the warnings below. |
| `dnn_parameters_final.txt` | Committed float weights and biases. The input to everything above. |

## Usage

```bash
python tools/export_mnist_image.py
python tools/pack_data_mem_v3.py dnn_parameters_final.txt data_mac4.mem \
       mnist_image.mem 127.0
```

`pack_data_mem_v3.py` takes `params out.mem [image] [x_scale] [headroom]`.
`x_scale` defaults to 127.0 and `headroom` to 2.0. It prints the memory map, the
per-layer scales and the requantisation shifts, then runs the golden model and
the float model and compares their argmax.

Expected layout for 784 → 128 → 64 → 10: **27,777 words, result word 27,776**,
shifts 11 / 8 / 0. If you see 28,509 words with result word 28,508, that is the
obsolete v2 packer.

## The one rule

**Only `pack_data_mem_v*.py` may write a `.mem` data image.**

This is not style. Two separate incidents came from breaking it:
`assembler.py`'s four-argument form used to overwrite a correctly-packed image
with an unpacked layout, and `sim_isa.py` used to regenerate the image with the
v2 packer before running the MAC4 binary against it. Both produced a design that
simulated cleanly and computed nonsense.

The one deliberate exception is `sim/verify_final.py`, which writes `_v.mem`
because it generates synthetic networks. It must never be pointed at a real
image.

## Things that will silently ruin a build

**The exported image is not fixed.** `export_mnist_image.py` picks its test
digit with an unseeded `random.randint`, so every run exports a different digit.
That invalidates anything recorded against a specific image — the golden logits,
the argmax, the true label — and, less obviously, the **requantisation shifts**,
because the packer calibrates them from the activation ranges of the actual
input. Re-exporting silently changes header word +7 and therefore what the
assembly does. Re-export only when you intend to, and re-record the logits when
you do. The recorded reference run gives logits

```
[-23156, -3442, -11215, 16736, -14205, 6306, -17383, -10368, 1316, -1613]
```

with argmax 3 against a true label of 3.

**Input normalisation, and why it is not fixed at source.** The model trains on
pixels in **[0, 1]**; `export_mnist_image.py` writes the **[-1, 1]** mapping —
`(p/255)*2 - 1`. That is an affine mismatch, and it is bug 3 in
[../docs/debugging.md](../docs/debugging.md). `load_image()` in the packer
detects it (a [0,1] image quantises to 0..127 and can never go strongly
negative) and remaps, printing
`[fix] ... remapped to [0,1] to match training`. **That line is expected, not a
fault.**

Correcting it in the exporter would be cleaner engineering and would change the
numbers. The repair path rounds twice — once to int8 on the [-1,1] scale, once
again after the remap — and a direct [0,1] quantisation differs from the
repaired result on roughly 5% of pixels (41 of 784 on a representative image),
always by exactly one LSB. That is enough to move the layer-1 accumulator and
therefore every bit-exact logit in `results/`. Fix it only as a deliberate act,
re-running the golden model and re-recording the logits in the same commit.

**The input scale is 127.0 by accident.** `max|array|` is driven by the
background, which maps to −1.0 in every MNIST image, not by the digit — so the
scale is exactly 127.0 regardless of which image is exported, and the packer's
`x_scale` argument of 127.0 agrees with it for that same accidental reason. If
the normalisation ever changes, this stops being true and both sides need
revisiting.

**Lane order.** Packing is little-endian: lane 0 is bits [7:0]. It must match
`ALU.v`'s `MAC4` exactly. A mismatch computes a valid-looking dot product over
the wrong pairs and raises no error of any kind.

## Requantisation shifts are not hardcoded

`pack_data_mem_v3.py`'s header comment says to hardcode the printed shifts into
the assembly because the ISA has no variable-shift instruction. **That
instruction is still missing, but the advice is stale.** Both programs read the
shift from header word +7 and apply it with a countdown loop of single-bit
`SRL`s, so the same binary adapts to whatever the packer computes.
`sim/verify_final.py` exists to prove exactly that, by running one binary against
networks with deliberately different weight magnitudes.

The cost is four instructions per bit per neuron. An `SRLV`-style register-shift
instruction is the best remaining speedup-per-gate in this design — see the root
[README](../README.md).

## Provenance of `dnn_parameters_final.txt`

Recorded for completeness. This is history, not a build step — the file is
committed, and the pipeline above runs from it.

The model was trained in `real_level_2.ipynb`, whose export cell writes
`level_2_weights.txt` in the same format. Two things were then fixed by hand:
the file was **renamed**, and the **input size was prepended to line 2**. The
notebook writes only the layer units (`128 64 10`), while `parse_dnn_parameters`
requires `num_layers + 1` sizes with the input first (`784 128 64 10`) — the
error it reports otherwise is *"Line 2 must list 4 sizes (input size first)"*.

Two caveats if you ever regenerate rather than use the committed file:

- The notebook **as committed builds 784 → 10 → 10 → 10** (8,070 parameters),
  not the 784 → 128 → 64 → 10 network this processor runs (109,386 parameters).
  The final model came from a run with the `Dense` units changed that was not
  saved back.
- A 10-unit hidden layer would be rejected by the packer regardless, because the
  assembly packs activations four to a word and flushes on every fourth neuron,
  so every hidden layer must be a multiple of four.

Regenerating therefore means retraining. The committed parameter file exists so
that nobody has to.

---

Every claim in this document has been checked against the file it describes.