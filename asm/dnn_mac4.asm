# =============================================================================
# dnn_mac4.asm -- DNN forward pass using MAC4 (SIMD 4-lane multiply-accumulate)
#
# Network: 784 -> 128 (ReLU) -> 64 (ReLU) -> 10 (linear) -> argmax
#
# WHAT IS DIFFERENT FROM dnn_final_packed.asm
# -------------------------------------------
# 1. ACTIVATIONS ARE PACKED, 4 int8 per 32-bit word, exactly like the weights
#    always were. Lane k of the activation word pairs with lane k of the
#    weight word; both are indexed by the input number i.
#
#      old inner loop: 1 weight LW + 4 activation LW + 4 MAC + 3 SRL + 4 ctrl
#                      = 16 instructions per 4 MACs
#      new inner loop: 1 weight LW + 1 activation LW + 1 MAC4 + 4 ctrl
#                      =  7 instructions per 4 MACs
#
#    The x pointer now advances 1 word per 4 inputs instead of 4, because
#    4 inputs LIVE in 1 word.
#
# 2. HIDDEN LAYERS PACK THEIR OWN OUTPUT. Layer l's activations become layer
#    l+1's inputs, so they must be written packed. Done with a rotate that
#    uses only constant shift amounts:
#
#        R26 = (R26 >> 8) | (activation << 24)
#
#    After four neurons, neuron j lands in byte j, little-endian. The word is
#    stored on every fourth neuron. n_out is 128 and 64 -- both divisible by
#    4 -- so no partial group is ever left unstored. The packer refuses to
#    generate a memory map if that stops being true.
#
# 3. ACTIVATIONS ARE NOW CLIPPED to [0,127]. Previously the accumulator was
#    stored unclipped and MAC simply read its low byte; that was correct only
#    because the peaks happened to be 52 and 61. With packing, an out-of-range
#    byte would overflow into the NEIGHBOURING lane and corrupt a different
#    input. The clip costs 4 instructions per neuron (~800 total) and makes
#    the hardware match the golden model by construction rather than by luck.
#
# 4. LAYER 3 IS UNCHANGED in structure: no ReLU, no requantisation, no clip,
#    no packing. Its 10 logits stay unpacked int32 because they feed argmax,
#    and argmax is scale-invariant.
#
# STILL TRUE FROM THE PREVIOUS VERSION
#   * requantisation shift is read from header word +7 at runtime, so no
#     magic constant has to be edited when the network is retrained
#   * all addresses are WORD indices (DataMemory.v is word-addressed)
#   * result (predicted digit) is stored at y3_base + n_out = word 27776
#
# MEMORY MAP (from pack_data_mem_v3.py)
#   header      0 ..    23     8 words per layer
#   image      24 ..   219     196 words, PACKED
#   L1 w      220 .. 25307     25088 words   b 25308..25435   y 25436..25467 (32 packed)
#   L2 w    25468 .. 27515      2048 words   b 27516..27579   y 27580..27595 (16 packed)
#   L3 w    27596 .. 27755       160 words   b 27756..27765   y 27766..27775 (10 int32)
#   result  27776
#
# REGISTERS
#   R0  zero                    R16 w_row_offset = j * w_row_stride
#   R1  packed activations      R17 group counter
#   R2  packed weights          R18 w_row_stride  (= n_in/4 = group count)
#   R3  scratch address         R19 argmax index
#   R4  packed output pointer   R20 argmax best value
#   R5  bias b[j]               R21 scratch
#   R6  accumulator             R22 scratch
#   R7  x pointer (words)       R23 requant shift S
#   R9  w pointer (words)       R24 rounding offset 2^(S-1)
#   R10 neuron index j          R25 shift countdown
#   R11 n_out                   R26 pack accumulator word
#   R12 x_base                  R27 pack counter (0..3)
#   R13 w_base
#   R14 b_base
#   R15 y_base
# =============================================================================


# ========================= Layer 1: 784 -> 128, ReLU =========================
    LW   R11, 1(R0)              # n_out = 128
    LW   R12, 2(R0)              # x_base = 24
    LW   R13, 3(R0)              # w_base = 220
    LW   R14, 4(R0)              # b_base = 25308
    LW   R15, 5(R0)              # y_base = 25436
    LW   R18, 6(R0)              # w_row_stride = 196 = groups of 4 inputs
    LW   R23, 7(R0)              # requant shift S1 = 11

# rounding offset R24 = (S1 > 0) ? 1 << (S1-1) : 0
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
    ADDI R26, R0,  0             # pack word = 0
    ADDI R27, R0,  0             # pack counter = 0
    ADDI R4,  R15, 0             # packed output pointer = y_base

LAYER1_NEURON_LOOP:
    ADDI R6,  R0,  0             # acc = 0
    ADDI R17, R0,  0             # group = 0
    ADD  R9,  R13, R16           # w ptr = w_base + j*row_stride
    ADDI R7,  R12, 0             # x ptr = x_base

LAYER1_INPUT_LOOP:
    LW   R2,  0(R9)              # w[j][i..i+3] packed
    LW   R1,  0(R7)              # x[i..i+3]    packed
    MAC4 R6,  R1,  R2            # four products, one instruction
    ADDI R7,  R7,  1             # ONE word per four inputs
    ADDI R9,  R9,  1
    ADDI R17, R17, 1
    BNE  R17, R18, LAYER1_INPUT_LOOP

    ADD  R3,  R14, R10           # &b1[j]
    LW   R5,  0(R3)
    ADD  R6,  R6,  R5
    RELU R6,  R6                 # value >= 0 from here, so SRL is safe

    ADD  R6,  R6,  R24           # round to nearest
    ADDI R25, R23, 0             # countdown = S1
L1_SHIFT_LOOP:
    BEQ  R25, R0,  L1_SHIFT_DONE
    SRL  R6,  R6,  1
    ADDI R25, R25, -1
    J    L1_SHIFT_LOOP
L1_SHIFT_DONE:

    ADDI R21, R6,  -127          # clip to 127
    SRL  R21, R21, 31            # 1 if R6 < 127
    BNE  R21, R0,  L1_NOCLIP
    ADDI R6,  R0,  127
L1_NOCLIP:

    SRL  R26, R26, 8             # rotate: make room in the low bytes
    SLL  R21, R6,  24            # new activation to the top byte
    OR   R26, R26, R21           # after 4 neurons, neuron j is in byte j

    ADDI R27, R27, 1
    ADDI R21, R27, -4
    BNE  R21, R0,  L1_NOSTORE
    SW   R26, 0(R4)              # flush a full word of 4 activations
    ADDI R4,  R4,  1
    ADDI R27, R0,  0
L1_NOSTORE:

    ADDI R10, R10, 1
    ADD  R16, R16, R18
    BNE  R10, R11, LAYER1_NEURON_LOOP


# ========================= Layer 2: 128 -> 64, ReLU ==========================
    LW   R11, 9(R0)
    LW   R12, 10(R0)             # x_base = 25436 = layer 1's y_base
    LW   R13, 11(R0)
    LW   R14, 12(R0)
    LW   R15, 13(R0)
    LW   R18, 14(R0)             # w_row_stride = 32
    LW   R23, 15(R0)             # requant shift S2 = 8

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
    ADDI R26, R0,  0
    ADDI R27, R0,  0
    ADDI R4,  R15, 0

LAYER2_NEURON_LOOP:
    ADDI R6,  R0,  0
    ADDI R17, R0,  0
    ADD  R9,  R13, R16
    ADDI R7,  R12, 0

LAYER2_INPUT_LOOP:
    LW   R2,  0(R9)
    LW   R1,  0(R7)
    MAC4 R6,  R1,  R2
    ADDI R7,  R7,  1
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

    ADDI R21, R6,  -127
    SRL  R21, R21, 31
    BNE  R21, R0,  L2_NOCLIP
    ADDI R6,  R0,  127
L2_NOCLIP:

    SRL  R26, R26, 8
    SLL  R21, R6,  24
    OR   R26, R26, R21

    ADDI R27, R27, 1
    ADDI R21, R27, -4
    BNE  R21, R0,  L2_NOSTORE
    SW   R26, 0(R4)
    ADDI R4,  R4,  1
    ADDI R27, R0,  0
L2_NOSTORE:

    ADDI R10, R10, 1
    ADD  R16, R16, R18
    BNE  R10, R11, LAYER2_NEURON_LOOP


# ======================== Layer 3: 64 -> 10, linear ==========================
# No ReLU, no requantisation, no clip, no packing. The 10 logits are stored
# as full int32 words because argmax consumes them, not MAC4.
    LW   R11, 17(R0)
    LW   R12, 18(R0)             # x_base = 27580 = layer 2's y_base
    LW   R13, 19(R0)
    LW   R14, 20(R0)
    LW   R15, 21(R0)
    LW   R18, 22(R0)             # w_row_stride = 16

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
    MAC4 R6,  R1,  R2
    ADDI R7,  R7,  1
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
    LW   R21, 0(R3)
    SUB  R22, R20, R21           # best - cur
    SRL  R22, R22, 31            # 1 if best < cur
    BEQ  R22, R0,  ARGMAX_SKIP   # ties keep the lower index
    ADDI R20, R21, 0
    ADDI R19, R10, 0
ARGMAX_SKIP:
    ADDI R10, R10, 1
    BNE  R10, R11, ARGMAX_LOOP

    ADD  R3,  R15, R11           # y3_base + 10 = 27776
    SW   R19, 0(R3)

# ================================ Halt =======================================
DONE:
    J    DONE