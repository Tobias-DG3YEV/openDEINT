`timescale 1ns / 1ps
`default_nettype none

//----------------------------------------------------------------------------
// Module : deinterleave_tap
// Purpose: Records the ports of the deinterleaver inside the openofdm
// receiver while openofdm's bench dot11_tb decodes a reference vector.
//
// Not a bench of its own: it is elaborated as a second top module next to
// dot11_tb (tools/capture_traces.sh) and reads the ports through the
// hierarchy, so openofdm is not changed. It writes one line for every
// clock in which a port differs from the clock before, sampled on the
// falling edge:
//
//   <clock> <inputs, 7 hex digits> <outputs, 3 hex digits>
//   inputs  = {reset, enable, soft_decoding, input_strobe, rate[7:0],
//              in_bits[5:0], soft_in_bits[5:0], soft_in_bits_pos[3:0]}
//   outputs = {output_strobe, erase[1:0], out_bits[5:0]}
//
// tb_deinterleave_replay reads this format. The recording starts with the
// first clock in which every input is known and ends with the simulation,
// or with +TAP_FRAMES=<n> before the receiver enables the decoder for the
// (n + 1)-th time (one enable per frame it found a SIGNAL symbol for).
//
// Plusargs: +TAP_FILE=<file> (default deinterleave_trace.txt),
//           +TAP_FRAMES=<n> (default 0 = all).
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
`define DEINTERLEAVE_TAP_DUT dot11_tb.dot11_inst.ofdm_decoder_inst.deinterleave_inst

module deinterleave_tap;

    reg  [8*512-1:0] file_name;
    integer          fd;
    integer          clock_idx;
    integer          max_frames;
    integer          frames;
    reg              started;
    reg              stopped;
    reg              prev_enable;
    reg  [27:0]      in_now;
    reg  [27:0]      in_last;
    reg  [8:0]       out_now;
    reg  [8:0]       out_last;

    initial begin
        if (!$value$plusargs("TAP_FILE=%s", file_name)) begin
            file_name = "deinterleave_trace.txt";
        end
        if (!$value$plusargs("TAP_FRAMES=%d", max_frames)) begin
            max_frames = 0;
        end
        fd          = $fopen(file_name, "w");
        clock_idx   = 0;
        frames      = 0;
        started     = 1'b0;
        stopped     = 1'b0;
        prev_enable = 1'b0;
        in_last     = 28'd0;
        out_last    = 9'd0;
    end

    always @(negedge `DEINTERLEAVE_TAP_DUT.i_clock) begin
        in_now  = {`DEINTERLEAVE_TAP_DUT.i_reset,
                   `DEINTERLEAVE_TAP_DUT.i_enable,
                   `DEINTERLEAVE_TAP_DUT.i_soft_decoding,
                   `DEINTERLEAVE_TAP_DUT.i_input_strobe,
                   `DEINTERLEAVE_TAP_DUT.i_rate,
                   `DEINTERLEAVE_TAP_DUT.i_in_bits,
                   `DEINTERLEAVE_TAP_DUT.i_soft_in_bits,
                   `DEINTERLEAVE_TAP_DUT.i_soft_in_bits_pos};
        out_now = {`DEINTERLEAVE_TAP_DUT.o_output_strobe,
                   `DEINTERLEAVE_TAP_DUT.o_erase,
                   `DEINTERLEAVE_TAP_DUT.o_out_bits};

        if (!stopped && (^in_now) !== 1'bx) begin
            if (in_now[26] && !prev_enable) begin
                frames = frames + 1;
                if (max_frames > 0 && frames > max_frames) begin
                    stopped = 1'b1;
                    $fclose(fd);
                    $display("deinterleave_tap: %0d frames recorded, finishing.", max_frames);
                    $finish;
                end
            end
            prev_enable = in_now[26];
            if (!stopped && (!started || in_now !== in_last || out_now !== out_last)) begin
                $fwrite(fd, "%0d %h %h\n", clock_idx, in_now, out_now);
                started  = 1'b1;
                in_last  = in_now;
                out_last = out_now;
            end
        end
        clock_idx = clock_idx + 1;
    end

endmodule

`undef DEINTERLEAVE_TAP_DUT
`default_nettype wire
