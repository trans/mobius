# Research status and next steps

_25 September 2026 — handoff note; updated 4 October 2026_

## Aim

Build a language model that makes predictions directly from corpus counts. The
current stream consists of character tokens (one byte per token in the ASCII
Tiny Shakespeare corpus). The statistical operations should also work on a
future stream of word or other token IDs, without adding word segmentation to
the character model.

We want to know how far exact corpus evidence can take us, including evidence
from noncontiguous context and from positions well beyond a short suffix. A
separate inference layer will decide how to combine that evidence. No neural
model is part of the present design.

## Agreed representation

- A context pattern has one to 16 positions in the current implementation.
  Each position specifies a byte or a fixed-position wildcard (`*`). Internal
  wildcards preserve the distances between specified bytes. Leading wildcards
  carry no constraint and are removed. Trailing wildcards move the target
  farther away: `a**` at target distance 1 equals `a` at distance 3.
- The CLI's target distance is measured from the end of the pattern as typed;
  distance 1 means its following token. After trailing wildcards are removed,
  the effective distance from the last specified byte includes their count.
  We want separate evidence for every useful positive distance; the index
  itself imposes no 1,000-position cap.
- The current query returns the empirical distribution of **one** target byte
  at a chosen distance. For semantic comparisons we also need joint events
  spanning several target tokens. Separate one-byte distributions at offsets
  1, 2, ... do not retain which bytes occurred together. For example, the
  continuation sets `{ab, ba}` and `{aa, bb}` have identical single-byte
  marginals at both offsets but different two-byte continuations.
- The proposed general operation is `cooccur(A, B, d)`: count corpus positions
  where the last specified token of context pattern `A` is at position `i`
  and event pattern `B` starts at position `i + d`. `d = 1` means adjacent;
  `B` may be one token, a multi-token sequence, or a masked sequence. Today's
  target-byte histogram is the case where `B` specifies one byte. This
  definition depends only on a stream of token IDs, so it applies unchanged
  after a tokenizer change.

## What exists now

The Crystal implementation is in [`src/mobius/index.cr`](../src/mobius/index.cr)
and the CLI is in [`src/mobius.cr`](../src/mobius.cr). It stores one positional
bit plane for each observed byte and a copy of the corpus. A masked-pattern
query intersects shifted bit planes to find matching endpoints, then reads
target bytes at the requested distance. It does **not** materialize a table
for every pattern, distance, and target.

The CLI provides `build`, `query`, `profile`, `cooccur`, and `events`.
`profile` reports support, empirical entropy, signed entropy change from the
previous distance, and the most common target byte. `cooccur` implements
`cooccur(A, B, d)` for a masked event `B`; `events` lists the observed
contiguous blocks of one length at distance `d`, so candidate `B` sequences
come from the corpus instead of from enumeration. `baseline` and `predict`
implement the contiguous-suffix Kneser–Ney control described below, using a
suffix array over the training text. `interactions` and `residual` mine
masked patterns that reach beyond the Kneser–Ney context and add them to it
([`src/mobius/interactions.cr`](../src/mobius/interactions.cr),
[`src/mobius/residual.cr`](../src/mobius/residual.cr), sharing
[`src/mobius/pattern_space.cr`](../src/mobius/pattern_space.cr)); both are
described under the observations below
([`src/mobius/kneser_ney.cr`](../src/mobius/kneser_ney.cr),
[`src/mobius/suffix_array.cr`](../src/mobius/suffix_array.cr)). The index format is versioned and currently requires
a little-endian machine. [`spec/mobius_spec.cr`](../spec/mobius_spec.cr) covers
wildcards, canonicalization, distant targets, bit-word boundaries, an index
round trip, joint counts against a direct scan, and a corpus whose
continuations `{ab, ba}` and `{aa, bb}` have identical single-byte marginals.
[`spec/kneser_ney_spec.cr`](../spec/kneser_ney_spec.cr) checks the suffix array
against direct sorting and counting, and the Kneser–Ney model against a
brute-force implementation at every held-out position and context limit.
Seventeen specs pass.

Tiny Shakespeare at `~/Projects/agpt/data/input.txt` contains 1,115,394 bytes
and 65 observed byte values. Its raw bit planes occupy 9,063,080 bytes; the
saved index, including its corpus copy and header, is 10,178,557 bytes. An
example index was built at `/tmp/tiny-shakespeare.midx` for local experiments;
rebuild it if that temporary file is gone.

```sh
mkdir -p bin
CRYSTAL_CACHE_DIR=/tmp/mobius-crystal-cache crystal build src/mobius.cr -o bin/mobius --release
bin/mobius build ~/Projects/agpt/data/input.txt /tmp/tiny-shakespeare.midx
bin/mobius query /tmp/tiny-shakespeare.midx 'the ca' 30
bin/mobius profile /tmp/tiny-shakespeare.midx 'ROMEO:' 40
CRYSTAL_CACHE_DIR=/tmp/mobius-crystal-cache crystal spec
```

The compiler cache override keeps Crystal's generated files in a writable
location in the current sandbox.

There is no automatic pattern miner, masked or distant predictor, or
semantic-similarity index yet. Those are the
proposed next layers.

## Observations worth keeping

### The contiguous-suffix baseline to beat

Interpolated modified Kneser–Ney over contiguous suffixes, nanoGPT's 90/10
split, context limit chosen on the last 10% of the training text:

| Context limit | 0 | 2 | 4 | 5 | **6** | 8 | 12 | 16 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Dev bits/byte | 4.773 | 2.907 | 2.204 | 2.154 | **2.152** | 2.166 | 2.166 | 2.165 |

Held-out result at limit 6: **2.1887 bits per byte (1.5171 nats)**. For
comparison, nanoGPT's README reports about 1.47 nats (about 2.12 bits) for its
small character transformer on the same split (quoted from memory; verify).
Longer contiguous contexts stop helping after six bytes because they are
rarely seen. The model then cannot see informative bytes further back:
for `the King of `, a limit-6 context sees only `ng of ` and predicts `t`
(0.32), not the `E`/`N` of England and Naples. Masked and distant evidence
must show its value as a reduction of this number.

### A truncated Möbius sum double counts

`interactions` mines patterns of up to 3 positions in a 16-byte window that
reach beyond the 6-byte Kneser–Ney context. It ranks them by bits saved over
their weakest parent and adds the Möbius terms of their subsets beyond
offset 6 to the Kneser–Ney log-probability. Every added pattern made held-out
loss worse: 2.1523 bits with none, 2.1542 with one, 2.2347 with 100, and
about 3.97 with 10,000 (sampled). The top pattern, a newline 7 bytes back, is
learned against plain byte frequencies (`I` 3.4×, `:` 3.8×), but at its
matches Kneser–Ney is already nearly right (`I` 0.054 expected, 0.058
actual), so the boost is counted twice. The dropped terms, interactions
between the far position and the whole near context, are large and negative,
and truncation sets them to zero.

### Patterns judged against Kneser–Ney help a little

`residual` judges each pattern by what Kneser–Ney gets wrong at its training
matches: actual next-byte counts a_x against the counts e_x that a
cross-fitted Kneser–Ney expected there (10 folds, each predicted by a model
trained on the others), with correction ratio (a_x + 1)/(e_x + 1). Patterns
with identical match sets are kept once.

| Folds | Development (best match only) | Held-out test |
| --- | ---: | ---: |
| Contiguous | −0.0013 bits | 2.1887 → 2.1845 (−0.0042) |
| Interleaved 1,000-byte blocks | −0.0042 bits | 2.1887 → 2.1845 (−0.0042) |

Contiguous folds leave each model blind to names local to a play, so the top
patterns compensate for that (`KING ******` predicting the `X` of `LEWIS XI`
at 14,546× before the smoothing fix). Interleaved folds remove those; the top
patterns are then line position (newline 7–13 bytes back: `.`, `?`, `;` 3–10×
less likely). Multiplying in every matching pattern still fails (+1.05 bits at
10,000 patterns; 26–70 patterns match per byte) because different patterns
make the same correction at the same positions. Only the best-ranked match is
used in the results above. A first version smoothed ratios with Witten–Bell,
which drives unseen bytes to d/(S + d) and produced infinite losses.

### Exact hits can be weak evidence

Lowercase `to be or ` has zero exact matches in this corpus. Uppercase
`To be or ` has one match, followed by `n` in “To be or none or little.”
The shorter `o be or ` also has one match followed by `n`; `or ` has 2,755
matches, of which 560 are followed by `t` and 86 by `n`. An inference engine
must distinguish a one-observation suggestion from a reliable distribution.
The phrase does not establish that the corpus contains the familiar Hamlet
quotation.

### Similar futures appear without word segmentation

The following counts use a **case-folded character stream** and ask for exact
four-character blocks beginning immediately after each pattern. These are
character blocks, not parsed words:

| Context `A` | Matches | `engl` | `napl` | `heav` |
| --- | ---: | ---: | ---: | ---: |
| `of ` | 3,711 | 17 | 8 | 26 |
| `queen of ` | 8 | 2 | 1 | 1 |
| `king of ` | 29 | 4 | 4 | 2 |

The three blocks are elevated after both longer contexts relative to the
common `of ` context. This suggests a shared predictive role, but the sample
sizes are small. The comparison should use smoothed probabilities and a
held-out check before treating it as a stable relation. The possible
continuations form a loose category through shared probability changes; a
small raw entropy value alone would not establish that category.

### Entropy alone is insufficient

Abrupt drops in target entropy at a distance may mark a binding to earlier
context; rises may mark a release from that binding. The full target
distribution matters in either case. Empirical entropy is biased downward at
low support, and a distribution can be informative relative to its baseline
without having especially low entropy. Long-distance correlations from the
earlier AGPT investigations motivate searching beyond the 16-position
context span; they still need out-of-sample validation here.

The broader research goal is a distributional comparison across the lattice
of weaker/stronger masked patterns and across target distances: something
akin to a family of KL-like information gains, with the important changes
retained and noise pruned. The exact statistic, how to treat entropy rises,
and whether a Möbius decomposition yields useful interaction terms remain
open questions.

## Proposed similarity and inference layers

For each observed pattern `A`, collect a sparse signature of events `(B, d)`:
the conditional frequency of `B` at offset `d`, its support, and its change
relative to a weaker or shared baseline pattern. For `queen of ` and
`king of `, `of ` is a useful common baseline. Comparing these signatures
would give an operational form of **predictive similarity**: patterns are
related when they change the probabilities of many of the same future events
in similar ways. Offline similarity research could also use events before
`A`; next-token inference itself must use only preceding context.

Candidate comparisons include smoothed Jensen–Shannon divergence between
distributions at the same offset and block length, or similarity of sparse
log-lift vectors. These are
proposals, not implemented choices. Their weights should reflect support,
redundancy between nested character blocks, and performance on held-out text.
Predictive similarity may express a shared role without implying that two
strings are synonyms.

An unseen full context has no direct continuation signature. Inference can
first fall back through weaker exact patterns in the mask/suffix lattice. A
later similarity layer can also use observed substrings and their surrounding
co-occurrences to retrieve analogous observed contexts. That transfer must
be visible in the evidence output, and it must be tested against exact-count
backoff rather than assumed helpful.

For each prediction, show a table of evidence actually used, with columns
such as context pattern, event/target, distance, context support, joint count,
raw and smoothed conditional probability, baseline probability, and effect on
the final score. A top target without its support and provenance hides the
main research question.

## Next considered steps

1. **Done (4 October 2026).** Exact `cooccur(A, B, d)` queries for masked
   multi-token `B`, plus `events` to generate candidate blocks from observed
   matches. Masked event *shapes* in `events` (for example, tallying the
   bytes at offsets 1 and 3 together) are not implemented yet.
2. Make an exploratory report comparing character-block signatures for
   `queen of `, `king of `, and control contexts. Try several block lengths
   and offsets. Decide how to avoid counting nested prefixes (`e`, `en`,
   `eng`, `engl`) as independent evidence.
3. **Baseline done (4 October 2026):** contiguous-suffix Kneser–Ney with an
   evidence table, scored at 2.1887 held-out bits per byte. Masked patterns
   judged against it give 2.1845 (see the observations). Combining
   overlapping patterns needs greedy refitting, each batch measured against
   the model that already includes earlier ones. The largest observed miss
   is recency (`DUKE VINCENTIO` in the development text: 4.4% actual, 1.2%
   predicted), which no 16-byte window can see.
4. Mine promising patterns starting with spans up to 8 and a provisional
   distance cap, perhaps 1,000. Use support, parent-relative distribution
   change, and held-out improvement to prune. A 16-position maximum and
   arbitrary-distance queries remain available. Avoid storing the full
   pattern × distance product.
5. Compare the inference layers on contiguous held-out corpus sections, with
   enough separation to prevent long-distance windows from crossing the
   train/test boundary. Track next-character log loss and the specific gain
   attributable to masks, distant events, and similarity transfer.

Open questions include the best event lengths and offsets, a defensible
significance threshold under many candidate tests, how to combine overlapping
evidence without double counting, whether case folding should be an optional
view, and when a larger token alphabet calls for positional postings instead
of one bit plane per token.

## Related work and earlier notes

- Shalizi and Crutchfield's [computational mechanics paper](https://csc.ucdavis.edu/~cmg/compmech/pubs/cmppss.html)
  formalizes predictive equivalence of histories. Our finite-corpus signature
  comparison is an approximation inspired by that idea, not an implementation
  of their causal-state reconstruction algorithm.
- [Levy, Goldberg, and Dagan (2015)](https://aclanthology.org/Q15-1016/)
  demonstrate useful semantic similarity from count-based distributional
  representations.
- Prior local AGPT explorations: `~/Projects/agpt/rnd/skip-horizon-agpt/README.md`
  and `~/Projects/agpt/notes/trie-structure/shakespeare-h0-depth-profile.md`.
