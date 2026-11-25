#!/bin/bash
# ---------------------------------------------------------------------------
# capture_traces.sh - record the recordings in tb/vectors/receiver/.
#
#   tools/capture_traces.sh [name ...]         default: every recording
#
# Simulates openofdm's receiver bench dot11_tb on one of its reference
# vectors with tb/deinterleave_tap.v as a second top module, which writes
# down the ports of the receiver's deinterleaver (format: see there).
# openofdm is not changed. Needs
#   * Vivado (xvlog on $PATH or in VIVADO_SETTINGS) and tclsh,
#   * an openofdm checkout that still has its own verilog/deinterleave.v:
#     OPENOFDM, default the checkout next to this one, with openViterbi,
#     openCMUL, openCDIV, openFFT and openATAN where its
#     tools/openofdm_sources.tcl finds them,
#   * the vectors of the table below in verilog/testing_inputs/.
# FRAMES (default 3) limits a recording to the first frames of a capture
# with many; 0 records all of them. A third column in the table below
# overrides it for one recording.
# Output: tb/vectors/receiver/<name>.txt, work files in build/capture/.
#
# Copyright 2026 Tobias Weber - SPDX-License-Identifier: Apache-2.0
# ---------------------------------------------------------------------------
set -eEuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OFDM="$(cd "${OPENOFDM:-$ROOT/../openofdm}" 2>/dev/null && pwd)" || { echo "capture_traces.sh: openofdm not found (set OPENOFDM)" >&2; exit 2; }
FRAMES="${FRAMES:-3}"
TI="$OFDM/verilog/testing_inputs"
MAC_A="e4_90_7e_15_2a_16_e8_de_27_90_6e_42"
MAC_N="98_5f_d3_c7_06_27_e8_de_27_90_6e_42"

# name                    vector below verilog/testing_inputs/                              frames
TABLE="
dot11a_6mbps              conducted/dot11a_6mbps_qos_data_${MAC_A}_openwifi.txt
dot11a_9mbps              conducted/dot11a_9mbps_qos_data_${MAC_A}_openwifi.txt
dot11a_12mbps             conducted/dot11a_12mbps_qos_data_${MAC_A}_openwifi.txt
dot11a_18mbps             conducted/dot11a_18mbps_qos_data_${MAC_A}_openwifi.txt
dot11a_24mbps             conducted/dot11a_24mbps_qos_data_${MAC_A}_openwifi.txt
dot11a_36mbps             conducted/dot11a_36mbps_qos_data_${MAC_A}_openwifi.txt
dot11a_48mbps             conducted/dot11a_48mbps_qos_data_${MAC_A}_openwifi.txt
dot11a_54mbps_len14       simulated/ag_54M_len14_pre100_post200_openwifi.txt
dot11a_54mbps_len1537     simulated/ag_54M_len1537_pre100_post200_openwifi.txt
dot11n_mcs0               conducted/dot11n_6.5mbps_${MAC_N}_openwifi.txt
dot11n_mcs0_sgi           conducted/dot11n_7.2mbps_${MAC_N}_openwifi.txt
dot11n_mcs1               conducted/dot11n_13mbps_${MAC_N}_openwifi.txt
dot11n_mcs2_radiated      radiated/dot11n_19.5mbps_openwifi.txt
dot11n_mcs3               conducted/dot11n_26mbps_${MAC_N}_openwifi.txt
dot11n_mcs4               conducted/dot11n_39mbps_${MAC_N}_openwifi.txt
dot11n_mcs5               conducted/dot11n_52mbps_${MAC_N}_openwifi.txt
dot11n_mcs6               conducted/dot11n_58.5mbps_${MAC_N}_openwifi.txt
dot11n_mcs7               conducted/dot11n_65mbps_${MAC_N}_openwifi.txt
dot11n_mcs7_sgi_len14     simulated/ht_mcs7_gi1_aggr0_len14_pre100_post200_openwifi.txt
dot11n_wrong_ht_sig       simulated/iq_11n_mcs7_gi0_100B_wrong_ht_sig_openwifi.txt
mixed                     simulated/iq_mixed_for_side_ch_openwifi.txt                          0
"

if ! command -v xvlog >/dev/null 2>&1; then
    S="${VIVADO_SETTINGS:-/tools/2025.2/Vivado/settings64.sh}"
    [ -r "$S" ] || { echo "capture_traces.sh: xvlog not on PATH and $S not found" >&2; exit 2; }
    set +eu; source "$S"; set -eu
fi
WORK="$ROOT/build/capture"; rm -rf "$WORK"; mkdir -p "$WORK" "$ROOT/tb/vectors/receiver"; cd "$WORK"

# the receiver's file list, from openofdm itself
cat > lists.tcl <<TCL
source $OFDM/tools/openofdm_sources.tcl
set fh [open files.f w]
foreach f [concat [openofdm::rtl] [openofdm::viterbi] [openofdm::testbench]] { puts \$fh \$f }
close \$fh
TCL
tclsh lists.tcl

# One xvlog call for the receiver: its files share \`define macros. The vector
# is chosen per run with the SAMPLE_FILE define, so compile per vector.
echo "$TABLE" | while read -r NAME VEC NFRAMES; do
    [ -n "$NAME" ] || continue
    if [ $# -gt 0 ]; then
        case " $* " in *" $NAME "*) ;; *) continue ;; esac
    fi
    [ -r "$TI/$VEC" ] || { echo "capture_traces.sh: $NAME: vector not found: $TI/$VEC" >&2; exit 1; }
    mkdir -p "$NAME"; cd "$NAME"
    xvlog -i "$OFDM/verilog" -d "LUT_DIR=\"$OFDM/verilog\"" -d "VECTOR_DIR=\"$TI\"" \
          -d "SAMPLE_FILE=\"$TI/$VEC\"" $(cat ../files.f) > xvlog.log 2>&1 || { grep ERROR xvlog.log | head; exit 1; }
    xvlog "$ROOT/tb/deinterleave_tap.v" "$XILINX_VIVADO/data/verilog/src/glbl.v" >> xvlog.log 2>&1
    xelab --snapshot capture --timescale 1ns/1ps -L work -L xpm -L unisims_ver \
          work.dot11_tb work.deinterleave_tap work.glbl > xelab.log 2>&1 || { tail -20 xelab.log; exit 1; }
    xsim capture -R --testplusarg "TAP_FILE=$ROOT/tb/vectors/receiver/$NAME.txt" \
         --testplusarg "TAP_FRAMES=${NFRAMES:-$FRAMES}" > xsim.log 2>&1 || { tail -20 xsim.log; exit 1; }
    echo "$NAME: $(wc -l < "$ROOT/tb/vectors/receiver/$NAME.txt") lines, FCS ok/bad $(grep -c 'fcs_ok = 1' xsim.log || true)/$(grep -c 'fcs_ok = 0' xsim.log || true)  ($VEC)"
    cd ..
done
