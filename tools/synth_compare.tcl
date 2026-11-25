# ---------------------------------------------------------------------------
# synth_compare.tcl - resources and speed of the deinterleaver next to
# openofdm's former one: out-of-context synthesis + opt_design of each
# variant, one after the other, in one Vivado session.
#
#   vivado -mode batch -source tools/synth_compare.tcl [-tclargs [-period ns] [variant ...]]
#
#   open      rtl/deinterleaver.v
#   legacy    tb/ref_deinterleave_legacy.v with its 4096 x 22 bit address
#             table tb/vectors/deinter_lut.mem: openofdm's deinterleave.v,
#             ram_2port.v, delayT.v and the deinter_lut ROM in one module
# (default: both).
#
# Part xc7a100tcsg324-2, clock on i_clk (default 3 ns, so that the slack
# shows the headroom), Fmax estimated as 1000 / (period - WNS) after
# opt_design; no placement or routing.
# Output: one line per variant on stdout and in build/synth/summary.txt
#   ### SYNTH <variant> LUT=<n> LUTRAM=<n> FF=<n> RAMB36=<n> RAMB18=<n> DSP=<n> WNS=<ns> FMAX_EST=<MHz>
# plus build/synth/<variant>/{utilization,timing}.rpt.
#
# Project: RA-Sentinel (NLnet)
# Engineer: Tobias Weber
# ---------------------------------------------------------------------------
# Copyright 2026 Tobias Weber
# SPDX-License-Identifier: Apache-2.0
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License. You may obtain
# a copy of the License at http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# ---------------------------------------------------------------------------
set root [file normalize [file join [file dirname [info script]] ..]]
set part xc7a100tcsg324-2

set period 3.0
set variants {}
set args_ [expr {[info exists argv] ? $argv : {}}]
for {set i 0} {$i < [llength $args_]} {incr i} {
    set a [lindex $args_ $i]
    if {$a eq "-period"} { incr i; set period [lindex $args_ $i]; continue }
    lappend variants $a
}
if {[llength $variants] == 0} { set variants {open legacy} }

set out $root/build/synth
file mkdir $out
set summary [open $out/summary.txt a]
puts $summary "==== [clock format [clock seconds]] period=${period}ns part=$part"

proc utilRow {rpt pattern} {
    if {[regexp -line "^\\|\\s*${pattern}\\s*\\|\\s*(\[0-9.\]+)" $rpt -> v]} { return $v }
    return "?"
}

foreach v $variants {
    set dir $out/$v
    file mkdir $dir
    create_project -in_memory -part $part
    set generics {}
    switch -- $v {
        open {
            read_verilog $root/rtl/deinterleaver.v
            set top deinterleaver
        }
        legacy {
            read_verilog $root/tb/ref_deinterleave_legacy.v
            set top ref_deinterleave_legacy
            set generics [list "ROM_FILE=\"$root/tb/vectors/deinter_lut.mem\""]
        }
        default { error "unknown variant '$v'" }
    }
    set cmd [list synth_design -top $top -mode out_of_context -part $part]
    foreach g $generics { lappend cmd -generic $g }
    {*}$cmd
    create_clock -period $period -name clk [get_ports i_clk]
    opt_design
    report_utilization -file $dir/utilization.rpt
    report_timing_summary -file $dir/timing.rpt
    set rpt    [report_utilization -return_string]
    set lut    [utilRow $rpt {Slice LUTs\*?}]
    set lutram [utilRow $rpt {LUT as Memory}]
    set ff     [utilRow $rpt {Slice Registers}]
    set ramb36 [utilRow $rpt {RAMB36/FIFO\*?}]
    set ramb18 [utilRow $rpt {RAMB18}]
    set dsp    [llength [get_cells -quiet -hier -filter {PRIMITIVE_GROUP == DSP}]]
    set wns    "n/a"
    set fmax   "n/a"
    set paths [get_timing_paths -quiet -max_paths 1 -setup]
    if {[llength $paths] > 0} {
        set wns  [get_property SLACK [lindex $paths 0]]
        set fmax [format %.1f [expr {1000.0 / ($period - $wns)}]]
    }
    set line "### SYNTH $v LUT=$lut LUTRAM=$lutram FF=$ff RAMB36=$ramb36 RAMB18=$ramb18 DSP=$dsp WNS=$wns FMAX_EST=$fmax"
    puts $line
    puts $summary $line
    flush $summary
    close_project
}
close $summary
puts "### SYNTH_COMPARE_DONE -> $out/summary.txt"
