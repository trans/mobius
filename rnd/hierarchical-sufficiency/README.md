---
title: Lattice sufficiency with parent-centered priors
kind: experiment
status: concluded
outcome: mixed
question: >-
  If each pattern's distribution is expected to resemble its parent's (the
  pattern without its farthest offset) instead of plain byte frequency, does
  the sufficiency posterior refine as deeply as Kneser–Ney's context, and does
  the model then reach Kneser–Ney, with suffixes only and with masks?
answer: >-
  Partly. Parent-centered priors fix the depth (5.56 against Kneser–Ney's 5.65)
  and narrow the gap with suffixes only to +0.060 ± 0.010 bits (β = 32), but
  masks remain 0.094 bits worse than suffixes only.
opened: 2026-10-05
updated: 2026-10-05
code: cooccur-kn-baseline
eval: every 10th development byte, Kneser–Ney on the same bytes, paired standard errors
tags: [lattice, masks, bayesian, hierarchical]
related: [lattice-sufficiency, kneser-ney-baseline]
---

# Lattice sufficiency with parent-centered priors

## Idea

[lattice-sufficiency](../lattice-sufficiency/) stops refining at about 3
positions, where Kneser–Ney uses 5.65. Every refinement had to learn a fresh
65-symbol distribution centered on plain byte frequency, which costs hundreds of
bits, so a pattern with thousands of matches could almost never be refined.

Here each pattern's distribution is expected to resemble its parent's. The
parent of S is S without its farthest offset, so for suffixes it is the next
shorter suffix, as in Kneser–Ney's interpolation. A refinement then pays only
for how much the refined pattern actually differs from the pattern it came
from.

## Method

Same refinement paths and posterior as lattice-sufficiency, with these
changes:

- **Estimates.** P̂_∅ = (c_∅ + β·P₀)/(n_∅ + β), and for every other pattern
  P̂_S = (c_S + β·P̂_parent(S))/(n_S + β), where parent(S) is S without its
  farthest offset. Each estimate is a Dirichlet posterior mean whose prior mean
  is the parent's estimate.
- **Stopping at S** explains S's matches with a Dirichlet of concentration β
  centered on P̂_parent(S).
- **Refining S by o** explains the matches that disagree with the history at o
  the same way (centered on P̂_parent(S)), and the agreeing matches continue down
  the path as the pattern S ∪ {o}, centered on its own parent's estimate.
- The prediction averages the leaves' P̂_S by their posterior weights.
- Patterns seen once are allowed (support 1), as the paired comparison favored.

## How to run

```sh
bin/mobius sufficiency ~/Projects/agpt/data/input.txt hierarchical suffixes support=1 prior=1,4,16 stride=10
bin/mobius sufficiency ~/Projects/agpt/data/input.txt hierarchical support=1 prior=4 stride=10
```

## Results

### 2026-10-05: suffixes only, prior strength

Every 10th development byte (10,039 bytes), support 1; Kneser–Ney on the same
bytes 2.1754. "Depth" is the weight-averaged number of positions in the
patterns the weight lands on (Kneser–Ney's longest seen context averages 5.65).

| β | Bits/byte | vs Kneser–Ney | Paired SE | Depth |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 2.3738 | +0.1985 | 0.0176 | 3.95 |
| 4 | 2.3217 | +0.1464 | 0.0150 | 4.64 |
| 16 | 2.2561 | +0.0807 | 0.0116 | 5.33 |
| **32** | **2.2354** | **+0.0601** | 0.0098 | 5.56 |
| 64 | 2.2446 | +0.0692 | 0.0090 | 5.68 |
| 128 | 2.2907 | +0.1154 | 0.0092 | 5.70 |
| 512 | 2.5001 | +0.3247 | 0.0115 | 5.53 |

The unigram-centered version scored +0.0899 on these bytes (support 1, β = 2)
and reached depth 3.19 (support 2, every 50th byte). Parent-centered priors fix the depth: the posterior now refines as
far as Kneser–Ney's context. The remaining 0.06 bits is the estimator: one
fixed β trusts every context's counts equally, while Kneser–Ney's discount ×
distinct-continuations term trusts a context with few distinct continuations
much more than one with many.

For `the King of ` the weight reaches the full 12-byte context (4 matches,
0.30 of the weight). For `…yonder window b` it stays at ` b` (0.999), because
`w b` continues like ` b` (`e`, `y`, `r`, `u`), so refining buys nothing.

### 2026-10-05: masks with parent-centered priors

Same 10,039 bytes, support 1, β = 32, all masked patterns in the 16-byte
window: **2.3290** bits per byte, +0.1537 ± 0.0131 against Kneser–Ney, depth
6.09, 61 ms per byte. Suffixes only scored 2.2354 on the same bytes, so masks
are still 0.094 bits worse. Parent-centered priors fixed the depth problem but
not the masks' cost: with about 16 possible refinements at every step, the
refinement prior is spread thin, and refinements fitted on the training plays
do not carry over.

### 2026-10-05: correction

The explanation of the remaining 0.06 bits above, that a fixed β cannot trust
contexts with few distinct continuations more, did not hold up: discounted
(Pitman–Yor) estimates were worse, not better
([discounted-sufficiency](../discounted-sufficiency/)). The likelier cause is
that Kneser–Ney backs off to continuation counts, which these estimates lack.
The reason given for the masks' cost (a thinly spread refinement prior, and
refinements that do not carry over from the training plays) is a hypothesis;
it has not been tested.
