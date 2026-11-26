---
title: Lattice sufficiency with discounted (Pitman–Yor) estimates
kind: experiment
status: concluded
outcome: negative
question: >-
  With parent-centered priors the sufficiency posterior refines as deeply as
  Kneser–Ney but still trails it by 0.06 bits. If each pattern's estimate
  discounts every observed byte by a fixed amount, as Kneser–Ney does, so that
  trust in a pattern's own counts depends on how many distinct bytes followed
  it, does the lattice model reach Kneser–Ney?
answer: >-
  No. Pitman–Yor estimates and evidence score 0.10 bits worse than Kneser–Ney,
  worse than the Dirichlet version (+0.06). The real gap is continuation
  counts: Kneser–Ney without them is 0.25 bits worse on the same bytes.
opened: 2026-10-05
updated: 2026-10-05
code: cooccur-kn-baseline
eval: every 10th development byte, Kneser–Ney on the same bytes, paired standard errors
tags: [lattice, bayesian, hierarchical, pitman-yor, discounting]
related: [hierarchical-sufficiency, lattice-sufficiency, kneser-ney-baseline]
---

# Lattice sufficiency with discounted estimates

## Idea

A Dirichlet estimate with a fixed strength β trusts every pattern's counts the
same way. Kneser–Ney instead subtracts a discount D from each observed byte's
count and gives the subtracted mass, D × (number of distinct bytes seen), to
the parent. A pattern followed by only one or two distinct bytes keeps almost
all its own counts; a pattern followed by many different bytes leans heavily on
its parent.

The Pitman–Yor process is the Bayesian prior with exactly this behavior; a
hierarchy of them, with one "table" per distinct byte, reproduces interpolated
Kneser–Ney (Teh, 2006). Its marginal likelihood has a closed form, so it slots
into the sufficiency posterior in place of the Dirichlet.

## Method

For a pattern with n matches, counts c_x, d distinct bytes, and prior mean m
(the parent's estimate; plain frequency for the empty pattern), with discount D
and strength θ:

- **Estimate.**
  P̂(x) = (max(c_x − D, 0) + (θ + D·d)·m_x) / (θ + n).
  With θ = 0 this is interpolated absolute discounting.
- **Likelihood**, in any order:
  log P = Σ_{seen x} log m_x + Σ_{j=1}^{d−1} log(θ + jD)
          − log Γ(θ + n) + log Γ(θ + 1)
          + Σ_x [log Γ(c_x − D) − log Γ(1 − D)].
- Everything else as in [hierarchical-sufficiency](../hierarchical-sufficiency/):
  refinement paths, parent = the pattern without its farthest offset, stopping
  and disagreeing matches judged against the parent's estimate.

Not yet included: Kneser–Ney also replaces a parent's raw counts by
continuation counts (how many distinct contexts a byte followed). That is the
step after this one.

## How to run

```sh
bin/mobius sufficiency ~/Projects/agpt/data/input.txt hierarchical suffixes support=1 discount=0.5,0.75,0.9 prior=0 stride=10
```

## Results

### 2026-10-05: Pitman–Yor evidence and estimates

Every 10th development byte (10,039 bytes), suffixes only, support 1;
Kneser–Ney on the same bytes 2.1754:

| θ | D | Bits/byte | vs Kneser–Ney | Paired SE | Depth |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 0 | 0.50 | 2.3221 | +0.1467 | 0.0146 | 3.57 |
| 0 | 0.75 | 2.2922 | +0.1168 | 0.0133 | 3.37 |
| 0 | 0.90 | 2.3073 | +0.1319 | 0.0132 | 3.13 |
| 1 | 0.50 | 2.2896 | +0.1143 | 0.0133 | 3.49 |
| 1 | 0.75 | 2.2797 | +0.1044 | 0.0125 | 3.27 |
| 1 | 0.90 | 2.3070 | +0.1316 | 0.0127 | 3.06 |

Worse than the Dirichlet with β = 32 (+0.0601, depth 5.56). The one-table
seating likelihood makes refinement expensive again, so the posterior stops at
about 3 positions.

### 2026-10-05: Dirichlet depth decisions, Pitman–Yor estimates

A scratch diagnostic (`decoupled.cr`) kept the Dirichlet (β = 32) likelihood
for the posterior and used Pitman–Yor only for the estimates:

| Estimates | Bits/byte | vs Kneser–Ney | Paired SE | Depth |
| --- | ---: | ---: | ---: | ---: |
| Dirichlet β = 32 | 2.2354 | +0.0601 | 0.0098 | 5.56 |
| Pitman–Yor D = 0.75, θ = 1 | 2.3883 | +0.2129 | 0.0153 | 5.53 |
| Pitman–Yor D = 0.75, θ = 0 | 2.4532 | +0.2779 | 0.0167 | 5.55 |
| Pitman–Yor D = 0.9, θ = 0 | 2.4054 | +0.2301 | 0.0157 | 5.38 |
| Pitman–Yor D = 0.6, θ = 2 | 2.3850 | +0.2097 | 0.0152 | 5.60 |

Discounting alone does not close the gap. It trusts deep patterns with few
matches too much.

### 2026-10-05: what Kneser–Ney's advantage actually is

Kneser–Ney on the same bytes, with and without continuation counts (raw counts
at every level is interpolated modified absolute discounting):

| Limit | Kneser–Ney | Raw counts at every level |
| ---: | ---: | ---: |
| 6 | 2.1754 | 2.4304 |
| 10 | 2.1883 | 2.6100 |
| 16 | 2.1861 | 2.6350 |

Continuation counts are worth a quarter of a bit, and they are what makes
longer limits safe. Discounting without them is 0.2 bits worse than the
Dirichlet lattice model. **Outcome: negative; the missing ingredient is
continuation counts** (see [continuation-sufficiency](../continuation-sufficiency/)).
