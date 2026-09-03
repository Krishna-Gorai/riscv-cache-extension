# Hit-speculative coherence bypass: design note

Target: DATE 2027. Abstract 13 Sep 2026, full paper 20 Sep 2026.

## Why

Our own measurement, not an assumption. `results/memlat.csv`:

| kernel | MemLat 2 | MemLat 8 | MemLat 20 |
|---|---|---|---|
| memcpy 16 KiB | **0.975x** | 1.509x | 2.285x |
| conv2d 64² | 1.852x | 4.133x | 7.941x |

At a shared-memory latency of two cycles the coherent data cache makes memcpy
**slower than having no cache at all**. The DCU charges a fixed toll on every
access — a second pipeline stage, and an arbitration round on the snoopy bus —
for a benefit that only materialises when there is reuse to capture and latency
to hide. Where a kernel streams, there is neither, and the toll is all that is
left.

The original design has no way to decline that toll. It is a cache, always.

## The design changed once, on evidence

The first proposal was a streaming mode: no snoop, no allocation, and
word-granularity reads for phases with no reuse. The measurements killed the
third part of it and redirected the rest.

The non-coherent baseline already *is* word-granularity streaming with no snoop,
so it bounds what such a mode could return. Against the coherent build on
memcpy it takes 20,493 cycles at MemLat 2 but 40,975 at 8 and 90,129 at 20,
against the cache's 21,010 / 27,151 / 39,439. Word reads win only at the lowest
latency and lose by better than two to one above it, because the line fill
amortises one memory latency across four words. A streaming mode built that way
would be the wrong design nearly everywhere.

Looking for where the time actually goes produced a better answer.

## What we build

`snp_req_o` is asserted for every core read, and stage 1 stalls on `snp_gnt_i`
until the snoopy bus grants it. It has to: the hit is not known until stage 2,
so stage 1 arbitrates before it can know whether it needed to. **Every read
therefore arbitrates for a shared, one-grant-per-cycle resource, including a
read that will hit in its own cache.** At conv2d's 96.25 % hit rate, 96 % of
those arbitrations buy nothing.

So: **hit-speculative coherence bypass.** A read presumes it will hit and takes
no bus transaction. Only on a miss does it arbitrate, in stage 2, before going
to memory.

Everything else is untouched: writes still broadcast an invalidation,
load-reserved still takes the bus to allocate the Link Register,
store-conditional is unchanged, and remote invalidations are still processed.

## Why it is correct

This is the part a reviewer will attack, so it is an argument rather than an
assertion.

The snoopy-bus READ REQ does two jobs. It screens the address against the
Invalidation Table, so the DCU does not install a line that another PE is in the
act of invalidating; and it allocates the Link Register for a load-reserved.

**Both jobs concern allocation, not lookup.** A read that hits returns a line
already resident, and that line is coherent for the reason it always was: remote
invalidations are still processed, and local writes still update it. Nothing
about a hit can install a stale copy, because a hit installs nothing.

So the screening is still performed on exactly the accesses that need it — the
misses, which are the accesses that allocate. It happens one stage later than
before, which is sound because a miss has not yet done anything observable when
it arbitrates.

Load-reserved is excluded and always takes the bus, because its bus transaction
exists to allocate the Link Register rather than to screen an address.

Writes are untouched. A write must broadcast an invalidation whether or not it
hits, because another PE may hold the line.

## What is saved, and what is not

Reads that hit save one arbitration round on a shared resource. Reads that miss
save nothing and pay a little: the arbitration they would have done in stage 1
now happens in stage 2, so a miss is a cycle or so later than before. The design
is therefore a bet on the hit rate, and the paper must report where the bet
loses as well as where it wins.

Writes save nothing at all, and the paper should say so plainly rather than
implying a uniform win.

The second-order effect is the more interesting one. The snoopy bus grants one
request per cycle across the whole cluster, so arbitrations a PE does not
perform are arbitrations every other PE does not queue behind. Removing roughly
96 % of read arbitrations from a high-hit-rate PE returns time to its
neighbours, including neighbours whose own hit rate is poor.

## The design was built, measured, and is wrong

Implemented behind a `SpecHit` parameter, run, and reverted. Both halves of the
premise turned out to be false, and the RTL found it in an afternoon.

**It does not help.** conv2d, four PEs, coherent:

| | cycles | snoop stall |
|---|---|---|
| baseline, MemLat 2 | 168,177 | 20,848 |
| speculative, MemLat 2 | 168,937 | 21,894 |
| baseline, MemLat 20 | 202,825 | 86,415 |
| speculative, MemLat 20 | 203,353 | 87,123 |

Slower at both latencies, with *more* stall, not less.

`snoopy_bus.sv` says why, and it was written down all along:

> Plain READ REQs are not arbitrated against each other -- multiple readers may
> proceed in the same cycle, which is the "Multiple-Readers" half of the MRSW
> invariant. A READ REQ is withheld while any other core has an INV REQ
> outstanding for the same line, which is the "Single-Writer" half.

Reads were never queuing for a grant, so there was no arbitration cost to
remove. The premise that every read pays an arbitration round was simply untrue
of this bus.

**And it is not correct.** The screening a READ REQ passes is not about
allocation. It is the single-writer half of MRSW: it stops a reader observing a
line while another core is in the middle of writing it. A read that hits a
resident line while a remote invalidation for that line is outstanding would
return stale data. The argument in the section above -- that a hit installs
nothing and so needs no screening -- confuses *what the read does to the cache*
with *what the bus is protecting*. The bus is protecting the read itself.

The eleven functional checks passed, which is worth recording: the race window
is narrow and a passing test said nothing about it. The measurement is what
prompted re-reading the bus, and the bus is what exposed the bug.

## What is actually there to win

The stall the counters report is therefore not queuing overhead that a cleverer
design could remove. It is genuine coherence conflict -- readers waiting on
writers, which is the invariant doing its job.

That reframes the opportunity a third time. Conflicts can still be reduced, but
only by having fewer of them, and the obvious lever is granularity: an
invalidation covers a whole 16-byte line, so two PEs touching different words of
one line conflict without sharing anything. Whether that false sharing accounts
for a meaningful share of the measured stall is a question the counters cannot
answer yet, and is the next thing to measure rather than the next thing to
build.

## Risks

- **The deadlock argument changes.** The existing stage-1 hold slot and
  preemption logic exists so that a DCU stalled on its own grant can still
  accept an incoming invalidation, which the bus withholds grants behind. Moving
  read arbitration to stage 2 changes those invariants, and they are the most
  delicate part of the design. This is the main implementation risk.
- **A low-hit-rate phase pays and gains nothing**, because every miss now
  arbitrates a stage later. A reuse predictor could gate the speculation, but
  that is a second mechanism and only worth adding if measurement says the loss
  is real.
- **Load-reserved ordering.** LR still arbitrates in stage 1 while ordinary
  reads no longer do, so two accesses from the same PE can reach the bus in a
  different order than they left the core. Whether that is observable needs
  checking against the Link Register semantics.

## Plan

| day | |
|---|---|
| 1-3 | RTL: move read arbitration to stage 2, preserve the deadlock invariants |
| 4-5 | Verification: the version-monotonicity checker must stay green, plus a bus-ordering stress case |
| 6-7 | Evaluation: both sweeps, plus a mixed workload where some PEs stream and others reuse |
| 8 | FPGA: area and timing cost of the change |
| 9-14 | Paper |
| 15-19 | Buffer, polish, internal review |

The mixed workload is the experiment that carries the contention claim, and it
does not exist yet -- no current kernel runs different code on different PEs.

Abstract registration on 13 Sep needs only a title and abstract, and is worth
doing whatever happens to the schedule.
