# -*- coding: utf-8 -*-

"""
Assembler for custom MIPS-like DNN processor
- Supports: R, I, and J types
- Supports labels and branch loops (BEQ, BNE, J)
- Supports automatic generation of data_mem.mem from Keras/NumPy weights
Author: Tinotenda Karambakuwa
"""

import re
import sys
import numpy as np

# ===================================================
# ISA DEFINITIONS
# ===================================================
opcodes = {
    # R-type
    "ADD": "000000", "SUB": "000000", "AND": "000000", "OR": "000000",
    "XOR": "000000", "SLL": "000000", "SRL": "000000", "MAC": "000000",
    "RELU": "000000", "NOT": "000000", "MULT": "000000",
    "SRA": "000000", # Sign-extend a byte out of a packed word
    "MAC4": "000000",# Vector MAC - Operation on 4 bytes each being int8/ 8bits at the same time.

    # I-type
    "ADDI": "000100", "LW": "000101", "SW": "000110",
    "BEQ": "000111", "BNE": "001000",

    # J-type
    "J": "000010",
    
    # Special
    "NOP": "111111"
}

functs = {
    "ADD": "000000", "SUB": "000001", "AND": "000010", "OR": "000011",
    "XOR": "000100", "SLL": "000101", "SRL": "000110",
    "MAC": "000111", "RELU": "001000", "NOT": "001001", "MULT": "001010",
    "SRA": "001011", "MAC4": "001100",
    "NOP": "111111"
}

registers = {f"R{i}": format(i, '05b') for i in range(32)}


# ===================================================
# UTILITY
# ===================================================
def imm_to_bin(val, bits=16):
    """Convert signed immediate to binary string."""
    val = int(val)
    if val < 0:
        val = (1 << bits) + val
    return format(val & ((1 << bits) - 1), f'0{bits}b')

def bin_str_to_signed_int(bin_str):
    """Converts a 32-bit 2's complement binary string to a signed integer."""
    val = int(bin_str, 2)
    if (val & (1 << 31)):  # Check if the sign bit is 1
        val = val - (1 << 32) # Compute the negative value
    return val

def strip_comments(line: str) -> str:
    """Remove inline '#' comments and trim whitespace."""
    return line.split("#", 1)[0].strip()

# ===================================================
# CORE ASSEMBLER
# ===================================================
def assemble_line(line, labels, pc):
    """Convert a single assembly line into binary code."""
    line = strip_comments(line)
    if not line:
        return None

    # Handle label definition
    if ":" in line:
        label, rest = line.split(":", 1)
        labels[label.strip()] = pc
        line = strip_comments(rest)
        if not line:
            return None

    tokens = re.split(r'[,\s()]+', line)
    tokens = [t for t in tokens if t != ""]

    mnemonic = tokens[0].upper()
    opcode = opcodes.get(mnemonic)

    # -----------------------------
    # R-type (opcode is 000000)
    # -----------------------------
    if opcode == "000000":
        funct = functs[mnemonic]

        # 2-Register format: RELU rd, rs | NOT rd, rs
        if mnemonic in ["RELU", "NOT"]:
            rd = registers[tokens[1]]
            rs = registers[tokens[2]]
            rt = "00000"
            shamt = "00000"
        # Shift format: SLL rd, rt, shamt | SRL rd, rt, shamt
        elif mnemonic in ["SLL", "SRL", "SRA"]:
            rd = registers[tokens[1]]
            rt = registers[tokens[2]]
            shamt = format(int(tokens[3]), '05b')
            rs = "00000"
        # 3-Register format: ADD, SUB, AND, OR, XOR, MAC, MULT
        else:
            rd = registers[tokens[1]]
            rs = registers[tokens[2]]
            rt = registers[tokens[3]]
            shamt = "00000"

        return opcode + rs + rt + rd + shamt + funct

    # -----------------------------
    # I-type
    # -----------------------------
    elif mnemonic in ["ADDI", "LW", "SW", "BEQ", "BNE"]:
        if mnemonic in ["LW", "SW"]:
            # Format: LW rt, imm(rs)
            rt = registers[tokens[1]]
            imm = tokens[2]
            rs = registers[tokens[3]]
        elif mnemonic in ["BEQ", "BNE"]:
            # Format: BNE rs, rt, label
            rs = registers[tokens[1]]
            rt = registers[tokens[2]]
            imm = tokens[3]
        else:  # ADDI
            # Format: ADDI rt, rs, imm
            rt = registers[tokens[1]]
            rs = registers[tokens[2]]
            imm = tokens[3]

        # Handle labels for branches
        if imm in labels:
            # CPU uses PC+4 as branch base (MIPS-like)
            imm_val = (labels[imm] - (pc + 4)) // 4
        else:
            imm_val = int(imm)

        return opcode + rs + rt + imm_to_bin(imm_val)

    # -----------------------------
    # J-type
    # -----------------------------
    elif mnemonic == "J":
        target = tokens[1]
        if target in labels:
            addr_val = labels[target] >> 2
        else:
            addr_val = int(target)
        return opcode + format(addr_val, '026b')

    # -----------------------------
    # Special (NOP)
    # -----------------------------
    elif mnemonic == "NOP":
        # Using SLL R0, R0, 0 as a true NOP
        return "00000000000000000000000000000000"

    else:
        raise ValueError(f"Unhandled mnemonic: {mnemonic}")


# ===================================================
# ASSEMBLE FILE FUNCTION
# ===================================================
def assemble_file(input_file, output_file):
    with open(input_file, "r") as f:
        raw_lines = [l.strip() for l in f.readlines()]

    # Pass 1: find labels with correct PC accounting
    labels = {}
    pc = 0
    for raw in raw_lines:
        line = strip_comments(raw)
        if not line:
            continue
        if ":" in line:
            label, rest = line.split(":", 1)
            labels[label.strip()] = pc
            line = strip_comments(rest)
            if not line:
                continue  # label-only line, no instruction at this PC
        # instruction present
        pc += 4

    # Pass 2: encode instructions
    pc = 0
    binary_instructions = []
    for raw in raw_lines:
        instr = assemble_line(raw, labels, pc)
        if instr:
            binary_instructions.append(instr)
            pc += 4

    with open(output_file, "w") as f:
        for instr in binary_instructions:
            f.write(instr + "\n")

    print(f"[SUCCESS] Assembled {len(binary_instructions)} instructions → {output_file}")


# ===================================================
# QUANTIZATION + DATA MEMORY GENERATION
# ===================================================
def quantize_to_int8(array):
    """Asymmetric quantization to INT8 range."""
    min_val, max_val = np.min(array), np.max(array)
    
    # Handle the case where min and max are the same
    if min_val == max_val:
        scale = 1.0
        zero_point = 0
    else:
        # Calculate scale and zero-point for mapping to [-128, 127]
        scale = (max_val - min_val) / 255.0
        zero_point = np.round(127 - max_val / scale)

    # Quantize, clip, and convert to int8
    quantized = np.round(array / scale + zero_point)
    quantized = np.clip(quantized, -128, 127).astype(np.int8)
    
    return quantized, scale

def quantize_to_int8_symmetric(array):
    """Symmetric INT8 quantization (zero_point = 0)."""
    amax = float(np.max(np.abs(array))) if array.size else 0.0
    scale = 1.0 if amax == 0.0 else amax / 127.0
    q = np.round(array / scale)
    q = np.clip(q, -128, 127).astype(np.int8)
    return q, scale


def parse_dnn_parameters(filename):
    with open(filename, "r") as f:
        lines = [l.strip() for l in f if l.strip() and not l.startswith("#")]

    idx = 0
    num_layers = int(lines[idx])
    idx += 1

    # Read all layer sizes
    layer_sizes = list(map(int, lines[idx].split()))
    idx += 1

    num_inputs_list = layer_sizes[:-1]
    num_neurons_list = layer_sizes[1:]

    weights = []
    biases = []
    inputs = None

    # Read weights: one line per layer, flattened
    for layer in range(num_layers):
        num_inputs = num_inputs_list[layer]
        num_neurons = num_neurons_list[layer]
        w_flat = [float(x) for x in lines[idx].split()]
        idx += 1
        # Reshape to (num_neurons, num_inputs)
        w = np.array(w_flat).reshape((num_neurons, num_inputs))
        weights.append(w)

    # Read biases: one line per layer
    for layer in range(num_layers):
        num_neurons = num_neurons_list[layer]
        b = [float(x) for x in lines[idx].split()]
        if len(b) != num_neurons:
            raise ValueError(f"Biases for layer {layer} should have {num_neurons} values, got {len(b)}")
        biases.append(np.array(b))
        idx += 1

    # Optionally, read inputs if present
    if idx < len(lines):
        inputs = np.array([float(x) for x in lines[idx].split()])

    return weights, biases, inputs

# def generate_data_mem(weights, biases, inputs, output_file="data_mem.mem"):
#     """
#     Memory layout:
#       Header (per layer, 6 words): [x_stride_bytes, y_stride_bytes, x_base, w_base, b_base, y_base]
#       Then: inputs, all weights, all biases, and reserved output spaces per layer.
#     All addresses in header are byte addresses.
#     """
#     word_bytes = 4
#     num_layers = len(weights)

#     def val_to_bin32(val):
#         return format((int(val) + (1 << 32)) % (1 << 32), '032b')

#     # Shapes from quantized weights: (num_neurons, num_inputs)
#     layer_in = [w.shape[1] for w in weights]
#     layer_out = [w.shape[0] for w in weights]

#     # Compute header size in bytes (6 words per layer)
#     header_words = 6 * num_layers
#     header_bytes = header_words * word_bytes

#     # Compute base addresses
#     # x_base for layer 0 starts right after header
#     x_base_l = [0] * num_layers
#     w_base_l = [0] * num_layers
#     b_base_l = [0] * num_layers
#     y_base_l = [0] * num_layers

#     # Current byte pointer after header
#     cur = header_bytes

#     # Place inputs first
#     x_base_l[0] = cur
#     cur += (len(inputs) if inputs is not None else 0) * word_bytes

#     # For each layer, place W, B, and reserve Y
#     for l in range(num_layers):
#         if l > 0:
#             # Next layer input is previous layer output
#             x_base_l[l] = y_base_l[l - 1]

#         n_in = layer_in[l]
#         n_out = layer_out[l]

#         w_base_l[l] = cur
#         cur += (n_in * n_out) * word_bytes

#         b_base_l[l] = cur
#         cur += n_out * word_bytes

#         y_base_l[l] = cur
#         cur += n_out * word_bytes  # reserve space for outputs

#     # Build header words
#     header = []
#     for l in range(num_layers):
#         x_stride_bytes = layer_in[l] * word_bytes
#         y_stride_bytes = layer_out[l] * word_bytes
#         header.extend([
#             x_stride_bytes,
#             y_stride_bytes,
#             x_base_l[l],
#             w_base_l[l],
#             b_base_l[l],
#             y_base_l[l],
#         ])

#     # Emit binary lines
#     lines = []

#     # 1) Header
#     lines.extend(val_to_bin32(v) for v in header)

#     # 2) Inputs
#     if inputs is not None:
#         for v in inputs:
#             lines.append(val_to_bin32(v))

#     # 3) Weights (row-major)
#     for w in weights:
#         for v in w.flatten():
#             lines.append(val_to_bin32(v))

#     # 4) Biases
#     for b in biases:
#         for v in b:
#             lines.append(val_to_bin32(v))

#     # 5) Reserve outputs (zeros)
#     for l in range(num_layers):
#         for _ in range(layer_out[l]):
#             lines.append(val_to_bin32(0))

#     with open(output_file, "w") as f:
#         f.write("\n".join(lines) + "\n")

#     print(f"[SUCCESS] Data memory with {len(lines)} entries written → {output_file}")

# def generate_data_mem_level1_flat(weights, biases, inputs, output_file="data_level_1.mem"):
#     """
#     Flat layout (no header), word-addressed:
#       x: [0..783]                (784 words)
#       w: [784..784+7840-1]      (10*784 words, row-major)
#       b: [8624..8633]           (10 words)
#       y: [8634..8643]           (10 words, init 0)
#     Values are written as 32-bit two’s complement.
#     """
#     assert len(weights) == 1 and len(biases) == 1, "flat level-1 expects a single layer"
#     W = weights[0]  # shape (10,784)
#     B = biases[0]   # shape (10,)
#     x = inputs      # length 784

#     def val_to_bin32(val: int) -> str:
#         v = int(val) & 0xFFFFFFFF
#         return format(v, '032b')

#     lines = []
#     # x
#     for v in (x if x is not None else [0]*784):
#         lines.append(val_to_bin32(v))
#     # w (row-major)
#     for v in W.flatten():
#         lines.append(val_to_bin32(v))
#     # b
#     for v in B:
#         lines.append(val_to_bin32(v))
#     # y (zeros)
#     for _ in range(10):
#         lines.append(val_to_bin32(0))

#     with open(output_file, "w") as f:
#         f.write("\n".join(lines) + "\n")
#     print(f"[SUCCESS] Flat level-1 data memory with {len(lines)} words → {output_file}")

# ===================================================
# EXAMPLE USAGE (FOR TEST)
# ===================================================


if __name__ == "__main__":
    # Usage:
    #   python assembler.py program.asm instruction_mem.mem
    #   python assembler.py program.asm instruction_mem.mem data_mem.mem dnn_parameters.txt

    if len(sys.argv) not in (3, 5):
        print("Usage:")
        print("  python assembler.py program.asm instruction_mem.mem")
        # print("  python assembler.py program.asm instruction_mem.mem data_mem.mem dnn_parameters.txt")
        sys.exit(1)

    asm_in = sys.argv[1]
    asm_out = sys.argv[2]
    assemble_file(asm_in, asm_out)

    if len(sys.argv) == 5:
        
        # # If inputs are in the parameters file then ...
        # weights, biases, inputs = parse_dnn_parameters(sys.argv[4])
        # inputs_q = quantize_to_int8(inputs)[0] if inputs is not None else None

        data_out = sys.argv[3]
        params_file = sys.argv[4]

        weights, biases, _ = parse_dnn_parameters(params_file)  # Ignore inputs from parameters

        # Load quantized image from mnist_image.mem
        # (already sign-extended 32b in mnist_image.mem)
        image_file = "mnist_image.mem"
        try:
            with open(image_file, "r") as f:
                # Use the helper function to correctly parse signed values
                inputs_q = np.array([bin_str_to_signed_int(line.strip()) for line in f.readlines()], dtype=np.int32)
        except FileNotFoundError:
            print(f"Error: {image_file} not found. Run export_mnist_image.py first.")
            sys.exit(1)


        # Read input quantization scale saved by export_mnist_image.py
        try:
            with open("mnist_image.scale", "r") as f:
                s_in = float(f.read().strip())
        except FileNotFoundError:
            print("Error: mnist_image.scale not found. Run export_mnist_image.py first.")
            sys.exit(1)
        
        # Align model quantization with fixed ASM shift (S=7)
        S = 7
        weights_q = []
        biases_q32 = []
        for l in range(len(weights)):
            w_q, s_w = quantize_to_int8_symmetric(weights[l])
            s_acc = s_in * s_w
            b_q32 = np.round(biases[l] / s_acc).astype(np.int32)
            weights_q.append(w_q)
            biases_q32.append(b_q32)
            # output scale becomes next layer's input scale after SRL S
            s_in = s_acc / (2 ** S)

        # generate_data_mem(weights_q, biases_q32, inputs_q, data_out)
        
        # weights_q = [quantize_to_int8_symmetric(w)[0] for w in weights]
        # biases_q = [quantize_to_int8_symmetric(b)[0] for b in biases]
        # generate_data_mem(weights_q, biases_q, inputs_q, data_out)
        # generate_data_mem_level1_flat(weights_q, biases_q, inputs_q, data_out)
