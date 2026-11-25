#!/usr/bin/env python3
"""Put one fault into every rate's list of the legacy deinterleaver table.

    mutate_lut.py <kind> <in.mem> <out.mem> [seed]

The table (tb/vectors/deinter_lut.mem, 4096 x 22 bit, one binary word per
line) starts with 32 pointers, indexed by {802.11n, RATE or MCS}; each
points to the list of one rate. A list entry is

    [21] erase A  [20] erase B  [19:14] RAM address A  [13:8] RAM address B
    [7:5] bit A   [4:2] bit B   [1] output strobe      [0] end of list

Kinds (one entry per rate, picked at random among those where the fault
changes a checked output):
    erase_a, erase_b    erase flag flipped
    addr_a, addr_b      lowest address bit flipped (bit not erased)
    bit_a, bit_b        lowest bit number flipped (bit not erased)
    strobe              output strobe cleared (one pair missing)
    swap                two neighbouring entries swapped
    pointer             the rate's pointer moved to the next rate's list

tools/fault_check.sh runs tb_deinterleave on each of them; the bench has to
fail for every rate.

Copyright 2026 Tobias Weber - SPDX-License-Identifier: Apache-2.0
"""
import random
import sys

KINDS = ("erase_a", "erase_b", "addr_a", "addr_b", "bit_a", "bit_b",
         "strobe", "swap", "pointer")
# pointer index {802.11n, RATE / MCS}: 6 .. 54 Mbit/s, MCS 0 .. 7
RATES = [0x0B, 0x0F, 0x0A, 0x0E, 0x09, 0x0D, 0x08, 0x0C] + list(range(0x10, 0x18))

ERASE_A, ERASE_B, STROBE, DONE = 1 << 21, 1 << 20, 1 << 1, 1 << 0


def rate_list(lut, rate):
    """Indices of the output entries of one rate's list."""
    idx = lut[rate]
    out = []
    while not lut[idx] & DONE:
        if lut[idx] & STROBE:
            out.append(idx)
        idx += 1
    return out


def main():
    if len(sys.argv) < 4 or sys.argv[1] not in KINDS:
        sys.exit(__doc__)
    kind, src, dst = sys.argv[1:4]
    rng = random.Random(int(sys.argv[4]) if len(sys.argv) > 4 else 1)
    with open(src) as f:
        lut = [int(line, 2) for line in f if line.strip()]
    orig = list(lut)

    for n, rate in enumerate(RATES):
        entries = rate_list(orig, rate)
        if kind == "pointer":
            lut[rate] = orig[RATES[(n + 1) % len(RATES)]]
            continue
        if kind == "swap":
            pairs = [i for i in entries[:-1] if orig[i] != orig[i + 1] and i + 1 in entries]
            i = rng.choice(pairs)
            lut[i], lut[i + 1] = orig[i + 1], orig[i]
            continue
        need = {"addr_a": ERASE_A, "bit_a": ERASE_A, "addr_b": ERASE_B, "bit_b": ERASE_B}.get(kind, 0)
        i = rng.choice([e for e in entries if not orig[e] & need])
        lut[i] ^= {"erase_a": ERASE_A, "erase_b": ERASE_B, "addr_a": 1 << 14, "addr_b": 1 << 8,
                   "bit_a": 1 << 5, "bit_b": 1 << 2, "strobe": STROBE}[kind]

    with open(dst, "w") as f:
        for word in lut:
            f.write("{:022b}\n".format(word))
    print("mutate_lut.py: %s, %d words differ" % (kind, sum(a != b for a, b in zip(orig, lut))))


if __name__ == "__main__":
    main()
