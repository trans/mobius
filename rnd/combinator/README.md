---
title: Combinators (pattern, pattern, target)
kind: design
status: planned
outcome: n/a
question: >-
  Beyond pattern → target relationships: given a pattern p1 and a later pattern
  p2 some distance apart, how does their combination change a still later
  target, compared with p2 alone? Do such ternary relationships carry the
  information needed to beat Kneser–Ney?
answer: ''
opened: 2026-10-05
updated: 2026-10-05
code: none yet
eval: development text first, test once settings are frozen
tags: [combinator, long-range, conditional]
related: [lattice-sufficiency, residual-patterns, recency-cache, mobius-truncation]
---

# Combinators

## Idea

So far every model has related one pattern to a target: given p, what follows.
A combinator relates two patterns and a target: p1, then p2 some distance
later, then a target some distance after p2. Its effect is how much knowing p1
changes the target's distribution **given p2**:

```text
effect(p1 | p2 → x) = log P(x | p1 then p2) − log P(x | p2)
```

This is the conditional (ternary) relationship. In the Möbius picture it is the
two-way interaction term between p1 and p2 for that target; in information
terms its average is the conditional mutual information I(X; P1 | P2).

## Why the conditional form matters

The record so far separates cleanly along this line:

| Experiment | How a pattern's effect was measured | Result |
| --- | --- | --- |
| [mobius-truncation](../mobius-truncation/) | Against plain byte frequency (unconditional) | Worse with every pattern |
| [lattice-self-weights](../lattice-self-weights/) | Against its own matches (unconditional) | Far worse than Kneser–Ney |
| [residual-patterns](../residual-patterns/) | Against Kneser–Ney's prediction, so given the near context | Small real gain |
| [lattice-sufficiency](../lattice-sufficiency/) | Given the current pattern, does one more history byte matter | Much better than self-weights |

Whenever an effect was measured unconditionally it double counted what the near
context already says. Whenever it was measured conditionally things improved.
A combinator makes the conditioning explicit, and it can do so at any distance:
the bit planes match p1 and p2 at arbitrary offsets, not only inside a 16-byte
window. The sufficiency step is already a small combinator: p2 is the current
pattern, p1 is one more history byte inside the window. The design here lets
p1 be a whole pattern, such as a word or a name, far back.

In neural terms this is what attention computes: the near context forms the
query, a distant piece of the history is the key, and the result changes the
prediction. The [recency cache](../recency-cache/) is the special case in which
p1 is p2 followed by the target itself, occurring recently.

## Open design questions

1. **Exact gap or "within the last D bytes".** An exact gap between p1 and p2 is
   rarely repeated at long range. Pooling "p1 occurred somewhere in the last D
   bytes" gives support. The bit planes support both: match p1, spread its
   matches forward over D positions, and AND with p2's matches.
2. **Which p2.** The near context that Kneser–Ney (or the sufficiency model)
   already uses, so the combinator's effect is exactly what that context misses.
3. **Which p1.** Candidates from the far history: substrings of a few bytes at
   distances beyond the window. Prune by support, and by the bound that a
   combinator's gain on the training text cannot exceed n · H(target | p2).
4. **Measuring effects without leakage.** Effects must be measured where the
   near-context model did not see the target, as in the cross-fitting of
   [residual-patterns](../residual-patterns/).
5. **Combining several combinators** without counting their overlap twice,
   which remains the central difficulty in every experiment so far.

## First measurement (proposed)

Before building a predictor, measure the ceiling: on development text, how
many bits per byte can far patterns (presence within the last D bytes, beyond
the 16-byte window) carry about the next byte given the near context, measured
against cross-fitted Kneser–Ney? A large number justifies the predictor; a
small one says the long-range information lies elsewhere.

## 2026-10-05: relations are range-weighted, not fixed-offset

Every pattern so far fixes its offsets: "this byte exactly k positions back".
Real dependencies have no fixed distance. If "Mary" is said and "she" follows
later, they are correlated whether 3 or 30 tokens apart; the strength of the
correlation falls with distance; and an intervening "Elizabeth" breaks it,
pinning "she" to Elizabeth instead. A fixed-offset pattern can only catch such
a relation where the distance happens to repeat, which may explain why masked
patterns find regularities in the training text that do not carry over to new
text ([nested-mask-prior](../nested-mask-prior/)).

This sharpens what a combinator should be:

- **p1 occurs within a range, weighted by recency**, not at an exact gap: the
  most recent occurrence counts most, and the weight decays with distance.
- **Interference is part of the relation.** The effect of p1 on the target
  given p2 holds only if no competing p1′ (another name) occurs in between.
  This is the transitive structure: p1 → (no intervening p1′) → p2 → target.
- The bit planes support this directly: a match set for p1 can be spread
  forward over a range (OR of shifts, or a running "most recent occurrence"
  distance), and a competing pattern's matches can cut the spread off.

In neural terms this is what attention with recency bias does, and what
induction heads do for copying. Here it would be explicit and countable.
