# Seamless Data-Cache Extension for a Multi-Core RISC-V SoC

An open-source, from-scratch RTL reproduction of

> A. Kamaleldin, M. Nickel, S. Wu and D. Göhringer,
> **"Seamless Cache Extension for FPGA-based Multi-Core RISC-V SoC"**,
> *IEEE 37th International System-on-Chip Conference (SOCC)*, 2024.
> doi:[10.1109/SOCC62300.2024.10737850](https://doi.org/10.1109/SOCC62300.2024.10737850)

The paper proposes a **private L1 data-cache sub-system that can be attached to
an in-order RISC-V core without modifying the core pipeline**, with cache
coherence handled entirely in hardware by a snooping invalidation bus — no
software involvement, no interconnect changes.

This repository builds that sub-system in SystemVerilog, integrates it into a
4-PE RISC-V SoC around a CV32E40P core and an AXI crossbar, and reproduces the
paper's evaluation on a Xilinx Zynq UltraScale+ device.

> **Status:** work in progress. See the roadmap below for what is finished.

---

## What is implemented

### Data Cache Unit (DCU)

| Property | Value |
|---|---|
| Organisation | `NumWays`-way set associative (default 2-way) |
| Capacity | configurable line width × set count (default 2 KiB = 2 × 64 × 16 B) |
| Write policy | **write-through, no-allocate** |
| Replacement | 1-bit LRU per set, invalid ways filled first |
| Pipeline | **two sequential stages** — lookup / snoopy-bus forward, then hit-check + control |
| Coherence | write-invalidate snooping, MRSW invariant, full hardware |
| Atomics | LR / SC support via the snoopy bus link register |
| Instrumentation | read/write hit and miss counters for hit-rate measurement |

The block decomposition follows Fig. 2b of the paper:

```
                   ┌──────────────── Data Cache Unit ────────────────┐
   core D-Port ───►│  Request  ──► stage 1 ──► stage 2 ──► CCL  ──►  │───► D-AXI port
                   │  Mgmt              │         │        ▲        │
   snoopy bus ────►│                Tag-RAM    HCL │       SCL       │───► snoopy bus
                   │                Data-RAM   Status-RAM  LRU       │
                   └────────────────────────────────────────────────┘
```

* **HCL** – Hit Check Logic (`rtl/cache/dcu_hcl.sv`)
* **CCL** – Cache Control Logic (FSM inside `rtl/cache/dcu.sv`)
* **SCL** – Stall Control Logic, implementing both stall-condition lists of
  Section III-B-a verbatim

Both awkward corner cases the paper calls out are implemented and directly
tested:

1. **Simultaneous write and read to the same location** from different cores,
   resolved by the Multiple-Readers-Single-Writer lock on the snoopy bus.
2. **An INV REQ that arrives before the MEM RESP** of an outstanding read: the
   invalidation is recorded as a flag, and the returned data is forwarded to the
   core *without* installing the line.

---

## Repository layout

```
rtl/
  include/cache_pkg.sv     shared types, request and atomic encodings
  cache/cache_ram.sv       dual-port RAM primitive with collision bypass
  cache/dcu_hcl.sv         Hit Check Logic
  cache/dcu.sv             Data Cache Unit (stages, CCL, SCL, arrays)
  snoop/                   snoopy bus: arbiters, link register, inv. table
  pe/                      data bridge, instruction bridge, ITCM, PE top
  soc/                     AXI crossbar wiring, shared memories, SoC top
tb/
  models/mem_model.sv      shared data memory model with latency + backpressure
  unit/tb_dcu.sv           self-checking DCU testbench
  system/                  multi-core coherence testbenches
sw/                        bare-metal benchmark kernels
fpga/                      Vivado synthesis and implementation scripts
sim/run_xsim.ps1           compile + run any testbench with Vivado xsim
docs/                      architecture notes, protocol description, results
```

---

## Running the simulations

Requires Vivado (tested with **2025.1**); adjust the path if yours differs.

```powershell
powershell -File sim/run_xsim.ps1 -Tb tb_dcu
# add -Wave to log all signals for waveform inspection
```

Current result:

```
 DCU counters: rd_hit=1403 rd_miss=620 wr_hit=764 wr_miss=299
 tb_dcu PASSED  (2549 checks)
```

`tb_dcu` covers compulsory misses, hits, write-through, no-allocate, byte
enables, snoop invalidation, the INV-before-MEM-RESP race, 2-way LRU
replacement, failed and successful store-conditionals, and a 3000-operation
randomised stress run against a golden memory model with concurrent
invalidation traffic.

---

## Roadmap

| Milestone | Content | Status |
|---|---|---|
| **M0** | Repository, simulation flow, licence | ✅ done |
| **M1** | DCU: arrays, HCL, CCL, SCL, self-checking testbench | ✅ done |
| **M2** | Snoopy bus: round-robin arbiters, Link Register, Invalidation Table | ⏳ next |
| **M3** | N-core coherent sub-system + coherence monitor (SWMR + value scoreboard) | ⏳ |
| **M4** | One PE: CV32E40P + Data-Bridge + Instruction-Bridge + ITCM | ⏳ |
| **M5** | 4-PE SoC over an AXI crossbar, plus a non-coherent baseline variant | ⏳ |
| **M6** | Bare-metal kernels: memcpy, matrix multiply, 2-D convolution, FFT | ⏳ |
| **M7** | Evaluation: reproduce the paper's latency, execution-time and hit-rate figures | ⏳ |
| **M8** | Vivado synthesis and implementation, resource and power breakdown | ⏳ |
| **M9** | Documentation, annotated waveforms, results write-up | ⏳ |

---

## Deviations from the paper

Recorded honestly as they arise; see `docs/architecture.md` for the full list.

* The paper's base platform (its reference [18], a modular memory system for
  RISC-V MPSoCs) is not public, so the Data-Bridge, Instruction-Bridge and ITCM
  are reimplemented from the description in Fig. 1 and Fig. 2c.
* The Status-RAM (valid bits) and the LRU table are flip-flop arrays rather than
  RAM macros. They are small, and this removes a stale-valid-bit hazard between
  the two pipeline stages.
* CV32E40P does not implement the A extension, so `lr.w` / `sc.w` cannot be
  issued by the core directly. The Link Register and exclusive-bit hardware is
  built and verified as specified; how software reaches it is decided at M4 and
  will be documented rather than quietly dropped.
* The paper targets an AMD/Xilinx Virtex UltraScale+ XCVU9P at 60 MHz. This work
  targets the Zynq UltraScale+ **XCZU7EV** on a ZCU104, so absolute resource and
  frequency numbers are directional rather than a like-for-like comparison.

---

## Licence

MIT — see [LICENSE](LICENSE).

This is an independent reimplementation for research and educational purposes.
All credit for the architecture belongs to the original authors at TU Dresden,
Chair of Adaptive Dynamic Systems.
