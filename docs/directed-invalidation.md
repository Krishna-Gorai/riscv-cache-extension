# Directed invalidation, and the fill-in-flight race it exposed

Session of 2026-09-08. Nothing here is committed yet.

Two separable outcomes, and the smaller-looking one is the important one.
**Both are now fully measured; sections 5.1 and 5.2 are resolved and the paper's
published cycle numbers are confirmed unchanged.**

1. **A coherence bug in the snoop filter as published in `paper/date2027.tex`.**
   A mirror of the caches' committed tag arrays is not a sound basis for
   suppressing an invalidation. Fixed. This applies to the filter the paper
   already claims, independently of anything below.
2. **Directed invalidation** — exact multicast with a partial barrier — built,
   correct, and worth almost nothing in cycles. A measured negative.

---

## 1. The fill-in-flight race

### What was wrong

`snoop_filter.sv` mirrors each DCU's tag and valid arrays, and the bus
suppressed a broadcast when no other cache *held* the line. `dcu.sv` already
documents the case that breaks this, calling it "special case 2":

> An INV REQ that targets the line currently being refilled arrives before the
> MEM RESP. It is recorded as a flag; the data is then forwarded to the core
> without updating the cache line.

A DCU in `CCL_RD_WAIT` has issued a memory read and has not yet refilled the
victim way. It holds nothing for that line, so it is absent from the mirror —
and it is precisely the cache that must hear the invalidation, because receiving
one is what cancels its refill. Suppress or steer around it and it installs a
line that was invalidated while in flight.

The mirror was exact about *committed residency*. The property the bus actually
needs is **residency ∪ imminent residency**.

### How it showed up

Directed invalidation made it fire immediately, because multicast steers the
fan-out on every invalidation whereas suppression only acts when the sharer set
looks empty:

```
CHECK FAILED: S4 stale line: core3 word1154 got 04820000, memory holds 04820001
tb_coherent_subsystem FAILED (1 errors / 3118 checks)
INVUSE rx=335 useful=332          <- 13 needed invalidations never sent
```

### The fix

`dcu.sv` exports the refill window:

```systemverilog
assign fill_busy_o = (ccl_q == CCL_RD_WAIT);
assign fill_addr_o = s2_addr_q;
```

The window opens when stage 2 enters `CCL_RD_WAIT` and closes on the cycle the
MEM RESP refills the way — which is the same cycle the mirror learns the tag, so
the two halves of the answer abut exactly and the line is covered in every cycle
by one or the other.

`snoopy_bus.sv` unions the two into the sharer set, and `bcast_needed` now gates
on `any_sharer` rather than on the mirror alone, so **plain suppression is fixed
too, not just multicast**.

### Evidence that it is load-bearing

`FILLRACE` counts granted invalidations where no other cache *holds* the line but
at least one is *fetching* it — i.e. the cases a committed-tag mirror would have
got wrong. On `tb_coherent_subsystem`, default seed:

| Configuration | invalidations granted | would be wrong with committed tags alone |
|---|---|---|
| Suppression only | 211 | **1** |
| Directed | 222 | **7** |

So the published filter would violate coherence roughly **once in 211
invalidations**. It passed 3,139 checks by luck rather than by construction: the
window is narrow and no existing check was aimed at it.

**Quote the ten-seed figure, not this one.** A single seed is exactly the sample
size that makes a race look like a fluke. Section 5.2 sweeps ten interleavings
and finds 20 of 2,241 across all of them, hitting in 10/10 runs — that is the
number the paper uses.

This is the same failure mode as the hit-speculative bypass recorded in
`adaptive-bypass.md` — a green test suite saying nothing about a narrow race —
and it is the second time on this project that the sharing testbench, not the
benchmark harness, was the thing that caught it.

### Two consumers that must NOT be narrowed to the sharer set

Both are commented in `snoopy_bus.sv`, because both would pass every functional
test if narrowed and both would be wrong:

- **`read_blocked`**, the single-writer lock. It protects a reader from fetching
  the pre-write value out of shared memory, which has nothing to do with whether
  that reader caches the line — a core with no copy is precisely the one that
  would miss, go to memory, and cache a stale word.
- **`link_register.inv_set_i`**. A reservation must break whether or not the
  reserving core still has the line cached; LR takes a reservation and the line
  can be evicted under it by ordinary capacity pressure.

---

## 2. Directed invalidation

### What it does

The mirror already computed a per-core sharer vector (`held_o`) and the bus threw
it away (`.held_o ()`). Wiring it in turns the invalidation bus from broadcast
plus full barrier into **exact multicast plus partial barrier**: drive the
invalidation into only the caches that hold the line, and hold the grant on only
those.

New parameter `DirectedInv`, requiring `SnoopFilter`, threaded
`snoopy_bus` → `coherent_subsystem` → `soc_top` → `fpga_top` / `tb_bench`.

### Why exactness is what enables it

A conservative filter may over-claim sharers safely, so it can gate an
all-or-nothing broadcast. Under multicast a *missing* sharer bit drops an
invalidation that was needed. So only an exact mirror may steer the fan-out —
exactness stops being a precision/area trade-off and becomes a capability that
approximation cannot have. That argument survives; the performance case does not.

### Results — the new `bench_stencil` kernel, 32×32, 8 steps

| MemLat | Baseline | Filtered | Directed | Directed vs filtered |
|---|---|---|---|---|
| 2  | 65,587 | 64,622 | 64,444 | 1.003× |
| 8  | 70,826 | 67,526 | 67,409 | 1.002× |
| 20 | 83,191 | 74,713 | 74,663 | 1.001× |

Snoop-stall cycles, and invalidations delivered (all 168 useful in every case):

| MemLat | stall base / filt / dir | delivered base / filt / dir |
|---|---|---|
| 2  | 1,891 / 326 / 66     | 27,690 / 504 / 168 |
| 8  | 7,983 / 639 / 57     | 27,690 / 504 / 173 |
| 20 | 39,182 / 2,528 / 1,713 | 27,690 / 528 / 196 |

The mechanism does exactly what it was built to do. At MemLat 2 it reaches
**100 % precision** — 168 delivered, 168 useful — against suppression's 504,
which is exactly 3× because suppression broadcasts to all three others when one
needs it. Snoop stall falls up to 11×.

### Why it does not pay

Cycles move 0.07–0.3 %. Exact suppression has already removed the traffic that
was causing the serialisation; what remains is largely irreducible, because
somebody really does have to be told and the writer really does have to wait for
them. The ceiling is arithmetic: removing *all* of the filtered design's snoop
stall gains at most 3.4 % at MemLat 20, and directed got 0.07 % of it.

**Conclusion: once you filter exactly, the residue is not worth steering.** That
is a real finding and belongs in the paper's "What Did Not Work" section — it
closes off the obvious reviewer question "why not just multicast?" with data.

---

## 3. The stencil benchmark

`sw/soc_kernels/bench_stencil.c`, golden model in `scripts/bench_golden.py`,
wired into `sw/build_bench.sh`.

Jacobi 5-point, double buffered, grid split into row bands. PE *p* computes rows
`[lo, hi)` from rows `[lo-1, hi]`, so the two rows on each band boundary are read
by one PE and written by its neighbour: sharer set of exactly **one** of the
three other caches for a boundary line, empty for every interior line.

This is the project's first kernel with **any** useful invalidations — 168, where
matmul/conv2d/FFT/memcpy have 0 of 1,048,821 between them. Whatever happens to
directed invalidation, the paper now has a partial-sharing data point instead of
only the empty-sharer-set extreme, which directly answers the Threats to Validity
concession that the results only cover workloads with no sharing.

Double buffering is what makes the sharing recur rather than happen once: buffers
alternate, so the line PE *p* caches from buffer B at step *t*+1 is rewritten by
PE *p*−1 at step *t*+2.

32×32 is chosen against the cache, not for neatness — a PE's working set is its
band plus two halo rows, 10 rows × 128 B = 1,280 B inside a 2 KiB two-way DCU.
Widening the grid without widening the cache turns this into a capacity benchmark
and the halo lines stop being resident when the neighbour writes them, which is
the whole effect being measured.

---

## 4. Verification status

All green with the fix in place:

| Testbench | Result |
|---|---|
| `tb_dcu` | PASSED (2,542 checks) |
| `tb_axi` | PASSED (32) |
| `tb_pe` | PASSED (5) |
| `tb_soc` | PASSED (273) |
| `tb_soc_nc` | PASSED (273) |
| `tb_coherent_subsystem` + `SNOOP_FILTER` | PASSED (3,127) |
| `tb_coherent_subsystem` + `SNOOP_FILTER DIRECTED_INV` | PASSED (3,106) |
| `tb_bench` / `_sf` / `_di` on stencil, MemLat 2/8/20 | PASSED, golden matched |

Check counts vary by a few between configurations. That is expected: the S3
stress uses a fixed seed for its *values*, but grant timing differs between
designs, so the interleaving — and with it the number of checks executed —
differs. Only pass/fail is comparable across configurations.

---

## 5. OPEN — do this first next session

### 5.1 RESOLVED — the paper's cycle numbers are NOT stale

Re-measured all four headline kernels, three configurations each, twelve runs,
all passing. **Every number is identical to the paper**, and the geometric mean
comes back at 1.1222 against the published 1.122x:

| Kernel | Baseline | Filtered | Directed | vs paper |
|---|---|---|---|---|
| matmul 64^2   | 1,337,850 | 1,094,750 | 1,094,750 | match |
| memcpy 16 KiB |    21,010 |    18,708 |    18,708 | match |
| conv2d 64^2   |   168,177 |   154,382 |   154,382 | match |
| FFT N=256     |    85,093 |    80,228 |    80,228 | match |

This is the expected outcome rather than a lucky one: the four kernels share
nothing, so the fill-in-flight term almost never fires on them (`INVUSE rx=0`
for every filtered run — the filter still suppresses everything). Directed is
bit-identical to filtered throughout, which is the same statement from the other
side: with an always-empty sharer set there is nothing to steer.

The correctness fix therefore costs nothing in cycles on the published
benchmarks, and the paper's Table V stands as written.

### 5.2 RESOLVED — seed sweep, and the fill race is not a fluke

`scripts/seed_sweep.ps1` (new) runs `tb_coherent_subsystem` over N interleavings
in both filter modes and writes `results/seed_sweep.csv`. Ten seeds each:

| Mode | runs | failed | invalidations granted | would be wrong with committed tags alone | runs affected |
|---|---|---|---|---|---|
| Suppression | 10 | 0 | 2,241 | **20 (0.89%)** | **10 / 10** |
| Directed    | 10 | 0 | 2,222 | **29 (1.31%)** |  9 / 10 |

So the race is not a single lucky observation: **every one of the ten
interleavings would have lost at least one needed invalidation** without the
fill-in-flight term, and all twenty runs pass with it. That is the number the
paper now quotes (Section IV, "Exact about the wrong property").

Two scripting notes, both of which cost a run each and are worth not
rediscovering:

- `xvlog` splits `-d NAME=VALUE` at the `=` and treats the value as a filename
  (`ERROR: [XSIM 43-4316] Can not find file: 3`). This is the same parser that
  mangles `-testplusarg` paths. The sweep therefore rewrites the
  `` `define STRESS_SEED `` line in the testbench per run and restores it in a
  `finally` block.
- `Set-Content -Encoding` failed outright in this environment, and PowerShell's
  `[uint32](x) -band y` casts before it masks and overflows. The script uses
  .NET `WriteAllText` with a no-BOM encoder and a literal seed table instead.

### 5.3 RESOLVED — FPGA cost re-measured, both variants, one batch

Both variants re-implemented at 60 MHz on 2026-09-08 against the fixed RTL.

| | Reference | Filtered | Delta |
|---|---|---|---|
| LUTs | 26,781 | 27,845 | **+1,064** |
| Flip-flops | 15,154 | 15,670 | **+516** |
| BRAM / DSP | 124 / 20 | 124 / 20 | 0 |
| WNS at 60 MHz | +1.265 ns | +1.199 ns | -0.066 |
| Failing endpoints | 0 / 46,952 | 0 / 49,624 | — |

The fill-in-flight term costs **+55 LUTs** on the published +1,009, and no
measurable slack. Both configurations meet 60 MHz.

**The important lesson here is methodological, and it caught me out mid-session.**
Comparing the new filtered run against the *published* reference showed slack
falling 4.307 -> 1.199 ns, which I reported as the fix consuming 72% of the
headroom. That was wrong. Re-running the reference showed it fell too, 2.597 ->
1.265 ns, on a netlist that is functionally unchanged (26,767 -> 26,781 LUTs,
identical flip-flops). Nothing in the RTL could have caused that.

So place-and-route outcomes on this design move by **more than the effect being
measured** — a 1.7 ns spread, in the opposite direction, from netlists differing
by fourteen LUTs. Within the matched batch the filter costs 66 ps on a 16.667 ns
period.

Rules that follow, and that the paper now states:

- Quote slack only between builds implemented **in the same batch**. Never
  compare a slack figure against one from another day.
- A slack difference smaller than about 1.5 ns on this design is not evidence of
  anything.
- The published pair had the *filtered* design with 1.7 ns MORE slack than the
  reference, which should have been recognised as implausible at the time.

`results/fpga_60mhz.csv` carries the new numbers and keeps the superseded ones in
a comment so the change stays traceable.

### 5.3b OPEN — the 75 MHz pair is still old-RTL

The paper justifies evaluating at 60 MHz by citing 75 MHz builds where the
filtered design fails at -2.586 ns and the reference meets at +1.327 ns. **Those
runs predate the fix, and given a 1.3 ns cross-run swing on a 14-LUT delta, the
3.9 ns gap they report is less solid than it reads.** Re-running the pair at
75 MHz is roughly 50 minutes:

```
! vivado -mode batch -nojournal -nolog -source fpga/run_impl.tcl -tclargs filtered 13.333 sw/build/soc_bench_matmul_64.hex
! vivado -mode batch -nojournal -nolog -source fpga/run_impl.tcl -tclargs coherent 13.333 sw/build/soc_bench_matmul_64.hex
```

Also unrun: the `directed` variant at 60 MHz, which would say whether directed
invalidation costs frequency on top of buying nothing.

**Running these:** launch Vivado **detached** via `Start-Process`, not as an
agent background task — the harness kills background tasks under memory
pressure, which is how the first attempt died mid-place-and-route.
`place_design` peaks near 5 GB on this 7.8 GB host; with ~2.5 GB free the run
takes 24-40 min and swaps heavily, and with more free memory it is closer to 24.

### 5.4 Paper rewrite

Not started, deliberately — no point writing against numbers that are about to
change. The reframing to make:

- §IV "An Exact Snoop Filter" must say what the mirror is exact *about*, and that
  committed tags alone are unsound. The current text's correctness argument
  ("when the mirror reports that no other cache holds the line, no other cache
  holds it") is **wrong as written** and has to be repaired.
- Add the fill-in-flight term and the 1-in-211 measurement as a contribution.
- Add the stencil as the partial-sharing data point, and soften the Threats to
  Validity concession accordingly.
- Add directed invalidation to §VI "What Did Not Work" with the stencil table.

Paper is at 6 pages, DATE's limit, so all of that has to displace something.

### 5.5 Housekeeping

- `bench_stencil.c` and `soc_bench_stencil_32.hex` are untracked.
- The `STRESS_SEED` guard landed between a comment block and the `ifdef` it
  belongs to in `tb_coherent_subsystem.sv`; cosmetic, worth moving.
- `sim/` has a dozen scratch run directories from this session.
- Nothing committed. Last commit is `8af594d`.

---

## 6. Files touched

| File | Change |
|---|---|
| `rtl/cache/dcu.sv` | `fill_busy_o` / `fill_addr_o` exports |
| `rtl/snoop/snoopy_bus.sv` | `DirectedInv` param, `filling_line`, `sharers`, `bcast_tgt`, partial barrier, directed fan-out, `FILLRACE` counter, dead `filt_any_other` removed |
| `rtl/soc/coherent_subsystem.sv` | fill wires, `DirectedInv` threading |
| `rtl/soc/soc_top.sv`, `fpga/fpga_top.sv` | `DirectedInv` threading |
| `fpga/run_impl.tcl` | `directed` variant |
| `tb/system/tb_bench.sv` | `DirectedInv` param, `tb_bench_di{,_l8,_l20}` |
| `tb/system/tb_coherent_subsystem.sv` | `DIRECTED_INV` ifdef, `STRESS_SEED` |
| `sim/run_xsim.ps1` | `_di` variants added to the core allow-list |
| `sw/soc_kernels/bench_stencil.c` | new |
| `scripts/bench_golden.py` | `bench_stencil` model, `STENCIL_N` / `STENCIL_T` |
| `sw/build_bench.sh` | `stencil` case |

---

## 7. RESOLVED (2026-09-10) — the page limit, from the CFP

The DATE 2027 call for papers settles it:

> "Submissions must **not exceed 6 pages in length, with one extra page allowed
> only for bibliographic references**."

So the earlier panic was misplaced in one direction and not strict enough in the
other. Seven pages is fine **provided page 7 holds nothing but references** — and
the paper had been failing that, because the tail of the conclusion was sharing
page 7 with them.

Fix: `\newpage` before `\begin{thebibliography}`. That is what the allowance is
for, and it hands the whole of page 6 back to the body. **Verify with
`pdftotext -f 7 -l 7 date2027.pdf -` that the first non-blank line is
`REFERENCES`** — do not judge it by page count alone, which looks identical
either way.

### Other CFP facts worth not re-deriving

| | |
|---|---|
| Abstract registration | Sunday 13 September 2026, AoE |
| Full paper | Sunday 20 September 2026, AoE |
| Notification | Monday 23 November 2026 |
| Camera-ready | Wednesday 16 December 2026 |
| Review | **Double-blind** — no names, no acknowledgements |
| Format | A4/Letter, double column, Times or equivalent, min 10 pt |
| Type-3 fonts | Forbidden. Checked: all embedded fonts are Type 1 |
| Preprints | arXiv etc. only **after** notification |

### Two open risks, both the author's call

1. **The public repo against double-blind.** `github.com/Krishna-Gorai/...`
   carries the author's name in the URL and both papers as committed PDFs. A
   reviewer searching a distinctive phrase can find it.
2. **The preprint clause.** A code repository is not literally a preprint, but
   the repo contains the manuscripts. Making it private until 23 November
   removes both risks.

### What was cut to fit six pages

Four floats, in this order, each commented in the source with its replacement:
`tab:stall`, `fig_result`, `tab:speedup`, `tab:invuse`, then later `fig_stall`.
Nothing that was evidence is gone — only restatement. `plot_date.py` still
generates `fig_result.pdf` and `fig_stall.pdf` if a venue with a looser limit
wants them back.
