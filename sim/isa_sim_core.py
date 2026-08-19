"""
isa_sim_core.py -- shared ISA simulator for the DNN ASIP.

Both sim_isa.py and verify_final.py import from here, so the simulator
exists in exactly one place. Previously each file had its own copy, which
is how they drifted apart.
"""
import numpy as np


def s32(v):
    v &= 0xFFFFFFFF
    return v - (1 << 32) if v & (1 << 31) else v


def s8(v):
    v &= 0xFF
    return v - 256 if v & 0x80 else v


def load_mem(path, words=32768):
    m = [int(l.strip(), 2) for l in open(path) if l.strip()]
    if len(m) > words:
        raise ValueError(f"{path} has {len(m)} words, DataMemory holds {words}. "
                         f"If this is ~110390 the packed file was overwritten by "
                         f"assembler.py's generate_data_mem -- re-run the packer.")
    return m + [0] * (words - len(m))


def run(instr_file, mem, max_steps=80_000_000, trace=False):
    """Execute the assembled binary. Returns (instruction_count, registers)."""
    prog = [l.strip() for l in open(instr_file) if l.strip()]
    R = [0] * 32
    pc = 0
    steps = 0

    while steps < max_steps:
        steps += 1
        if (pc >> 2) >= len(prog):
            raise RuntimeError(f"PC {pc} ran past the end of {instr_file}")
        w = prog[pc >> 2]
        op = w[0:6]; rs = int(w[6:11], 2); rt = int(w[11:16], 2)
        rd = int(w[16:21], 2); sh = int(w[21:26], 2); fn = w[26:32]
        imm = int(w[16:32], 2)
        imm = imm - (1 << 16) if imm & 0x8000 else imm
        nxt = pc + 4

        def rv(i):
            return 0 if i == 0 else R[i]

        if op == "000000":                      # R-type
            a, b, c = rv(rs), rv(rt), rv(rd)
            if   fn == "000000": r = s32(a + b)                     # ADD
            elif fn == "000001": r = s32(a - b)                     # SUB
            elif fn == "000010": r = a & b                          # AND
            elif fn == "000011": r = a | b                          # OR
            elif fn == "000100": r = a ^ b                          # XOR
            elif fn == "000101": r = s32(b << sh)                   # SLL
            elif fn == "000110": r = (b & 0xFFFFFFFF) >> sh         # SRL
            elif fn == "000111": r = s32(c + s8(a) * s8(b))         # MAC
            elif fn == "001000": r = 0 if a < 0 else a              # RELU
            elif fn == "001001": r = s32(~a)                        # NOT
            elif fn == "001010": r = s32(a * b)                     # MULT
            elif fn == "001011": r = a >> sh                        # SRA
            elif fn == "001100":                                    # MAC4
                r = s32(c + sum(s8((a >> (8 * k)) & 0xFF) *
                                s8((b >> (8 * k)) & 0xFF) for k in range(4)))
            else: r = 0
            if rd: R[rd] = r

        elif op == "000100":                    # ADDI
            if rt: R[rt] = s32(rv(rs) + imm)
        elif op == "000101":                    # LW
            if rt: R[rt] = s32(mem[(rv(rs) + imm) & 0x7FFF])
        elif op == "000110":                    # SW
            mem[(rv(rs) + imm) & 0x7FFF] = rv(rt) & 0xFFFFFFFF
        elif op == "000111":                    # BEQ
            if rv(rs) == rv(rt): nxt = pc + 4 + imm * 4
        elif op == "001000":                    # BNE
            if rv(rs) != rv(rt): nxt = pc + 4 + imm * 4
        elif op == "000010":                    # J
            tgt = int(w[6:32], 2) * 4
            if tgt == pc:
                return steps, R                 # self-jump == halt
            nxt = tgt

        if trace and steps < 40:
            print(f"  {steps:4d}  pc={pc:5d}  {w}")
        pc = nxt

    raise RuntimeError("no halt reached -- infinite loop?")


def check(cal, mem, gold, result_word):
    """Compare hardware memory contents against the golden model."""
    yb = cal['y_base'][-1]
    hw = [s32(mem[yb + i]) for i in range(cal['n_out'][-1])]
    arg = s32(mem[result_word])
    return hw, arg, (hw == list(gold) and arg == int(np.argmax(gold)))
