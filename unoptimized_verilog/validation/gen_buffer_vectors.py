#!/usr/bin/env python3
"""
Generates random stimulus + expected results for testbenches/tb_buffer_rand.sv.

Writes three files (default: into software/):
  buffer_mem0.bits   MEM0 contents (matrix), one row per line
  buffer_mem1.bits   MEM1 contents (vector), one word per line
  buffer_vec.hex     one line per clock cycle:
      {pad[2], valid[1], opcode[2], mode[2], mema[16], memb[16], output_data[512],
       check_data[1], exp_matrix[512], exp_vector[32], exp_mem2_row[512]}

Expected values come from a small model written straight from the spec.
If the staff Python reference (simulator/src/main_buffer.py) can be imported,
every step is ALSO run through it and the two must agree, so the expected
values are the reference's answers.

Run from unoptimized_verilog/validation:
    python3 gen_buffer_vectors.py                 # 20000 cycles, seed 1
    python3 gen_buffer_vectors.py -n 100000 -s 7
"""
import argparse
import os
import random
import sys

# Widths, matching defines.sv
MEM0_W, MEM1_W, MEM2_W = 512, 32, 512
MEM0_DEPTH, MEM1_DEPTH, MEM2_DEPTH = 65536, 16384, 65536
OFF_W = 16
READ, WRITE, NOP = 0, 1, 2
LANE_W = {0: 8, 1: 16, 2: 32}          # mode field -> lane width

# How many rows get loaded / used. Small, so writes land on the same rows
# again and again and every overwrite gets re-checked.
MEM0_ROWS, MEM1_ROWS, MEM2_ROWS = 256, 128, 64

VEC_BITS = 1608                         # must match VW in tb_buffer_rand.sv


# ---------------------------------------------------------------------------
# Spec model (lane 0 = least-significant bits)
# ---------------------------------------------------------------------------
class Model:
    def __init__(self, mem0, mem1):
        self.mem0, self.mem1, self.mem2 = mem0, mem1, {}
        self.matrix = 0
        self.vector = 0

    def step(self, valid, op, mode, a, b, out_data):
        if not valid:
            return
        if op == READ:
            lw = LANE_W[mode]
            lanes = MEM1_W // lw
            self.matrix = self.mem0[a]
            word = self.mem1[b // lanes]                        # MemBOffset[MSB:k]
            piece = (word >> ((b % lanes) * lw)) & ((1 << lw) - 1)  # MemBOffset[k-1:0]
            self.vector = 0
            for k in range(lanes):                              # repeat across the word
                self.vector |= piece << (k * lw)
        elif op == WRITE:
            self.mem2[a] = out_data
        # NOP: nothing


# ---------------------------------------------------------------------------
# Optional: the staff Python reference, for cross-checking
# ---------------------------------------------------------------------------
def load_reference(mem0, mem1):
    sim_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "simulator")
    sys.path.insert(0, sim_dir)
    try:
        from bitstring import Bits
        from src.main_buffer import MainBuffer, MainBufferConfiguration
        from src.instruction import MemoryInstruction, MemoryInstructionConfiguration
    except Exception as e:                                       # noqa: BLE001
        print(f"note: staff reference not importable ({e}); using the spec model only")
        return None

    buf = MainBuffer(MainBufferConfiguration(
        MEM0_BITWIDTH=MEM0_W, MEM0_DEPTH=MEM0_DEPTH,
        MEM1_BITWIDTH=MEM1_W, MEM1_DEPTH=MEM1_DEPTH,
        MEM2_BITWIDTH=MEM2_W, MEM2_DEPTH=MEM2_DEPTH))
    zero0, zero1 = Bits(uint=0, length=MEM0_W), Bits(uint=0, length=MEM1_W)
    buf.set_mem0_bits([Bits(uint=v, length=MEM0_W) for v in mem0] + [zero0] * (MEM0_DEPTH - len(mem0)))
    buf.set_mem1_bits([Bits(uint=v, length=MEM1_W) for v in mem1] + [zero1] * (MEM1_DEPTH - len(mem1)))
    icfg = MemoryInstructionConfiguration(OPCODE_BITWIDTH=2, MODE_BITWIDTH=2,
                                          MEMA_OFFSET_BITWIDTH=OFF_W, MEMB_OFFSET_BITWIDTH=OFF_W)

    def step(op, mode, a, b, out_data):
        inst = MemoryInstruction(icfg)
        inst.set_opcode(op)
        inst.set_mode(mode)
        inst.set_mema_offset(a)
        inst.set_memb_offset(b)
        buf.write_mem2_input(Bits(uint=out_data, length=MEM2_W))
        buf.execute_instruction(inst)
        return (buf.read_mem0_output().uint, buf.read_mem1_output().uint,
                buf.read_mem2_bits()[a].uint)

    print("note: cross-checking every step against the staff Python reference")
    return step


# ---------------------------------------------------------------------------
# Random data, biased so a wrong lane or wrong word can't match by accident
# ---------------------------------------------------------------------------
def rand_bits(rng, w):
    r = rng.random()
    if r < 0.25:                                     # every byte different (rows are <= 64 bytes)
        return int.from_bytes(bytes(rng.sample(range(256), w // 8)), "big")
    if r < 0.32:
        return rng.choice([0, (1 << w) - 1, 1 << (w - 1), 1])
    return rng.getrandbits(w)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-n", "--cycles", type=int, default=20000)
    ap.add_argument("-s", "--seed", type=int, default=1)
    ap.add_argument("-o", "--outdir", default="software")
    ap.add_argument("--hex-mem", action="store_true",
                    help="write memory files in hex instead of binary (if array.sv's loadmem uses $readmemh)")
    args = ap.parse_args()

    rng = random.Random(args.seed)
    os.makedirs(args.outdir, exist_ok=True)

    mem0 = [rand_bits(rng, MEM0_W) for _ in range(MEM0_ROWS)]
    mem1 = [rand_bits(rng, MEM1_W) for _ in range(MEM1_ROWS)]

    def write_mem(path, rows, w):
        with open(path, "w") as f:
            for v in rows:
                f.write((format(v, f"0{w // 4}x") if args.hex_mem else format(v, f"0{w}b")) + "\n")

    p0 = os.path.join(args.outdir, "buffer_mem0.bits")
    p1 = os.path.join(args.outdir, "buffer_mem1.bits")
    pv = os.path.join(args.outdir, "buffer_vec.hex")
    write_mem(p0, mem0, MEM0_W)
    write_mem(p1, mem1, MEM1_W)

    model = Model(mem0, mem1)
    ref = load_reference(mem0, mem1)
    counts = {"READ": 0, "WRITE": 0, "NOP": 0, "invalid": 0}

    with open(pv, "w") as f:
        for cyc in range(args.cycles):
            valid = 1 if rng.random() < 0.9 else 0
            op = rng.choice([READ] * 5 + [WRITE] * 3 + [NOP])
            mode = rng.choice([0, 1, 2])
            lanes = MEM1_W // LANE_W[mode]
            if valid and op == READ:
                a = rng.randrange(MEM0_ROWS)
                b = rng.randrange(MEM1_ROWS * lanes)
            elif valid and op == WRITE:
                a = rng.randrange(MEM2_ROWS)
                b = rng.randrange(1 << OFF_W)            # B is unused on WRITE: make it junk
            else:                                        # NOP / invalid: offsets must be ignored
                a = rng.randrange(1 << OFF_W)
                b = rng.randrange(1 << OFF_W)
            out_data = rng.getrandbits(MEM2_W)           # junk every cycle; only a WRITE may store it

            model.step(valid, op, mode, a, b, out_data)
            exp_m2 = model.mem2.get(a, 0)

            if ref is not None and valid:
                r_mat, r_vec, r_m2 = ref(op, mode, a, b, out_data)
                if (r_mat, r_vec, r_m2) != (model.matrix, model.vector, exp_m2):
                    sys.exit(f"cycle {cyc}: spec model and staff reference disagree "
                             f"(op={op} mode={mode} a={a} b={b}); please report this")

            check = 1 if (valid and op == READ) else 0
            counts["invalid" if not valid else ["READ", "WRITE", "NOP"][op]] += 1

            word = 0
            for value, width in [(0, 2), (valid, 1), (op, 2), (mode, 2), (a, OFF_W), (b, OFF_W),
                                 (out_data, MEM2_W), (check, 1), (model.matrix, MEM0_W),
                                 (model.vector, MEM1_W), (exp_m2, MEM2_W)]:
                word = (word << width) | value
            f.write(format(word, f"0{VEC_BITS // 4}x") + "\n")

    print(f"wrote {p0}, {p1}, {pv}")
    print(f"{args.cycles} cycles: " + ", ".join(f"{k}={v}" for k, v in counts.items()))
    print("run with:")
    print(f"  ./simv +VEC_FILE={pv} +NVEC={args.cycles} +MEM0_FILE={p0} +MEM1_FILE={p1}")


if __name__ == "__main__":
    main()
