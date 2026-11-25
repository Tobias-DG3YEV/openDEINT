//----------------------------------------------------------------------------
// Module : deinterleaver
// Purpose: Deinterleaver and depuncturer of an IEEE 802.11a/g/n OFDM
// receiver (20 MHz, one spatial stream), without a table. Open replacement
// for the deinterleaver of openofdm, which read the order of the coded bits
// from a 4096 x 22 bit ROM: here three small counters follow the
// interleaver of the standard.
//
// One OFDM symbol: N_SD = 48 (802.11a/g) or 52 (802.11n, i_rate[7] = 1)
// demodulated subcarriers arrive with i_input_strobe in the order of the
// FFT, data subcarrier N_SD / 2 first, wrapping from N_SD - 1 to 0, and are
// stored. With the last one the core hands out the N_DBPS pairs (A, B) of
// the rate 1/2 mother code in the order the convolutional coder produced
// them, one pair per clock, the first one 6 clocks after the last
// subcarrier. A bit is a 3 bit soft value (3'b111 strongest one, 3'b011
// strongest zero); where the transmitter punctured a bit, o_erase is set
// and the value has no meaning.
//
// Where coded bit k of a symbol is found (802.11-2012 18.3.5.7, 802.11n:
// 20.3.11.8.3, N_COL = 16 or 13, N_ROW = N_CBPS / N_COL, s = max(N_BPSC / 2, 1)):
//
//   i = N_ROW (k mod N_COL) + floor(k / N_COL)
//   j = s floor(i / s) + (i + N_CBPS - floor(N_COL i / N_CBPS)) mod s
//
// With col = k mod N_COL and row = floor(k / N_COL) = hi N_BPSC + g s + r
// (hi < N_ROW / N_BPSC, g < 2, r < s) this is
//
//   subcarrier = (N_ROW / N_BPSC) col + hi          (3 col + hi or 4 col + hi)
//   bit        = g s + (r - col) mod s
//
// so col, (r, g, hi) and col mod 3 are counted along with k and no
// multiplier, divider or table is needed. A pair is two consecutive coded
// bits k and k + 1; after it k moves on by 2, by 1 or not at all, as the
// puncturing pattern of the rate says (18.3.5.6, rate 5/6: 20.3.11.6):
//
//   1/2: A0 B0                 3/4: A0 B0 A1 -- -- B2
//   2/3: A0 B0 A1 --           5/6: A0 B0 A1 -- -- B2 A3 -- -- B4
//
// Soft decoding (i_soft_decoding = 1): the demodulator delivers one soft
// value per axis and subcarrier (i_soft_in_bits[2:0] in-phase, [5:3]
// quadrature) and the bit of that axis it belongs to
// (i_soft_in_bits_pos[1:0] / [3:2], 3 = none). That bit is handed out with
// the soft value, every other bit with its hard value.
//
// Drop-in for openofdm: every output equals the old block's in every clock
// (tb_deinterleave_replay +STRICT, tb_deinterleave_compare). For that the
// sequence of the old block is kept, two idle clocks before the first pair
// and one entry without strobe after the last pair included.
//
// i_rst: synchronous, active high; has to come with every change of
// i_rate. i_enable low: no output, no progress. Rates other than the 16 of
// the list below are not decoded by the receiver; the core treats them as
// BPSK, rate 1/2.
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
`timescale 1ns / 1ps
`default_nettype none

module deinterleaver (
    input  wire       i_clk,
    input  wire       i_rst,
    input  wire       i_enable,
    input  wire [7:0] i_rate,               // [7] 802.11n, [3:0] RATE field or MCS
    input  wire [5:0] i_in_bits,            // demodulated bits of one subcarrier
    input  wire [5:0] i_soft_in_bits,       // soft values, [2:0] I, [5:3] Q
    input  wire [3:0] i_soft_in_bits_pos,   // bit the soft values belong to
    input  wire       i_input_strobe,
    input  wire       i_soft_decoding,
    output reg  [5:0] o_out_bits,           // [2:0] bit A, [5:3] bit B
    output wire [1:0] o_erase,              // [0] A erased, [1] B erased
    output wire       o_output_strobe
);

    localparam [1:0] ST_INPUT  = 2'd0;      // subcarriers come in
    localparam [1:0] ST_START  = 2'd1;      // two clocks before the first entry
    localparam [1:0] ST_OUTPUT = 2'd2;      // pairs go out

    localparam [1:0] MOD_BPSK  = 2'd0;      // = N_BPSC / 2
    localparam [1:0] MOD_QPSK  = 2'd1;
    localparam [1:0] MOD_QAM16 = 2'd2;
    localparam [1:0] MOD_QAM64 = 2'd3;

    localparam [1:0] COD_1_2   = 2'd0;
    localparam [1:0] COD_2_3   = 2'd1;
    localparam [1:0] COD_3_4   = 2'd2;
    localparam [1:0] COD_5_6   = 2'd3;

    // Entry: what one clock of the output phase hands out
    localparam integer E_ERASE_A = 21;      // bit A was punctured
    localparam integer E_ERASE_B = 20;      // bit B was punctured
    localparam integer E_ADDR_A  = 14;      // [19:14] subcarrier of bit A
    localparam integer E_ADDR_B  = 8;       // [13:8]  subcarrier of bit B
    localparam integer E_BIT_A   = 5;       // [7:5]   bit of that subcarrier
    localparam integer E_BIT_B   = 2;       // [4:2]
    localparam integer E_STROBE  = 1;       // a pair
    localparam integer E_LAST    = 0;       // end of the symbol

    //---- Rate decoding -------------------------------------------------------
    wire       ht = i_rate[7];
    reg  [1:0] modulation;
    reg  [1:0] coding;
    reg        rate_known;

    always @* begin
        rate_known = 1'b1;
        case ({i_rate[7], i_rate[3:0]})
            5'b01011: begin modulation = MOD_BPSK;  coding = COD_1_2; end   //  6 Mbit/s
            5'b01111: begin modulation = MOD_BPSK;  coding = COD_3_4; end   //  9 Mbit/s
            5'b01010: begin modulation = MOD_QPSK;  coding = COD_1_2; end   // 12 Mbit/s
            5'b01110: begin modulation = MOD_QPSK;  coding = COD_3_4; end   // 18 Mbit/s
            5'b01001: begin modulation = MOD_QAM16; coding = COD_1_2; end   // 24 Mbit/s
            5'b01101: begin modulation = MOD_QAM16; coding = COD_3_4; end   // 36 Mbit/s
            5'b01000: begin modulation = MOD_QAM64; coding = COD_2_3; end   // 48 Mbit/s
            5'b01100: begin modulation = MOD_QAM64; coding = COD_3_4; end   // 54 Mbit/s
            5'b10000: begin modulation = MOD_BPSK;  coding = COD_1_2; end   // MCS 0
            5'b10001: begin modulation = MOD_QPSK;  coding = COD_1_2; end   // MCS 1
            5'b10010: begin modulation = MOD_QPSK;  coding = COD_3_4; end   // MCS 2
            5'b10011: begin modulation = MOD_QAM16; coding = COD_1_2; end   // MCS 3
            5'b10100: begin modulation = MOD_QAM16; coding = COD_3_4; end   // MCS 4
            5'b10101: begin modulation = MOD_QAM64; coding = COD_2_3; end   // MCS 5
            5'b10110: begin modulation = MOD_QAM64; coding = COD_3_4; end   // MCS 6
            5'b10111: begin modulation = MOD_QAM64; coding = COD_5_6; end   // MCS 7
            default: begin
                modulation = MOD_BPSK;
                coding     = COD_1_2;
                rate_known = 1'b0;
            end
        endcase
    end

    wire [5:0] num_data_carrier  = ht ? 6'd52 : 6'd48;
    wire [5:0] half_data_carrier = ht ? 6'd26 : 6'd24;
    wire       use_soft          = i_soft_decoding && rate_known;

    //---- Position of a coded bit ---------------------------------------------
    // Counters of coded bit k, packed: {hi[1:0], g, r[1:0], col_mod3[1:0], col[3:0]}
    localparam integer POS_W = 11;

    // the counters of bit k + 1: {k was the last bit of the symbol, counters}
    function [POS_W:0] next_position;
        input [POS_W-1:0] pos;
        input             is_ht;
        input [1:0]       mod;
        reg   [3:0]       col;
        reg   [1:0]       col_mod3;
        reg   [1:0]       r;
        reg               g;
        reg   [1:0]       hi;
        reg               wrap;
        begin
            {hi, g, r, col_mod3, col} = pos;
            wrap = 1'b0;
            if (col != (is_ht ? 4'd12 : 4'd15)) begin
                col      = col + 4'd1;
                col_mod3 = (col_mod3 == 2'd2) ? 2'd0 : col_mod3 + 2'd1;
            end
            else begin
                col      = 4'd0;
                col_mod3 = 2'd0;
                if (r != ((mod == MOD_QAM64) ? 2'd2 : (mod == MOD_QAM16) ? 2'd1 : 2'd0)) begin
                    r = r + 2'd1;
                end
                else begin
                    r = 2'd0;
                    if (!g && mod != MOD_BPSK) begin
                        g = 1'b1;
                    end
                    else begin
                        g = 1'b0;
                        if (hi != (is_ht ? 2'd3 : 2'd2)) begin
                            hi = hi + 2'd1;
                        end
                        else begin
                            hi   = 2'd0;
                            wrap = 1'b1;
                        end
                    end
                end
            end
            next_position = {wrap, hi, g, r, col_mod3, col};
        end
    endfunction

    // where the bit is: {subcarrier[5:0], bit[2:0]}
    function [8:0] locate;
        input [POS_W-1:0] pos;
        input             is_ht;
        input [1:0]       mod;
        reg   [3:0]       col;
        reg   [1:0]       col_mod3;
        reg   [1:0]       r;
        reg               g;
        reg   [1:0]       hi;
        reg   [5:0]       carrier;
        reg   [1:0]       rot;
        reg   [2:0]       bit_idx;
        begin
            {hi, g, r, col_mod3, col} = pos;
            if (is_ht) begin
                carrier = {col, 2'b00} + {4'd0, hi};
            end
            else begin
                carrier = {1'b0, col, 1'b0} + {2'd0, col} + {4'd0, hi};
            end
            case (mod)
                MOD_QAM16: rot = {1'b0, r[0] ^ col[0]};
                MOD_QAM64: rot = (r >= col_mod3) ? r - col_mod3 : r + 2'd3 - col_mod3;
                default:   rot = 2'd0;
            endcase
            bit_idx = g ? {1'b0, mod} + {1'b0, rot} : {1'b0, rot};
            locate  = {carrier, bit_idx};
        end
    endfunction

    //---- Entry generator -----------------------------------------------------
    // The rate is taken over with the last subcarrier of a symbol, so the
    // entries of a symbol do not depend on what i_rate does afterwards.
    reg              gen_ht;
    reg  [1:0]       gen_mod;
    reg  [1:0]       gen_coding;
    reg              gen_run;               // the entries of the symbol
    reg              gen_end;               // the entry after the last pair
    reg  [POS_W-1:0] gen_pos;               // coded bit k = bit A of the next entry
    reg  [2:0]       gen_phase;             // pair of the puncturing period

    reg              erase_a;
    reg              erase_b;
    reg  [1:0]       gen_step;              // coded bits used up by the entry
    reg              phase_last;

    always @* begin
        erase_a    = 1'b0;
        erase_b    = 1'b0;
        gen_step   = 2'd2;
        phase_last = 1'b1;
        case (gen_coding)
            COD_2_3: begin
                erase_b    = gen_phase[0];
                gen_step   = gen_phase[0] ? 2'd1 : 2'd2;
                phase_last = (gen_phase == 3'd1);
            end
            COD_3_4: begin
                erase_b    = (gen_phase == 3'd1);
                erase_a    = (gen_phase == 3'd2);
                gen_step   = (gen_phase == 3'd1) ? 2'd0 : 2'd2;
                phase_last = (gen_phase == 3'd2);
            end
            COD_5_6: begin
                erase_b    = (gen_phase == 3'd1) || (gen_phase == 3'd3);
                erase_a    = (gen_phase == 3'd2) || (gen_phase == 3'd4);
                gen_step   = (gen_phase == 3'd1 || gen_phase == 3'd3) ? 2'd0 : 2'd2;
                phase_last = (gen_phase == 3'd4);
            end
            default: begin
            end
        endcase
    end

    wire [POS_W:0] pos_plus1 = next_position(gen_pos, gen_ht, gen_mod);
    wire [POS_W:0] pos_plus2 = next_position(pos_plus1[POS_W-1:0], gen_ht, gen_mod);
    wire [8:0]     loc_a     = locate(gen_pos, gen_ht, gen_mod);
    wire [8:0]     loc_b     = locate(pos_plus1[POS_W-1:0], gen_ht, gen_mod);

    // the entry used up the last coded bit of the symbol
    wire           gen_last  = (gen_step == 2'd2) ? (pos_plus1[POS_W] | pos_plus2[POS_W]) :
                               (gen_step == 2'd1) ? pos_plus1[POS_W] : 1'b0;
    wire [POS_W-1:0] gen_pos_next = (gen_step == 2'd2) ? pos_plus2[POS_W-1:0] :
                                    (gen_step == 2'd1) ? pos_plus1[POS_W-1:0] : gen_pos;

    reg  [21:0]    entry_next;

    always @* begin
        entry_next = 22'd0;
        if (gen_run) begin
            entry_next[E_ERASE_A]         = erase_a;
            entry_next[E_ERASE_B]         = erase_b;
            entry_next[E_ADDR_A +: 6]     = loc_a[8:3];
            entry_next[E_ADDR_B +: 6]     = loc_b[8:3];
            entry_next[E_BIT_A +: 3]      = loc_a[2:0];
            entry_next[E_BIT_B +: 3]      = loc_b[2:0];
            entry_next[E_STROBE]          = 1'b1;
        end
        else if (gen_end) begin
            entry_next[E_ADDR_A +: 6]     = gen_ht ? 6'd26 : 6'd24;
            entry_next[E_LAST]            = 1'b1;
        end
    end

    reg  [21:0] entry;

    always @(posedge i_clk) begin
        entry <= entry_next;
    end

    wire [5:0] entry_addr_a = entry[E_ADDR_A +: 6];
    wire [5:0] entry_addr_b = entry[E_ADDR_B +: 6];
    wire       entry_last   = entry[E_LAST];

    //---- Subcarrier memory (64 x 16, read first) -----------------------------
    reg  [15:0] ram [0:63];
    reg  [5:0]  addr_a;                     // write address, then subcarrier of bit A
    reg  [5:0]  addr_b;                     // subcarrier of bit B
    reg  [15:0] word_a;
    reg  [15:0] word_b;
    integer     ram_idx;

    initial begin
        for (ram_idx = 0; ram_idx < 64; ram_idx = ram_idx + 1) begin
            ram[ram_idx] = 16'd0;
        end
        word_a = 16'd0;
        word_b = 16'd0;
    end

    always @(posedge i_clk) begin
        if (i_input_strobe) begin
            ram[addr_a] <= {i_in_bits, i_soft_in_bits, i_soft_in_bits_pos};
        end
        word_a <= ram[addr_a];
    end

    always @(posedge i_clk) begin
        word_b <= ram[addr_b];
    end

    //---- Entry delayed by the memory read (2 clocks) -------------------------
    reg         entry_valid;
    reg  [22:0] entry_d1;
    reg  [22:0] entry_d2;

    always @(posedge i_clk) begin
        if (i_rst) begin
            entry_d1 <= 23'd0;
            entry_d2 <= 23'd0;
        end
        else begin
            entry_d1 <= {entry_valid, entry};
            entry_d2 <= entry_d1;
        end
    end

    wire       out_valid = entry_d2[22];
    wire [2:0] out_bit_a = entry_d2[E_BIT_A +: 3];
    wire [2:0] out_bit_b = entry_d2[E_BIT_B +: 3];

    assign o_erase[0]      = entry_d2[E_ERASE_A];
    assign o_erase[1]      = entry_d2[E_ERASE_B];
    assign o_output_strobe = i_enable & out_valid & entry_d2[E_STROBE];

    //---- Output selection ----------------------------------------------------
    // One bit of one subcarrier as a 3 bit soft value: the demodulator's soft
    // value if it belongs to this bit, otherwise the hard decision.
    function [2:0] soft_bit;
        input [15:0] word;      // {bits[5:0], soft values[5:0], positions[3:0]}
        input [2:0]  bit_idx;
        input        soft_en;
        input [1:0]  mod;       // = N_BPSC / 2
        reg   [5:0]  hard;
        reg   [5:0]  soft;
        reg   [3:0]  pos;
        begin
            {hard, soft, pos} = word;
            if (hard[bit_idx] == 1'b1) begin
                soft_bit = 3'b111;
            end
            else begin
                soft_bit = 3'b011;
            end
            if (soft_en) begin
                if (mod == MOD_BPSK || bit_idx < {1'b0, mod}) begin
                    if (bit_idx[1:0] == pos[1:0]) begin
                        soft_bit = soft[2:0];
                    end
                end
                else begin
                    if (bit_idx == ({1'b0, pos[3:2]} + {1'b0, mod})) begin
                        soft_bit = soft[5:3];
                    end
                end
            end
        end
    endfunction

    always @* begin
        if (out_valid) begin
            o_out_bits[2:0] = soft_bit(word_a, out_bit_a, use_soft, modulation);
            o_out_bits[5:3] = soft_bit(word_b, out_bit_b, use_soft, modulation);
        end
        else begin
            o_out_bits = 6'd0;
        end
    end

    //---- Sequencer -----------------------------------------------------------
    reg [1:0] state;
    reg       second;                       // second clock of a two clock step
    reg       ht_d1;

    always @(posedge i_clk) begin
        if (i_rst) begin
            addr_a      <= num_data_carrier >> 1;
            addr_b      <= 6'd0;
            gen_ht      <= 1'b0;
            gen_mod     <= MOD_BPSK;
            gen_coding  <= COD_1_2;
            gen_run     <= 1'b0;
            gen_end     <= 1'b0;
            gen_pos     <= {POS_W{1'b0}};
            gen_phase   <= 3'd0;
            entry_valid <= 1'b0;
            ht_d1       <= 1'b0;
            second      <= 1'b0;
            state       <= ST_INPUT;
        end
        else if (i_enable) begin
            ht_d1 <= ht;
            if (ht != ht_d1) begin
                addr_a <= num_data_carrier >> 1;
            end

            case (state)
                ST_INPUT: begin
                    if (i_input_strobe) begin
                        if (addr_a == half_data_carrier - 6'd1) begin
                            gen_ht      <= ht;
                            gen_mod     <= modulation;
                            gen_coding  <= coding;
                            second      <= 1'b0;
                            entry_valid <= 1'b0;
                            state       <= ST_START;
                        end
                        else if (addr_a == num_data_carrier - 6'd1) begin
                            addr_a <= 6'd0;
                        end
                        else begin
                            addr_a <= addr_a + 6'd1;
                        end
                    end
                end

                ST_START: begin
                    if (second) begin
                        gen_run   <= 1'b1;
                        gen_end   <= 1'b0;
                        gen_pos   <= {POS_W{1'b0}};
                        gen_phase <= 3'd0;
                        second    <= 1'b0;
                        state     <= ST_OUTPUT;
                    end
                    else begin
                        second <= 1'b1;
                    end
                end

                ST_OUTPUT: begin
                    if (second) begin
                        addr_a <= entry_addr_a;
                        addr_b <= entry_addr_b;
                    end
                    if (second && entry_last) begin
                        gen_run     <= 1'b0;
                        gen_end     <= 1'b0;
                        entry_valid <= 1'b0;
                        state       <= ST_INPUT;
                    end
                    else begin
                        second      <= 1'b1;
                        entry_valid <= 1'b1;
                        // the next entry
                        if (gen_run) begin
                            gen_pos   <= gen_pos_next;
                            gen_phase <= phase_last ? 3'd0 : gen_phase + 3'd1;
                            if (gen_last) begin
                                gen_run <= 1'b0;
                                gen_end <= 1'b1;
                            end
                        end
                        else begin
                            gen_end <= 1'b0;
                        end
                    end
                end

                default: begin
                end
            endcase
        end
    end

endmodule

`default_nettype wire
