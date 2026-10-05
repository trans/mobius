---
title: Möbius interaction probe of a character LLM and the counts
kind: design
status: planned
outcome: n/a
question: >-
  Where, in the lattice of history positions, does a trained character model
  (nanoGPT) carry interaction structure that exact corpus counts do not: which
  orders, which distances, and with which signs? In particular, where are the
  negative interactions that our models have been losing?
answer: ''
opened: 2026-10-05
updated: 2026-10-05
code: none yet
eval: contexts from development text; nanoGPT trained on the training split only
tags: [moebius, anova, interpretability, nanogpt, interactions]
related: [mobius-truncation, combinator, lattice-sufficiency]
---

# Möbius interaction probe

## Idea

The ANOVA Möbius transform
([`docs/anova_m_bius_transform_in_nlp_interpretability.md`](../../docs/anova_m_bius_transform_in_nlp_interpretability.md))
decomposes a model's prediction into main effects and interaction terms over
subsets of the input. The terms carry signs: φ(not, good) = −1.40 is "not"
cancelling "good". Our first Möbius experiment
([mobius-truncation](../mobius-truncation/)) failed because it dropped
exactly such negative terms: the interactions between far positions and the
near context. Every model since has been a mixture, which can choose among
patterns but never subtract.

Use the decomposition as a measurement instrument on two models over the same
contexts:

- **Counts:** v(T) = log P(next byte | masked pattern T), from the bit planes.
- **nanoGPT:** v(T) = log of nanoGPT's predicted probability of the next byte,
  averaged over the corpus contexts that match T.

Then compare φ_LLM(T) with φ_counts(T) by order, distance and sign. Where
nanoGPT has interaction strength that the counts lack is what it learned
beyond corpus statistics, and it shows where the
[combinator](../combinator/) work should look.

## The fill problem, solved by the corpus

Masking a position means asking what the model predicts when that position is
unknown. Artificial mask tokens put the model out of distribution. Here the
corpus supplies the fill: a masked pattern's matches in the bit planes are real
contexts that agree with the history on the kept positions and contain real
text everywhere else. These are the nearest neighbors of the user's earlier
edit-distance idea. For counts, averaging over them is exactly what a wildcard
means. For nanoGPT, its predictions are averaged over the same contexts. For
the full history no fill is needed.

## Open questions

- **Train nanoGPT on the training split only** (`[0, 903,468)` for development
  probes). Small character config, RTX 4070 available.
- **Which v.** Log of the averaged probability, or the average of log
  probabilities; and whether to probe the actual next byte or the whole
  distribution.
- **Scale.** 2^k subsets for k positions. Start with small windows, or bounded
  orders (Shapley–Taylor). Note: the formula labelled Shapley–Taylor in the docs
  file appears to be the Shapley interaction index (Grabisch), which does not
  guarantee efficiency; check Sundararajan et al. (2020) before using it.
- **Memorization.** nanoGPT has seen the training contexts used as fills, so
  its predictions there may echo the counts. Fills from text it did not train
  on, or a held-out split, may be needed.
