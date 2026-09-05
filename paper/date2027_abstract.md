# DATE 2027 — title and abstract

Registration deadline: 13 September 2026 AoE. Needs title, abstract, co-authors.
Full paper 20 September 2026 AoE (firm).

**Authors:** Krishna Gorai, Bikram Paul — Indian Institute of Technology Mandi

---

## Title

> **An Exact Snoop Filter for Seamless Cache Coherence in FPGA-Based
> Multi-Core RISC-V**

"Exact" is the technical differentiator and is doing real work in the title: the
filter is a structural mirror of the caches' tag arrays, not a conservative
hashed approximation, which is what makes the correctness argument trivial and
what a reviewer will look for first. The title also reads as an architecture
contribution rather than a measurement study, which matters here because the
reproduction is the motivation and not the claim.

Considered and set aside: a measurement-first title (*How Much Coherence Traffic
Is Useless?*) and a colon hook (*Private Data, Cluster-Wide Broadcasts*). Both
foreground the finding at the cost of foregrounding the mechanism.

---

## Abstract (198 words)

Attaching a private, snoop-coherent L1 data cache to an unmodified RISC-V core
is an attractive way to build FPGA multi-core systems, and a recently proposed
design does so with coherence handled entirely in hardware. We reproduce that
design in open-source RTL and measure where its time actually goes.

Across four benchmark kernels the cluster issues 1,048,821 invalidation
broadcasts and not one of them invalidates a line in another cache. Every kernel
partitions its data per processing element, so every written line is private,
yet each write still pays a cluster-wide arbitration and a handshake that waits
on every other cache. That accounts for between 6 and 33 percent of a core's
execution time, and on a streaming kernel it makes the cache extension slower
than having no cache at all.

We add a snoop filter that keeps an exact mirror of the caches' tag arrays and
suppresses a broadcast when no other cache holds the line. It costs 1,006 LUTs
and 519 flip-flops, preserves coherence under a version-monotonicity checker,
and is worth a geometric mean 1.12x, up to 1.22x on matrix multiplication. It
also converts the streaming kernel from 0.98x to 1.10x against an uncached
baseline. We report the frequency it costs, and evaluate at the original
design's own 60 MHz operating point.

---

## Notes for the full paper

The last sentence of the abstract is doing deliberate work. The filter costs
frequency -- the unfiltered design reaches 83 MHz and the filtered one 63 -- so
the speedup is real at a fixed clock and vanishes if the baseline is allowed to
clock freely. Stating that in the abstract rather than burying it is both
honest and pre-empts the first reviewer objection.

The three rejected designs (streaming mode, hit-speculative bypass, and the two
failed structural fixes to the mirror) belong in the paper as a short section.
One of them was not merely useless but incorrect while passing its functional
tests, which is worth reporting in a venue that cares about verification.
