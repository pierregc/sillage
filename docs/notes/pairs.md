# Four scenes in five are pairs

Pierre wants four scenes in five to have exactly two galaxies (#176), a globular or a dwarf
companion counting as a galaxy and a black hole as none. Library 2026-10-30-b held 25 pairs of
50, and its night picked a triple and a group of four.

## The batch, by place

- **Not by retuning `FreeDraw.countShares`.** The spacing rule weighs the count 1.5 in the
  signature, so as the corner of pairs fills it passes over more of them and the share sinks.
  The share is held by place instead, as the archetype share is: place `i` is a pair place when
  `floor((i + 1) × share)` passes `floor(i × share)`, so any ten places in a row hold eight.
- **A pair place** takes one of the six archetypes of two galaxies (all but `compact-group` and
  `black-hole-pass`), each once in every six such places, or a free draw of two galaxies. **Any
  other place** takes the compact group and the black hole's pass in turns, or a free draw of
  another count. A free draw is classed once its black hole is decided, which the scene's own
  stream does, so a triple whose companion became a hole is a pair.
- **Each kind of free place walks the batch's one Sobol sequence** and passes over the points of
  the other kind, so it keeps the spacing and the patience of a batch of its own and no point is
  drawn twice. Spacing each kind apart loses little: by the count alone a pair sits 0.375 from
  any other scene, past the 0.3 of the spacing, but for the few a black hole changed.
- **The others keep their shares among themselves**, but for the archetypes, which follow the
  archetype share in both kinds of place: the compact group and the black hole's pass are a
  quarter of the others where they were an eighth.

Drafts of 100 places on 11 batches (2026-10-30-b's seed and 1 to 10), the others as shares of
the others:

| | pairs | one galaxy | a galaxy and a hole | three | four | five |
| --- | --- | --- | --- | --- | --- | --- |
| before | 48 % | 12 % | 9 % | 37 % | 24 % | 18 % |
| after | 80 % | 12 % | 14 % | 30 % | 24 % | 19 % |

The first 50 places of 2026-10-30-b went from 25 pairs, 3 single galaxies, 2 with a hole, 9
triples, 6 groups of four and 5 of five to 40 pairs, 1 galaxy with a hole, 4, 2 and 3. The
library's own 50 (places 1 to 52, two groups of five rejected) were 25, 3, 2, 10, 7 and 3. Every
ten places in a row hold eight pairs, at 50 and 100 places, on all 11 batches.

## A batch started before

`batch.conf` records `pair_share`: the share, or `off` when `--galaxies` names the counts. A
batch whose file has none was started before the share, and resumes with `--pair-share off`,
the draw it started with: with the share off, 1 111 drafts of 11 batches give scene files equal
to the byte to those of the code before. The draw had drifted before this change, though: the
counts and archetypes of 2026-10-30-b come out as that night drew them, but 14 of its 50 scenes
have other families past their first two galaxies, which come from a stream other changes have
since drawn differently.

## The picks

The score leans to groups: 0.70 for pairs on 2026-10-30-b, 0.74 for triples and 0.81 for
groups of four. So each pick slot goes to a pair with the chance the share gives, drawn from the
batch seed in a stream of its own (`PAIRSLOT`, beside the world's `FREEWRLD`), and takes the
best pair, or the best of the others, or the best scene left once its kind runs out. A scene
marked yes by hand comes first. The picks are then ranked as before, so `progress.picks`, and
the worlds a resumed night draws from it, do not move. Taking the lean out of the score was the
other way, but the score is there to find what is interesting, not to balance it.

## Open

What counts as a galaxy is Pierre's question on #176. Today a globular or a dwarf companion
counts and a black hole does not, as `--galaxies` already read it.
