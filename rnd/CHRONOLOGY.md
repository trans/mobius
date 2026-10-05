# `rnd/` Chronology

The order in which the experiments under `rnd/` were tried. Each directory's
`README.md` has the idea, method, commands and results.

| Order | First seen | Experiment | Outcome |
| --- | --- | --- | --- |
| 1 | 2026-10-04 | [kneser-ney-baseline](kneser-ney-baseline/) | Reference: 2.1887 test bits per byte at context limit 6. |
| 2 | 2026-10-04 | [mobius-truncation](mobius-truncation/) | Negative: mined patterns double count what Kneser–Ney already knows. |
| 3 | 2026-10-04 | [residual-patterns](residual-patterns/) | Small gain: 2.1845 test with patterns judged against Kneser–Ney, best match only. |
| 4 | 2026-10-04 | [recency-cache](recency-cache/) | Mostly an artifact: online Kneser–Ney alone reaches 2.0595; recency adds about 0.017. |
| 5 | 2026-10-05 | [lattice-self-weights](lattice-self-weights/) | Negative: 2.87 against 2.14 on sampled test bytes. |
| 6 | 2026-10-05 | [lattice-sufficiency](lattice-sufficiency/) | Trails Kneser–Ney by 0.095 bits even with suffixes only: the prior stops refinement at ~3 positions. |
| 7 | 2026-10-05 | [combinator](combinator/) | Design: the effect of a far pattern on a target given the near pattern. |
