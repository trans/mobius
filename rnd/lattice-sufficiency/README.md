---
title: Lattice sufficiency (Context Tree Weighting over masked patterns)
kind: experiment
status: running
outcome: negative
question: >-
  If each masked pattern consistent with the history is weighted by the
  posterior probability that refining it further would not change the
  prediction for this history, a Bayesian extension of Context Tree Weighting
  from suffixes to the masked lattice, does a training-free lattice model reach
  Kneser–Ney?
answer: >-
  Not yet. On every 10th development byte (10,039 bytes, paired standard errors),
  suffixes only trail Kneser–Ney by 0.095 ± 0.012 bits and the masked lattice by
  0.188 ± 0.014. The cause is the prior: every refinement must learn a fresh
  distribution centered on plain byte frequency, which with 65 symbols costs
  hundreds of bits, so the posterior stops at about 3 positions where Kneser–Ney
  uses 5.65. The fix is a prior centered on the parent pattern's distribution.
opened: 2026-10-05
updated: 2026-10-05
code: uncommitted (src/mobius/sufficiency.cr, src/mobius/lattice_search.cr)
eval: every 100th (and every 10th) development byte; every 100th test byte; Kneser–Ney on the same bytes
tags: [lattice, masks, bayesian, ctw]
related: [lattice-self-weights, kneser-ney-baseline]
---

# Lattice sufficiency

## Idea

Weight should measure relevance to this history, not internal consistency
(see [lattice-self-weights](../lattice-self-weights/)). Starting from the empty
pattern, keep asking: given what this pattern already fixes, does the history's
own byte at some other offset change what comes next?

- Refining by offset o compares two groups of the pattern's matches: those that
  agree with the history at o and those that don't. If they continue
  differently, weight moves into the agreeing group. If they continue alike,
  Occam's razor keeps the weight at the simpler pattern.
- Doing this for every offset at every pattern sends the weight through the
  lattice toward the refinements that matter for this history. A pattern's
  final weight is the probability that refinement stops there.

This is Context Tree Weighting's calculation (Willems, Shtarkov and Tjalkens,
1995), generalized from "add the next older byte" to "add any offset".

## Method

- **Models** are refinement paths from the empty pattern. At pattern S with
  matches D_S, a model stops (probability `stop` = ½) and predicts from D_S, or
  refines by a supported offset o chosen uniformly: matches agreeing with the
  history at o continue down the path, and the disagreeing ones are explained by
  an estimate of their own. A pattern with no supported refinement always stops.
- **Estimates** use a Dirichlet prior with mean P₀ (training byte frequencies)
  and β pseudo-counts (`prior`):
  P(D) = Γ(β)/Γ(n + β) · Π Γ(c_x + βP₀(x))/Γ(βP₀(x)), and
  P(x | D) = (c_x + βP₀(x))/(n + β).
- **Weights** are posterior probabilities that the path ends at each pattern,
  computed bottom-up (weighted probabilities) and top-down (path probabilities)
  over the supported patterns. The prediction is the weighted average of the
  patterns' estimates.
- **Ablation:** with `suffixes`, a pattern may only be refined by the next older
  offset, so the patterns are contiguous suffixes: CTW along the current context.

Code: [`src/mobius/sufficiency.cr`](../../src/mobius/sufficiency.cr). Specs
check the weights against explicit enumeration of every refinement path (with
likelihoods computed as sequential predictive products, not the closed form),
for both the full lattice and suffixes only.

## How to run

```sh
bin/mobius sufficiency ~/Projects/agpt/data/input.txt
bin/mobius sufficiency ~/Projects/agpt/data/input.txt suffixes
bin/mobius sufficient ~/Projects/agpt/data/input.txt 'the King of '
```

## Results

### 2026-10-05: every 100th byte

Development (1,004 bytes; Kneser–Ney on the same bytes 2.2229):

| Support | Prior β | Masked lattice | Suffixes only |
| --- | ---: | ---: | ---: |
| 2 | 0.5 | 2.3962 | 2.3384 |
| 2 | 2.0 | 2.3724 | **2.3054** |
| 2 | 8.0 | 2.4018 | 2.3335 |
| 10 | 0.5 | 2.4574 | 2.3834 |
| 10 | 2.0 | 2.4247 | 2.3445 |
| 10 | 8.0 | 2.4330 | 2.3583 |

Test (1,116 bytes, support 2, β = 2; Kneser–Ney 2.1302): masked 2.3945,
suffixes only 2.2656. About 38 ms per byte masked, 4 ms suffixes only.

For `the King of `, the weight concentrates on `K*** of ` (0.39; 13 matches:
`E` 4, `F` 2, `k` 2) and ` of ` (0.36). The `KING RICHARD` headings that
dominated the self-prediction weights are gone, and `E` is the top prediction
(0.15).

**Reading.** The gap to Kneser–Ney appears with suffixes alone, Kneser–Ney's own
contexts, so it lies in the estimator: each pattern leans toward plain byte
frequency rather than toward its parent's distribution, and patterns seen once
are excluded. Allowing masks spreads the refinement prior over about 16 offsets
at every step and did worse. Caution: about 1,000 bytes per number gives a
standard error of several hundredths of a bit; see the paired comparison below.

### 2026-10-05: paired comparison on every 10th byte

10,039 development bytes, support and prior as chosen above (β = 2):

| Model | Mean bits/byte | Difference | Paired SE |
| --- | ---: | ---: | ---: |
| Kneser–Ney | 2.1754 | | |
| Suffixes only, support 2 | 2.2704 | +0.0951 vs KN | 0.0115 |
| Suffixes only, support 1 | 2.2653 | +0.0899 vs KN | 0.0113 |
| Masked, support 2 | 2.3628 | +0.1875 vs KN | 0.0139 |
| Masked − suffixes (support 2) | | +0.0924 | 0.0115 |
| Support 1 − support 2 (suffixes) | | −0.0051 | 0.0019 |

All differences are many standard errors from zero. Neighboring bytes are
correlated, so the true errors are somewhat larger; the conclusions do not
depend on that.

### 2026-10-05: why it trails Kneser–Ney — the posterior stops too early

Average number of specified positions in the patterns the weight lands on, on
every 50th development byte (2,008 bytes):

| Model | Depth |
| --- | ---: |
| Kneser–Ney, longest context seen (cap 6) | 5.65 |
| Sufficiency, suffixes only | 3.19 |
| Sufficiency, masked | 3.78 |

At the 1,605 bytes where Kneser–Ney has a full 6-byte context, the suffixes-only
model stops at 3.29 on average. An independent audit found the same: median top
weight 1.0, more than 0.9 of the weight on one pattern at 83% of positions,
mean depth 3.2 against an available 7.1, typical support about 600 at the
stopping pattern. For `…yonder window b` all the weight sits on ` b`.

**Cause.** When a pattern is refined, the matches that disagree with the
history, and the refined pattern itself, each get a fresh Dirichlet estimate
centered on plain byte frequency. Learning a 65-symbol distribution from
scratch costs on the order of hundreds of bits, so a pattern with thousands of
matches can only be refined if its small agreeing subgroup saves more than
that, which it rarely can. Kneser–Ney's contexts are in the candidate set, but
the weighting stops before reaching them.

**Also.** Suffixes-only mode is not exact Context Tree Weighting: CTW splits a
context's data among every child, while this model lumps all disagreeing
matches into one estimate.

**Next.** Center every estimate on its parent pattern's distribution (a
hierarchical prior, the construction behind Kneser–Ney's interpolation), so
refining costs bits only in proportion to how much the child actually differs.
