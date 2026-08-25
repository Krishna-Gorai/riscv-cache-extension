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

### Processing Element

An **unmodified CV32E40P** (pinned git submodule) with a private ITCM, an
Instruction-Bridge and a Data-Bridge. The core issues ordinary loads and stores
and never learns that a coherent cache is underneath it — that is the whole
point of the paper's "seamless" claim.

| Top nibble | Region |
|---|---|
| `0x0` | local ITCM — instruction fetch, and data writes that load code |
| `0x1` | coherent shared data memory — through the private DCU |
| `0x2` | shared instruction memory — non-coherent, across the AXI crossbar |
| `0x8` | uncached control region — simulation exit handshake and console |

### AXI4 crossbar

The PEs meet the shared memories in a real AXI4 fabric, which Table I of the
paper lists as its own resource line. Each PE presents three masters -- the
Instruction-Bridge's fetch port, the DCU's memory port, and the Data-Bridge's
external port -- onto three slaves: the shared data memory, the shared
instruction memory, and the control region.

AXI4 rather than AXI4-Lite is the point: a DCU line fill is one **INCR burst**
of `LineBytes/4` beats, so a miss pays for one arbitration and one address
phase instead of four. Write-through goes the other way as a single beat whose
`WSTRB` carries the byte enables. `AxCACHE`, `AxPROT`, `AxQOS`, `AxREGION`,
`AxLOCK` and WRAP/FIXED bursts are deliberately not implemented: nothing here
uses them, and they would inflate the figure Table I is compared against.

Masters carry no ID of their own -- the crossbar tags each transaction with the
master index and routes the response back by it. A master may have several
transactions in flight but only to one slave at a time, which is what keeps its
responses ordered without a reorder buffer. An address matching no slave is
answered with `DECERR` rather than left to hang.

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
  cache/dcu_bypass.sv      the non-coherent baseline: a PE with no data cache
  snoop/                   snoopy bus: arbiters, link register, inv. table
  pe/                      data bridge, instruction bridge, ITCM, PE top
  axi/axi_xbar.sv          the AXI4 crossbar of Fig. 1
  axi/axi_sram.sv          AXI4 slave wrapping a memory array
  axi/axi_ctrl.sv          uncached control region + the hardware barrier
  axi/axi_master_simple.sv single-beat port to AXI4 master
  axi/axi_master_dcu.sv    cache memory port to AXI4: line fill as one burst
  soc/coherent_subsystem.sv  NumCores DCUs + the snoopy bus
  soc/soc_top.sv           the 4-PE SoC, coherent or non-coherent
tb/
  models/mem_model.sv      shared data memory model with latency + backpressure
  models/core_stub.sv      core-shaped stand-in, for simulator-independent tests
  unit/tb_dcu.sv           self-checking DCU testbench
  unit/tb_axi.sv           self-checking tests for the AXI4 fabric
  system/                  multi-core coherence and SoC testbenches
sw/kernels/                single-PE bare-metal kernels
sw/soc_kernels/            multi-PE bare-metal kernels
fpga/                      Vivado synthesis and implementation scripts
sim/run_xsim.ps1           compile + run any testbench with Vivado xsim
sim/run_iverilog.sh        run the simulator-independent subset with Icarus
docs/                      architecture notes, protocol description, results
```

---

## Running the simulations

Requires Vivado (tested with **2025.1**); adjust the path if yours differs.

```powershell
powershell -File sim/run_xsim.ps1 -Tb tb_dcu
# add -Wave to log all signals for waveform inspection
```

```powershell
powershell -File sim/run_xsim.ps1 -Tb tb_coherent_subsystem
# add -Plusargs TRACE_BUS to print every bus request, grant and broadcast

powershell -File sim/run_xsim.ps1 -Tb tb_pe -Hex sw/build/smoke.hex
```

The 4-PE SoC, in both of the architectures Section IV-A compares:

```powershell
powershell -File sim/run_xsim.ps1 -Tb tb_soc    -Hex sw/build/soc_par_smoke.hex
powershell -File sim/run_xsim.ps1 -Tb tb_soc_nc -Hex sw/build/soc_par_smoke.hex
```

### The AXI fabric on its own

```bash
sim/run_iverilog.sh tb_axi       # crossbar, slaves and both master adapters
```

### Without Vivado

Three testbenches avoid the constructs Icarus Verilog does not implement, so
the SoC and its coherence behaviour can be checked with an open-source
toolchain alone:

```bash
sim/run_iverilog.sh                # tb_soc_mem, tb_soc_stub_nc, tb_soc_stub
```

`tb_soc_stub` builds the complete SoC with `tb/models/core_stub.sv` compiled in
place of the CV32E40P. The stub is not a RISC-V core: it drives the data port
through the same phase pattern as the compiled kernel, so the integration and
the coherence result are exercised without a simulator that can elaborate the
real core. `tb_dcu`, `tb_coherent_subsystem`, `tb_pe` and `tb_soc` still need
xsim.

Clone with the submodule, since `tb_pe` needs the core:

```
git clone --recursive https://github.com/Krishna-Gorai/riscv-cache-extension
```

Rebuilding the bare-metal kernels needs a RISC-V toolchain (tested with the
xPack `riscv-none-elf-gcc` 15.2.0); prebuilt `.hex` images are committed so the
simulations run without one.

```bash
cd sw && ./build.sh                     # or: make, if you have it
TOOLCHAIN=/path/to/bin ./build.sh       # to point at your own toolchain
```

Current results:

```
 xsim (reference simulator)
   tb_dcu                 PASSED  (2544 checks)
   tb_coherent_subsystem  PASSED  (3103 checks)
   tb_pe                  PASSED  (5 checks)
   tb_soc                 not yet run
   tb_soc_nc              not yet run

 Icarus Verilog (no Vivado needed)
   tb_axi                 PASSED  (31 checks)
   tb_soc_stub*           do not complete under Icarus -- see below
```

**What is and is not verified.** `tb_axi` exercises the AXI4 fabric on its
own: single reads and writes through the crossbar, a cache line fetched as one
four-beat INCR burst with the lanes in the right order, byte-strobed
write-through, the control region and its hardware barrier over AXI, two
masters contending for one slave, and an address no slave claims -- which must
come back `DECERR` and leave the fabric usable afterwards. That is the M5b
deliverable and it is green.

**The SoC as a whole is not verified.** Every `tb_soc*` build needs a simulator
this machine currently lacks:

* `tb_soc` / `tb_soc_nc` instantiate the real CV32E40P, which Icarus cannot
  elaborate. They need xsim.
* `tb_soc_stub*` replace the core with `tb/models/core_stub.sv` to get around
  that, and they did pass before the crossbar landed. With the crossbar they
  stop advancing simulation time once the PEs begin shared-memory traffic --
  cycle 136 at 2 PEs, cycle 6 at 4. Time stopping rather than slowing means a
  zero-delay loop.

Three such loops were found and fixed in the crossbar while building M5b:
`always_comb` blocks that wrote a vector both at a loop index and at an index
carried in a signal. That is a read-modify-write of the whole vector, which
puts the block into its own sensitivity list, so it re-triggers on its own
writes and never settles. There is likely one more of that family in the SoC
path. It has not been located, and whether it is a design defect or an
Icarus-specific artefact is genuinely unresolved -- the coherent SoC stalled
the same way *before* the crossbar existed. Recorded as open rather than
guessed at.

`tb_dcu` covers compulsory misses, hits, write-through, no-allocate, byte
enables, snoop invalidation, the INV-before-MEM-RESP race, 2-way LRU
replacement, failed and successful store-conditionals, and a 3000-operation
randomised stress run against a golden memory model with concurrent
invalidation traffic.

`tb_coherent_subsystem` runs four DCUs on one snoopy bus against a shared
memory model: a producer/consumer ping-pong, the Link Register and
store-conditional semantics of Fig. 4, a randomised four-core stress checked
with a **version monotonicity invariant** (a core that has observed version *k*
of a location may never afterwards observe a version below *k*), and a final
quiesce in which every core re-reads the whole window so that any line left
stale in any cache is caught against the shared memory content.

`tb_pe` boots a real compiled program on the CV32E40P out of its ITCM. The
kernel fills an array in the coherent shared data memory and sums it twice:

```
smoke: sum=12224
 cycles         = 2092
 DCU  rd_hit=112 rd_miss=16 wr_hit=0 wr_miss=66
 read  hit rate = 87.50 %  (112 of 128)
 write hit rate = 0.00 %   (0 of 66)
 average        = 57.73 %  (112 of 194)
```

The split is reported the way Fig. 7 of the paper does. Reads hit 87.5 % — 16
compulsory line fills serve 128 reads — while every store misses, because
**write-through/no-allocate never installs a line on a write**. A kernel that
stores into data it has already read shows a non-zero write hit rate.

---

## Roadmap

| Milestone | Content | Status |
|---|---|---|
| **M0** | Repository, simulation flow, licence | ✅ done |
| **M1** | DCU: arrays, HCL, CCL, SCL, self-checking testbench | ✅ done |
| **M2** | Snoopy bus: round-robin arbiters, Link Register, Invalidation Table | ✅ done |
| **M3** | 4-core coherent sub-system + version-monotonicity coherence checker | ✅ done |
| **M4** | One PE: CV32E40P + Data-Bridge + Instruction-Bridge + ITCM | ✅ done |
| **M5** | 4-PE SoC: shared boot/data memories, control region, non-coherent baseline | 🟡 built; baseline verified, coherent build awaiting xsim |
| **M5b** | AXI4 crossbar in place of the direct arbiters, for the Table I breakdown | 🟡 fabric built and verified; SoC integration unverified |
| **M6** | Bare-metal kernels: memcpy, matrix multiply, 2-D convolution, FFT | ⏳ |
| **M7** | Evaluation: reproduce the paper's latency, execution-time and hit-rate figures | ⏳ |
| **M8** | Vivado synthesis and implementation, resource and power breakdown | ⏳ |
| **M9** | Documentation, annotated waveforms, results write-up | ⏳ |

---

## Protocol issues found while building this

Five real bugs the verification caught, all documented in
`docs/architecture.md`:

1. **Shared array read port vs. a stalled stage 2.** The Tag-RAM and Data-RAM
   read address is driven by stage 1, so while stage 2 stalled on a miss,
   stage 1's different index replaced the data stage 2 was still evaluating.
   Every hit decision taken after a stall used the wrong set.
2. **The MRSW lock was released too early.** Releasing it when the INV REQ is
   *granted* is not enough: a remote read granted in the window before the
   writer's write-through actually reaches memory fetches the pre-write value
   and caches it, and no further invalidation is ever sent for it. The lock has
   to be held until the write lands, so the DCU now exports a write-in-flight
   signal that the bus screens against.
3. **A failed store-conditional released another core's reservation.** There is
   a single Link Register for the whole cluster, so an SC may only consume the
   reservation if it is the one that owns it.
4. **The non-coherent baseline never withdrew a granted request.** `dcu_bypass`
   held `mem_rd_req` asserted from issue until the response arrived, so the
   memory re-granted the same still-asserted request on later cycles and the
   surplus reads returned their data into whatever transaction was outstanding
   by then. It showed up as checksums that were wrong in *both* directions in a
   system with only one copy of the data, which is what ruled out coherence and
   pointed at the request handshake. A request must be dropped on grant, not on
   response -- the DCU proper had always done this, the baseline had not.
5. **`always_comb` blocks that re-triggered on their own writes.** Three blocks
   in the crossbar wrote a vector twice: once at the loop index, and once at an
   index carried in a signal (`m_arready_o[ar_gnt_mst[s]]`). A bit-write through
   a variable index is a read-modify-write of the whole vector, which puts the
   vector in the block's own sensitivity list, so the block schedules itself
   forever and simulation time stops. Each was fixed by moving the selection
   into a per-master or per-slave generate block that assigns only local
   scalars. Worth knowing about: it presents as a hang with no error message,
   and the fix is structural rather than a matter of logic.

A fourth, subtler one was a language trap rather than a protocol flaw: a helper
function that read a module port directly instead of taking it as an argument
did not put that port into the sensitivity list of a continuous assignment, so
every invalidation was broadcast with a stale address.

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
  built and verified as specified by `tb_coherent_subsystem`, but no core in
  this SoC can reach it. Multi-PE software therefore synchronises through a
  hardware barrier in the uncached control region, which counts arrivals one
  per cycle behind its arbiter and so is atomic by construction. The paper's
  LR/SC path implies CV32E40X and its eXtension interface.
* The paper's PEs boot from the shared instruction memory. They do so here too,
  but each PE then copies its code into its private ITCM and jumps there --
  the "instructions transfer from the shared instruction memory to the ITCM
  (write-mode)" the paper gives the Data-Bridge. Without that transfer four
  cores would spend most of their cycles arbitrating for instructions, and the
  data-cache comparison would be measuring the wrong bottleneck.
* The AXI4 subset implements AW/W/B/AR/R with INCR bursts, WSTRB and ID-based
  response routing, and leaves out `AxCACHE`, `AxPROT`, `AxQOS`, `AxREGION`,
  `AxLOCK`, `AxSIZE` and WRAP/FIXED bursts. Nothing in this SoC issues them, and
  implementing them would add logic to the very number Table I is compared
  against. A master may have several transactions outstanding but only to one
  slave at a time.
* Each PE presents three AXI masters. The paper's Fig. 1 implies two, one per
  bridge; folding the Instruction-Bridge's fetch port and the DCU's memory port
  together would need an extra arbiter inside the PE, and the crossbar is
  parameterised in master count either way. This is a difference to note when
  the crossbar's own resource line is compared with Table I.
* The paper targets an AMD/Xilinx Virtex UltraScale+ XCVU9P at 60 MHz. This work
  targets the Zynq UltraScale+ **XCZU7EV** on a ZCU104, so absolute resource and
  frequency numbers are directional rather than a like-for-like comparison.

---

## Licence

MIT — see [LICENSE](LICENSE).

This is an independent reimplementation for research and educational purposes.
All credit for the architecture belongs to the original authors at TU Dresden,
Chair of Adaptive Dynamic Systems.
