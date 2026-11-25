# openDEINT

Open deinterleaver for the [openofdm](https://github.com/Tobias-DG3YEV/openofdm)
802.11a/g/n receiver, part of the NLnet project
[RA-Sentinel Code Liberation](https://nlnet.nl/project/RA-Sentinel-liberation/).

`rtl/deinterleaver.v` puts the coded bits of an OFDM symbol back into the
order of the convolutional coder and marks the bits the transmitter
punctured. It replaces the deinterleaver of openofdm, which read that order
from a 4096 x 22 bit table of unknown making. The new core has no table:
three small counters follow the interleaver of IEEE 802.11. It is a drop-in:
its outputs equal the old block's in every clock.

## Files

```
rtl/deinterleaver.v            the core (plain Verilog-2001, one file)
tb/tb_deinterleave.v           bench against IEEE 802.11 (interleaver, puncturing)
tb/tb_deinterleave_replay.v    bench that replays recordings from the receiver
tb/tb_deinterleave_compare.v   bench that runs the core and the old block side by side
tb/ref_deinterleave_legacy.v   openofdm's former deinterleaver as one file (reference)
tb/deinterleave_tap.v          records the deinterleaver's ports inside the receiver
tb/vectors/deinter_lut.mem     address table of the reference (4096 x 22 bit)
tb/vectors/receiver/           21 recordings, see the README there
tools/run_tb.sh                compiles and runs the benches with XSim
tools/fault_check.sh           runs tb_deinterleave on faulty tables
tools/mutate_lut.py            puts a fault into the table
tools/capture_traces.sh        records tb/vectors/receiver/ from openofdm
tools/synth_compare.tcl        resources and speed, core and old block
```

## The deinterleaver in the receiver

The block sits between the demodulator and the Viterbi decoder. It undoes
two steps of the transmitter in one pass: the interleaver, which spreads the
coded bits of an OFDM symbol over the subcarriers, and the puncturing, which
drops coded bits to reach the rates 2/3, 3/4 and 5/6.

| port | width | |
|---|---|---|
| `i_clk`, `i_rst` | 1 | reset is synchronous, active high, and comes with every rate change; the outputs are not used while it is high |
| `i_enable` | 1 | low: no output, no progress; the receiver takes it low at the end of a frame, also while pairs are still going out, and resets the block before the next frame |
| `i_rate` | 8 | `[7]` = 802.11n, `[3:0]` = RATE field of the SIGNAL symbol or MCS 0..7 |
| `i_in_bits` | 6 | hard bits of one data subcarrier, bit 0 = first coded bit |
| `i_soft_in_bits` | 6 | one soft value per axis, `[2:0]` in-phase, `[5:3]` quadrature |
| `i_soft_in_bits_pos` | 4 | which bit of its axis each soft value belongs to, `[1:0]` / `[3:2]`, 3 = none |
| `i_input_strobe` | 1 | one subcarrier |
| `i_soft_decoding` | 1 | 1: use the soft values |
| `o_out_bits` | 6 | one pair of the rate 1/2 mother code, `[2:0]` = A, `[5:3]` = B |
| `o_erase` | 2 | `[0]` = A was punctured, `[1]` = B was punctured |
| `o_output_strobe` | 1 | one pair |

- **Input.** One symbol is N_SD = 48 (802.11a/g) or 52 (802.11n) subcarriers
  in the order of the FFT: data subcarrier N_SD / 2 first (the first positive
  frequency), up to N_SD - 1, then 0 to N_SD / 2 - 1. Any spacing.
- **Output.** N_DBPS pairs per symbol (24 at 6 Mbit/s, 260 at MCS 7), in the
  order the convolutional coder produced them. A bit is a 3 bit soft value:
  `111` strongest one, `011` strongest zero. With `i_soft_decoding` the
  demodulator's soft value replaces the hard value of the bit it belongs to.
  The value of an erased bit has no meaning.
- **Timing.** The first pair leaves 6 clocks after the last subcarrier, then
  one pair per clock. The next symbol may start after the last pair; in the
  receiver it starts at least 153 clocks later (MCS 7, 120 MHz clock).
- **Rates.** 6, 9, 12, 18, 24, 36, 48, 54 Mbit/s and MCS 0..7 (20 MHz, one
  spatial stream). The receiver decodes no other rate.
- **Disable.** After `i_enable` was low the block has to be reset before it
  is used again; that held for the old block as well.

## How it works

The interleaver of the standard (802.11-2012 18.3.5.7; 802.11n, 20 MHz:
20.3.11.8.3) moves coded bit k of a symbol to position j:

```
i = N_ROW (k mod N_COL) + floor(k / N_COL)
j = s floor(i / s) + (i + N_CBPS - floor(N_COL i / N_CBPS)) mod s

N_COL = 16 (802.11a/g) or 13 (802.11n), N_ROW = N_CBPS / N_COL, s = max(N_BPSC / 2, 1)
```

Write `col = k mod N_COL` and split the row `floor(k / N_COL)` into
`hi N_BPSC + g s + r` (`hi` < 3 or 4, `g` < 2, `r` < s). Then position j is

```
subcarrier = 3 col + hi   (802.11a/g)   or   4 col + hi   (802.11n)
bit        = g s + (r - col) mod s
```

So the core counts `col`, `col mod 3`, `r`, `g` and `hi` along with k and
needs no multiplier, no divider and no table. A pair is two consecutive coded
bits, k and k + 1. After a pair, k moves on by 2, by 1 or not at all, as the
puncturing of the rate says (18.3.5.6; rate 5/6: 20.3.11.6):

```
1/2: A0 B0                 3/4: A0 B0 A1 -- -- B2
2/3: A0 B0 A1 --           5/6: A0 B0 A1 -- -- B2 A3 -- -- B4
```

The subcarriers of a symbol are kept in a 64 x 16 bit memory. The sequence of
the old block is kept (two idle clocks before the first pair, one entry
without strobe after the last one), so that the outputs are the same in every
clock.

## Benches

**tb_deinterleave: against IEEE 802.11.** The bench is the transmitter. For
every symbol it draws the pairs of the mother code at random, punctures them,
interleaves them with the two permutations of the standard and hands the
subcarriers to the deinterleaver. Every pair that comes back is compared, and
so are the erase flags, the number of pairs and their timing. The reference
is the formulas of the standard, written as they stand there, not a table and
not the counters of the core.

| test | what | symbols |
|---|---|---|
| A | all 16 rates, hard and soft decoding, three subcarrier spacings | 19 200 |
| B | frames as the receiver decodes them (SIGNAL, HT-SIG, resets, rate changes) | 1 784 |
| C | reset while a symbol comes in | 800 |
| D | reset while the pairs go out | 1 600 |
| E | enable low between frames | 816 |
| F | enable low while the pairs go out | 1 600 |

Test A also counts coverage: every coded bit of every rate is seen as a hard
zero, as a hard one and as a soft value.

**tb_deinterleave_replay: real frames, clock for clock.**
`tb/vectors/receiver/` holds 21 recordings of the deinterleaver's ports,
taken from the old block inside openofdm's receiver while it decoded its
reference vectors: conducted and radiated captures of every 802.11a/g rate
and every MCS, and simulated frames, among them one with a damaged HT-SIG.
The bench replays the inputs and compares strobe, pairs and erase flags in
every clock without reset; with `+STRICT` every output in every clock.

**tb_deinterleave_compare: side by side.** The core and the old block get the
same inputs, and all outputs are compared in every clock: frames as in the
receiver, then every input at random (strobes while pairs go out, resets and
disables at any time), then also rate changes at any time.

## Results

Vivado 2025.2 (XSim), 2026-11-19, `make tb`:

| bench | on | result |
|---|---|---|
| tb_deinterleave | deinterleaver | PASS: 25 800 symbols, 2 980 935 pairs, 0 errors |
| tb_deinterleave_replay | deinterleaver | PASS: 21 recordings, 63 frames, 670 462 clocks, 53 652 pairs, 0 mismatches |
| tb_deinterleave_replay `+STRICT` | deinterleaver | PASS: 0 mismatches |
| tb_deinterleave_compare | deinterleaver and old block | PASS: 13 064 701 clocks, 5 369 113 pairs, 0 mismatches |
| tb_deinterleave, tb_deinterleave_replay `+STRICT` | old block (`DUT=legacy`, `DUT=openofdm`) | PASS, same numbers |
| fault check | old block with faulty tables | 9 kinds of fault, each found for all 16 rates, hard and soft |

In the receiver: openofdm's bench `dot11_tb` on all 39 reference vectors of
openofdm, once with the old block and once with `deinterleaver`. Same verdict
for every frame (148 with a good FCS, 14 with a bad one), and all 585 dump
files of the bench (decoded bytes, Viterbi input and output, descrambler
output, ...) are identical byte for byte.

Three things the benches brought to light about the old block:

- Its table follows the standard for all 16 rates.
- When the receiver took enable low while pairs were going out, the old
  block gives one stray strobe in the first clock of the next reset. The
  decoder is in reset then and ignores it. The core does the same.
- Disabled in the very clock in which it reads the end of its list, the old
  block misses the end and runs on into the list of the next rate until it
  is reset. The receiver resets it in time. The core stops instead.

The fault check shows that tb_deinterleave does not pass by accident:
`tools/mutate_lut.py` puts one fault per rate into the old block's table
(erase flag flipped, wrong subcarrier, wrong bit, pair missing, two pairs
swapped, list of another rate), and the bench has to fail for every rate.

## Resources

`make synth`: out-of-context synthesis and opt_design for xc7a100tcsg324-2,
Fmax estimated from the slack at a 3 ns clock, no placement.

| | LUT | FF | RAMB36 | RAMB18 | Fmax (est.) |
|---|---|---|---|---|---|
| deinterleaver | 125 | 81 | 0 | 1 | ~285 MHz |
| old block (table) | 82 | 50 | 3 | 1 | ~254 MHz |

The table cost three 36 kbit block RAMs; the counters cost 43 LUTs and 31
flip-flops. The RAMB18 is the subcarrier memory in both.

## Using it from openofdm

openofdm's `verilog/deinterleave.v` keeps its port names and instantiates
`deinterleaver`; `tools/openofdm_sources.tcl` finds `rtl/deinterleaver.v`
through `$OPENDEINT` or in a clone next to openofdm. The `deinter_lut` ROM and
its `.coe` / `.mif` files are no longer needed.

## Running the benches

Needs Vivado (XSim); `tools/run_tb.sh` looks for `xvlog` on `$PATH`, then in
`VIVADO_SETTINGS` (default `/tools/2025.2/Vivado/settings64.sh`).

```
make tb                         # all three benches on rtl/deinterleaver.v
make tb BENCH=deinterleave      # one bench (deinterleave | deinterleave_replay | deinterleave_compare)
make tb DUT=legacy              # on tb/ref_deinterleave_legacy.v
make tb DUT=openofdm            # on the deinterleave.v of an openofdm checkout (OPENOFDM=<checkout>)
make tb XSIM_ARGS="--testplusarg STRICT"
make faults                     # fault check
make synth                      # resources and speed (build/synth/summary.txt)
make traces                     # record tb/vectors/receiver/ again
```


tools/capture_traces.sh

Logs are written to `build/`; a bench passes if it prints `RESULT: PASS`.
`make traces` needs an openofdm checkout that still has the old block in
`verilog/deinterleave.v`, with its reference vectors.

make traces re-records the reference data that one of openDEINT's benches checks against. You don't need it to use or test openDEINT. It's only for re-recording those files or adding new ones.

  What it does (tools/capture_traces.sh)
  1. It takes the openofdm receiver as it was before openDEINT, with the old table-based deinterleave.v.
  2. It runs openofdm's own receiver bench dot11_tb on 21 of openofdm's test captures (verilog/testing_inputs/): 802.11a at every rate, 802.11n MCS 0–7, short guard interval, a wrong HT-SIG, a mixed capture, and one over the air.
  3. Next to the receiver it loads tb/deinterleave_tap.v. This module reads the old deinterleaver's inputs and outputs through the hierarchy and writes a line every time one of them changes. openofdm itself isn't modified.
  4. It writes the results to tb/vectors/receiver/<name>.txt, one line per changed clock:
  <clock> <inputs: reset, enable, soft, strobe, rate, bits…> <outputs: strobe, erase, bits>

  What the recordings are for
  tb_deinterleave_replay feeds those recorded inputs to the new deinterleaver.v clock for clock and checks that its outputs match what the old block produced. This is the "real receiver traffic" test, alongside the IEEE-formula bench and the side-by-side comparison with the old block.



## License

Apache-2.0, see [LICENSE](LICENSE). `tb/ref_deinterleave_legacy.v` is derived
from openofdm (https://github.com/jhshi/openofdm, Apache-2.0), and
`tb/vectors/deinter_lut.mem` is openofdm's `deinter_lut.coe`. Use of
generative AI: see [GENAI.md](GENAI.md).
