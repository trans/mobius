---
title: Kneser–Ney baseline
kind: experiment
status: concluded
outcome: reference
question: >-
  How well do contiguous suffixes alone predict the next byte, done properly,
  so that every other idea has a fixed number to beat?
answer: >-
  Interpolated modified Kneser–Ney with a context limit of 6 bytes (chosen on
  development text) scores 2.1887 bits per byte on the test text (1.5171 nats,
  perplexity 4.56). Longer contexts stop helping after 6 bytes because they are
  rarely seen.
opened: 2026-10-04
updated: 2026-10-05
code: cooccur-kn-baseline (04df0b1)
eval: full development and test text
tags: [baseline, suffixes]
related: []
---

# Kneser–Ney baseline

## Idea

Predict the next byte from the last few bytes, using every suffix length at
once. For `the King of ?` with a limit of 6, Kneser–Ney asks the training
text what followed `ng of `, then `g of `, ` of `, and so on down to no
context, and blends the answers. Longer contexts are trusted more when they
were seen often. It is the standard count-based language model and the bar
every other method here must clear.

## Method

Interpolated modified Kneser–Ney (Chen and Goodman, 1998):

- Under context limit L, a context of exactly L bytes uses raw counts; every
  shorter context uses continuation counts (how many distinct bytes precede
  the context-plus-next-byte string). When the L-byte context was never seen,
  all levels use continuation counts.
- Three discounts per level (for counts 1, 2 and 3+) come from the numbers of
  strings seen exactly 1–4 times in the training text.
- The final fallback is uniform over all 256 byte values.
- A suffix array over the training text supplies exact counts.

Code: [`src/mobius/kneser_ney.cr`](../../src/mobius/kneser_ney.cr),
[`src/mobius/suffix_array.cr`](../../src/mobius/suffix_array.cr). Specs check
the suffix array against direct sorting and the model against a brute-force
Kneser–Ney at every held-out position and limit.

## How to run

```sh
bin/mobius baseline ~/Projects/agpt/data/input.txt
bin/mobius predict ~/Projects/agpt/data/input.txt 'the King of ' 6
```

## Results

### 2026-10-04

Context limit chosen on development text:

| Limit | 0 | 1 | 2 | 3 | 4 | 5 | **6** | 7 | 8 | 12 | 16 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Dev bits/byte | 4.7729 | 3.6010 | 2.9072 | 2.4150 | 2.2039 | 2.1535 | **2.1523** | 2.1606 | 2.1658 | 2.1657 | 2.1652 |

Test at limit 6: **2.1887 bits per byte**, 1.5171 nats, perplexity 4.559.
Per whitespace-separated word (20,153 words, 5.5 bytes each): perplexity
about 4,400.

nanoGPT's small character transformer reports about 1.47 nats (about 2.12
bits, perplexity 4.35) on the same split. That figure is quoted from memory of
its README and is unverified. It sees at most 256 bytes of history.

The limit-0 row matches a unigram cross-entropy computed independently in
Python (4.7727; the difference is the discount mass sent to the uniform
fallback).

`predict` for `the King of ` at limit 6 sees only `ng of ` and gives `t` 0.32,
`h` 0.10, `a` 0.09. `King` is outside its window.
