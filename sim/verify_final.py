#!/usr/bin/env python3
"""
verify_final.py -- regression harness.

Runs the SAME assembled binary against several networks with different
weight magnitudes, confirming the runtime-shift assembly adapts to whatever
S the packer computes. Also runs the real network as case 0.

Difference from sim_isa.py: sim_isa runs one real case in detail;
verify_final runs many cases and reports pass/fail per case. Both share the
simulator in isa_sim_core.py.

FIXED vs the previous version:
  * dead exec(...if False else '') line removed
  * duplicated simulator body removed (now imported)
  * real network added as case 0
"""
import sys
import numpy as np
import importlib.util
from isa_sim_core import run, load_mem, check

# FIXED: was hardcoded to v2. Pass the packer as argv[2] so this can verify
# either build. Note this script DOES write _v.mem on purpose -- it generates
# synthetic networks. Never point it at a real .mem file.
PACKER = sys.argv[2] if len(sys.argv) > 2 else "pack_data_mem_v3.py"
spec = importlib.util.spec_from_file_location("p", PACKER)
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)

IMEM = sys.argv[1] if len(sys.argv) > 1 else "instruction_mac4.mem"
ok_all = True

# ---- case 0: the real network -------------------------------------------
try:
    W, B = p.parse_dnn_parameters("dnn_parameters_final.txt")
    xq = p.load_image("mnist_image.mem", 127.0, verbose=False)
    cal = p.generate(W, B, xq, 127.0, "_v.mem", verbose=False)
    mem = load_mem("_v.mem")
    steps, _ = run(IMEM, mem)
    gold = [int(v) for v in p.golden_model(cal, xq, verbose=False)]
    hw, arg, ok = check(cal, mem, gold, cal['result_word'])
    flt = int(np.argmax(p.float_model(W, B, np.asarray(xq, float) / 127.0)))
    ok_all &= ok
    print(f"REAL       shifts={cal['shift']}  instr={steps:,}  "
          f"hw={arg}  gold={int(np.argmax(gold))}  float={flt}  "
          f"{'OK' if ok else 'FAIL'}")
except FileNotFoundError as e:
    print(f"REAL       skipped ({e.filename} not found)")

# ---- cases 1..3: synthetic networks at different weight magnitudes ------
for seed, scales in [(3, [0.09, 0.16, 0.22]),
                     (7, [0.05, 0.10, 0.15]),
                     (11, [0.15, 0.25, 0.30])]:
    rng = np.random.default_rng(seed)
    sizes = [784, 128, 64, 10]
    W = [rng.normal(0, s, (sizes[i + 1], sizes[i])) for i, s in enumerate(scales)]
    B = [rng.normal(0, 0.1, sizes[i + 1]) for i in range(3)]
    xq = np.round(np.clip(rng.random(784) * 1.5 - 0.25, 0, 1) * 127).astype(np.int64)

    cal = p.generate(W, B, xq, 127.0, "_v.mem", verbose=False)
    mem = load_mem("_v.mem")
    steps, _ = run(IMEM, mem)
    gold = [int(v) for v in p.golden_model(cal, xq, verbose=False)]
    hw, arg, ok = check(cal, mem, gold, cal['result_word'])
    flt = int(np.argmax(p.float_model(W, B, xq / 127.0)))
    ok_all &= ok
    print(f"seed {seed:<5d} shifts={cal['shift']}  instr={steps:,}  "
          f"hw={arg}  gold={int(np.argmax(gold))}  float={flt}  "
          f"{'OK' if ok else 'FAIL'}")

print("\nALL MATCH" if ok_all else "\nFAILURE")
sys.exit(0 if ok_all else 1)