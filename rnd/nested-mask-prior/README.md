---
title: Masks nested in the suffix model
kind: experiment
status: concluded
outcome: negative
question: >-
  If the refinement prior favors the nearest unfixed offset with probability p
  and spreads only 1 − p over masked refinements, so that p = 1 is exactly the
  suffix model, is there a p < 1 that beats the suffix model? That is, do masks
  carry information the contiguous context lacks?
answer: >-
  No. Even with only 1% prior on masked refinements, the training evidence gives
  masks 24% of the weight, and the model scores 0.067 bits worse than suffixes
  only. Where masks take over (15% of bytes) they cost 0.64 bits per byte.
opened: 2026-10-05
updated: 2026-10-05
code: cooccur-kn-baseline
eval: development bytes not used for earlier choices, Kneser–Ney on the same bytes, paired standard errors
tags: [lattice, masks, prior, bayesian]
related: [continuation-sufficiency, hierarchical-sufficiency]
---

# Masks nested in the suffix model

## Idea

Every lattice model so far gave all supported refinements the same prior
probability. From any pattern there are up to 16 possible refinements, so the
contiguous extension, which we know is the most valuable, got about 1/16 of the
refinement probability, and masks were always worse than suffixes.

Here the prior is nested. The nearest offset the pattern does not yet fix gets
probability p; the other offsets share 1 − p. Probability given to a refinement
that lacks support goes to stopping. With p = 1 the model is exactly the
suffix model (a spec checks this), so any p < 1 that scores better is direct
evidence that masks carry information the contiguous context lacks. Masks have
to earn their weight from the data against a strong default.

## Method

[continuation-sufficiency](../continuation-sufficiency/) with support 1,
β_leaf = 4, β_chain = 32 (chosen there for suffixes), and refinement shares as
above. The other development bytes are used, since every 10th byte has
already been used to choose settings.

## How to run

```sh
bin/mobius sufficiency ~/Projects/agpt/data/input.txt hierarchical suffixes support=1 prior=4 chain=32 stride=10 offset=5
bin/mobius sufficiency ~/Projects/agpt/data/input.txt hierarchical support=1 prior=4 chain=32 nearest=0.9,0.99 stride=10 offset=5
```

## Results

### 2026-10-05

Every 10th development byte starting 5 bytes in (10,039 bytes, none used to
choose settings); Kneser–Ney on the same bytes 2.1624:

| Mask prior | Bits/byte | vs Kneser–Ney | Paired SE | Depth |
| --- | ---: | ---: | ---: | ---: |
| none: suffixes only (p = 1) | 2.1595 | −0.0029 | 0.0081 | 3.94 |
| 1% (p = 0.99) | 2.2292 | +0.0668 | 0.0109 | 4.53 |
| 10% (p = 0.9) | 2.2318 | +0.0694 | 0.0108 | 4.65 |

About 120 ms per byte with masks, 4.4 ms suffixes only.

Where the weight goes with a 1% mask prior (every 200th development byte from
offset 5, 502 bytes, scratch `mask_weight.cr`):

- Masked patterns receive 0.237 of the posterior weight on average, mostly
  patterns reaching offsets 5–9 (0.055, 0.053, 0.036, 0.023, 0.023 of all weight
  for farthest offsets 5–9).
- Extra bits of the masked model over the suffix model, by how much weight
  went to masks:

  | Weight on masks | Bytes | Extra bits per byte |
  | --- | ---: | ---: |
  | under 10% | 344 | +0.002 |
  | 10–90% | 80 | +0.042 |
  | over 90% | 78 | **+0.642** |

**Reading.** The prior is not what sinks masks. The training text supplies
enough evidence to override a 1% prior, and the masked refinements it selects
predict new text badly: about two thirds of a bit per byte wherever they take
over. The masked regularities the evidence finds are either redundant with the
contiguous context or specific to the training plays; the Bayesian evidence is
computed on the training text and cannot tell which.
