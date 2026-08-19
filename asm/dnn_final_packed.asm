# DNN forward pass, INT8-packed weights, word-addressed DMEM, argmax output.
# Network: 784 -> 128 (ReLU) -> 64 (ReLU) -> 10 (linear) -> argmax
#
# FINAL -- Level 3
#
# The requantisation shift is NOT hardcoded. Each layer reads its own shift
# from header word +7 and builds both the rounding offset and the shift with
# short loops. Re-run pack_data_mem.py with different weights, a different
# image, or a different headroom and this binary still runs correctly.
#
# Cost of the runtime shift: about 6,300 instructions across all 192 hidden
# neurons, against ~440,000 for the network. Under 1.5% overhead, and it
# removes the single most error-prone constant in the whole project.
#
# MEMORY LAYOUT (word indices; DataMemory.v is word-addressed)
#   header, 8 words per layer, layer l at 8*l:
#     +0 n_in   +1 n_out   +2 x_base   +3 w_base
#     +4 b_base +5 y_base  +6 w_row_stride  +7 requant_shift
#   weights packed 4 x int8 per word, row-major per neuron
#   biases int32 at accumulator scale
#   result (argmax index) at y3_base + 10
#
# REGISTERS
#   R0  zero                  R14 b_base (word)
#   R1  activation x[i]       R15 y_base (word)
#   R2  packed weight word    R16 w_row_offset = j * w_row_stride
#   R3  scratch address       R17 group counter
#   R4  output address        R18 w_row_stride = n_in / 4
#   R5  bias b[j]             R19 argmax index
#   R6  accumulator           R20 argmax best value
#   R7  x pointer (word)      R21 argmax current value
#   R9  w pointer (word)      R22 argmax compare scratch
#   R10 neuron index j        R23 requant shift S
#   R11 n_out                 R24 rounding offset = 2^(S-1)
#   R12 x_base (word)         R25 shift countdown
#   R13 w_base (word)
# =============================================================================


# ========================= Layer 1: 784 -> 128, ReLU =========================
    LW   R11, 1(R0)              # n_out = 128
    LW   R12, 2(R0)              # x_base
    LW   R13, 3(R0)              # w_base
    LW   R14, 4(R0)              # b_base
    LW   R15, 5(R0)              # y_base
    LW   R18, 6(R0)              # w_row_stride = 784/4 = 196
    LW   R23, 7(R0)              # requant shift S1

# --- build rounding offset R24 = (S1 > 0) ? 1 << (S1-1) : 0 ---
    ADDI R24, R0,  0
    BEQ  R23, R0,  L1_ROUND_DONE
    ADDI R24, R0,  1
    ADDI R25, R23, -1
L1_ROUND_LOOP:
    BEQ  R25, R0,  L1_ROUND_DONE
    ADD  R24, R24, R24
    ADDI R25, R25, -1
    J    L1_ROUND_LOOP
L1_ROUND_DONE:

    ADDI R10, R0,  0             # j = 0
    ADDI R16, R0,  0             # w_row_offset = 0

LAYER1_NEURON_LOOP:
    ADDI R6,  R0,  0             # acc = 0
    ADDI R17, R0,  0             # group = 0
    ADD  R9,  R13, R16           # w ptr = w_base + j*row_stride
    ADDI R7,  R12, 0             # x ptr = x_base

LAYER1_INPUT_LOOP:
    LW   R2,  0(R9)              # w[j][i..i+3], packed
    LW   R1,  0(R7)
    MAC  R6,  R1,  R2            # lane 0 -- MAC sign-extends the low byte
    SRL  R2,  R2,  8
    LW   R1,  1(R7)
    MAC  R6,  R1,  R2            # lane 1
    SRL  R2,  R2,  8
    LW   R1,  2(R7)
    MAC  R6,  R1,  R2            # lane 2
    SRL  R2,  R2,  8
    LW   R1,  3(R7)
    MAC  R6,  R1,  R2            # lane 3
    ADDI R7,  R7,  4
    ADDI R9,  R9,  1
    ADDI R17, R17, 1
    BNE  R17, R18, LAYER1_INPUT_LOOP

    ADD  R3,  R14, R10           # &b1[j]
    LW   R5,  0(R3)
    ADD  R6,  R6,  R5
    RELU R6,  R6                 # value now >= 0, so SRL is safe

    ADD  R6,  R6,  R24           # round-to-nearest
    ADDI R25, R23, 0             # countdown = S1
L1_SHIFT_LOOP:
    BEQ  R25, R0,  L1_SHIFT_DONE
    SRL  R6,  R6,  1
    ADDI R25, R25, -1
    J    L1_SHIFT_LOOP
L1_SHIFT_DONE:

    ADD  R4,  R15, R10           # &y1[j]
    SW   R6,  0(R4)

    ADDI R10, R10, 1
    ADD  R16, R16, R18
    BNE  R10, R11, LAYER1_NEURON_LOOP


# ========================= Layer 2: 128 -> 64, ReLU ==========================
    LW   R11, 9(R0)
    LW   R12, 10(R0)
    LW   R13, 11(R0)
    LW   R14, 12(R0)
    LW   R15, 13(R0)
    LW   R18, 14(R0)             # w_row_stride = 128/4 = 32
    LW   R23, 15(R0)             # requant shift S2

    ADDI R24, R0,  0
    BEQ  R23, R0,  L2_ROUND_DONE
    ADDI R24, R0,  1
    ADDI R25, R23, -1
L2_ROUND_LOOP:
    BEQ  R25, R0,  L2_ROUND_DONE
    ADD  R24, R24, R24
    ADDI R25, R25, -1
    J    L2_ROUND_LOOP
L2_ROUND_DONE:

    ADDI R10, R0,  0
    ADDI R16, R0,  0

LAYER2_NEURON_LOOP:
    ADDI R6,  R0,  0
    ADDI R17, R0,  0
    ADD  R9,  R13, R16
    ADDI R7,  R12, 0

LAYER2_INPUT_LOOP:
    LW   R2,  0(R9)
    LW   R1,  0(R7)
    MAC  R6,  R1,  R2
    SRL  R2,  R2,  8
    LW   R1,  1(R7)
    MAC  R6,  R1,  R2
    SRL  R2,  R2,  8
    LW   R1,  2(R7)
    MAC  R6,  R1,  R2
    SRL  R2,  R2,  8
    LW   R1,  3(R7)
    MAC  R6,  R1,  R2
    ADDI R7,  R7,  4
    ADDI R9,  R9,  1
    ADDI R17, R17, 1
    BNE  R17, R18, LAYER2_INPUT_LOOP

    ADD  R3,  R14, R10
    LW   R5,  0(R3)
    ADD  R6,  R6,  R5
    RELU R6,  R6

    ADD  R6,  R6,  R24
    ADDI R25, R23, 0
L2_SHIFT_LOOP:
    BEQ  R25, R0,  L2_SHIFT_DONE
    SRL  R6,  R6,  1
    ADDI R25, R25, -1
    J    L2_SHIFT_LOOP
L2_SHIFT_DONE:

    ADD  R4,  R15, R10
    SW   R6,  0(R4)

    ADDI R10, R10, 1
    ADD  R16, R16, R18
    BNE  R10, R11, LAYER2_NEURON_LOOP


# ======================== Layer 3: 64 -> 10, linear ==========================
# No ReLU and no requantisation -- argmax is scale-invariant.
    LW   R11, 17(R0)
    LW   R12, 18(R0)
    LW   R13, 19(R0)
    LW   R14, 20(R0)
    LW   R15, 21(R0)
    LW   R18, 22(R0)             # w_row_stride = 64/4 = 16

    ADDI R10, R0, 0
    ADDI R16, R0, 0

LAYER3_NEURON_LOOP:
    ADDI R6,  R0,  0
    ADDI R17, R0,  0
    ADD  R9,  R13, R16
    ADDI R7,  R12, 0

LAYER3_INPUT_LOOP:
    LW   R2,  0(R9)
    LW   R1,  0(R7)
    MAC  R6,  R1,  R2
    SRL  R2,  R2,  8
    LW   R1,  1(R7)
    MAC  R6,  R1,  R2
    SRL  R2,  R2,  8
    LW   R1,  2(R7)
    MAC  R6,  R1,  R2
    SRL  R2,  R2,  8
    LW   R1,  3(R7)
    MAC  R6,  R1,  R2
    ADDI R7,  R7,  4
    ADDI R9,  R9,  1
    ADDI R17, R17, 1
    BNE  R17, R18, LAYER3_INPUT_LOOP

    ADD  R3,  R14, R10
    LW   R5,  0(R3)
    ADD  R6,  R6,  R5            # linear output
    ADD  R4,  R15, R10
    SW   R6,  0(R4)

    ADDI R10, R10, 1
    ADD  R16, R16, R18
    BNE  R10, R11, LAYER3_NEURON_LOOP


# ============ Argmax over y3[0..9]; R15 = y3_base, R11 = 10 ==================
    LW   R20, 0(R15)             # best = y3[0]
    ADDI R19, R0,  0             # best index = 0
    ADDI R10, R0,  1             # j = 1

ARGMAX_LOOP:
    ADD  R3,  R15, R10
    LW   R21, 0(R3)              # cur = y3[j]
    SUB  R22, R20, R21           # best - cur
    SRL  R22, R22, 31            # sign bit: 1 if best < cur
    BEQ  R22, R0,  ARGMAX_SKIP   # best >= cur, keep (ties -> lower index)
    ADDI R20, R21, 0
    ADDI R19, R10, 0
ARGMAX_SKIP:
    ADDI R10, R10, 1
    BNE  R10, R11, ARGMAX_LOOP

    ADD  R3,  R15, R11           # y3_base + 10 = result word
    SW   R19, 0(R3)

# ================================ Halt =======================================
DONE:
    J    DONE