# -*- coding: utf-8 -*-
"""
pack_data_mem_v3.py -- INT8-packed WEIGHTS *and* ACTIVATIONS, for MAC4.

v2 fixes the reason the golden model predicted the wrong digit.

THE BUG
-------
v1 chose the inter-layer right-shift as round(log2(w_scale)), i.e. it undid
the WEIGHT scale only. That is wrong.

The accumulator after layer l sits at scale a_scale[l] * w_scale[l].
Undoing only w_scale leaves the activation at a_scale[l] = 127, which assumes
each layer's output floats span the same range as its input floats. They do
not. MNIST inputs are in [0, 1]; layer-1 pre-activations are in roughly
[-15, 15]. So the requantised activation came out around 15 * 127 = 1900,
got clipped to 127, and essentially every hidden unit saturated. All
information was destroyed in layer 1 and the argmax became arbitrary.

THE FIX
-------
Each layer gets its OWN activation scale, calibrated from the float model:

    acc_scale[l]  = a_scale[l] * w_scale[l]
    shift[l]      = round(log2( acc_scale[l] / (127 / peak_activation) ))
    a_scale[l+1]  = acc_scale[l] / 2**shift[l]

Biases are stored as int32 at acc_scale[l]. The final layer gets shift 0 --
argmax is scale-invariant, so there is nothing to requantise.

The shifts are printed AND written to header word +7. Hardcode the printed
values into the assembly (the ISA has no variable-shift instruction).

MEMORY LAYOUT (word indices; DataMemory.v is word-addressed)
------------------------------------------------------------
  [0 .. 8L-1]                        header, 8 words per layer
  [x_base[0] ..]                     input image, 4 int8 per 32-bit word
  per layer l:
    [w_base[l] ..]                   PACKED weights, 4 int8 per word
    [b_base[l] ..]                   biases, int32, at acc_scale[l]
    [y_base[l] ..]                   activations, 4 int8 per 32-bit word
  [result_word]                      one word for the argmax result

Header for layer l (base = 8*l):
  +0 n_in          +1 n_out         +2 x_base        +3 w_base
  +4 b_base        +5 y_base        +6 w_row_stride  +7 requant_shift

Weight for neuron j, input i:
  word = w_base + j*w_row_stride + (i >> 2),  byte = i & 3
"""

import sys
import numpy as np

HEADER_WORDS_PER_LAYER = 8


def quantize_to_int8(array):
    a = np.asarray(array, dtype=np.float64)
    max_val = np.max(np.abs(a))
    scale = 127.0 / max_val if max_val != 0 else 1.0
    q = np.clip(np.round(a * scale), -127, 127).astype(np.int8)
    return q, scale


def pack_int8_words(int8_flat):
    a = np.asarray(int8_flat, dtype=np.int64) & 0xFF
    pad = (-len(a)) % 4
    if pad:
        a = np.concatenate([a, np.zeros(pad, dtype=np.int64)])
    return (a[0::4] | (a[1::4] << 8) | (a[2::4] << 16) | (a[3::4] << 24))


def to_bin32(val):
    return format(int(val) & 0xFFFFFFFF, '032b')


def bin_str_to_signed_int(s):
    v = int(s, 2)
    return v - (1 << 32) if v & (1 << 31) else v


def load_image(image_file, x_scale=127.0, verbose=True):
    """Load mnist_image.mem and return int8 inputs matching the network's
    training normalisation.

    export_mnist_image.py maps pixels to [-1, 1]:
        array = (pixels / 255) * 2 - 1
    but level_2.py trains on [0, 1]:
        x_train = pixels / 255
    Feeding the [-1, 1] version to the network is an affine mismatch: every
    background pixel becomes -1 instead of 0, so the whole first layer sees
    the wrong input. Detected here by the presence of strongly negative
    values (a [0,1] image quantises to 0..127 and can never go below 0).
    """
    q = np.array([bin_str_to_signed_int(l.strip())
                  for l in open(image_file) if l.strip()], dtype=np.int64)

    if q.min() < -1:
        pix = (q / x_scale + 1.0) / 2.0          # undo (p*2 - 1)
        q = np.clip(np.round(pix * x_scale), 0, 127).astype(np.int64)
        if verbose:
            print(f"[fix] {image_file} was exported on the [-1,1] mapping; "
                  f"remapped to [0,1] to match training")
    return q


def parse_dnn_parameters(filename):
    with open(filename, "r") as f:
        lines = [l.strip() for l in f if l.strip() and not l.startswith("#")]

    num_layers = int(lines[0])
    layer_sizes = list(map(int, lines[1].split()))
    if len(layer_sizes) != num_layers + 1:
        raise ValueError(
            f"Line 2 must list {num_layers + 1} sizes (input size first), got "
            f"{layer_sizes}. Notebook cell 18 omits the 784 -- prepend it.")

    n_in, n_out = layer_sizes[:-1], layer_sizes[1:]

    idx = 2
    weights = []
    for l in range(num_layers):
        w = np.array([float(x) for x in lines[idx].split()])
        idx += 1
        if w.size != n_in[l] * n_out[l]:
            raise ValueError(f"layer {l}: expected {n_in[l]*n_out[l]} weights, got {w.size}")
        # Keras Dense stores (n_in, n_out); transpose to (n_out, n_in) so each
        # neuron's weights are contiguous, matching the assembly's row stride.
        weights.append(w.reshape((n_in[l], n_out[l])).T.copy())

    biases = []
    for l in range(num_layers):
        b = np.array([float(x) for x in lines[idx].split()])
        idx += 1
        if b.size != n_out[l]:
            raise ValueError(f"layer {l}: expected {n_out[l]} biases, got {b.size}")
        biases.append(b)

    return weights, biases


def calibrate(weights_f, biases_f, x_float, x_scale, headroom=2.0):
    """Per-layer activation scales and power-of-two requant shifts."""
    L = len(weights_f)
    w_q, w_scale = [], []
    for w in weights_f:
        q, s = quantize_to_int8(w)
        w_q.append(q)
        w_scale.append(s)

    a_f = np.asarray(x_float, dtype=np.float64)
    a_scale = x_scale

    acc_scale, shift, b_q, a_scales = [], [], [], [x_scale]

    for l in range(L):
        acc_s = a_scale * w_scale[l]
        acc_scale.append(acc_s)
        b_q.append(np.round(biases_f[l] * acc_s).astype(np.int64))

        z_f = weights_f[l] @ a_f + biases_f[l]
        last = (l == L - 1)
        a_next_f = z_f if last else np.maximum(z_f, 0.0)

        if last:
            s = 0                       # argmax is scale-invariant
        else:
            peak = np.max(np.abs(a_next_f)) * headroom
            target = 127.0 / peak if peak > 0 else 1.0
            s = max(0, int(round(np.log2(acc_s / target))))
        shift.append(s)

        a_scale = acc_s / (2 ** s)
        a_scales.append(a_scale)
        a_f = a_next_f

    return dict(w_q=w_q, w_scale=w_scale, b_q=b_q,
                acc_scale=acc_scale, shift=shift, a_scales=a_scales)


def golden_model(cal, inputs_q, verbose=True):
    """Bit-exact replica of what the assembly executes:
       acc = sum(sext8(x) * sext8(w)) + bias
       relu, then (acc + 2^(s-1)) >> s, then CLIP to [0,127].

    v3: the clip is no longer cosmetic. With packed activations an
    out-of-range byte overflows into the NEIGHBOURING lane, corrupting a
    different input. The assembly now clips explicitly, so this model matches
    it exactly rather than by luck of headroom."""
    x = np.asarray(inputs_q, dtype=np.int64)
    L = len(cal['w_q'])
    for l in range(L):
        acc = cal['w_q'][l].astype(np.int64) @ x + cal['b_q'][l]
        if l < L - 1:
            acc = np.maximum(acc, 0)
            s = cal['shift'][l]
            if s > 0:
                acc = (acc + (1 << (s - 1))) >> s
            sat = int(np.sum(acc > 127))
            if verbose and sat:
                print(f"  [warn] layer {l}: {sat}/{len(acc)} activations "
                      f"clipped at 127 -- raise headroom")
            x = np.clip(acc, 0, 127)
        else:
            x = acc
    if verbose:
        print("\n  logits:", x)
        print("  predicted digit:", int(np.argmax(x)))
    return x


def float_model(weights_f, biases_f, x_float):
    a = np.asarray(x_float, dtype=np.float64)
    L = len(weights_f)
    for l in range(L):
        a = weights_f[l] @ a + biases_f[l]
        if l < L - 1:
            a = np.maximum(a, 0.0)
    return a


def generate(weights_f, biases_f, inputs_q, x_scale,
             output_file="data_mem.mem", mem_words=32768,
             headroom=2.0, verbose=True):

    L = len(weights_f)
    n_in = [w.shape[1] for w in weights_f]
    n_out = [w.shape[0] for w in weights_f]

    x_float = np.asarray(inputs_q, dtype=np.float64) / x_scale
    cal = calibrate(weights_f, biases_f, x_float, x_scale, headroom)

    w_row_stride = [(n_in[l] + 3) // 4 for l in range(L)]
    w_packed = []
    for l in range(L):
        rows = [pack_int8_words(cal['w_q'][l][j, :]) for j in range(n_out[l])]
        w_packed.append(np.concatenate(rows))

    cur = HEADER_WORDS_PER_LAYER * L
    x_base = [0] * L; w_base = [0] * L; b_base = [0] * L; y_base = [0] * L

    # v3: the input image is PACKED 4 int8 per word -> ceil(784/4) = 196 words
    inputs_packed = pack_int8_words(inputs_q)

    x_base[0] = cur
    cur += len(inputs_packed)
    for l in range(L):
        if l > 0:
            x_base[l] = y_base[l - 1]
        w_base[l] = cur; cur += len(w_packed[l])
        b_base[l] = cur; cur += n_out[l]
        y_base[l] = cur
        # v3: hidden-layer activations are written PACKED by the program.
        # The final layer's logits stay unpacked int32 -- they feed argmax,
        # not another MAC4.
        cur += ((n_out[l] + 3) // 4) if l < L - 1 else n_out[l]

    result_word = cur
    cur += 1
    for l in range(L - 1):
        if n_out[l] % 4 != 0:
            raise ValueError(
                f"layer {l} has n_out={n_out[l]}, not a multiple of 4. The "
                f"assembly packs activations in groups of four and flushes on "
                f"every fourth neuron, so a partial final group would never be "
                f"stored. Pad the layer or special-case the tail.")
        if n_in[l + 1] != n_out[l]:
            raise ValueError(f"layer {l+1} n_in != layer {l} n_out")

    total = cur
    if total > mem_words:
        raise ValueError(f"needs {total} words, DataMemory holds {mem_words}")

    lines = []
    for l in range(L):
        lines += [to_bin32(v) for v in (
            n_in[l], n_out[l], x_base[l], w_base[l],
            b_base[l], y_base[l], w_row_stride[l], cal['shift'][l])]
    lines += [to_bin32(v) for v in inputs_packed]
    for l in range(L):
        lines += [to_bin32(v) for v in w_packed[l]]
        lines += [to_bin32(v) for v in cal['b_q'][l]]
        lines += [to_bin32(0)] * (((n_out[l] + 3) // 4) if l < L - 1 else n_out[l])
    lines.append(to_bin32(0))

    with open(output_file, "w") as f:
        f.write("\n".join(lines) + "\n")

    if verbose:
        print(f"[OK] {output_file}: {len(lines)} words "
              f"({len(lines)*32/1024:.1f} Kb of {mem_words*32/1024:.0f} Kb)\n")
        print("  layer  n_in n_out  x_base  w_base  b_base  y_base rowstr shift"
              "   w_scale   a_scale_out")
        for l in range(L):
            print(f"  {l:5d} {n_in[l]:5d} {n_out[l]:5d} {x_base[l]:7d} "
                  f"{w_base[l]:7d} {b_base[l]:7d} {y_base[l]:7d} "
                  f"{w_row_stride[l]:6d} {cal['shift'][l]:5d} "
                  f"{cal['w_scale'][l]:9.2f} {cal['a_scales'][l+1]:13.2f}")
        print(f"\n  x_scale     = {x_scale}")
        print(f"  result word = {result_word}")
        print("\n  HARDCODE THESE IN THE ASSEMBLY:")
        for l in range(L - 1):
            s = cal['shift'][l]
            print(f"    layer {l+1}:  ADDI R6, R6, {(1 << (s-1)) if s else 0}"
                  f"   /   SRL R6, R6, {s}")
        print(f"    layer {L}:  no requantisation (argmax is scale-invariant)")

    cal.update(dict(x_base=x_base, w_base=w_base, b_base=b_base,
                    y_base=y_base, w_row_stride=w_row_stride,
                    result_word=result_word, total_words=total,
                    n_in=n_in, n_out=n_out))
    return cal


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: python pack_data_mem.py dnn_parameters.txt data_mem.mem "
              "[mnist_image.mem] [x_scale] [headroom]")
        sys.exit(1)

    params_file = sys.argv[1]
    out_file = sys.argv[2]
    image_file = sys.argv[3] if len(sys.argv) > 3 else "mnist_image.mem"
    x_scale = float(sys.argv[4]) if len(sys.argv) > 4 else 127.0
    headroom = float(sys.argv[5]) if len(sys.argv) > 5 else 2.0

    weights_f, biases_f = parse_dnn_parameters(params_file)
    inputs_q = load_image(image_file, x_scale)

    cal = generate(weights_f, biases_f, inputs_q, x_scale, out_file,
                   headroom=headroom)

    print("\n[golden] integer model (bit-exact with the assembly):")
    q_logits = golden_model(cal, inputs_q)

    f_logits = float_model(weights_f, biases_f,
                           np.asarray(inputs_q, dtype=np.float64) / x_scale)
    print("\n[float]  reference logits: "
          + np.array2string(f_logits, precision=2))
    print(f"[float]  predicted digit: {int(np.argmax(f_logits))}")
    if int(np.argmax(q_logits)) != int(np.argmax(f_logits)):
        print("\n  MISMATCH. Try a larger headroom, e.g. 4.0, and re-run.")
