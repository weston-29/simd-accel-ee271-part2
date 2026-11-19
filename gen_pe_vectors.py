#!/usr/bin/env python3
"""
Generate random test vectors for the Verilog processing element, with the
expected results computed by the course's own Python reference PE
(simulator/src/processing_element.py).

Run from the REPO ROOT (the directory that contains simulator/):
    python3 gen_pe_vectors.py --seqs 1500 --out unoptimized_verilog/validation/pe_vectors.hex

Each line of the output is one clock cycle, as one 170-bit hex word:
    {valid[1], opcode[2], mode[2], value[5], A[32], B[32], exp_acc[64], exp_out[32]}
The number of lines is printed; pass it to the testbench as +NVEC=<n>.
"""
import argparse
import os
import random
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "simulator"))
sys.path.insert(0, "simulator")

from bitstring import Bits
from src.processing_element import ProcessingElement, ProcessingElementConfiguration
from src.instruction import (
    ProcessingElementInstruction,
    ProcessingElementInstructionConfiguration,
    PEI,
    Mode,
)

PE_CFG = ProcessingElementConfiguration(INPUT_BITWIDTH=32, ACCUMULATION_BITWIDTH=64, OUTPUT_BITWIDTH=32)
INST_CFG = ProcessingElementInstructionConfiguration(OPCODE_BITWIDTH=2, MODE_BITWIDTH=2, VALUE_BITWIDTH=5)

OPS = ["MAC"] * 4 + ["PASS", "OUT", "OUT", "RND", "RND", "CLR", "NOP"]


def make_inst(op, mode_bits, shift):
    inst = ProcessingElementInstruction(INST_CFG)
    if op == "RND":
        inst.set_opcode(PEI.RND)
        inst.set_value(shift)
    else:
        inst.set_opcode(PEI.NO_VALUE)
        inst.set_value(getattr(PEI, op))
    inst.set_mode(Mode.opcode(mode_bits))
    return inst


def special(w):
    lo, hi = -(1 << (w - 1)), (1 << (w - 1)) - 1
    return [lo, lo + 1, -2, -1, 0, 1, 2, hi - 1, hi]


def rand_word(rng, lane_w):
    """A random 32-bit input word built from lanes, biased toward boundary values."""
    n = 32 // lane_w
    word = 0
    for i in range(n):
        lim = 1 << (lane_w - 1)
        v = rng.choice(special(lane_w)) if rng.random() < 0.5 else rng.randint(-lim, lim - 1)
        word |= (v & ((1 << lane_w) - 1)) << (i * lane_w)
    return word


def encode(valid, opcode, mode, value, a, b, acc, out):
    word = valid
    for field, width in ((opcode, 2), (mode, 2), (value, 5), (a, 32), (b, 32), (acc, 64), (out, 32)):
        word = (word << width) | (field & ((1 << width) - 1))
    return f"{word:043x}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seqs", type=int, default=1500, help="sequences per mode")
    ap.add_argument("--steps", type=int, default=30, help="instructions per sequence")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--out", default="pe_vectors.hex")
    args = ap.parse_args()

    rng = random.Random(args.seed)
    lines = []

    for mode_bits in (8, 16, 32):
        for _ in range(args.seqs):
            pe = ProcessingElement(PE_CFG)
            mode_field = Mode.opcode(mode_bits)

            # Every sequence starts with CLR (zeroes the accumulator and output),
            # so the hardware and the reference start each sequence in step.
            ops = ["CLR"] + [rng.choice(OPS) for _ in range(args.steps)]
            for idx, op in enumerate(ops):
                a, b = rand_word(rng, mode_bits), rand_word(rng, mode_bits)
                shift = rng.choice([0, 1, 2, 3, 4, rng.randint(0, 31), rng.randint(0, 31)])

                # Sometimes present the instruction with valid = 0 and garbage fields:
                # the PE must ignore it. (Reference state is left untouched.)
                if idx > 0 and rng.random() < 0.08:       # never the opening CLR
                    lines.append(encode(0, rng.randint(0, 3), rng.randint(0, 3), rng.randint(0, 31), a, b,
                                        pe.get_accumulation().uint, pe.get_output().uint))
                    continue

                pe.input_a(Bits(uint=a, length=32))
                pe.input_b(Bits(uint=b, length=32))
                inst = make_inst(op, mode_bits, shift)
                try:
                    pe.execute_instruction(inst)
                except ValueError:
                    # The reference raises on MAC accumulator overflow, which the course
                    # does not test. Avoid it by loading A into the accumulator instead.
                    if op != "MAC":
                        raise
                    op = "PASS"
                    inst = make_inst(op, mode_bits, shift)
                    pe.execute_instruction(inst)

                opcode = inst.get_opcode().uint
                value = inst.get_value().uint
                lines.append(encode(1, opcode, mode_field, value, a, b,
                                    pe.get_accumulation().uint, pe.get_output().uint))

    with open(args.out, "w") as f:
        f.write("\n".join(lines) + "\n")
    print(f"wrote {len(lines)} vectors to {args.out}")
    print(f"run the testbench with +NVEC={len(lines)}")


if __name__ == "__main__":
    main()
