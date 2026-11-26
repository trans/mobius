---
title: Refinements judged on text they were not counted from
kind: experiment
status: concluded
outcome: negative
question: >-
  Masked refinements win on training-text evidence but mispredict new text. If
  every stop-or-refine decision is judged by how well each choice predicts
  parts of the training text it was not counted from (cross-validated, with
  contiguous folds so the held-out part is a different stretch of plays), do
  masks stop hurting, and does any masked structure help?
answer: >-
  No. With five contiguous folds, masks score +0.156 bits against Kneser–Ney,
  0.131 worse than suffixes judged the same way; cross-validation also makes
  suffixes only 0.028 worse than the marginal likelihood.
opened: 2026-10-05
updated: 2026-10-05
code: cooccur-kn-baseline
eval: every 10th development byte from offset 5 (not used for choosing earlier settings), Kneser–Ney on the same bytes, paired standard errors
tags: [lattice, masks, cross-validation, pseudo-bayes-factor]
related: [nested-mask-prior, continuation-sufficiency]
---

# Refinements judged on text they were not counted from

## Idea

In [nested-mask-prior](../nested-mask-prior/), even a 1% prior did not keep
masked refinements out: the training text's own evidence gave them 24% of the
weight, and where they took over they cost 0.64 bits per byte. The evidence is
computed from the same counts that produce the estimates, so a refinement that
fits regularities of the training plays looks good whether or not it carries
over.

Here each choice is judged the way the model will actually be used: predicting
text it has not seen. The training text is cut into K contiguous folds. For a
pattern, each fold's matches are predicted from the counts of the other folds,
and the log-probabilities are added up. A refinement wins only if the agreeing
matches are better predicted, out of fold, by their own estimate than by the
coarser pattern's. Contiguous folds make the held-out part a different stretch
of plays, which is the situation that broke the masks.

Weighting models by cross-validated predictive probability instead of marginal
likelihood is the pseudo-Bayes factor (Geisser and Eddy, 1979), a known remedy
when the model class is misspecified.

## Method

As [continuation-sufficiency](../continuation-sufficiency/) (support 1,
β_leaf 4, β_chain 32, parent-centered priors with continuation counts), except
that the evidence of a set of matches with prior mean m is

  Σ over folds f, Σ_x c_f(x) · log[(c(x) − c_f(x) + β·m_x) / (n − n_f + β)],

with c_f the counts from matches in fold f. It is used for stopping at a
pattern and for the matches that disagree when it is refined. Prior means are
computed from all the training text (a plug-in): only the refinement counts are
held out, which is where the selection effect arises. Leaf estimates for
prediction are unchanged.

## How to run

```sh
bin/mobius sufficiency ~/Projects/agpt/data/input.txt hierarchical suffixes support=1 prior=4 chain=32 folds=5 stride=10 offset=5
bin/mobius sufficiency ~/Projects/agpt/data/input.txt hierarchical support=1 prior=4 chain=32 folds=5 stride=10 offset=5
```

## Results

### 2026-10-05: suffixes only

Every 10th development byte from offset 5 (10,039 bytes); Kneser–Ney on the
same bytes 2.1624. Five contiguous folds.

| Evidence | Bits/byte | vs Kneser–Ney | Paired SE | Depth |
| --- | ---: | ---: | ---: | ---: |
| Marginal likelihood | 2.1595 | −0.0029 | 0.0081 | 3.94 |
| Cross-validated, 5 folds | 2.1879 | +0.0255 | 0.0083 | 4.28 |

For suffixes, cross-validated evidence is 0.028 bits worse, and it refines
slightly deeper. Why is not established; one possibility is that the plug-in
prior means (computed from all the training text, held-out fold included) make
held-out matches look easier to predict at deep patterns.

### 2026-10-05: masks

Same bytes, all masked patterns in the 16-byte window, uniform refinement
prior, five contiguous folds: **2.3188**, +0.1564 ± 0.0111 against Kneser–Ney,
depth 5.64, 200 ms per byte. Suffixes only with the same evidence: 2.1879.
Masks are 0.131 bits worse; cross-validated evidence does not keep them out.

**Reading.** Masked refinements hold up when judged on held-out stretches of
the training text, yet still mispredict the development text. A guess that the
development text differs in line structure (verse against prose) is refuted
by the data: mean speech-line length is 38.1 bytes in training, 38.5 in
development and 37.4 in test, with under 1% of lines longer than 55 bytes in
each. Why masked regularities that survive cross-validation fail on new text
remains open. The plug-in prior means are one untested leak.

**Outcome: negative.** Fixed-offset masked patterns have now failed under
marginal-likelihood evidence, a uniform prior, a 1% prior, and cross-validated
evidence. See [combinator](../combinator/) for relations that are
range-weighted rather than fixed-offset.
