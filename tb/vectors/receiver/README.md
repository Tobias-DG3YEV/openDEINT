# Recordings of the deinterleaver inside the receiver

Taken with `tb/deinterleave_tap.v` from openofdm's `deinterleave.v`
(ROM table `deinter_lut_from_coe.mif`) while openofdm's bench `dot11_tb`
decoded the vectors below at a 120 MHz clock, soft decoding on
(`tools/capture_traces.sh`, 2026-11-19). `tb_deinterleave_replay` replays
them.

One line per clock in which a port differs from the clock before:

```
<clock> <inputs, 7 hex digits> <outputs, 3 hex digits>
inputs  = {reset, enable, soft_decoding, input_strobe, rate[7:0],
           in_bits[5:0], soft_in_bits[5:0], soft_in_bits_pos[3:0]}
outputs = {output_strobe, erase[1:0], out_bits[5:0]}
```

The vectors are in openofdm's `verilog/testing_inputs/`. A recording holds
the first three frames of a capture (one frame = the receiver found a SIGNAL
symbol and enabled the decoder), `mixed` and the single-frame vectors hold
everything. Every recording also contains SIGNAL symbols at 6 Mbit/s, the
802.11n ones HT-SIG symbols as well.

| recording | vector | frames | rates of the data symbols |
|---|---|---|---|
| dot11a_6mbps | conducted/dot11a_6mbps_qos_data_..._openwifi.txt | 3 | 6 Mbit/s |
| dot11a_9mbps | conducted/dot11a_9mbps_qos_data_..._openwifi.txt | 3 | 9 Mbit/s |
| dot11a_12mbps | conducted/dot11a_12mbps_qos_data_..._openwifi.txt | 3 | 12 Mbit/s |
| dot11a_18mbps | conducted/dot11a_18mbps_qos_data_..._openwifi.txt | 3 | 18, 12 Mbit/s |
| dot11a_24mbps | conducted/dot11a_24mbps_qos_data_..._openwifi.txt | 3 | 24 Mbit/s |
| dot11a_36mbps | conducted/dot11a_36mbps_qos_data_..._openwifi.txt | 3 | 36 Mbit/s |
| dot11a_48mbps | conducted/dot11a_48mbps_qos_data_..._openwifi.txt | 3 | 48 Mbit/s |
| dot11a_54mbps_len14 | simulated/ag_54M_len14_pre100_post200_openwifi.txt | 1 | 54 Mbit/s |
| dot11a_54mbps_len1537 | simulated/ag_54M_len1537_pre100_post200_openwifi.txt | 1 | 54 Mbit/s, 58 symbols; enable goes low while the last pairs go out |
| dot11n_mcs0 | conducted/dot11n_6.5mbps_..._openwifi.txt | 3 | MCS 0 |
| dot11n_mcs0_sgi | conducted/dot11n_7.2mbps_..._openwifi.txt | 3 | MCS 0, short guard interval |
| dot11n_mcs1 | conducted/dot11n_13mbps_..._openwifi.txt | 3 | MCS 1 |
| dot11n_mcs2_radiated | radiated/dot11n_19.5mbps_openwifi.txt | 3 | MCS 2, over the air |
| dot11n_mcs3 | conducted/dot11n_26mbps_..._openwifi.txt | 3 | MCS 3 |
| dot11n_mcs4 | conducted/dot11n_39mbps_..._openwifi.txt | 3 | MCS 4 |
| dot11n_mcs5 | conducted/dot11n_52mbps_..._openwifi.txt | 3 | MCS 5, 24 Mbit/s |
| dot11n_mcs6 | conducted/dot11n_58.5mbps_..._openwifi.txt | 3 | MCS 6, 24 Mbit/s |
| dot11n_mcs7 | conducted/dot11n_65mbps_..._openwifi.txt | 3 | MCS 7 |
| dot11n_mcs7_sgi_len14 | simulated/ht_mcs7_gi1_aggr0_len14_pre100_post200_openwifi.txt | 1 | MCS 7, short guard interval |
| dot11n_wrong_ht_sig | simulated/iq_11n_mcs7_gi0_100B_wrong_ht_sig_openwifi.txt | 1 | none: HT-SIG damaged, decoding stops |
| mixed | simulated/iq_mixed_for_side_ch_openwifi.txt | 11 | 24, 48 Mbit/s, MCS 7; one reset and one enable low while pairs go out |

Not every frame in these captures has a good FCS (the 64-QAM captures are
marginal). That does not matter here: the recording is what the deinterleaver
was given and what it answered.
