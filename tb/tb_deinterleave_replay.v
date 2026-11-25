`timescale 1ns / 1ps
`default_nettype none

//----------------------------------------------------------------------------
// Module : tb_deinterleave_replay
// Purpose: Self-checking XSim bench that replays a recording of the
// deinterleaver's ports inside the openofdm receiver, clock for clock.
//
// The recordings in tb/vectors/receiver/ were taken with deinterleave_tap.v
// from openofdm's deinterleaver while the receiver decoded its reference
// vectors (tools/capture_traces.sh). A recording holds one line for every
// clock in which a port differs from the clock before:
//
//   <clock> <inputs, 7 hex digits> <outputs, 3 hex digits>
//   inputs  = {reset, enable, soft_decoding, input_strobe, rate[7:0],
//              in_bits[5:0], soft_in_bits[5:0], soft_in_bits_pos[3:0]}
//   outputs = {output_strobe, erase[1:0], out_bits[5:0]}
//
// The bench drives the recorded inputs on the falling clock edge and
// compares the outputs a quarter period later, in every clock without
// reset:
//   - o_output_strobe must equal the recording,
//   - o_out_bits and o_erase must equal the recording while the strobe is
//     high (the receiver reads them only then),
//   - with +STRICT all three in every clock, strobe low and reset included.
// While the reset is high the decoder behind the deinterleaver is in reset
// too and does not look at the outputs. (openofdm's block gives one stray
// strobe in the first reset clock after it was disabled in mid-output; the
// recording 'mixed' holds one.)
// That is the test for a drop-in replacement: same pairs, same erasures,
// same clock, for real frames with their resets and rate changes.
//
// The recording has to start in reset (the receiver's does); the bench
// holds its first line for PRE_ROLL clocks before it starts to compare.
//
// DUT: deinterleaver (rtl/), with `define DUT_LEGACY ref_deinterleave_legacy,
// with `define DUT_OPENOFDM the deinterleave of an openofdm checkout
// (tools/run_tb.sh, DUT=open | legacy | openofdm).
//
// Report (machine-greppable):
//   [tb_deinterleave_replay] <file> clocks=<n> frames=<n> resets=<n>
//     subcarriers=<n> pairs=<n> erased=<n> mismatches=<n> PASS|FAIL
//   [tb_deinterleave_replay] RESULT: PASS   or   RESULT: FAIL
//
// Plusargs: +TRACE=<file> the recording (required), +STRICT see above.
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
module tb_deinterleave_replay;

    //---- Bench constants -----------------------------------------------------
    localparam integer PERIOD    = 10;      // ns
    localparam integer PRE_ROLL  = 4;       // clocks in reset before the first compare
    localparam integer POST_ROLL = 32;      // clocks after the last line
    localparam integer MAX_PRINT = 10;      // mismatches printed

    //---- DUT ports -----------------------------------------------------------
    reg         clk;
    reg  [27:0] in_word;                    // layout as in the recording
    wire [5:0]  dut_out_bits;
    wire [1:0]  dut_erase;
    wire        dut_output_strobe;
    wire [8:0]  out_word = {dut_output_strobe, dut_erase, dut_out_bits};

    wire        in_rst           = in_word[27];
    wire        in_enable        = in_word[26];
    wire        in_soft_decoding = in_word[25];
    wire        in_strobe        = in_word[24];
    wire [7:0]  in_rate          = in_word[23:16];
    wire [5:0]  in_bits          = in_word[15:10];
    wire [5:0]  in_soft_bits     = in_word[9:4];
    wire [3:0]  in_soft_bits_pos = in_word[3:0];

`ifdef DUT_OPENOFDM
    deinterleave u_dut (
        .i_clock            (clk),
        .i_reset            (in_rst),
        .i_enable           (in_enable),
        .i_rate             (in_rate),
        .i_in_bits          (in_bits),
        .i_soft_in_bits     (in_soft_bits),
        .i_soft_in_bits_pos (in_soft_bits_pos),
        .i_input_strobe     (in_strobe),
        .i_soft_decoding    (in_soft_decoding),
        .o_out_bits         (dut_out_bits),
        .o_erase            (dut_erase),
        .o_output_strobe    (dut_output_strobe)
    );
`elsif DUT_LEGACY
    ref_deinterleave_legacy u_dut (
        .i_clk              (clk),
        .i_rst              (in_rst),
        .i_enable           (in_enable),
        .i_rate             (in_rate),
        .i_in_bits          (in_bits),
        .i_soft_in_bits     (in_soft_bits),
        .i_soft_in_bits_pos (in_soft_bits_pos),
        .i_input_strobe     (in_strobe),
        .i_soft_decoding    (in_soft_decoding),
        .o_out_bits         (dut_out_bits),
        .o_erase            (dut_erase),
        .o_output_strobe    (dut_output_strobe)
    );
`else
    deinterleaver u_dut (
        .i_clk              (clk),
        .i_rst              (in_rst),
        .i_enable           (in_enable),
        .i_rate             (in_rate),
        .i_in_bits          (in_bits),
        .i_soft_in_bits     (in_soft_bits),
        .i_soft_in_bits_pos (in_soft_bits_pos),
        .i_input_strobe     (in_strobe),
        .i_soft_decoding    (in_soft_decoding),
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

    //---- Recording -----------------------------------------------------------
    reg  [8*512-1:0] trace_name;
    integer          fd;
    integer          scan_count;
    integer          line_clock;            // clock of the line read ahead
    reg  [27:0]      line_in;
    reg  [8:0]       line_out;
    reg              line_valid;

    task read_line;
        begin
            scan_count = $fscanf(fd, "%d %h %h", line_clock, line_in, line_out);
            line_valid = (scan_count == 3);
        end
    endtask

    //---- Replay and compare --------------------------------------------------
    integer     clock_idx;                  // clock of the recording being replayed
    integer     idle_clocks;
    integer     n_clocks;
    integer     n_frames;
    integer     n_resets;
    integer     n_subcarriers;
    integer     n_pairs;
    integer     n_erased;
    integer     n_mismatch;
    reg  [8:0]  exp_word;
    reg         strict;
    reg         prev_rst;
    reg         prev_enable;
    reg         mismatch;

    initial begin
        n_clocks      = 0;
        n_frames      = 0;
        n_resets      = 0;
        n_subcarriers = 0;
        n_pairs       = 0;
        n_erased      = 0;
        n_mismatch    = 0;
        idle_clocks   = 0;
        prev_rst      = 1'b0;
        prev_enable   = 1'b0;
        strict        = $test$plusargs("STRICT");

        if (!$value$plusargs("TRACE=%s", trace_name)) begin
            $display("[tb_deinterleave_replay] no recording given (+TRACE=<file>)");
            $display("[tb_deinterleave_replay] RESULT: FAIL");
            $finish;
        end
        fd = $fopen(trace_name, "r");
        if (fd == 0) begin
            $display("[tb_deinterleave_replay] cannot open %0s", trace_name);
            $display("[tb_deinterleave_replay] RESULT: FAIL");
            $finish;
        end
        read_line;
        if (!line_valid || line_in[27] !== 1'b1) begin
            $display("[tb_deinterleave_replay] %0s does not start in reset", trace_name);
            $display("[tb_deinterleave_replay] RESULT: FAIL");
            $finish;
        end

        // The first line, held for PRE_ROLL clocks: the receiver had been in
        // reset for longer than that when the recording started.
        in_word   = line_in;
        exp_word  = line_out;
        clock_idx = line_clock;
        repeat (PRE_ROLL) begin
            @(negedge clk);
        end
        read_line;

        while (idle_clocks < POST_ROLL) begin
            @(negedge clk);
            clock_idx = clock_idx + 1;
            if (line_valid && line_clock == clock_idx) begin
                in_word  = line_in;
                exp_word = line_out;
                read_line;
            end
            else if (line_valid && line_clock < clock_idx) begin
                $display("[tb_deinterleave_replay] %0s: clock %0d out of order", trace_name, line_clock);
                n_mismatch = n_mismatch + 1;
                read_line;
            end
            if (!line_valid) begin
                idle_clocks = idle_clocks + 1;
            end

            #(PERIOD / 4);
            mismatch = 1'b0;
            if (strict) begin
                mismatch = (out_word !== exp_word);
            end
            else if (!in_rst) begin
                if (out_word[8] !== exp_word[8]) begin
                    mismatch = 1'b1;
                end
                else if (exp_word[8] && out_word !== exp_word) begin
                    mismatch = 1'b1;
                end
            end
            if (mismatch) begin
                n_mismatch = n_mismatch + 1;
                if (n_mismatch <= MAX_PRINT) begin
                    $display("[tb_deinterleave_replay] clock %0d: strobe/erase/bits %b/%b/%b, recorded %b/%b/%b (inputs %h)",
                             clock_idx, out_word[8], out_word[7:6], out_word[5:0],
                             exp_word[8], exp_word[7:6], exp_word[5:0], in_word);
                end
            end

            n_clocks = n_clocks + 1;
            if (in_rst && !prev_rst) begin
                n_resets = n_resets + 1;
            end
            if (in_enable && !prev_enable) begin
                n_frames = n_frames + 1;
            end
            if (in_strobe) begin
                n_subcarriers = n_subcarriers + 1;
            end
            if (exp_word[8] && !in_rst) begin
                n_pairs  = n_pairs + 1;
                n_erased = n_erased + exp_word[7] + exp_word[6];
            end
            prev_rst    = in_rst;
            prev_enable = in_enable;
        end

        $fclose(fd);
        if (n_pairs == 0) begin
            $display("[tb_deinterleave_replay] %0s holds no output", trace_name);
            n_mismatch = n_mismatch + 1;
        end
        $display("[tb_deinterleave_replay] %0s clocks=%0d frames=%0d resets=%0d subcarriers=%0d pairs=%0d erased=%0d mismatches=%0d %0s",
                 trace_name, n_clocks, n_frames, n_resets, n_subcarriers, n_pairs, n_erased,
                 n_mismatch, (n_mismatch == 0) ? "PASS" : "FAIL");
        if (n_mismatch == 0) begin
            $display("[tb_deinterleave_replay] RESULT: PASS");
        end
        else begin
            $display("[tb_deinterleave_replay] RESULT: FAIL");
        end
        $finish;
    end

endmodule

`default_nettype wire
