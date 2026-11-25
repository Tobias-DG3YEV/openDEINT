`timescale 1ns / 1ps
`default_nettype none

//----------------------------------------------------------------------------
// Module : tb_deinterleave_compare
// Purpose: Self-checking XSim bench that runs the deinterleaver (rtl/) and
// openofdm's former deinterleaver (ref_deinterleave_legacy) side by side on
// the same inputs and compares all outputs in every clock.
//
// tb_deinterleave shows that the core does what IEEE 802.11 asks for, and
// tb_deinterleave_replay that it equals the old block on recorded frames.
// This bench closes the gap between the two: equality on inputs no
// recording holds, also where the standard says nothing (the value of an
// erased bit, the outputs without strobe, what happens when the block is
// disabled or reset at any moment).
//
// Stimulus, three parts:
//   frames  symbols as in the receiver: reset with a new rate (all 16 in
//           turn), N_SD subcarriers with random gaps, a pause for the pairs;
//           now and then a reset while a symbol comes in, or enable low or a
//           reset while the pairs go out
//   random  every input at random in every clock: strobes in bursts of
//           changing density, also while pairs go out, enable low for a few
//           clocks, resets at any time; the rate changes with a reset only
//   rate    the same, and the rate and i_soft_decoding change at any time
//           (the receiver does not do that)
// In all three a reset follows before the block is enabled again, as in the
// receiver. Without it neither block carries on properly: pairs are lost
// while disabled, and the old block, disabled in the very clock in which it
// reads the end of its list, runs on into the list of the next rate.
//
// Check: {o_output_strobe, o_erase, o_out_bits} of the two blocks equal in
// every clock after the first reset. A part also fails if it produced no
// pairs.
//
// Report (machine-greppable):
//   [tb_deinterleave_compare] <part> clocks=<n> subcarriers=<n> pairs=<n>
//     resets=<n> disables=<n> mismatches=<n> PASS|FAIL
//   [tb_deinterleave_compare] RESULT: PASS   or   RESULT: FAIL
//
// Plusargs: +QUICK a tenth of the clocks (debug aid, not a full run),
//           +SEED=<n> another random sequence.
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
module tb_deinterleave_compare;

    //---- Bench constants -----------------------------------------------------
    localparam integer PERIOD      = 10;        // ns
    localparam integer NUM_RATE    = 16;
    localparam integer NUM_SYMBOLS = 20000;     // frames: symbols
    localparam integer NUM_CLOCKS  = 4000000;   // random, rate: clocks each
    localparam integer QUICK_DIV   = 10;
    localparam integer MAX_PRINT   = 10;        // mismatches printed per part
    localparam integer SEED_INIT   = 20261119;

    //---- Ports of both blocks ------------------------------------------------
    reg         clk;
    reg         rst;
    reg         enable;
    reg  [7:0]  rate;
    reg  [5:0]  in_bits;
    reg  [5:0]  in_soft_bits;
    reg  [3:0]  in_soft_bits_pos;
    reg         in_strobe;
    reg         soft_decoding;
    wire [5:0]  new_out_bits;
    wire [1:0]  new_erase;
    wire        new_output_strobe;
    wire [5:0]  old_out_bits;
    wire [1:0]  old_erase;
    wire        old_output_strobe;
    wire [8:0]  new_word = {new_output_strobe, new_erase, new_out_bits};
    wire [8:0]  old_word = {old_output_strobe, old_erase, old_out_bits};

    deinterleaver u_new (
        .i_clk              (clk),
        .i_rst              (rst),
        .i_enable           (enable),
        .i_rate             (rate),
        .i_in_bits          (in_bits),
        .i_soft_in_bits     (in_soft_bits),
        .i_soft_in_bits_pos (in_soft_bits_pos),
        .i_input_strobe     (in_strobe),
        .i_soft_decoding    (soft_decoding),
        .o_out_bits         (new_out_bits),
        .o_erase            (new_erase),
        .o_output_strobe    (new_output_strobe)
    );

    ref_deinterleave_legacy u_old (
        .i_clk              (clk),
        .i_rst              (rst),
        .i_enable           (enable),
        .i_rate             (rate),
        .i_in_bits          (in_bits),
        .i_soft_in_bits     (in_soft_bits),
        .i_soft_in_bits_pos (in_soft_bits_pos),
        .i_input_strobe     (in_strobe),
        .i_soft_decoding    (soft_decoding),
        .o_out_bits         (old_out_bits),
        .o_erase            (old_erase),
        .o_output_strobe    (old_output_strobe)
    );

    //---- Clock ---------------------------------------------------------------
    initial begin
        clk = 1'b0;
    end

    always begin
        #(PERIOD / 2) clk = ~clk;
    end

    //---- Rate table ----------------------------------------------------------
    // i_rate of configuration r: 0..7 = 6 .. 54 Mbit/s, 8..15 = MCS 0..7
    function [7:0] rate_code;
        input integer r;
        begin
            case (r)
                0:       rate_code = 8'h0B;
                1:       rate_code = 8'h0F;
                2:       rate_code = 8'h0A;
                3:       rate_code = 8'h0E;
                4:       rate_code = 8'h09;
                5:       rate_code = 8'h0D;
                6:       rate_code = 8'h08;
                7:       rate_code = 8'h0C;
                default: rate_code = 8'h80 + (r - 8);
            endcase
        end
    endfunction

    // pairs per symbol
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

    //---- Random numbers ------------------------------------------------------
    integer seed;

    // 0 .. n - 1
    function integer rnd;
        input integer n;
        begin
            rnd = {$random(seed)} % n;
        end
    endfunction

    //---- Compare -------------------------------------------------------------
    reg         armed;                      // first reset done
    reg         prev_rst;
    reg         prev_enable;
    integer     cycle;
    integer     n_clocks;
    integer     n_subcarriers;
    integer     n_pairs;
    integer     n_resets;
    integer     n_disables;
    integer     n_mismatch;
    integer     errors_total;
    integer     parts_passed;
    integer     parts_failed;

    always @(posedge clk) begin
        cycle = cycle + 1;
        if (armed) begin
            n_clocks = n_clocks + 1;
            if (new_word !== old_word) begin
                n_mismatch = n_mismatch + 1;
                if (n_mismatch <= MAX_PRINT) begin
                    $display("[tb_deinterleave_compare] clock %0d: strobe/erase/bits %b/%b/%b, old block %b/%b/%b (rate %h, reset %b, enable %b)",
                             cycle, new_word[8], new_word[7:6], new_word[5:0],
                             old_word[8], old_word[7:6], old_word[5:0], rate, rst, enable);
                end
            end
            if (old_output_strobe === 1'b1) begin
                n_pairs = n_pairs + 1;
            end
            if (in_strobe) begin
                n_subcarriers = n_subcarriers + 1;
            end
            if (rst && !prev_rst) begin
                n_resets = n_resets + 1;
            end
            if (!enable && prev_enable) begin
                n_disables = n_disables + 1;
            end
        end
        prev_rst    = rst;
        prev_enable = enable;
    end

    task report_part;
        input [8*6-1:0] part_name;
        reg ok;
        begin
            ok = (n_mismatch == 0) && (n_pairs > 0);
            $display("[tb_deinterleave_compare] %0s clocks=%0d subcarriers=%0d pairs=%0d resets=%0d disables=%0d mismatches=%0d %0s",
                     part_name, n_clocks, n_subcarriers, n_pairs, n_resets, n_disables, n_mismatch,
                     ok ? "PASS" : "FAIL");
            if (ok) begin
                parts_passed = parts_passed + 1;
            end
            else begin
                parts_failed = parts_failed + 1;
            end
            errors_total  = errors_total + n_mismatch;
            n_clocks      = 0;
            n_subcarriers = 0;
            n_pairs       = 0;
            n_resets      = 0;
            n_disables    = 0;
            n_mismatch    = 0;
        end
    endtask

    //---- Stimulus (driven on the falling edge) -------------------------------
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

    task apply_reset;
        input integer r;
        input integer n;
        begin
            rst           = 1'b1;
            enable        = 1'b1;
            rate          = rate_code(r);
            soft_decoding = rnd(4) != 0;
            in_strobe     = 1'b0;
            idle(n);
            rst           = 1'b0;
        end
    endtask

    // n subcarriers with random gaps
    task send_subcarriers;
        input integer n;
        integer c;
        integer g;
        begin
            for (c = 0; c < n; c = c + 1) begin
                in_strobe = 1'b1;
                input_noise;
                @(negedge clk);
                g = (rnd(4) == 0) ? rnd(12) : 0;
                if (g > 0) begin
                    in_strobe = 1'b0;
                    input_noise;
                    idle(g);
                end
            end
            in_strobe = 1'b0;
        end
    endtask

    // symbols as in the receiver
    task part_frames;
        input integer n_symbols;
        integer n;
        integer r;
        integer nsd;
        integer left;                       // symbols until the next rate
        integer what;
        begin
            r    = 0;
            left = 0;
            for (n = 0; n < n_symbols; n = n + 1) begin
                if (left == 0) begin
                    r    = (r + 1) % NUM_RATE;
                    left = 1 + rnd(8);
                    apply_reset(r, 1 + rnd(10));
                    idle(rnd(20));
                end
                left = left - 1;
                nsd  = (r >= 8) ? 52 : 48;
                what = rnd(20);
                if (what == 0) begin
                    // reset while the symbol comes in
                    send_subcarriers(1 + rnd(nsd - 1));
                    apply_reset(r, 1 + rnd(3));
                    idle(rnd(6));
                end
                else begin
                    send_subcarriers(nsd);
                    if (what == 1) begin
                        // enable low while the pairs go out, then reset
                        idle(rnd(rate_ndbps(r) + 8));
                        enable = 1'b0;
                        idle(1 + rnd(40));
                        apply_reset(r, 1 + rnd(10));
                        idle(rnd(6));
                    end
                    else if (what == 2) begin
                        // reset while the pairs go out
                        idle(rnd(rate_ndbps(r) + 8));
                        apply_reset(r, 1 + rnd(3));
                        idle(rnd(6));
                    end
                    else begin
                        idle(rate_ndbps(r) + 8 + rnd(40));
                    end
                end
            end
            idle(300);
        end
    endtask

    // every input at random
    task part_random;
        input integer n_clocks_run;
        input integer rate_any_time;
        integer n;
        integer density;                    // strobes per 64 clocks
        integer rst_left;
        integer dis_left;
        begin
            density  = 64;
            rst_left = 0;
            dis_left = 0;
            for (n = 0; n < n_clocks_run; n = n + 1) begin
                @(negedge clk);
                if (rnd(200) == 0) begin
                    case (rnd(5))
                        0:       density = 64;
                        1:       density = 48;
                        2:       density = 16;
                        3:       density = 2;
                        default: density = 60;
                    endcase
                end
                in_strobe = (rnd(64) < density);
                input_noise;

                if (rst_left > 0) begin
                    rst_left = rst_left - 1;
                end
                else if (rnd(1500) == 0) begin
                    rst_left      = 1 + rnd(4);
                    rate          = rate_code(rnd(NUM_RATE));
                    soft_decoding = rnd(4) != 0;
                    if (rnd(2) == 0) begin
                        dis_left = 0;
                    end
                end
                rst = (rst_left > 0);

                if (dis_left > 0) begin
                    dis_left = dis_left - 1;
                    if (dis_left == 0) begin
                        // enabled again: with a reset
                        rst_left      = 1 + rnd(4);
                        rate          = rate_code(rnd(NUM_RATE));
                        soft_decoding = rnd(4) != 0;
                        rst           = 1'b1;
                    end
                end
                else if (rnd(700) == 0) begin
                    dis_left = 1 + rnd(30);
                end
                enable = (dis_left == 0);

                if (rate_any_time != 0) begin
                    if (rnd(900) == 0) begin
                        rate = rate_code(rnd(NUM_RATE));
                    end
                    if (rnd(900) == 0) begin
                        soft_decoding = ~soft_decoding;
                    end
                end
            end
            in_strobe = 1'b0;
            rst       = 1'b0;
            enable    = 1'b1;
            idle(300);
        end
    endtask

    //---- Test sequence -------------------------------------------------------
    integer num_symbols;
    integer num_clocks;

    initial begin
        cycle         = 0;
        armed         = 1'b0;
        prev_rst      = 1'b0;
        prev_enable   = 1'b0;
        n_clocks      = 0;
        n_subcarriers = 0;
        n_pairs       = 0;
        n_resets      = 0;
        n_disables    = 0;
        n_mismatch    = 0;
        errors_total  = 0;
        parts_passed  = 0;
        parts_failed  = 0;

        seed = SEED_INIT;
        if ($value$plusargs("SEED=%d", seed)) begin
            $display("[tb_deinterleave_compare] seed %0d", seed);
        end
        num_symbols = NUM_SYMBOLS;
        num_clocks  = NUM_CLOCKS;
        if ($test$plusargs("QUICK")) begin
            num_symbols = NUM_SYMBOLS / QUICK_DIV;
            num_clocks  = NUM_CLOCKS / QUICK_DIV;
            $display("[tb_deinterleave_compare] +QUICK: not a full run");
        end

        rst              = 1'b1;
        enable           = 1'b0;
        rate             = rate_code(0);
        in_strobe        = 1'b0;
        in_bits          = 6'd0;
        in_soft_bits     = 6'd0;
        in_soft_bits_pos = 4'd0;
        soft_decoding    = 1'b1;
        idle(6);
        armed = 1'b1;
        idle(4);
        rst   = 1'b0;

        part_frames(num_symbols);
        report_part("frames");

        apply_reset(0, 4);
        part_random(num_clocks, 0);
        report_part("random");

        apply_reset(0, 4);
        part_random(num_clocks, 1);
        report_part("rate");

        if (errors_total == 0 && parts_failed == 0 && parts_passed == 3) begin
            $display("[tb_deinterleave_compare] RESULT: PASS");
        end
        else begin
            $display("[tb_deinterleave_compare] RESULT: FAIL (%0d mismatches, %0d of 3 parts failed)",
                     errors_total, parts_failed);
        end
        $finish;
    end

endmodule

`default_nettype wire
