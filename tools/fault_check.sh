#!/bin/bash
# ---------------------------------------------------------------------------
# fault_check.sh - does tb_deinterleave notice a wrong deinterleaver?
#
#   tools/fault_check.sh [kind ...]            default: every kind
#
# Runs tb_deinterleave (+QUICK) on ref_deinterleave_legacy with a table that
# tools/mutate_lut.py put one fault per rate into: a flipped erase flag, a
# wrong RAM address, a wrong bit, a missing pair, two pairs swapped, the
# list of another rate. The bench has to report FAIL for each of the 16
# rates, with hard and with soft decoding (32 report lines of test A), for
# every kind of fault; the untouched table has to pass.
# Log: build/fault_check.log; exit 0 only if every fault was found.
#
# Copyright 2026 Tobias Weber - SPDX-License-Identifier: Apache-2.0
# ---------------------------------------------------------------------------
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KINDS="${*:-erase_a erase_b addr_a addr_b bit_a bit_b strobe swap pointer}"
LOG="$ROOT/build/fault_check.log"
if ! command -v xvlog >/dev/null 2>&1; then
    S="${VIVADO_SETTINGS:-/tools/2025.2/Vivado/settings64.sh}"
    [ -r "$S" ] || { echo "fault_check.sh: xvlog not on PATH and $S not found" >&2; exit 2; }
    set +eu; source "$S"; set -eu
fi

# own work directory and snapshot, so the logs of 'make tb' stay as they are
WORK="$ROOT/build/fault_check"; rm -rf "$WORK"; mkdir -p "$WORK"; cd "$WORK"
: > "$LOG"
{
    xvlog "$ROOT/tb/ref_deinterleave_legacy.v"
    xvlog -d DUT_LEGACY "$ROOT/tb/tb_deinterleave.v"
    xelab --snapshot fault_snap --timescale 1ns/1ps -L work work.tb_deinterleave
} > build.log 2>&1 || { echo "fault_check.sh: build failed ($WORK/build.log)" >&2; exit 1; }

# the untouched table has to pass
cp "$ROOT/tb/vectors/deinter_lut.mem" deinter_lut.mem
xsim fault_snap -R --testplusarg QUICK > fault_none.log 2>&1 || true
grep -q "RESULT: PASS" fault_none.log \
    || { echo "fault_check.sh: tb_deinterleave fails without a fault ($WORK/fault_none.log)" | tee -a "$LOG"; exit 1; }
echo "fault_check.sh: no fault: PASS" | tee -a "$LOG"

RC=0
for K in $KINDS; do
    python3 "$ROOT/tools/mutate_lut.py" "$K" "$ROOT/tb/vectors/deinter_lut.mem" deinter_lut.mem >> "$LOG"
    xsim fault_snap -R --testplusarg QUICK > "fault_$K.log" 2>&1 || true
    FOUND=$(grep -c "^\[tb_deinterleave\] A .* FAIL$" "fault_$K.log" || true)
    grep "RESULT:" "fault_$K.log" >> "$LOG" || true
    if [ "$FOUND" -eq 32 ] && grep -q "RESULT: FAIL" "fault_$K.log"; then
        echo "fault_check.sh: $K: found for 32/32 rates and decodings" | tee -a "$LOG"
    else
        echo "fault_check.sh: $K: NOT found ($FOUND/32, build/fault_check/fault_$K.log)" | tee -a "$LOG"; RC=1
    fi
done
[ $RC -eq 0 ] && echo "fault_check.sh: PASS" | tee -a "$LOG" || echo "fault_check.sh: FAIL" | tee -a "$LOG"
exit $RC
