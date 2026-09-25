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
```

The query command prints the exact target-character histogram and entropy in
bits. The profile command prints one row per distance and a signed entropy
change: positive means entropy fell from the previous distance; negative means
it rose. Leading ignored positions are removed; trailing ones are added to the
target distance. For example, `a**` at distance 1 is `a` at distance 3.
These are empirical counts; a sharp change with very few matches is not yet
evidence of a reliable correlation. Automatic pattern mining and significance
filtering are separate steps.

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
