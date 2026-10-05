---
title: Truncated Möbius sum over mined patterns
kind: experiment
status: concluded
outcome: negative
question: >-
  If masked patterns that reach past Kneser–Ney's 6-byte context are mined by
  how much they change the next-byte distribution relative to their parents,
  and their Möbius (ANOVA) interaction terms are added to Kneser–Ney, does
  held-out loss fall?
answer: >-
  No. Every added pattern made development loss worse: 2.1523 bits with none,
  2.1542 with one, 2.2347 with 100, about 3.97 with 10,000. The patterns' effects
  were learned against plain byte frequencies, but Kneser–Ney's context already
  carries most of them, so they are counted twice.
opened: 2026-10-04
updated: 2026-10-05
code: cooccur-kn-baseline (4947a64)
eval: full development text (0–100 patterns); every 200th byte (1,000–10,000)
tags: [masks, moebius, interactions]
related: [kneser-ney-baseline, residual-patterns]
---

# Truncated Möbius sum over mined patterns

## Idea

Follow the ANOVA Möbius decomposition
([`docs/anova_m_bius_transform_in_nlp_interpretability.md`](../../docs/anova_m_bius_transform_in_nlp_interpretability.md)).
Treat the history positions as the "tokens", a masked pattern as a subset of
them, and log P(next | pattern) from exact counts as the value function v(T).
The Möbius term φ(T) = Σ over U ⊆ T of (−1)^|T−U| v(U) is the pure
contribution of that combination of positions. The full prediction is the sum
of all φ terms, but the full history is never seen, so sum only the terms we
can estimate and treat the rest as zero.

Kneser–Ney's 6-byte context stands in for every subset of offsets 1–6, so
summing φ over all of them collapses to log P_KN. Patterns reaching beyond
offset 6 add their own terms. For one pattern B this reduces to
P_KN(x) · P(x | B) / P(x | B ∩ {1..6}).

## Method

- Mine every pattern with 1–3 specified positions in the last 16 bytes whose
  shape reaches beyond offset 6, with at least 10 matches in the training
  text: 7,300,196 candidates.
- Score each by the bits it saves on the training text over its least-improved
  parent (the pattern minus one position), less a chance allowance of
  (d − 1)/(2 ln 2) for d distinct next bytes. Keep the best N.
- At each position, sum the Möbius terms of the subsets of matching kept
  patterns that reach beyond offset 6, and add them to log P_KN. Each P(x | U)
  is Witten–Bell smoothed toward U minus its farthest offset.

Code: [`src/mobius/interactions.cr`](../../src/mobius/interactions.cr). Specs
check counts, scores and the combined prediction against a literal sum of φ
terms with brute-force probabilities.

## How to run

```sh
bin/mobius interactions ~/Projects/agpt/data/input.txt keep=10000 stride=200
```

## Results

### 2026-10-04

Development bits per byte by number of patterns used:

| Patterns | 0 | 1 | 3 | 10 | 30 | 100 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| All development bytes | 2.1523 | 2.1542 | 2.1555 | 2.1623 | 2.1848 | 2.2347 |

On every 200th development byte (502 bytes): 2.1408 with none, 2.4299 with
1,000 patterns, 3.9721 with 10,000.

The top patterns were almost all "newline k bytes back" (k = 7–10) and
"period k bytes back": the position within a line or sentence.

At the 3,627 development positions where the top pattern (newline 7 bytes back,
31,898 training matches) matches, Kneser–Ney averaged 1.8519 bits and adding the
pattern raised it to 1.9052:

| Next | Actual | Kneser–Ney average | P(x \| pattern) | Plain frequency |
| --- | ---: | ---: | ---: | ---: |
| space | 0.116 | 0.105 | 0.125 | 0.153 |
| `I` | 0.058 | 0.054 | 0.034 | 0.010 |
| `:` | 0.051 | 0.045 | 0.034 | 0.009 |
| `V` | 0.044 | 0.012 | 0.001 | 0.001 |

Kneser–Ney is already nearly right on average. The pattern multiplies `I` by
3.4× (0.034 / 0.010), a boost measured against plain frequency, which the near
context has already supplied.

**Diagnosis.** The decomposition is exact only with every term. The dropped
terms, interactions between the far position and the whole near context, are
large and negative because they cancel this overlap. Truncation sets them to
zero. The parent-relative selection score has the same flaw: for one-position
patterns the parent is plain frequency, so line-position patterns with huge
support rank first.

The `V` row is `DUKE VINCENTIO`, who speaks 161 times in the development text
and 31 times in the training text before it: a recency effect (see
[recency-cache](../recency-cache/)).
