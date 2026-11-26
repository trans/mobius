---
title: Mined patterns judged against Kneser–Ney
kind: experiment
status: concluded
outcome: mixed
question: >-
  If each mined pattern is judged by what Kneser–Ney gets wrong at its training
  matches, instead of against plain byte frequencies, do the patterns lower
  held-out loss?
answer: >-
  Slightly. Using only the best-ranked matching pattern, test loss falls from
  2.1887 to 2.1845 bits (−0.0042) with either fold scheme. The signal is mostly
  position within the line. Multiplying in every matching pattern still fails
  (+1.05 bits at 10,000 patterns) because different patterns make the same
  correction at the same positions.
opened: 2026-10-04
updated: 2026-10-05
code: cooccur-kn-baseline (4947a64)
eval: full development and test text
tags: [masks, residual, kneser-ney]
related: [mobius-truncation, kneser-ney-baseline]
---

# Mined patterns judged against Kneser–Ney

## Idea

For each pattern, compare outcomes at the same positions: at its training
matches, what actually came next versus what Kneser–Ney predicted there.
Kneser–Ney never needs to see the pattern's distant bytes; if they carry
information it lacks, its predictions will be wrong in a consistent direction
at exactly the positions the pattern selects. The correction is
actual ÷ expected, so a pattern adds nothing where Kneser–Ney is already right.

## Method

- **Cross-fitting.** Kneser–Ney must not predict text it was trained on, or it
  looks nearly perfect. The training text is cut into 10 folds; each fold is
  predicted by a Kneser–Ney trained on the other 9 joined end to end. Folds are
  contiguous blocks, or (`interleave=1000`) 1,000-byte blocks dealt to the folds
  in turn.
- **Mining.** Patterns of 1–3 positions in the last 16 bytes reaching beyond
  offset 6, at least 10 matches. At each pattern's matches, actual counts a_x
  and expected counts e_x (the sum of cross-fitted Kneser–Ney distributions).
  Correction ratio r_x = (a_x + 1)/(e_x + 1). Score: Σ a_x log₂ r_x less the
  chance allowance (d − 1)/(2 ln 2). Patterns matching exactly the same positions
  are kept once.
- **Prediction.** Kneser–Ney trained on all training text, multiplied by the
  ratios of the matching kept patterns and renormalized: either every match, or
  only the best-ranked one.

Code: [`src/mobius/residual.cr`](../../src/mobius/residual.cr). Specs check the
cross-fitted expectations against separately built Kneser–Ney models, each
pattern's score and ratios against direct scanning, and both prediction rules.

## How to run

```sh
bin/mobius residual ~/Projects/agpt/data/input.txt                 # contiguous folds
bin/mobius residual ~/Projects/agpt/data/input.txt interleave=1000 # interleaved folds
```

## Results

### 2026-10-04: first version (superseded)

Ratios were Witten–Bell smoothed, (a_x + d·q_x)/((S + d)·q_x), and exact
duplicates were not removed. Best-match rule: +0.0002 bits at 10,000 patterns.
Every-match rule: infinite loss from 10,000 patterns. Two defects:

- Witten–Bell drives a byte that never followed the pattern to d/(S + d), about
  0.002 for the newline pattern, even where Kneser–Ney expected it only 0.01
  times. A few such factors multiplied together underflow the true byte to
  probability zero.
- Seven or more patterns (`KING ******`, `NG ******`, `K**G ******`, …) matched
  the same 465 positions and applied one correction seven times.

Contiguous folds also produced play-local artifacts: `KING ******` predicted the
`X` of `KING LEWIS XI` at 14,546× because all its occurrences sit in one fold.

### 2026-10-05: ratio (a + 1)/(e + 1), duplicates removed

Development change versus Kneser–Ney (2.1523):

| Folds | Patterns | 10 | 100 | 1,000 | 10,000 | all kept |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Contiguous | best match | +0.0018 | +0.0002 | −0.0013 | −0.0013 | −0.0013 |
| Contiguous | every match | +0.0053 | +0.0167 | +0.2074 | +1.2570 | ∞ |
| Interleaved | best match | −0.0017 | −0.0041 | −0.0042 | −0.0042 | −0.0042 |
| Interleaved | every match | −0.0019 | −0.0007 | +0.1167 | +1.0529 | +4.9156 |

Test, settings from development:

| Folds | Setting | Kneser–Ney | With patterns |
| --- | --- | ---: | ---: |
| Contiguous | 10,000, best match | 2.1887 | 2.1845 (−0.0042) |
| Interleaved | 1,000, best match | 2.1887 | 2.1845 (−0.0042) |

With interleaved folds the play-local names disappear and the top patterns are
line position: newline 7–13 bytes back, where `.`, `?` and `;` are 3–10× less
likely than Kneser–Ney thinks. Between 26 and 70 kept patterns match each byte;
"newline 7 back", "newline 8 back" and so on are different patterns with the
same correction, so the every-match rule double counts them.

### 2026-10-05: audit note

The two fold schemes chose different settings (10,000 patterns, 12.9 matched
per byte; 1,000 patterns, 6.7 matched per byte) yet both printed 2.1845. It is
probably a coincidence at four decimals; it has not been rechecked with more
precision. The cross-fitted Kneser–Ney is also slightly stronger than the one
the corrections are applied to (it is trained on text from the same plays when
folds are interleaved), so interleaved corrections may be slightly too small.
