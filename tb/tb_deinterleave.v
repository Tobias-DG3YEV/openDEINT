`timescale 1ns / 1ps
`default_nettype none

//----------------------------------------------------------------------------
// Module : tb_deinterleave
// Purpose: Self-checking XSim bench for the deinterleaver of the openofdm
// receiver, against IEEE 802.11 (not against a table or another model).
//
// The bench is the transmitter: for every OFDM symbol it draws the pairs
// (A, B) of the rate 1/2 mother code at random, punctures them (802.11-2012
// 18.3.5.6, rate 5/6: 20.3.11.6), interleaves the remaining N_CBPS bits
// (18.3.5.7, 802.11n 20 MHz: 20.3.11.8.3 with N_COL = 13, N_ROW = 4 N_BPSC)
// and maps them to the N_SD data subcarriers, bit 0 of a subcarrier first.
// The subcarriers go to the DUT as the receiver's FFT delivers them,
// subcarrier N_SD / 2 first, wrapping from N_SD - 1 to 0. The DUT has to
// hand back the pairs in their original order, with an erase flag wherever
// the transmitter punctured a bit.
//
//   interleaver, k = index before, j = index after, s = max(N_BPSC / 2, 1):
//     i = N_ROW (k mod N_COL) + floor(k / N_COL)
//     j = s floor(i / s) + (i + N_CBPS - floor(N_COL i / N_CBPS)) mod s
//   802.11a/g: N_COL = 16, N_ROW = 3 N_BPSC; 802.11n: N_COL = 13, N_ROW = 4 N_BPSC
//   puncturing, sent bits of one period:
//     2/3: A0 B0 A1          3/4: A0 B0 A1 B2          5/6: A0 B0 A1 B2 A3 B4
//
// Output format: 3 bit soft value per bit, 3'b111 = one, 3'b011 = zero,
// o_out_bits[2:0] = A, [5:3] = B, o_erase[0] = A erased, [1] = B erased.
// With i_soft_decoding the demodulator's soft value replaces the hard value
// of the one bit per axis it belongs to (i_soft_in_bits[2:0] and
// i_soft_in_bits_pos[1:0] for the in-phase bits 0 .. N_BPSC / 2 - 1, [5:3]
// and [3:2] for the quadrature bits, position 3 = none). The bench draws
// soft values and positions at random, so a value taken from the wrong
// place shows. The value of an erased bit is not checked.
//
// Configurations: 0..7 = 6, 9, 12, 18, 24, 36, 48, 54 Mbit/s (802.11a/g),
// 8..15 = MCS 0..7 (802.11n, 20 MHz, one spatial stream).
//
// Tests:
//   A) every configuration, hard and soft decoding, NUM_SYM symbols for each
//      of three subcarrier spacings (back to back, bursts as in the receiver,
//      random gaps), the next symbol GAP_MIN .. GAP_MAX clocks after the last
//      pair
//   B) frames as the receiver decodes them: reset, SIGNAL at 6 Mbit/s, reset
//      with the new rate (802.11n: two HT-SIG symbols and a long reset
//      first), data symbols, enable low
//   C) reset while a symbol is coming in, then a complete symbol
//   D) reset while the pairs are going out, then a complete symbol
//   E) enable low between frames with strobes on the input, then reset and
//      a complete symbol
//   F) enable low while the pairs are going out (the receiver does that at
//      the end of a frame), then reset and a complete symbol
//
// Checks: every pair compared in order with the expectation (erase flags,
// soft value of every bit that is not erased), the number of pairs per
// symbol (no pair missing, none too many, none before the last subcarrier,
// none after a reset, none while disabled), the timing of the legacy block
// that a drop-in has to keep (first pair EXP_LATENCY clocks after the last
// subcarrier, then one pair per clock), and the reference model itself
// (the interleaver is a permutation, N_DBPS pairs per symbol). Coverage:
// every coded bit of every configuration has to be seen as a hard zero, as
// a hard one and, with soft decoding, as a soft value.
// While i_rst is high the outputs are not looked at: the decoder behind the
// deinterleaver is in the same reset. (openofdm's block gives one stray
// strobe in the first reset clock after it was disabled in mid-output.)
//
// DUT: deinterleaver (rtl/), with `define DUT_LEGACY ref_deinterleave_legacy,
// with `define DUT_OPENOFDM the deinterleave of an openofdm checkout
// (tools/run_tb.sh, DUT=open | legacy | openofdm).
//
// Report (machine-greppable):
//   [tb_deinterleave] A <rate> N_BPSC=.. R=.. N_SD=.. hard|soft symbols=<n>
//     pairs=<n> erased=<n> soft_values=<n> latency=<min>..<max> min_gap=<n>
//     cov=<n>/<N_CBPS> soft_cov=<n>/<N_CBPS> errors=<n> PASS|FAIL
//   [tb_deinterleave] B|C|D|E|F <rate> ... errors=<n> PASS|FAIL
//   [tb_deinterleave] RESULT: PASS (<n> symbols, <n> pairs)   or   RESULT: FAIL (...)
//
// Plusargs: +QUICK a tenth of the symbols (debug aid, not a full run),
//           +SEED=<n> another random sequence.
// `define DUMP dumps a VCD (tb_deinterleave.vcd).
//
// Project: RA-Sentinel (NLnet), https://github.com/Tobias-DG3YEV/openDEINT
// Engineer: Tobias Weber
//----------------------------------------------------------------------------
// Copyright 2026 Tobias Weber
// SPDX-License-Identifier: Apache-2.0
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may
// not use this file except in compliance with the License. You may obtain
// a copy of the License at http://www.apache.org/licenses/LICENSE-2.0
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//----------------------------------------------------------------------------
module tb_deinterleave;

    //---- Bench constants -----------------------------------------------------
    localparam integer PERIOD      = 10;        // ns
    localparam integer NUM_RATE    = 16;
    localparam integer MAX_SD      = 52;        // data subcarriers
    localparam integer MAX_CBPS    = 312;       // coded bits per symbol
    localparam integer MAX_DBPS    = 260;       // pairs per symbol
    localparam integer NUM_PACE    = 3;
    localparam integer NUM_SYM     = 200;       // A: symbols per rate, mode and spacing
    localparam integer NUM_FRAME   = 20;        // B: frames per rate
    localparam integer NUM_RESET   = 50;        // C, D, E, F: repetitions per rate
    localparam integer QUICK_DIV   = 10;
    localparam integer EXP_LATENCY = 6;         // clocks, last subcarrier -> first pair
    localparam integer GAP_MIN     = 4;         // idle clocks after the last pair
    localparam integer GAP_MAX     = 60;
    localparam integer OUT_TIMEOUT = 2000;      // clocks to wait for the pairs
    localparam integer MAX_PRINT   = 10;        // errors printed per report line
    localparam integer SEED_INIT   = 20261119;
    localparam integer WATCHDOG    = 400000000; // clocks

    //---- DUT ports -----------------------------------------------------------
    reg         clk;
    reg         rst;
    reg         enable;
    reg  [7:0]  rate;
    reg  [5:0]  in_bits;
    reg  [5:0]  in_soft_bits;
    reg  [3:0]  in_soft_bits_pos;
    reg         in_strobe;
    reg         soft_decoding;
    wire [5:0]  dut_out_bits;
    wire [1:0]  dut_erase;
    wire        dut_output_strobe;

`ifdef DUT_OPENOFDM
    deinterleave u_dut (
        .i_clock            (clk),
        .i_reset            (rst),
        .i_enable           (enable),
        .i_rate             (rate),
        .i_in_bits          (in_bits),
        .i_soft_in_bits     (in_soft_bits),
        .i_soft_in_bits_pos (in_soft_bits_pos),
        .i_input_strobe     (in_strobe),
        .i_soft_decoding    (soft_decoding),
        .o_out_bits         (dut_out_bits),
        .o_erase            (dut_erase),
        .o_output_strobe    (dut_output_strobe)
    );
`elsif DUT_LEGACY
    ref_deinterleave_legacy u_dut (
        .i_clk              (clk),
        .i_rst              (rst),
        .i_enable           (enable),
        .i_rate             (rate),
        .i_in_bits          (in_bits),
        .i_soft_in_bits     (in_soft_bits),
        .i_soft_in_bits_pos (in_soft_bits_pos),
        .i_input_strobe     (in_strobe),
        .i_soft_decoding    (soft_decoding),
        .o_out_bits         (dut_out_bits),
        .o_erase            (dut_erase),
        .o_output_strobe    (dut_output_strobe)
    );
`else
    deinterleaver u_dut (
        .i_clk              (clk),
        .i_rst              (rst),
        .i_enable           (enable),
        .i_rate             (rate),
        .i_in_bits          (in_bits),
        .i_soft_in_bits     (in_soft_bits),
        .i_soft_in_bits_pos (in_soft_bits_pos),
        .i_input_strobe     (in_strobe),
        .i_soft_decoding    (soft_decoding),
        .o_out_bits         (dut_out_bits),
        .o_erase            (dut_erase),
        .o_output_strobe    (dut_output_strobe)
    );
`endif

    //---- Clock ---------------------------------------------------------------
    initial begin
        clk = 1'b0;
    end

    always begin
        #(PERIOD / 2) clk = ~clk;
    end

`ifdef DUMP
    initial begin
        $dumpfile("tb_deinterleave.vcd");
        $dumpvars(0, tb_deinterleave);
    end
`endif

    //---- Rate table ----------------------------------------------------------
    // i_rate: [7] = 802.11n, [3:0] = RATE field of the SIGNAL symbol or MCS
    function [7:0] rate_code;
        input integer r;
        begin
            case (r)
                0:       rate_code = 8'h0B;     //  6 Mbit/s
                1:       rate_code = 8'h0F;     //  9 Mbit/s
                2:       rate_code = 8'h0A;     // 12 Mbit/s
                3:       rate_code = 8'h0E;     // 18 Mbit/s
                4:       rate_code = 8'h09;     // 24 Mbit/s
                5:       rate_code = 8'h0D;     // 36 Mbit/s
                6:       rate_code = 8'h08;     // 48 Mbit/s
                7:       rate_code = 8'h0C;     // 54 Mbit/s
                default: rate_code = 8'h80 + (r - 8);
            endcase
        end
    endfunction

    function [8*10-1:0] rate_name;
        input integer r;
        begin
            case (r)
                0:       rate_name = "6 Mbit/s";
                1:       rate_name = "9 Mbit/s";
                2:       rate_name = "12 Mbit/s";
                3:       rate_name = "18 Mbit/s";
                4:       rate_name = "24 Mbit/s";
                5:       rate_name = "36 Mbit/s";
                6:       rate_name = "48 Mbit/s";
                7:       rate_name = "54 Mbit/s";
                8:       rate_name = "MCS 0";
                9:       rate_name = "MCS 1";
                10:      rate_name = "MCS 2";
                11:      rate_name = "MCS 3";
                12:      rate_name = "MCS 4";
                13:      rate_name = "MCS 5";
                14:      rate_name = "MCS 6";
                default: rate_name = "MCS 7";
            endcase
        end
    endfunction

    // coded bits per subcarrier: BPSK 1, QPSK 2, 16-QAM 4, 64-QAM 6
    function integer rate_nbpsc;
        input integer r;
        begin
            case (r)
                0, 1, 8:        rate_nbpsc = 1;
                2, 3, 9, 10:    rate_nbpsc = 2;
                4, 5, 11, 12:   rate_nbpsc = 4;
                default:        rate_nbpsc = 6;
            endcase
        end
    endfunction

    // coding rate: 0 = 1/2, 1 = 2/3, 2 = 3/4, 3 = 5/6
    function integer rate_coding;
        input integer r;
        begin
            case (r)
                0, 2, 4, 8, 9, 11:  rate_coding = 0;
                6, 13:              rate_coding = 1;
                15:                 rate_coding = 3;
                default:            rate_coding = 2;
            endcase
        end
    endfunction

    function [8*3-1:0] coding_name;
        input integer coding;
        begin
            case (coding)
                0:       coding_name = "1/2";
                1:       coding_name = "2/3";
                2:       coding_name = "3/4";
                default: coding_name = "5/6";
            endcase
        end
    endfunction

    function integer rate_nsd;
        input integer r;
        begin
            rate_nsd = (r >= 8) ? 52 : 48;
        end
    endfunction

    // data bits per symbol = pairs per symbol, from the data rate (4 us symbols)
    function integer rate_ndbps;
        input integer r;
        begin
            case (r)
                0:       rate_ndbps = 24;
                1:       rate_ndbps = 36;
                2:       rate_ndbps = 48;
                3:       rate_ndbps = 72;
                4:       rate_ndbps = 96;
                5:       rate_ndbps = 144;
                6:       rate_ndbps = 192;
                7:       rate_ndbps = 216;
                8:       rate_ndbps = 26;
                9:       rate_ndbps = 52;
                10:      rate_ndbps = 78;
                11:      rate_ndbps = 104;
                12:      rate_ndbps = 156;
                13:      rate_ndbps = 208;
                14:      rate_ndbps = 234;
                default: rate_ndbps = 260;
            endcase
        end
    endfunction

    //---- Puncturing (802.11-2012 Figure 18-9, Figure 20-11) ------------------
    function integer punct_period;
        input integer coding;
        begin
            case (coding)
                0:       punct_period = 1;
                1:       punct_period = 2;
                2:       punct_period = 3;
                default: punct_period = 5;
            endcase
        end
    endfunction

    // 1 = bit A of pair <phase> of the period is sent
    function keep_a;
        input integer coding;
        input integer phase;
        begin
            case (coding)
                2:       keep_a = (phase != 2);                 // 3/4: A0 A1 -
                3:       keep_a = (phase != 2) && (phase != 4); // 5/6: A0 A1 - A3 -
                default: keep_a = 1'b1;
            endcase
        end
    endfunction

    // 1 = bit B of pair <phase> of the period is sent
    function keep_b;
        input integer coding;
        input integer phase;
        begin
            case (coding)
                1:       keep_b = (phase != 1);                 // 2/3: B0 -
                2:       keep_b = (phase != 1);                 // 3/4: B0 - B2
                3:       keep_b = (phase != 1) && (phase != 3); // 5/6: B0 - B2 - B4
                default: keep_b = 1'b1;
            endcase
        end
    endfunction

    //---- Interleaver (802.11-2012 18.3.5.7, 20.3.11.8.3) ---------------------
    // position after interleaving of coded bit k
    function integer interleave_pos;
        input integer k;
        input integer nbpsc;
        input integer ht;
        integer n_col;
        integer n_row;
        integer n_cbps;
        integer s;
        integer i;
        begin
            n_col  = ht ? 13 : 16;
            n_row  = ht ? 4 * nbpsc : 3 * nbpsc;
            n_cbps = n_col * n_row;
            s      = (nbpsc / 2 > 1) ? nbpsc / 2 : 1;
            i      = n_row * (k % n_col) + k / n_col;
            interleave_pos = s * (i / s) + (i + n_cbps - (n_col * i) / n_cbps) % s;
        end
    endfunction

    //---- Random numbers ------------------------------------------------------
    integer seed;

    // 0 .. n - 1
    function integer rnd;
        input integer n;
        begin
            rnd = {$random(seed)} % n;
        end
    endfunction

    //---- One symbol of the reference model -----------------------------------
    reg         tx_bit    [0:MAX_CBPS-1];   // coded bits after interleaving
    reg         tx_hit    [0:MAX_CBPS-1];
    integer     pos_a     [0:MAX_DBPS-1];   // interleaved position of A, -1 = punctured
    integer     pos_b     [0:MAX_DBPS-1];
    reg  [5:0]  car_bits  [0:MAX_SD-1];     // subcarriers as the demodulator delivers them
    reg  [5:0]  car_soft  [0:MAX_SD-1];
    reg  [3:0]  car_pos   [0:MAX_SD-1];
    reg  [5:0]  exp_bits  [0:MAX_DBPS-1];   // expected pairs
    reg  [1:0]  exp_erase [0:MAX_DBPS-1];
    reg  [1:0]  exp_soft  [0:MAX_DBPS-1];   // bit is a soft value: [0] A, [1] B
    integer     sym_pairs;
    integer     model_errors;

    // Soft value of the coded bit at interleaved position j: {is soft, value}
    function [3:0] ref_value;
        input integer j;
        input integer nbpsc;
        input integer soft_mode;
        integer     m;
        integer     b;
        integer     half;
        reg  [5:0]  hard;
        reg  [5:0]  soft;
        reg  [3:0]  pos;
        begin
            m    = j / nbpsc;
            b    = j % nbpsc;
            half = nbpsc / 2;
            hard = car_bits[m];
            soft = car_soft[m];
            pos  = car_pos[m];
            ref_value = {1'b0, hard[b] ? 3'b111 : 3'b011};
            if (soft_mode != 0) begin
                if (nbpsc == 1 || b < half) begin
                    if (pos[1:0] == b) begin
                        ref_value = {1'b1, soft[2:0]};
                    end
                end
                else if (pos[3:2] == b - half) begin
                    ref_value = {1'b1, soft[5:3]};
                end
            end
        end
    endfunction

    task model_error;
        input integer r;
        input integer code;
        begin
            model_errors = model_errors + 1;
            if (model_errors <= MAX_PRINT) begin
                $display("[tb_deinterleave] reference model inconsistent for %0s (%0d)", rate_name(r), code);
            end
        end
    endtask

    task build_symbol;
        input integer r;
        input integer soft_mode;
        integer     nbpsc;
        integer     ht;
        integer     nsd;
        integer     n_cbps;
        integer     coding;
        integer     period;
        integer     n_pos;
        integer     k;
        integer     n;
        integer     j;
        integer     m;
        integer     b;
        integer     v;
        reg  [5:0]  word;
        reg  [3:0]  pos;
        reg  [3:0]  val;
        reg  [1:0]  soft;
        begin
            nbpsc  = rate_nbpsc(r);
            ht     = (r >= 8) ? 1 : 0;
            nsd    = rate_nsd(r);
            n_cbps = nsd * nbpsc;
            coding = rate_coding(r);
            period = punct_period(coding);

            // mother code, puncturing, interleaving
            for (j = 0; j < n_cbps; j = j + 1) begin
                tx_hit[j] = 1'b0;
            end
            k = 0;
            n = 0;
            while (k < n_cbps && n < MAX_DBPS) begin
                pos_a[n] = -1;
                pos_b[n] = -1;
                if (keep_a(coding, n % period)) begin
                    j = interleave_pos(k, nbpsc, ht);
                    if (j < 0 || j >= n_cbps || tx_hit[j]) begin
                        model_error(r, 1);
                    end
                    else begin
                        tx_hit[j] = 1'b1;
                        tx_bit[j] = rnd(2);
                    end
                    pos_a[n] = j;
                    k = k + 1;
                end
                if (keep_b(coding, n % period)) begin
                    j = interleave_pos(k, nbpsc, ht);
                    if (k >= n_cbps || j < 0 || j >= n_cbps || tx_hit[j]) begin
                        model_error(r, 2);
                    end
                    else begin
                        tx_hit[j] = 1'b1;
                        tx_bit[j] = rnd(2);
                    end
                    pos_b[n] = j;
                    k = k + 1;
                end
                n = n + 1;
            end
            sym_pairs = n;
            if (k != n_cbps || n != rate_ndbps(r)) begin
                model_error(r, 3);
            end

            // subcarriers: bit 0 first; soft values and their positions at random
            n_pos = (nbpsc / 2 > 1) ? nbpsc / 2 : 1;
            for (m = 0; m < nsd; m = m + 1) begin
                word = 6'd0;
                for (b = 0; b < nbpsc; b = b + 1) begin
                    word[b] = tx_bit[m * nbpsc + b];
                end
                car_bits[m] = word;
                word = rnd(64);
                if (nbpsc == 1) begin
                    word[5:3] = 3'b000;
                end
                car_soft[m] = word;
                v = rnd(n_pos + 1);
                pos[1:0] = (v == n_pos) ? 2'd3 : v;
                v = rnd(n_pos + 1);
                pos[3:2] = (nbpsc == 1 || v == n_pos) ? 2'd3 : v;
                car_pos[m] = pos;
            end

            // what the DUT has to hand back
            for (n = 0; n < sym_pairs; n = n + 1) begin
                word = 6'd0;
                soft = 2'b00;
                exp_erase[n] = {pos_b[n] < 0, pos_a[n] < 0};
                if (pos_a[n] >= 0) begin
                    val       = ref_value(pos_a[n], nbpsc, soft_mode);
                    word[2:0] = val[2:0];
                    soft[0]   = val[3];
                end
                if (pos_b[n] >= 0) begin
                    val       = ref_value(pos_b[n], nbpsc, soft_mode);
                    word[5:3] = val[2:0];
                    soft[1]   = val[3];
                end
                exp_bits[n] = word;
                exp_soft[n] = soft;
            end
        end
    endtask

    //---- Scoreboard ----------------------------------------------------------
    integer     cycle;                      // rising clock edges
    integer     exp_n;                      // pairs expected for the symbol in flight
    integer     out_n;                      // pairs received
    reg         inputs_done;                // last subcarrier of the symbol on the port
    integer     last_in_cycle;
    integer     prev_out_cycle;
    reg         gap_armed;                  // symbol complete, waiting for the next
    reg         in_seen;
    integer     cur_r;                      // configuration and decoding of the symbol
    integer     cur_soft;
    integer     cur_sym;                    // symbol number within the report line
    reg         print_it;

    integer     errors_total;
    integer     errors_line;                // errors since the last report line
    integer     stat_symbols;
    integer     stat_pairs;
    integer     stat_erased;
    integer     stat_soft;
    integer     total_symbols;
    integer     total_pairs;
    integer     lat_min;
    integer     lat_max;
    integer     gap_min_seen;
    reg         cov_zero  [0:MAX_CBPS-1];
    reg         cov_one   [0:MAX_CBPS-1];
    reg         cov_soft  [0:MAX_CBPS-1];

    task count_error;
        begin
            errors_total = errors_total + 1;
            errors_line  = errors_line + 1;
            print_it     = (errors_line <= MAX_PRINT);
        end
    endtask

    task check_half;
        input integer j;                    // interleaved position, -1 = erased
        input [2:0]   got;
        input [2:0]   expected;
        input         is_soft;
        input [8*1-1:0] half_name;
        begin
            if (j >= 0) begin
                if (got !== expected) begin
                    count_error;
                    if (print_it) begin
                        $display("[tb_deinterleave] %0s symbol %0d pair %0d bit %0s: %b, expected %b (subcarrier %0d bit %0d%0s)",
                                 rate_name(cur_r), cur_sym, out_n, half_name, got, expected,
                                 j / rate_nbpsc(cur_r), j % rate_nbpsc(cur_r),
                                 is_soft ? ", soft value" : "");
                    end
                end
                else if (is_soft) begin
                    cov_soft[j] = 1'b1;
                    stat_soft   = stat_soft + 1;
                end
                else if (expected[2]) begin
                    cov_one[j] = 1'b1;
                end
                else begin
                    cov_zero[j] = 1'b1;
                end
            end
            else begin
                stat_erased = stat_erased + 1;
            end
        end
    endtask

    always @(posedge clk) begin
        cycle = cycle + 1;

        if (in_strobe && enable && !rst) begin
            last_in_cycle = cycle;
            if (gap_armed) begin
                if (cycle - prev_out_cycle < gap_min_seen) begin
                    gap_min_seen = cycle - prev_out_cycle;
                end
                gap_armed = 1'b0;
            end
        end

        if (dut_output_strobe === 1'bx) begin
            count_error;
            if (print_it) begin
                $display("[tb_deinterleave] o_output_strobe unknown at clock %0d", cycle);
            end
        end
        else if (dut_output_strobe && !rst) begin
            if (!enable) begin
                count_error;
                if (print_it) begin
                    $display("[tb_deinterleave] %0s symbol %0d: pair while disabled at clock %0d",
                             rate_name(cur_r), cur_sym, cycle);
                end
            end
            else if (out_n >= exp_n) begin
                count_error;
                if (print_it) begin
                    $display("[tb_deinterleave] %0s symbol %0d: pair without a symbol at clock %0d",
                             rate_name(cur_r), cur_sym, cycle);
                end
            end
            else if (!inputs_done) begin
                count_error;
                if (print_it) begin
                    $display("[tb_deinterleave] %0s symbol %0d: pair before the last subcarrier at clock %0d",
                             rate_name(cur_r), cur_sym, cycle);
                end
            end
            else begin
                if (dut_erase !== exp_erase[out_n]) begin
                    count_error;
                    if (print_it) begin
                        $display("[tb_deinterleave] %0s symbol %0d pair %0d: erase %b, expected %b",
                                 rate_name(cur_r), cur_sym, out_n, dut_erase, exp_erase[out_n]);
                    end
                end
                check_half(pos_a[out_n], dut_out_bits[2:0], exp_bits[out_n][2:0], exp_soft[out_n][0], "A");
                check_half(pos_b[out_n], dut_out_bits[5:3], exp_bits[out_n][5:3], exp_soft[out_n][1], "B");

                if (out_n == 0) begin
                    if (cycle - last_in_cycle < lat_min) begin
                        lat_min = cycle - last_in_cycle;
                    end
                    if (cycle - last_in_cycle > lat_max) begin
                        lat_max = cycle - last_in_cycle;
                    end
                    if (cycle - last_in_cycle != EXP_LATENCY) begin
                        count_error;
                        if (print_it) begin
                            $display("[tb_deinterleave] %0s symbol %0d: first pair %0d clocks after the last subcarrier, expected %0d",
                                     rate_name(cur_r), cur_sym, cycle - last_in_cycle, EXP_LATENCY);
                        end
                    end
                end
                else if (cycle != prev_out_cycle + 1) begin
                    count_error;
                    if (print_it) begin
                        $display("[tb_deinterleave] %0s symbol %0d pair %0d: %0d clocks after the pair before, expected 1",
                                 rate_name(cur_r), cur_sym, out_n, cycle - prev_out_cycle);
                    end
                end
                prev_out_cycle = cycle;
                out_n          = out_n + 1;
                stat_pairs     = stat_pairs + 1;
                if (out_n == exp_n) begin
                    gap_armed = 1'b1;
                end
            end
        end

        // a reset or a disable drops the symbol in flight: no pair may follow
        if (rst || !enable) begin
            exp_n       = 0;
            out_n       = 0;
            inputs_done = 1'b0;
            gap_armed   = 1'b0;
        end

        if (cycle == WATCHDOG) begin
            $display("[tb_deinterleave] watchdog");
            $display("[tb_deinterleave] RESULT: FAIL (watchdog)");
            $finish;
        end
    end

    //---- Stimulus tasks (driven on the falling edge) -------------------------
    task idle;
        input integer n;
        begin
            repeat (n) begin
                @(negedge clk);
            end
        end
    endtask

    task input_noise;
        begin
            in_bits          = rnd(64);
            in_soft_bits     = rnd(64);
            in_soft_bits_pos = rnd(16);
        end
    endtask

    // reset for n clocks, with the rate of configuration r, as the receiver does
    task apply_reset;
        input integer r;
        input integer n;
        begin
            rst       = 1'b1;
            enable    = 1'b1;
            rate      = rate_code(r);
            in_strobe = 1'b0;
            idle(n);
            rst       = 1'b0;
        end
    endtask

    // clocks between two subcarriers
    function integer pace_gap;
        input integer pace;
        integer v;
        begin
            case (pace)
                0:       pace_gap = 0;                  // back to back
                1: begin                                // bursts as in the receiver
                    v = rnd(8);
                    pace_gap = (v < 5) ? 0 : (v == 5) ? 1 : (v == 6) ? 7 : 11;
                end
                default: pace_gap = rnd(16);
            endcase
        end
    endfunction

    // the first n subcarriers of a symbol (n = N_SD: all of them)
    task send_subcarriers;
        input integer r;
        input integer n;
        input integer pace;
        integer nsd;
        integer c;
        integer m;
        integer g;
        begin
            nsd = rate_nsd(r);
            for (c = 0; c < n; c = c + 1) begin
                m                = (c + nsd / 2) % nsd;
                in_strobe        = 1'b1;
                in_bits          = car_bits[m];
                in_soft_bits     = car_soft[m];
                in_soft_bits_pos = car_pos[m];
                if (c == nsd - 1) begin
                    inputs_done = 1'b1;
                end
                @(negedge clk);
                g = pace_gap(pace);
                if (g > 0 && c < n - 1) begin
                    in_strobe = 1'b0;
                    input_noise;
                    idle(g);
                end
            end
            in_strobe = 1'b0;
            input_noise;
        end
    endtask

    task wait_pairs;
        integer t;
        begin
            t = 0;
            while (out_n < exp_n && t < OUT_TIMEOUT) begin
                @(negedge clk);
                t = t + 1;
            end
            if (out_n < exp_n) begin
                count_error;
                if (print_it) begin
                    $display("[tb_deinterleave] %0s symbol %0d: %0d of %0d pairs after %0d clocks",
                             rate_name(cur_r), cur_sym, out_n, exp_n, OUT_TIMEOUT);
                end
                exp_n = 0;
                out_n = 0;
            end
        end
    endtask

    // announce a symbol to the scoreboard
    task expect_symbol;
        input integer r;
        input integer soft_mode;
        begin
            build_symbol(r, soft_mode);
            cur_r         = r;
            cur_soft      = soft_mode;
            cur_sym       = cur_sym + 1;
            soft_decoding = (soft_mode != 0);
            out_n         = 0;
            exp_n         = sym_pairs;
            inputs_done   = 1'b0;
            stat_symbols  = stat_symbols + 1;
        end
    endtask

    // one complete symbol and its pairs
    task run_symbol;
        input integer r;
        input integer soft_mode;
        input integer pace;
        begin
            expect_symbol(r, soft_mode);
            send_subcarriers(r, rate_nsd(r), pace);
            wait_pairs;
        end
    endtask

    //---- Report --------------------------------------------------------------
    integer     pass_lines;
    integer     fail_lines;

    task clear_stats;
        integer j;
        begin
            errors_line  = 0;
            stat_symbols = 0;
            stat_pairs   = 0;
            stat_erased  = 0;
            stat_soft    = 0;
            cur_sym      = 0;
            lat_min      = 1000000;
            lat_max      = 0;
            gap_min_seen = 1000000;
            for (j = 0; j < MAX_CBPS; j = j + 1) begin
                cov_zero[j] = 1'b0;
                cov_one[j]  = 1'b0;
                cov_soft[j] = 1'b0;
            end
        end
    endtask

    task report_line;
        input [8*1-1:0] test_name;
        input integer   r;
        input integer   soft_mode;          // 0 hard, 1 soft, 2 both
        input integer   need_cov;           // 1: the coverage has to be complete
        integer n_cbps;
        integer n_hard;
        integer n_soft;
        integer j;
        reg     ok;
        begin
            n_cbps = rate_nsd(r) * rate_nbpsc(r);
            n_hard = 0;
            n_soft = 0;
            for (j = 0; j < n_cbps; j = j + 1) begin
                if (cov_zero[j] && cov_one[j]) begin
                    n_hard = n_hard + 1;
                end
                if (cov_soft[j]) begin
                    n_soft = n_soft + 1;
                end
            end
            ok = (errors_line == 0) && (stat_symbols > 0) && (stat_pairs > 0);
            if (need_cov != 0) begin
                if (n_hard != n_cbps || (soft_mode != 0 && n_soft != n_cbps)) begin
                    ok = 1'b0;
                    errors_total = errors_total + 1;
                end
            end
            if (need_cov != 0) begin
                $display("[tb_deinterleave] %0s %0s N_BPSC=%0d R=%0s N_SD=%0d %0s symbols=%0d pairs=%0d erased=%0d soft_values=%0d latency=%0d..%0d min_gap=%0d cov=%0d/%0d soft_cov=%0d/%0d errors=%0d %0s",
                         test_name, rate_name(r), rate_nbpsc(r), coding_name(rate_coding(r)), rate_nsd(r),
                         (soft_mode == 0) ? "hard" : "soft", stat_symbols, stat_pairs, stat_erased, stat_soft,
                         lat_min, lat_max, gap_min_seen, n_hard, n_cbps, n_soft, n_cbps, errors_line,
                         ok ? "PASS" : "FAIL");
            end
            else begin
                $display("[tb_deinterleave] %0s %0s symbols=%0d pairs=%0d erased=%0d soft_values=%0d errors=%0d %0s",
                         test_name, rate_name(r), stat_symbols, stat_pairs, stat_erased, stat_soft, errors_line,
                         ok ? "PASS" : "FAIL");
            end
            if (ok) begin
                pass_lines = pass_lines + 1;
            end
            else begin
                fail_lines = fail_lines + 1;
            end
            total_symbols = total_symbols + stat_symbols;
            total_pairs   = total_pairs + stat_pairs;
            clear_stats;
        end
    endtask

    //---- Test sequence -------------------------------------------------------
    integer     r;
    integer     soft_mode;
    integer     pace;
    integer     n;
    integer     f;
    integer     num_sym;
    integer     num_frame;
    integer     num_reset;
    integer     n_data;
    integer     n_part;
    integer     n_wait;

    initial begin
        cycle         = 0;
        exp_n         = 0;
        out_n         = 0;
        inputs_done   = 1'b0;
        last_in_cycle = 0;
        prev_out_cycle = 0;
        gap_armed     = 1'b0;
        cur_r         = 0;
        cur_soft      = 0;
        errors_total  = 0;
        model_errors  = 0;
        total_symbols = 0;
        total_pairs   = 0;
        pass_lines    = 0;
        fail_lines    = 0;
        print_it      = 1'b0;
        clear_stats;

        seed = SEED_INIT;
        if ($value$plusargs("SEED=%d", seed)) begin
            $display("[tb_deinterleave] seed %0d", seed);
        end
        num_sym   = NUM_SYM;
        num_frame = NUM_FRAME;
        num_reset = NUM_RESET;
        if ($test$plusargs("QUICK")) begin
            num_sym   = NUM_SYM / QUICK_DIV;
            num_frame = NUM_FRAME / QUICK_DIV;
            num_reset = NUM_RESET / QUICK_DIV;
            $display("[tb_deinterleave] +QUICK: not a full run");
        end

        rst              = 1'b1;
        enable           = 1'b0;
        rate             = 8'd0;
        in_strobe        = 1'b0;
        in_bits          = 6'd0;
        in_soft_bits     = 6'd0;
        in_soft_bits_pos = 4'd0;
        soft_decoding    = 1'b0;
        idle(10);

        // A) every configuration, hard and soft, three subcarrier spacings
        for (soft_mode = 0; soft_mode < 2; soft_mode = soft_mode + 1) begin
            for (r = 0; r < NUM_RATE; r = r + 1) begin
                apply_reset(r, 2);
                for (pace = 0; pace < NUM_PACE; pace = pace + 1) begin
                    for (n = 0; n < num_sym; n = n + 1) begin
                        run_symbol(r, soft_mode, pace);
                        idle((n % 2 == 0) ? GAP_MIN : GAP_MIN + rnd(GAP_MAX - GAP_MIN + 1));
                    end
                end
                report_line("A", r, soft_mode, 1);
            end
        end

        // B) frames as the receiver decodes them
        for (r = 0; r < NUM_RATE; r = r + 1) begin
            for (f = 0; f < num_frame; f = f + 1) begin
                soft_mode = (f % 4 != 3) ? 1 : 0;
                apply_reset(0, 1);                      // SIGNAL: 6 Mbit/s
                idle(rnd(40));
                run_symbol(0, soft_mode, 1);
                idle(GAP_MIN + rnd(GAP_MAX));
                if (r >= 8) begin
                    apply_reset(0, 2);                  // HT-SIG: two symbols at 6 Mbit/s
                    idle(rnd(40));
                    run_symbol(0, soft_mode, 1);
                    idle(GAP_MIN + rnd(GAP_MAX));
                    run_symbol(0, soft_mode, 1);
                    idle(GAP_MIN + rnd(GAP_MAX));
                    apply_reset(r, 1 + rnd(500));       // HT-STF, HT-LTF
                end
                else begin
                    apply_reset(r, 1 + rnd(3));
                end
                idle(rnd(40));
                n_data = 1 + rnd(6);
                for (n = 0; n < n_data; n = n + 1) begin
                    run_symbol(r, soft_mode, 1);
                    idle(GAP_MIN + rnd(GAP_MAX));
                end
                enable = 1'b0;
                idle(20 + rnd(100));
                rst    = 1'b1;
                rate   = 8'd0;
                idle(10);
                rst    = 1'b0;
                idle(rnd(20));
            end
            report_line("B", r, 2, 0);
        end

        // C) reset while a symbol is coming in
        for (r = 0; r < NUM_RATE; r = r + 1) begin
            apply_reset(r, 2);
            for (n = 0; n < num_reset; n = n + 1) begin
                soft_mode = n % 2;
                n_part    = 1 + rnd(rate_nsd(r) - 1);
                build_symbol(r, soft_mode);
                send_subcarriers(r, n_part, n % NUM_PACE);
                idle(rnd(4));
                apply_reset(r, 1 + rnd(3));
                idle(rnd(4));
                run_symbol(r, soft_mode, n % NUM_PACE);
                idle(GAP_MIN + rnd(GAP_MAX));
            end
            report_line("C", r, 2, 0);
        end

        // D) reset while the pairs are going out
        for (r = 0; r < NUM_RATE; r = r + 1) begin
            apply_reset(r, 2);
            for (n = 0; n < num_reset; n = n + 1) begin
                soft_mode = n % 2;
                expect_symbol(r, soft_mode);
                send_subcarriers(r, rate_nsd(r), n % NUM_PACE);
                n_part = 1 + rnd(sym_pairs - 1);
                n_wait = 0;
                while (out_n < n_part && exp_n != 0 && n_wait < OUT_TIMEOUT) begin
                    @(negedge clk);
                    n_wait = n_wait + 1;
                end
                apply_reset(r, 1 + rnd(3));
                idle(rnd(6));
                run_symbol(r, soft_mode, n % NUM_PACE);
                idle(GAP_MIN + rnd(GAP_MAX));
            end
            report_line("D", r, 2, 0);
        end

        // E) enable low between frames, strobes on the input meanwhile
        for (r = 0; r < NUM_RATE; r = r + 1) begin
            apply_reset(r, 2);
            for (n = 0; n < num_reset; n = n + 1) begin
                soft_mode = n % 2;
                run_symbol(r, soft_mode, n % NUM_PACE);
                idle(GAP_MIN + rnd(GAP_MAX));
                enable = 1'b0;
                n_part = rnd(2 * rate_nsd(r));
                repeat (n_part) begin
                    in_strobe = rnd(2);
                    input_noise;
                    @(negedge clk);
                end
                in_strobe = 1'b0;
                idle(rnd(10));
                apply_reset(r, 1 + rnd(3));
                idle(rnd(6));
            end
            run_symbol(r, 1, 0);
            idle(GAP_MIN);
            report_line("E", r, 2, 0);
        end

        // F) enable low while the pairs are going out
        for (r = 0; r < NUM_RATE; r = r + 1) begin
            apply_reset(r, 2);
            for (n = 0; n < num_reset; n = n + 1) begin
                soft_mode = n % 2;
                expect_symbol(r, soft_mode);
                send_subcarriers(r, rate_nsd(r), n % NUM_PACE);
                n_part = 1 + rnd(sym_pairs - 1);
                n_wait = 0;
                while (out_n < n_part && exp_n != 0 && n_wait < OUT_TIMEOUT) begin
                    @(negedge clk);
                    n_wait = n_wait + 1;
                end
                enable = 1'b0;
                idle(1 + rnd(40));
                apply_reset(r, 1 + rnd(10));
                idle(rnd(6));
                run_symbol(r, soft_mode, n % NUM_PACE);
                idle(GAP_MIN + rnd(GAP_MAX));
            end
            report_line("F", r, 2, 0);
        end

        idle(50);
        if (model_errors != 0) begin
            $display("[tb_deinterleave] reference model: %0d inconsistencies", model_errors);
        end
        if (errors_total == 0 && model_errors == 0 && fail_lines == 0 && pass_lines > 0) begin
            $display("[tb_deinterleave] RESULT: PASS (%0d symbols, %0d pairs, %0d report lines)",
                     total_symbols, total_pairs, pass_lines);
        end
        else begin
            $display("[tb_deinterleave] RESULT: FAIL (%0d errors, %0d of %0d report lines failed)",
                     errors_total + model_errors, fail_lines, pass_lines + fail_lines);
        end
        $finish;
    end

endmodule

`default_nettype wire
