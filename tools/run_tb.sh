#!/bin/bash
# ---------------------------------------------------------------------------
# run_tb.sh - compile and run the benches in tb/ with XSim.
#
#   tools/run_tb.sh [deinterleave|deinterleave_replay|deinterleave_compare|all] [xsim args]
#                                   e.g. deinterleave --testplusarg QUICK
#
# tb_deinterleave         the deinterleaver against the interleaver and the
#                         puncturing of IEEE 802.11, all 16 rates.
# tb_deinterleave_replay  the recordings in tb/vectors/receiver/ replayed
#                         clock for clock, one simulation per recording
#                         (TRACES="<files>" selects others).
# tb_deinterleave_compare rtl/deinterleaver.v and tb/ref_deinterleave_legacy.v
#                         side by side, every output in every clock (DUT is
#                         not used).
#
# DUT selects the module under test:
#   DUT=open       rtl/deinterleaver.v (default)
#   DUT=legacy     tb/ref_deinterleave_legacy.v, openofdm's former
#                  deinterleaver as one file with tb/vectors/deinter_lut.mem
#   DUT=openofdm   the deinterleave.v of an openofdm checkout with whatever
#                  it is built from there (delayT.v, ram_2port.v, lut_roms.v)
#                  and rtl/deinterleaver.v: OPENOFDM, default the checkout
#                  next to this one
# Needs nothing but Vivado (xvlog on $PATH or in VIVADO_SETTINGS).
# Every source file gets its own xvlog call: xvlog keeps `define macros
# across the files of one invocation.
# Log: build/<bench>.log; exit 0 only if every simulation printed
# "RESULT: PASS".
#
# Copyright 2026 Tobias Weber - SPDX-License-Identifier: Apache-2.0
# ---------------------------------------------------------------------------
set -eEuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WHICH="${1:-all}"; [ $# -gt 0 ] && shift
case "$WHICH" in
    deinterleave|deinterleave_replay|deinterleave_compare) BENCHES="$WHICH" ;;
    all) BENCHES="deinterleave deinterleave_replay deinterleave_compare" ;;
    *) echo "run_tb.sh: unknown bench '$WHICH' (deinterleave|deinterleave_replay|deinterleave_compare|all)" >&2; exit 2 ;;
esac
DUT="${DUT:-open}"
OFDM="${OPENOFDM:-$ROOT/../openofdm}"
case "$DUT" in
    open|legacy) ;;
    openofdm) [ -r "$OFDM/verilog/deinterleave.v" ] || { echo "run_tb.sh: openofdm not found at $OFDM (set OPENOFDM)" >&2; exit 2; } ;;
    *) echo "run_tb.sh: unknown DUT '$DUT' (open|legacy|openofdm)" >&2; exit 2 ;;
esac
if ! command -v xvlog >/dev/null 2>&1; then
    S="${VIVADO_SETTINGS:-/tools/2025.2/Vivado/settings64.sh}"
    [ -r "$S" ] || { echo "run_tb.sh: xvlog not on PATH and $S not found" >&2; exit 2; }
    set +eu; source "$S"; set -eu
    command -v xvlog >/dev/null 2>&1 || { echo "run_tb.sh: xvlog still missing" >&2; exit 2; }
fi
BUILD="$ROOT/build"; mkdir -p "$BUILD"
RC=0
for TB in $BENCHES; do
    TBN="tb_$TB"; LOG="$BUILD/$TBN.log"; WORK="$BUILD/$TBN"
    rm -rf "$WORK"; mkdir -p "$WORK"; : > "$LOG"
    RUNS=1
    (
        cd "$WORK"
        log() { echo "$*" | tee -a "$LOG"; }
        run() { log "+ $*"; "$@" 2>&1 | tee -a "$LOG"; }
        trap 'echo "### run_tb.sh: $TBN FAILED (see $LOG)" | tee -a "$LOG"; exit 1' ERR
        log "### run_tb.sh $TBN  $([ "$TB" = deinterleave_compare ] || echo "DUT=$DUT  ")$(date '+%Y-%m-%d %H:%M:%S')  root=$ROOT"
        DEFS=()
        if [ "$TB" = deinterleave_compare ]; then
            cp "$ROOT/tb/vectors/deinter_lut.mem" .
            SRC=("$ROOT/rtl/deinterleaver.v" "$ROOT/tb/ref_deinterleave_legacy.v")
        elif [ "$DUT" = openofdm ]; then
            OFDM="$(cd "$OFDM" && pwd)"
            DEFS=(-d DUT_OPENOFDM -d "LUT_DIR=\"$OFDM/verilog\"")
            SRC=("$ROOT/rtl/deinterleaver.v")
            for f in delayT.v ram_2port.v lut_roms.v deinterleave.v; do
                [ -r "$OFDM/verilog/$f" ] && SRC+=("$OFDM/verilog/$f")
            done
        elif [ "$DUT" = legacy ]; then
            DEFS=(-d DUT_LEGACY)
            cp "$ROOT/tb/vectors/deinter_lut.mem" .
            SRC=("$ROOT/tb/ref_deinterleave_legacy.v")
        else
            SRC=("$ROOT/rtl/deinterleaver.v")
        fi
        for f in "${SRC[@]}" "$ROOT/tb/$TBN.v"; do
            run xvlog ${DEFS[@]+"${DEFS[@]}"} "$f"
        done
        run xelab --snapshot ${TBN}_snap --timescale 1ns/1ps -L work "work.$TBN"
        if [ "$TB" = deinterleave_replay ]; then
            for t in ${TRACES:-"$ROOT"/tb/vectors/receiver/*.txt}; do
                [ -r "$t" ] || { log "run_tb.sh: recording not found: $t"; false; }
                run xsim ${TBN}_snap -R --testplusarg "TRACE=$t" "$@"
            done
        else
            run xsim ${TBN}_snap -R "$@"
        fi
    ) || true
    [ "$TB" = deinterleave_replay ] && RUNS=$(ls ${TRACES:-"$ROOT"/tb/vectors/receiver/*.txt} 2>/dev/null | wc -l)
    PASSES=$(grep -c "RESULT: PASS" "$LOG" || true)
    if [ "$PASSES" -ge 1 ] && [ "$PASSES" -eq "$RUNS" ] && ! grep -q "RESULT: FAIL\|FAILED" "$LOG"; then
        echo "### run_tb.sh: $TBN PASS  ($PASSES/$RUNS simulations, $LOG)" | tee -a "$LOG"
    else
        echo "### run_tb.sh: $TBN FAIL  ($PASSES/$RUNS simulations passed, $LOG)" | tee -a "$LOG"; RC=1
    fi
done
exit $RC
