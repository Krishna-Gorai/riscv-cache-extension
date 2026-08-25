#!/usr/bin/env bash
# =============================================================================
#  run_iverilog.sh -- run the simulator-independent testbenches with Icarus.
#
#  Vivado xsim is the reference simulator for this repository, but not everyone
#  has it. These three testbenches avoid the constructs Icarus 12 does not
#  implement, so the SoC and its coherence behaviour can be checked with a
#  purely open-source toolchain:
#
#    tb_soc_mem       unit tests for the shared memories, the control region
#                     and the non-coherent data path
#    tb_soc_stub_nc   the whole SoC built as the non-coherent baseline, with
#                     tb/models/core_stub.sv compiled in place of the CV32E40P
#
#  KNOWN LIMITATION -- tb_soc_stub (the *coherent* SoC) elaborates under Icarus
#  but stalls at its first DCU transaction, at around cycle 5, and does so even
#  with NumPes=1. The same DCU and snoopy bus pass 5647 checks under xsim, so
#  this looks like an Icarus evaluation limitation rather than an RTL defect --
#  most likely its handling of always_comb convergence, given it also warns
#  that it cannot represent the constant selects in the bridges precisely. It
#  has NOT been proven either way, so tb_soc_stub is deliberately left out of
#  the default list below: run it under xsim.
#
#  Also needing xsim: tb_dcu and tb_coherent_subsystem (their stimulus uses
#  `break` and procedural `automatic`), and tb_pe / tb_soc, which instantiate
#  the real CV32E40P -- Icarus cannot elaborate it, as it uses `inside`
#  expressions among other things.
#
#  The array size is a knob: -DSOC_STUB_N=<n> (default 64).
#
#  Usage:  sim/run_iverilog.sh                 run the two that pass
#          sim/run_iverilog.sh tb_soc_stub_nc  run one
# =============================================================================
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/sim/out"
mkdir -p "$out"

# Probe the usual install locations, then fall back to $PATH.
IVERILOG="${IVERILOG:-}"
if [ -z "$IVERILOG" ]; then
  for cand in "/c/Users/$USERNAME/OneDrive/Desktop/iverilog/bin" \
              "/c/iverilog/bin" "/usr/bin" "/usr/local/bin"; do
    if [ -x "$cand/iverilog" ] || [ -x "$cand/iverilog.exe" ]; then
      IVERILOG="$cand"
      break
    fi
  done
fi
IVERILOG="${IVERILOG:-$(dirname "$(command -v iverilog)")}"

IV="$IVERILOG/iverilog"
VVP="$IVERILOG/vvp"

RTL="$root/rtl/include/cache_pkg.sv
     $root/rtl/cache/cache_ram.sv
     $root/rtl/cache/dcu_hcl.sv
     $root/rtl/cache/dcu.sv
     $root/rtl/cache/dcu_bypass.sv
     $root/rtl/snoop/rr_arbiter.sv
     $root/rtl/snoop/invalidation_table.sv
     $root/rtl/snoop/link_register.sv
     $root/rtl/snoop/snoopy_bus.sv
     $root/rtl/soc/coherent_subsystem.sv
     $root/rtl/soc/shared_data_mem.sv
     $root/rtl/soc/shared_instr_mem.sv
     $root/rtl/soc/soc_ctrl.sv
     $root/rtl/pe/bridge_router.sv
     $root/rtl/pe/itcm.sv
     $root/rtl/pe/instr_bridge.sv
     $root/rtl/pe/data_bridge.sv
     $root/rtl/pe/pe_top.sv
     $root/rtl/soc/soc_top.sv"

run_one() {
  tb="$1"
  case "$tb" in
    tb_soc_mem)
      srcs="$root/rtl/include/cache_pkg.sv
            $root/rtl/cache/dcu_bypass.sv
            $root/rtl/soc/shared_data_mem.sv
            $root/rtl/soc/shared_instr_mem.sv
            $root/rtl/soc/soc_ctrl.sv
            $root/tb/unit/tb_soc_mem.sv" ;;
    tb_soc_stub|tb_soc_stub_nc|tb_soc_stub_1pe)
      # core_stub.sv defines a module called cv32e40p_top, so compiling it
      # instead of the submodule swaps the core out of the whole SoC.
      srcs="$RTL
            $root/tb/models/core_stub.sv
            $root/tb/system/tb_soc_stub.sv" ;;
    *)
      echo "unknown testbench: $tb" >&2
      echo "this script runs: tb_soc_mem, tb_soc_stub_nc" >&2
      echo "everything else needs Vivado xsim -- see sim/run_xsim.ps1" >&2
      return 2 ;;
  esac

  echo "== iverilog $tb =="
  # These "sorry" notes are Icarus telling us it ignored a hint (unique case,
  # constant selects); none of them changes behaviour here.
  # shellcheck disable=SC2086
  "$IV" -g2012 -o "$out/$tb.vvp" -s "$tb" $srcs 2>&1 \
    | grep -viE "unique/unique0 qualities|constant selects in always|cannot be synthesized|expects 2 bits|Padding 1 high bits" || true

  "$VVP" "$out/$tb.vvp"
}

if [ $# -gt 0 ]; then
  for tb in "$@"; do run_one "$tb"; done
else
  for tb in tb_soc_mem tb_soc_stub_nc; do run_one "$tb"; done
fi
