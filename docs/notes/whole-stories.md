# Whole stories

A clip used to run a fixed 700 Myr after 80 Myr of settling, whatever the scene did in it
(#13's settings). #123 makes it run from the approach until nothing moves: `explore` follows
the story past the planned frames, records where it starts and ends in `clip.json`, and `hires`
replays exactly that. The detector is `Story` in `SillageCore`; `sillage-render story <folder>`
runs it again on curves already written.

## How many stories were cut

The 35 scenes of `library/2026-10-25-night`, judged on their `curves.csv` as explored:

**16 of 35 were still going when their clip ended**, judged with the detector below on the
curves as explored, 700 Myr after 80 of settling:

- tails still forming: 0004, 0008, 0014, 0016, 0023, 0026, 0027, 0029, 0031, 0032, 0034;
- a pair bound and coming back: 0018, 0019, 0021;
- a disk still being disrupted: 0012; the remnant's extent still changing: 0033.

The other 19 end inside their clip, two of them lone galaxies with no collision at all.

## The detector

It reads only what `curves.csv` holds, frame by frame, and decides with the frames up to now:
explore has to know whether to go on without seeing the future. The story is over when no
collision is still to come and either a whole window of 150 Myr has been quiet or the aftermath
has run out. It ends on the first frame of the over that lasts to the end of the run, so a clip
closes on up to 150 Myr where nothing changes. Explore judges the lines it has just written to
`curves.csv`, rounding included, so `story` on the file gives the same answer.

**No pair comes closer again.** Each pair's relative velocity is fitted over the last 20 Myr of
centres, and its energy taken in the potential the generator places encounters with
(`EncounterCentres`, so each galaxy pulls with the mass it holds inside the separation). Then:

- unbound and receding: parted for good;
- the inner turning point at that energy and angular momentum, the next pericentre if nothing
  intervened, is wider than 1.5 times the two disks' combined reach (`SceneCheck.reach`): it
  passes wide, which is not a collision;
- unbound and approaching closer than that: a collision is coming;
- bound and coming back closer than that: a collision is coming, unless the pair has settled;
- due after 2 Gyr of simulated time, timed along that orbit: not this story. Without it, a pair
  bound at 300 kpc kept 0012 going to the cap for a pericentre billions of years away.

**Merged centres stay together.** After a merger the two centres of mass do not meet. What is
left of a disrupted disk has its centre wherever its debris is, and in five of the scenes it
sat 20 to 50 kpc from the other and drifted slowly outwards for hundreds of megayears, with no
tangential motion at all (0003, 0004, 0011, 0030, 0033). Taken as an orbit, the potential says
such a pair should fall straight back through the centre; it never does. A bound pair counts as
settled when, over the window, its separation stays within 30 % of itself (or 3 kpc) and curves
by less than 0.3 of the pull the potential predicts at that separation. A real orbit inside its
reach does not pass: near apocentre at 40 kpc it falls back by 4 kpc in 75 Myr, which is the
pull it should have, and at a pericentre the curvature is large the other way. A satellite on a
circular orbit passes, which is right: it will sink in eventually, but not in a clip.

**Tails, extent and disruption change by less than a threshold over the window.** Measured per
100 Myr on the night's curves: the share of stars in tails moves by 0.1 to 1.5 % when nothing
happens and by 3 to 24 % while tails form, so 2 % over the window. Extent is the hard one: an
isolated disk, the control, spreads by 6 to 9 % per 150 Myr all by itself (0006 and 0017,
scattered outskirts), and so does a merger remnant whose debris expands; a 5 % threshold never
ends anything. It is 15 %, and it is only judged while every pair is within its reach: galaxies
parting stretch the extent for as long as they move, whatever the stars do. Disruption only
ever rises; more than 0.05 over the window is a disk still being taken apart.

**The aftermath runs out.** The first detector, with only the window, ran the twenty scenes
still going at the end of their clip on to 2 Gyr, and seven of them reached it. In four the
tails share kept rising long after both galaxies had parted or merged: 0009 and 0020 (+0.11
and +0.24 after the end found now), 0012 (+0.29) and 0027 (+0.56). It is not a story: a
dwarf's stream lengthening hundreds of kiloparsecs away, a disk heating on its own at 100 000
particles until its disruption reading creeps up, or, in 0027, the two centres of mass of a
merger remnant drifting 40 to 90 kpc from the core with its debris, so that stars sitting in
the remnant count as beyond every centre. The preview frames show nothing happening. So once
no collision is to come, the story may run 400 Myr past the last moment a pair was inside its
reach and still moving as two bodies, whatever still changes: tails form within 250 Myr of a
pericentre on the night's curves (0004, 0011, 0014, 0022, 0030, 0033), and the window closes
the clip.

**Checked on the long runs.** Nineteen runs went on 76 to 1 367 Myr past the end the detector
found. None has a pass of any pair below its reach after it, and the preview frames after it
(0009, 0012, 0020, 0027) show a remnant settling or galaxies drifting apart.

## Where the story starts

At the first collision, the first pass of any pair below its reach confirmed by the pair
separating again, less 150 Myr: what the clip opens on is the approach. A scene with no
collision keeps the clip it planned.

The generator used to map the pericentres it draws over 60 to 420 Myr onto the whole clip,
so an archetype that puts its passage early in that window (`along` 0.02 to 0.25) landed on the
clip's first frames. Read off the curves, four of the 35 scenes showed less than 100 Myr of
approach: 0003 (68 Myr), 0015 (20), 0019 (56) and 0035 (74). Pericentres are now mapped onto
the clip less its first 150 Myr (`SceneConfig.encounterWindow`). The same 35 draws placed that
way put every first pericentre 165 to 505 Myr after the clip starts (`--check-only`); a pair
lands within a few Myr of where it is placed and a group of four within 5 to 20 %
([encounters](encounters.md)), so the 100 Myr hold. A batch resumed across this change draws
its later scenes with the new placement.

## How much longer

The 20 scenes not over at the end of their clip, or not judged over by the first detector, were
explored again from their `scene.json` at the batch's own size, past the clip until the story
ended and then 300 Myr more (`--story-after`, for the check above), four at once. What each needs
past its planned end:

| scene | galaxies | ends at | more than planned |
| --- | --- | --- | --- |
| 0004 | 2 | 965 Myr | 174 Myr |
| 0008 | 3 | 992 | 201 |
| 0012 | 2 | 935 | 144 |
| 0014 | 2 | 870 | 97 |
| 0016 | 4 | 1 033 | 242 |
| 0018 | 3 | 1 062 | 271 |
| 0019 | 4 | still going at 2 000 | 1 209 or more |
| 0021 | 5 | 1 924 | 1 133 |
| 0023 | 2 | 1 113 | 180 |
| 0026 | 4 | 907 | 116 |
| 0027 | 2 | 1 156 | 365 |
| 0029 | 3 | 833 | 75 |
| 0031 | 2 | 1 071 | 286 |
| 0032 | 5 | 969 | 59 |
| 0033 | 2 | 808 | 17 |
| 0034 | 3 | 1 116 | 325 |

0003, 0007, 0009 and 0020 end inside their clip: the first detector kept them going on a pair
bound more than 100 kpc apart or on tails that never stop rising, which is what the horizon
and the aftermath answer.

Over all 35 scenes, a story runs 140 Myr past the planned span on average, a fifth of it; the
median of the 16 is 190 Myr. Only groups of four or five need more than 400. The placement above
moves each scene's last pericentre 78 Myr later on average, which brings the average to about
177 Myr, a quarter of the span: `explore-batch.sh` budgets a scene at its planned span times
1.25 (`STORY_EXTRA`, and `Story.extraShare` for whoever plans in Swift). The nineteen that end
inside their clip still cost their planned span: explore never stops early, and `hires` is where
a short story saves time.

**The cap stays at 2 Gyr.** One scene of 35, a group of four still trading passes at 1 800 Myr
(0019), reaches it; the next longest, 0021, ends at 1 924. A longer cap would buy one scene in
35 a clip of over a minute at the preview's cadence. `interest.py` halves the score of a story
still going at the cap, so the night picks prefer the ones they can show whole.

## Downstream

- `clip.json` keeps `frames` and `steps` as they ran, and `story` with its first and last frame,
  their megayears, and `complete`, false when the run reached the cap with the story going on.
- `hires` settles through everything before the story's first frame and stops at its last;
  `--frames N` takes the first N frames of it. A `clip.json` from before has no story and
  replays its whole clip.
- `export` already took the whole take unless `--start` or `--duration` say otherwise.
- `interest.py` multiplies the score of a story still going at the cap by 0.5, so the night
  picks prefer scenes they can show whole; `interest.json` keeps `story_complete`.
- `explore-batch.sh` budgets a scene at its planned span plus the share measured above, and
  writes the frames and steps that ran into `index.csv`, which is what the cost model reads.
  `CostModel.hiresSeconds(_:particles:)` prices a scene's hires on its own story.
