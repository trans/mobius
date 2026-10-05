---
title: Lattice sufficiency with continuation counts
kind: experiment
status: concluded
outcome: positive
question: >-
  Kneser–Ney loses a quarter of a bit without continuation counts. If the
  sufficiency model's parent estimates count how many distinct bytes occurred
  at the dropped offset before each next byte, instead of raw frequencies, does
  it reach Kneser–Ney with suffixes only, and do masks then help?
answer: >-
  With suffixes only, yes: 2.1509 against Kneser–Ney's 2.1498 on 90,347
  development bytes not used for choosing (+0.0011 ± 0.0028), and −0.0029 ±
  0.0081 on another disjoint sample. A 32-byte window changes nothing. Masks do
  not help: +0.088 bits against suffixes with a uniform refinement prior.
opened: 2026-10-05
updated: 2026-10-05
code: cooccur-kn-baseline (scratch prototype first)
eval: every 10th development byte, Kneser–Ney on the same bytes, paired standard errors
tags: [lattice, bayesian, hierarchical, continuation-counts, kneser-ney]
related: [hierarchical-sufficiency, discounted-sufficiency, kneser-ney-baseline]
---

# Lattice sufficiency with continuation counts

## Idea

When Kneser–Ney falls back from `ng of ` to `g of `, the shorter context's
distribution does not count how often each byte followed `g of `. It counts
**after how many different bytes before `g of `** each byte followed it. A byte
that follows `g of ` only because of one frequent longer phrase gets little
credit. This matters exactly when the longer context is rare and the model
must back off, which is the case the fallback exists for. Without it,
Kneser–Ney is 0.25 bits worse on our development bytes
([discounted-sufficiency](../discounted-sufficiency/)).

The idea carries over to masks. A pattern S is reached from its parent by
adding its farthest offset f. As S's parent, a pattern's continuation count for
byte x is the number of distinct bytes at offset f among its matches followed
by x. For suffixes this is exactly Kneser–Ney's continuation count.

## Method

As [hierarchical-sufficiency](../hierarchical-sufficiency/) (Dirichlet
strength β, parent-centered priors), with the parent's estimate replaced by a
continuation estimate:

- Q₋₁ = plain byte frequencies.
- As a parent, a pattern P with continuation counts N(x) (for the offset its
  child adds) has Q_P = (N + β·Q_parent(P)) / (ΣN + β).
- A pattern S, as a leaf or when stopping, uses raw counts on top of its
  parent's continuation estimate: P̂_S = (c_S + β·Q_parent(S)) / (n_S + β).
- Stopping at S, and the matches that disagree when S is refined, are judged
  against Q_parent(S).

A suffixes-only prototype first (`continuation.cr`, scratch), reading raw and
continuation counts from the Kneser–Ney suffix-array levels, so the same code
can also reproduce the raw-count model as a check.

## Results

### 2026-10-05: suffixes-only prototype

`continuation.cr` (scratch) reads raw and continuation counts from Kneser–Ney's
suffix-array levels (contexts up to 16 bytes, support 1). With raw parents and
β = 32 it reproduces the library's hierarchical suffixes-only model exactly
(2.2354 on the same bytes), which cross-checks both implementations.

Settings chosen on every 10th development byte (10,039 bytes; Kneser–Ney
2.1754), with β_chain the strength of the continuation chain and β_leaf the
strength of the leaf estimates and evidence:

| β_chain \ β_leaf | 1 | 2 | 4 | 8 |
| ---: | ---: | ---: | ---: | ---: |
| 1 | | +0.0972 | +0.1087 | +0.1388 |
| 2 | | +0.0625 | +0.0682 | +0.0923 |
| 4 | | +0.0319 | +0.0333 | +0.0530 |
| 8 | +0.0307 | +0.0096 | +0.0094 | +0.0275 |
| 16 | +0.0196 | −0.0022 | −0.0025 | |
| **32** | +0.0183 | −0.0035 | **−0.0037** | |
| 64 | +0.0232 | +0.0027 | +0.0039 | |
| 128 | +0.0315 | +0.0162 | +0.0183 | |

(Differences from Kneser–Ney; paired SE about 0.009. Raw parents, β = 32:
+0.0601.)

Chosen β_chain = 32, β_leaf = 4, then scored on the other 90,347 development
bytes, which were not used for choosing:

| Model | Bits/byte | vs Kneser–Ney (2.1498) | Paired SE | Depth |
| --- | ---: | ---: | ---: | ---: |
| Raw parents, β = 32 | 2.2084 | +0.0587 | 0.0032 | 5.56 |
| **Continuation parents, 32 / 4** | **2.1509** | **+0.0011** | 0.0028 | 3.94 |

With continuation counts the suffixes-only Bayesian model ties Kneser–Ney. It
reaches that while stopping at about 4 positions on average, against
Kneser–Ney's 5.65: the continuation chain makes short contexts much better
estimates.

### 2026-10-05: in the library; window 32 for suffixes

The library now computes continuation counts during the lattice walk, for
suffixes and masks (`chain=`). It reproduces the prototype exactly on every
10th development byte: support 1, β_leaf 4, β_chain 32 gives 2.1716, −0.0037 ±
0.0083 against Kneser–Ney, depth 3.93. Specs check it against enumeration of
every refinement path with naive continuation counts.

Suffixes only with a 32-byte window: 2.1716 again, identical to four decimals.
Contiguous context beyond 16 bytes gets no weight, as the suffix tree's depth
suggests: such contexts occur once, and the posterior never refines into them.

### 2026-10-05: masks with continuation counts, uniform refinement prior

Same 10,039 bytes and settings (support 1, β_leaf 4, β_chain 32), all masked
patterns in the 16-byte window, each supported refinement equally likely:
**2.2593**, +0.0840 ± 0.0106 against Kneser–Ney, depth 4.87, 120 ms per byte.
Suffixes only: 2.1716 on the same bytes. Masks remain 0.088 bits worse; the
continuation estimator improved both versions by about the same amount. See
[nested-mask-prior](../nested-mask-prior/) for masks under a prior that
favors the contiguous extension.
