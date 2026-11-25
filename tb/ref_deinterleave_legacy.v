//----------------------------------------------------------------------------
// Module : ref_deinterleave_legacy
// Purpose: openofdm's deinterleaver before openDEINT, as a reference model:
// the deinterleave.v of openofdm with its three helpers written out in one
// module, the 64 x 16 dual-port RAM (ram_2port), the 4096 x 22 address ROM
// (deinter_lut, once a coregen Block Memory Generator core) and the two
// clock delay line (delayT).
//
// One OFDM symbol: N_SD = 48 (802.11a/g) or 52 (802.11n, i_rate[7] = 1)
// demodulated subcarriers arrive with i_input_strobe and are written to the
// RAM, the first one to address N_SD / 2, wrapping from N_SD - 1 to 0 (the
// FFT hands out the positive subcarriers first). With the last subcarrier
// the ROM is read: the entry at {i_rate[7], i_rate[3:0]} points to the
// rate's list, and each list entry names two RAM cells and the bit to take
// from each. The two bits are one pair (A, B) of the rate 1/2 mother code;
// where the transmitter punctured a bit the entry sets an erase flag
// instead. The output is a 3 bit soft value per bit (3'b111 strongest one,
// 3'b011 strongest zero) and o_erase = {B erased, A erased}.
//
// ROM entry: [21] erase A, [20] erase B, [19:14] RAM address A, [13:8] RAM
// address B, [7:5] bit A, [4:2] bit B, [1] output strobe, [0] end of list.
//
// Soft decoding (i_soft_decoding = 1): the demodulator delivers one soft
// value per axis and subcarrier (i_soft_in_bits[2:0] in-phase, [5:3]
// quadrature) and says which bit of that axis it belongs to
// (i_soft_in_bits_pos[1:0] / [3:2], 3 = none). That bit is handed out with
// the soft value, every other bit with its hard value.
//
// Timing: the first pair leaves 6 clocks after the last subcarrier, then
// one pair per clock.
//
// Differences to openofdm's file: port names i_clk / i_rst, the three
// helper modules written out, the output selection as a function instead
// of the same code twice. The behaviour is the same clock for clock
// (tb_deinterleave_replay checks it against recordings of openofdm's
// module inside the receiver).
//
// Derived from deinterleave.v, ram_2port.v and delayT.v of openofdm
// (https://github.com/jhshi/openofdm, Apache-2.0).
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

module ref_deinterleave_legacy #(
    parameter ROM_FILE = "deinter_lut.mem"  // $readmemb file, 4096 x 22 bit
) (
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

    localparam [1:0] S_INPUT    = 2'd0;
    localparam [1:0] S_GET_BASE = 2'd1;
    localparam [1:0] S_OUTPUT   = 2'd2;

    //---- Rate decoding -------------------------------------------------------
    wire       ht                = i_rate[7];
    wire [5:0] num_data_carrier  = ht ? 6'd52 : 6'd48;
    wire [5:0] half_data_carrier = ht ? 6'd26 : 6'd24;

    wire [4:0] mod_type = {i_rate[7], i_rate[3:0]};
    wire       bpsk     = (mod_type == 5'b01011) || (mod_type == 5'b01111) ||
                          (mod_type == 5'b10000);
    wire       qpsk     = (mod_type == 5'b01010) || (mod_type == 5'b01110) ||
                          (mod_type == 5'b10001) || (mod_type == 5'b10010);
    wire       qam_16   = (mod_type == 5'b01001) || (mod_type == 5'b01101) ||
                          (mod_type == 5'b10011) || (mod_type == 5'b10100);
    wire       qam_64   = (mod_type == 5'b01000) || (mod_type == 5'b01100) ||
                          (mod_type == 5'b10101) || (mod_type == 5'b10110) ||
                          (mod_type == 5'b10111);
    wire [2:0] n_bpsc_div_2 = bpsk   ? 3'b000 :
                              qpsk   ? 3'b001 :
                              qam_16 ? 3'b010 :
                              qam_64 ? 3'b011 : 3'b111;
    wire       use_soft = i_soft_decoding && (bpsk || qpsk || qam_16 || qam_64);

    //---- Subcarrier RAM (ram_2port, 64 x 16, read first) ---------------------
    reg  [15:0] ram [0:63];
    reg  [5:0]  addra;
    reg  [5:0]  addrb;
    reg  [15:0] doa;
    reg  [15:0] dob;
    integer     ram_idx;

    initial begin
        for (ram_idx = 0; ram_idx < 64; ram_idx = ram_idx + 1) begin
            ram[ram_idx] = 16'd0;
        end
        doa = 16'd0;
        dob = 16'd0;
    end

    always @(posedge i_clk) begin
        if (i_input_strobe) begin
            ram[addra] <= {i_in_bits, i_soft_in_bits, i_soft_in_bits_pos};
        end
        doa <= ram[addra];
        dob <= ram[addrb];
    end

    wire [5:0] bit_outa          = doa[15:10];
    wire [5:0] soft_bit_outa     = doa[9:4];
    wire [3:0] soft_bit_outa_pos = doa[3:0];
    wire [5:0] bit_outb          = dob[15:10];
    wire [5:0] soft_bit_outb     = dob[9:4];
    wire [3:0] soft_bit_outb_pos = dob[3:0];

    //---- Address ROM (deinter_lut, 4096 x 22, registered output) -------------
    reg  [21:0] rom [0:4095];
    reg  [11:0] lut_key;
    reg  [21:0] lut_out;

    initial begin
        $readmemb(ROM_FILE, rom);
    end

    always @(posedge i_clk) begin
        lut_out <= rom[lut_key];
    end

    wire [5:0] lut_addra = lut_out[19:14];
    wire [5:0] lut_addrb = lut_out[13:8];
    wire       lut_done  = lut_out[0];

    //---- ROM entry delayed by the RAM read (delayT, 2 clocks) ----------------
    reg         lut_valid;
    reg  [22:0] delay_s1;
    reg  [22:0] delay_s2;

    always @(posedge i_clk) begin
        if (i_rst) begin
            delay_s1 <= 23'd0;
            delay_s2 <= 23'd0;
        end
        else begin
            delay_s1 <= {lut_valid, lut_out};
            delay_s2 <= delay_s1;
        end
    end

    wire        lut_valid_delayed = delay_s2[22];
    wire [21:0] lut_out_delayed   = delay_s2[21:0];
    wire [2:0]  lut_bita          = lut_out_delayed[7:5];
    wire [2:0]  lut_bitb          = lut_out_delayed[4:2];

    assign o_erase[0]      = lut_out_delayed[21];
    assign o_erase[1]      = lut_out_delayed[20];
    assign o_output_strobe = i_enable & lut_valid_delayed & lut_out_delayed[1];

    //---- Output selection ----------------------------------------------------
    // One bit of one subcarrier as a 3 bit soft value: the demodulator's soft
    // value if it belongs to this bit, otherwise the hard decision.
    function [2:0] pick_bit;
        input [5:0] hard;       // demodulated bits of the subcarrier
        input [5:0] soft;       // soft values, [2:0] I, [5:3] Q
        input [3:0] pos;        // bit the soft values belong to, [1:0] I, [3:2] Q
        input [2:0] bit_idx;    // bit of the subcarrier to hand out
        input       soft_en;
        input       is_bpsk;
        input [2:0] half;       // N_BPSC / 2
        reg   [2:0] hard3;
        begin
            if (hard[bit_idx] == 1'b1) begin
                hard3 = 3'b111;
            end
            else begin
                hard3 = 3'b011;
            end
            pick_bit = hard3;
            if (soft_en) begin
                if (is_bpsk || bit_idx < half) begin
                    if (bit_idx[1:0] == pos[1:0]) begin
                        pick_bit = soft[2:0];
                    end
                end
                else begin
                    if (bit_idx == ({1'b0, pos[3:2]} + half)) begin
                        pick_bit = soft[5:3];
                    end
                end
            end
        end
    endfunction

    always @* begin
        if (lut_valid_delayed) begin
            o_out_bits[2:0] = pick_bit(bit_outa, soft_bit_outa, soft_bit_outa_pos,
                                       lut_bita, use_soft, bpsk, n_bpsc_div_2);
            o_out_bits[5:3] = pick_bit(bit_outb, soft_bit_outb, soft_bit_outb_pos,
                                       lut_bitb, use_soft, bpsk, n_bpsc_div_2);
        end
        else begin
            o_out_bits = 6'd0;
        end
    end

    //---- Sequencer -----------------------------------------------------------
    reg [1:0] state;
    reg       ram_delay;
    reg       ht_delayed;

    always @(posedge i_clk) begin
        if (i_rst) begin
            addra      <= num_data_carrier >> 1;
            addrb      <= 6'd0;
            lut_key    <= 12'd0;
            lut_valid  <= 1'b0;
            ht_delayed <= 1'b0;
            ram_delay  <= 1'b0;
            state      <= S_INPUT;
        end
        else if (i_enable) begin
            ht_delayed <= ht;
            if (ht != ht_delayed) begin
                addra <= num_data_carrier >> 1;
            end

            case (state)
                S_INPUT: begin
                    if (i_input_strobe) begin
                        if (addra == half_data_carrier - 6'd1) begin
                            lut_key   <= {7'b0, ht, i_rate[3:0]};
                            ram_delay <= 1'b0;
                            lut_valid <= 1'b0;
                            state     <= S_GET_BASE;
                        end
                        else if (addra == num_data_carrier - 6'd1) begin
                            addra <= 6'd0;
                        end
                        else begin
                            addra <= addra + 6'd1;
                        end
                    end
                end

                S_GET_BASE: begin
                    if (ram_delay) begin
                        lut_key   <= lut_out[11:0];
                        ram_delay <= 1'b0;
                        state     <= S_OUTPUT;
                    end
                    else begin
                        ram_delay <= 1'b1;
                    end
                end

                S_OUTPUT: begin
                    if (ram_delay) begin
                        addra <= lut_addra;
                        addrb <= lut_addrb;
                        if (lut_done) begin
                            lut_key   <= 12'd0;
                            lut_valid <= 1'b0;
                            state     <= S_INPUT;
                        end
                        else begin
                            lut_valid <= 1'b1;
                            lut_key   <= lut_key + 12'd1;
                        end
                    end
                    else begin
                        ram_delay <= 1'b1;
                        lut_valid <= 1'b1;
                        lut_key   <= lut_key + 12'd1;
                    end
                end

                default: begin
                end
            endcase
        end
    end

endmodule

`default_nettype wire
