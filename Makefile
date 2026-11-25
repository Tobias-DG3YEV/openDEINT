# openDEINT - open deinterleaver for the openofdm 802.11a/g/n receiver
#   make tb            run all self-checking XSim benches (needs Vivado on
#                      $PATH or in /tools/2025.2, see tools/run_tb.sh)
#   make tb BENCH=deinterleave      one bench (deinterleave |
#                                   deinterleave_replay | deinterleave_compare)
#   make tb DUT=legacy              the benches on openofdm's former
#                                   deinterleaver (tb/ref_deinterleave_legacy.v)
#   make tb DUT=openofdm            the benches on the deinterleave.v of an
#                                   openofdm checkout (OPENOFDM=<checkout>)
#   make faults        check that tb_deinterleave finds a wrong table
#   make synth         resources and Fmax, core and old block (build/synth/)
#   make traces        record tb/vectors/receiver/ again from openofdm
#   make clean
BENCH   ?= all
DUT     ?= open
VIVADO  ?= vivado
VFLAGS  ?= -mode batch -nojournal -nolog
SETTINGS ?= /tools/2025.2/Vivado/settings64.sh
.PHONY: tb faults synth traces clean
tb:
	DUT=$(DUT) bash tools/run_tb.sh $(BENCH) $(XSIM_ARGS)
faults:
	bash tools/fault_check.sh
synth:
	mkdir -p build && cd build && bash -c 'command -v $(VIVADO) >/dev/null || source $(SETTINGS); $(VIVADO) $(VFLAGS) -source ../tools/synth_compare.tcl'
traces:
	bash tools/capture_traces.sh
clean:
	rm -rf build .Xil
