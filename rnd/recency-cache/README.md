---
title: Recency cache
kind: experiment
status: concluded
outcome: mixed
question: >-
  Does counting what followed each recent context in the last few thousand
  bytes of the text being read, mixed with Kneser–Ney, lower held-out loss?
answer: >-
  Mostly no. Against the frozen Kneser–Ney the mixture scores 2.0422 test bits
  (−0.146), but a Kneser–Ney that simply keeps counting the text it has read
  scores 2.0595 (refreshed every 2,000 bytes). Recency itself adds about 0.017
  bits; the rest is online learning of vocabulary new to the current play,
  which any model reading the text can do. See the 2026-10-05 correction.
opened: 2026-10-04
updated: 2026-10-05
code: uncommitted (src/mobius/recency.cr)
eval: full development and test text
tags: [recency, cache, nonstationarity]
related: [kneser-ney-baseline, mobius-truncation]
---

# Recency cache

## Idea

Each play brings its own names and words. Keep a running count, over the last
`span` bytes before the current position (including earlier text of the play
being read), of which byte followed each recent context of 0–7 bytes. Blend
that local prediction with Kneser–Ney's global one.

This is a classic idea (cache language models, Kuhn and De Mori, 1990). It is
recorded here because it measures how much of the remaining surprise comes
from the text itself rather than from the training corpus.

## Method

- **Cache.** Exact counts over the window, updated as the position advances:
  for each context length k ≤ 7, how often each byte followed the k bytes
  before it, with totals and distinct counts.
- **Cache prediction.** Witten–Bell interpolation from the empty context up to
  the longest context present in the window, ending in uniform.
- **Mixture.** P = (1 − λ_m) · P_KN + λ_m · P_cache, with one weight per longest
  cached context m. The weights are fitted by EM on development text and the
  window size is chosen there; both are then frozen for the test text.

Code: [`src/mobius/recency.cr`](../../src/mobius/recency.cr). Specs check the
window counts against direct scanning as it slides, the Witten–Bell chain, and
that EM reaches the likelihood maximum found by grid search.

## How to run

```sh
bin/mobius recency ~/Projects/agpt/data/input.txt
bin/mobius recency ~/Projects/agpt/data/input.txt context=4 spans=50000
```

## Results

### 2026-10-04

Window size on development text (Kneser–Ney 2.1523):

| Span | 500 | 2,000 | 10,000 | **50,000** | 100,000 | 200,000 | 1,000,000 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Dev bits/byte | 2.0876 | 2.0542 | 2.0392 | **2.0307** | 2.0325 | 2.0422 | 2.0778 |

Fitted cache weight by longest cached context (span 50,000):

| Longest context | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Development bytes | 306 | 3,256 | 10,881 | 17,333 | 17,664 | 15,040 | 35,905 |
| λ | 0.085 | 0.133 | 0.226 | 0.285 | 0.278 | 0.206 | 0.318 |

Test: **2.1887 → 2.0422 bits per byte** (−0.1464), perplexity 4.56 → 4.12.

### 2026-10-05: is it just a longer Kneser–Ney?

No. Cache context length, span 50,000:

| Cache context | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Dev change | 0.0000 | −0.0050 | −0.0420 | −0.0992 | −0.1278 | −0.1286 | −0.1234 | −0.1217 |
| Test change | 0.0000 | −0.0104 | −0.0621 | −0.1261 | −0.1534 | −0.1538 | −0.1487 | −0.1464 |

Kneser–Ney itself with a 7-byte limit is worse than with 6 (2.1606 against
2.1523). Splitting the development gain at cache context 4: positions whose
5-byte string (4 context bytes plus the predicted byte) never occurs in the
training text are 10.0% of positions and receive 79.9% of the gain, 1.025 bits
each; the other 90% receive 0.028 bits each.

| Name | Training | Development | Test |
| --- | ---: | ---: | ---: |
| KATHARINA | 0 | 10 | 71 |
| PETRUCHIO | 0 | 21 | 137 |
| DUKE VINCENTIO | 31 | 161 | 0 |

The text is not stationary: much of what Kneser–Ney misses is vocabulary that
exists only in the current play. Counting all the history (1,000,000 bytes) does
worse than the last 50,000: local beats global. nanoGPT's 2.12 bits is not
comparable here; it sees at most 256 bytes of history.

### 2026-10-05: correction — the baseline was frozen

The comparison above is unfair. The cache learns from earlier test text while
the reference Kneser–Ney's counts stop at the start of the test text. An
independent audit rebuilt Kneser–Ney from all text before each block of the
test text (training, development and earlier test text: only the past), and
I reran it:

| Model | Test bits/byte |
| --- | ---: |
| Kneser–Ney, frozen at the start of the test text | 2.1887 |
| Kneser–Ney, refreshed every 10,000 bytes | 2.0901 |
| Kneser–Ney, refreshed every 2,000 bytes | 2.0595 |
| Frozen Kneser–Ney + recency cache | 2.0422 |

Most of the 0.146-bit gain is online learning: KATHARINA and PETRUCHIO become
known once they have been read, whichever model counts them. The part
attributable to recency (forgetting older text) is about 0.017 bits, and a
per-byte refresh would likely narrow it further. A fair test of recency mixes
the cache with an online Kneser–Ney. Script:
`audit_dynamic.cr` (the audit), rerun as `online_kn` with blocks of 10,000 and
2,000.
