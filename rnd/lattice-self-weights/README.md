---
title: Lattice nearest neighbors weighted by self-prediction
kind: experiment
status: concluded
outcome: negative
question: >-
  Predicting from the masked patterns consistent with the current history alone
  (no Kneser–Ney), with each pattern weighted by how well it predicts its own
  training matches, can a training-free lattice model approach Kneser–Ney?
answer: >-
  No: 2.87 test bits per byte against Kneser–Ney's 2.14 on the same sampled
  bytes. Self-prediction rewards patterns that drop the most informative offsets
  and switch to a different, self-consistent population of contexts (for
  `the King of `, the 602 `KING RICHARD` speaker headings).
opened: 2026-10-05
updated: 2026-10-05
code: uncommitted (src/mobius/lattice.cr, src/mobius/lattice_search.cr)
eval: every 50th development and test byte, Kneser–Ney on the same bytes
tags: [lattice, nearest-neighbors, masks]
related: [lattice-sufficiency]
---

# Lattice nearest neighbors weighted by self-prediction

## Idea

Go straight to inference. Every training position agrees with the current
history at some set of offsets; that set is a masked pattern, and the bit
planes give its exact next-byte distribution. So a "neighbor" is a matching
pattern, and its weight should fall out of its distribution. Average the
best-weighted patterns' distributions.

## Method

- **Candidates.** Every subset of offsets 1–16, filled with the history's bytes,
  with at least `support` matches in the training text, found by walking the
  subsets with bit-plane ANDs. Patterns with identical counts are kept once.
- **Estimate.** Each pattern predicts with Witten–Bell smoothing toward plain
  byte frequencies.
- **Weight.** Leave each match out in turn and predict it from the rest; the
  weight is the geometric-mean probability given to the byte that actually
  followed, 2^(−bits per match).
- **Prediction.** The weight-proportional average of the k heaviest patterns.
  The walk prunes below the minimum support and skips branches whose best
  attainable weight, (n − 1 + max P₀)/n, cannot enter the top k.

Code: [`src/mobius/lattice.cr`](../../src/mobius/lattice.cr),
[`src/mobius/lattice_search.cr`](../../src/mobius/lattice_search.cr). Specs
check the pruned search against brute-force enumeration (including on nearly
repetitive text where pruning fires constantly) and the pruning ceiling against
the best weight actually attainable.

## How to run

```sh
bin/mobius lattice ~/Projects/agpt/data/input.txt stride=50
bin/mobius neighbors ~/Projects/agpt/data/input.txt 'the King of '
```

## Results

### 2026-10-05

Every 50th development byte (2,008 bytes); Kneser–Ney on the same bytes 2.185:

| Min support | k=1 | k=4 | k=16 | k=64 |
| --- | ---: | ---: | ---: | ---: |
| 2 | 4.5595 | 3.9055 | 3.3011 | 3.0234 |
| 5 | 4.3972 | 3.6763 | 3.0975 | 2.8834 |
| 10 | 3.9972 | 3.3422 | 2.9274 | 2.8090 |
| 25 | 3.5527 | 3.0600 | 2.8206 | 2.8215 |

Test (every 50th byte, support 10, k = 64): 2.8674 against Kneser–Ney 2.1449.
About 21 ms per byte.

Larger k at support 25 (every 100th development byte; Kneser–Ney 2.2229):
k=16 2.8239, k=64 2.7983, k=256 3.0103, all patterns 3.3891. Qualifying patterns
per context: 846–2,369 at support ≥ 2, 506–1,749 at support ≥ 25 (three sample
contexts). Many small weights add up: with ~1,000 patterns averaged, the
low-ranked crowd outweighs the top few.

For `the King of `, none of the top 16 patterns uses offsets 1–3 (` of`). The top
pattern, `K*** ***` (a `K` 8 back, a space 4 back), matches 602 speaker headings
such as `KING RICHARD`, whose continuations are consistent, so it predicts its
own matches well. The prediction ranks `h`, `r`, `a` first.

**Diagnosis.** Predicting its own matches well is not the same as being
relevant to this history. The weight must measure relevance. See
[lattice-sufficiency](../lattice-sufficiency/).
