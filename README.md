# Mobius: exact masked-context counts

Current research decisions and next steps are in
[`docs/research-status.md`](docs/research-status.md).

This Crystal tool stores one bit plane for each byte found in a corpus. It can
answer an exact count query for any masked context of up to 16 positions and any
positive target distance without storing a table for each pattern or distance.
The current implementation treats bytes as character tokens; Tiny Shakespeare
is ASCII, so bytes and characters coincide. `*` means one ignored position;
`\\*` means a literal asterisk. A period is always a literal period.

## Build and query

```sh
mkdir -p bin
crystal build src/mobius.cr -o bin/mobius --release
bin/mobius build ~/Projects/agpt/data/input.txt tiny-shakespeare.midx
bin/mobius query tiny-shakespeare.midx 'the ca' 30
bin/mobius query tiny-shakespeare.midx 't*e ' 30
bin/mobius profile tiny-shakespeare.midx 'ROMEO:' 40
bin/mobius cooccur tiny-shakespeare.midx 'King of ' 'Engl' 1
bin/mobius events tiny-shakespeare.midx 'King of ' 4 1
bin/mobius baseline ~/Projects/agpt/data/input.txt
bin/mobius predict ~/Projects/agpt/data/input.txt 'the King of ' 6
```

The query command prints the exact target-character histogram and entropy in
bits. The profile command prints one row per distance and a signed entropy
change: positive means entropy fell from the previous distance; negative means
it rose. Leading ignored positions are removed; trailing ones are added to the
target distance. For example, `a**` at distance 1 is `a` at distance 3.
These are empirical counts; a sharp change with very few matches is not yet
evidence of a reliable correlation. Automatic pattern mining and significance
filtering are separate steps.

The cooccur command counts a joint event: how many context matches have an
event pattern `B` starting at the given distance. Its support counts the
matches whose event window fits inside the corpus. `B` may contain wildcards;
leading ones delay its first literal, so `*b` at distance 1 is `b` at distance
2. The events command lists the contiguous blocks of a given length that
actually occur at that distance, with their counts. These joint counts keep
information that one-byte histograms at separate distances lose: continuations
`{ab, ba}` and `{aa, bb}` have identical single-byte marginals.

## Kneser–Ney baseline

The baseline command measures how well contiguous suffixes alone predict the
next byte. It uses nanoGPT's split: the first 90% of the corpus supplies
counts, and the last 10% is held out. It fits interpolated modified Kneser–Ney
(Chen and Goodman) with a suffix array over the training text. The context
limit, from 0 to 16 bytes, is chosen on the last 10% of the training text
before the held-out text is scored once. Results are in bits per byte and in
nats per byte, nanoGPT's loss unit. The predict command prints the evidence
for one context: each suffix length, its occurrences, whether raw or
continuation counts were used, its backoff weight, and how the top
candidate's probability changes at each level.

For the 1,115,394-byte Tiny Shakespeare corpus and its 65 observed bytes, the
raw bit planes occupy 9,063,080 bytes, including 64-bit word padding. The
index also contains a copy of the corpus for reading target bytes. The on-disk
format uses little-endian 64-bit words and is currently supported on
little-endian machines.

The index answers queries on demand. It does not enumerate all masked contexts
or distances. A practical mining pass should start with spans up to 8, use
occurrence support to prune the mask lattice, and retain only entropy changes
whose full target distributions survive held-out checks. Larger distances do
not increase the base index size, although scanning many distances increases
query time.

## Verify

```sh
CRYSTAL_CACHE_DIR=/tmp/mobius-crystal-cache crystal spec
```
