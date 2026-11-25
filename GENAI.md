# Use of generative AI in openDEINT

This file implements NLnet's *Policy on the use of Generative Artificial
Intelligence for NLnet-funded projects*
(https://nlnet.nl/foundation/policies/generativeAI/). openDEINT is part of the
NLnet-funded project RA-Sentinel Code Liberation
(https://nlnet.nl/project/RA-Sentinel-liberation/), task 4 "Deinterlacer".

## General stance

The testbench (milestone a) and the core (milestone b) were written in
November 2026 with the help of **Claude Code** (Anthropic), model Claude
Fable 5.2, as a coding assistant.

The division of work:

- **Tobias Weber** specified the task, architecture, interface a testbench
  for the deinterleaver of openofdm, then an own implementation in its own
  repository that replaces openofdm's module as a drop-in) and decided the approach.
  He reviewed and edited the generated code, ran the benches.

- **Claude (Claude Code, Anthropic)** drafted the core `rtl/deinterleaver.v`
  (the counters that replace the address table were derived from the
  interleaver formulas of IEEE 802.11 in that session), the three
  self-checking benches, the reference copy of openofdm's deinterleaver, the
  port recorder, the shell / Python / Tcl tools and the documentation under
  that direction, in an interactive session, and ran them with XSim and
  Vivado.

## tools/capture_traces.sh

This script is written by **Claude (Claude Code, Fable 5.2)
It re-records the reference data that one of openDEINT's benches checks against. You don't need it to use or test openDEINT. It's only for re-recording those files or adding new ones.
It can alse be called by "make traces" in the project directory.

Commits without such a block were written without generative AI.
