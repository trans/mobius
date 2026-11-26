# Research and development experiments

Each idea we try gets its own directory here with a `README.md` that explains
the idea, the method, how to run it, and its results. Results are appended as
dated sections; earlier results are never rewritten. A correction is a new
dated section that says what was wrong. [`CHRONOLOGY.md`](CHRONOLOGY.md) lists
the experiments in order.

Each `README.md` starts with front matter:

```yaml
title:     short name
kind:      experiment | design
status:    planned | running | concluded
outcome:   positive | negative | mixed | reference | n/a
question:  the question the experiment answers
answer:    the answer so far, with the headline numbers
opened:    date
updated:   date
code:      branch or commit
eval:      which protocol and sample
tags:      [...]
related:   [other experiment directories]
```

## Evaluation protocol

All experiments use the same protocol unless their README says otherwise.

- **Corpus:** Tiny Shakespeare, `~/Projects/agpt/data/input.txt`, 1,115,394
  bytes, 65 distinct byte values. One byte is one token.
- **Task:** predict each byte from every byte before it. The score is the mean
  of −log₂ P(actual byte): bits per byte. Perplexity is 2^bits.
- **Splits** (nanoGPT's 90/10 split, with a development tail):

  ```text
  0            903,468      1,003,854      1,115,394
  |-- training --|-- development --|---- test ----|
  ```

  - Settings are chosen by scoring development bytes, with counts from
    `[0, 903,468)`.
  - The test text is scored once, with settings frozen, and counts from
    `[0, 1,003,854)`.
  - No setting is ever chosen by looking at the test text. A model may read
    the history before the byte it predicts, including earlier test text.
- **Reference:** interpolated modified Kneser–Ney at context limit 6:
  2.1523 development and 2.1887 test bits per byte
  ([kneser-ney-baseline](kneser-ney-baseline/)).
- **Samples:** an experiment that scores only every *n*th byte must compare
  against Kneser–Ney on the same bytes and report paired standard errors.
  Every 100th byte is about 1,000 bytes: across the 100 possible starting
  offsets, Kneser–Ney's development mean ranges from 1.94 to 2.34 (sd 0.072).
  Never compare a sampled number with a full-set number.
- **Static or online.** A model that adds the text it has read to its counts
  must be compared with a Kneser–Ney that does the same. Online Kneser–Ney
  (counts refreshed every 2,000 bytes) scores 2.0595 test bits per byte,
  against 2.1887 frozen ([recency-cache](recency-cache/)).
- **Test reuse.** Every look at the test text spends some of its credibility.
  Development decides; the test text confirms a finished result, once.

## Building and verifying

```sh
CRYSTAL_CACHE_DIR=/tmp/mobius-crystal-cache crystal build src/mobius.cr -o bin/mobius --release
CRYSTAL_CACHE_DIR=/tmp/mobius-crystal-cache crystal spec
```
