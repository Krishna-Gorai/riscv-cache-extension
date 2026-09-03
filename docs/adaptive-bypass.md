# Reuse-aware bypass: design note

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

## What we build

A DCU that switches, per PE and at runtime, between **cached mode** (what
exists today) and **streaming mode**, and pays the coherence toll only when it
will earn it.

Streaming mode changes exactly three things, and only for ordinary reads:

1. **No snoopy-bus READ REQ.** The read goes straight to memory.
2. **No allocation.** Nothing is installed in the arrays.
3. **Word-granularity read** rather than a line fill, so a streaming kernel
   stops fetching four words to use one.

Everything else is untouched: writes, load-reserved, store-conditional, and the
handling of invalidations broadcast by other PEs all behave exactly as they do
now.

## Why it is correct

This is the part a reviewer will attack, so it is stated as an argument rather
than asserted.

The policy is write-through, so **shared memory always holds the current value
of every location**. Three consequences follow.

*A streaming-mode read is correct.* It returns memory's value, which is current
by the paragraph above. The snoopy-bus READ REQ it skips exists to screen the
address against the Invalidation Table — that is, to stop the DCU caching a line
that another PE is in the act of invalidating — and to allocate the Link
Register for a load-reserved. A read that caches nothing needs no screening, and
a load-reserved is not an ordinary read and is not bypassed.

*Streaming mode cannot create a stale copy.* It installs nothing.

*Retained lines do not go stale while the mode is streaming.* Lines installed
before the switch are still updated on a local write hit, because writes are
unchanged, and are still invalidated by remote broadcasts, because snoop
handling is unchanged.

Therefore **the mode may change at any access boundary with no flush, no drain
and no quiescence**. That is what makes the mechanism cheap enough to be worth
having, and it is a direct consequence of write-through: the same policy that
makes this class of extension attractive on an FPGA is what makes bypassing it
safe.

## What is saved, and what is not

Honestly: writes save nothing. A write must still broadcast an invalidation,
because another PE may hold the line, and it must still write through. Only
reads are bypassed, and the paper should say so plainly rather than implying a
uniform win.

For a streaming kernel the saving per read is one arbitration round, one
pipeline stage, and three quarters of the memory traffic a line fill would have
moved.

## Predicting reuse

The predictor is deliberately the least novel part of the design, and the paper
should say so. The contribution is bypass inside a seamless coherent L1 and the
argument above, not a new predictor.

Per PE: a saturating counter over a window of accesses, tracking read hit rate.
Below a low-water mark, switch to streaming; above a high-water mark, switch
back. Hysteresis between the two prevents oscillation.

One wrinkle worth stating: in streaming mode there are no lookups, so there is
no hit rate to observe, and the predictor would never switch back. The DCU
therefore **duty-cycles** — every M accesses it spends a short window in cached
mode to re-measure. The cost of probing is bounded by the duty ratio and the
benefit is that a phase change is noticed.

## Risks

- **Oscillation** around the threshold on a mixed workload. Mitigated by
  hysteresis; must be measured, not assumed.
- **Probing cost** on a workload that never wants the cache. Bounded by the
  duty ratio, but it means streaming mode is never quite as fast as the
  non-coherent baseline. That is a real limitation and belongs in the paper.
- **A kernel with spatial but not temporal reuse.** memcpy is sequential, so
  the line fill helps it even though nothing is re-read. Word-granularity reads
  give that up. Whether streaming mode actually wins on memcpy is an open
  question the evaluation has to answer, and it may be that the right streaming
  read is a line fill without allocation.

That last risk is the one that could invalidate the design, so it is measured
first.

## Plan

| | |
|---|---|
| 1-2 | RTL: mode input, streaming read path, predictor |
| 3-4 | Verification: existing coherence checker must stay green, plus mode-switch stress |
| 5-6 | Evaluation: re-run both sweeps with the adaptive DCU |
| 7 | FPGA: area and timing cost of the mechanism |
| 8-13 | Paper |
| 14-19 | Buffer, polish, internal review |

Abstract registration on 13 Sep needs only a title and abstract, and is worth
doing whatever happens to the schedule.
