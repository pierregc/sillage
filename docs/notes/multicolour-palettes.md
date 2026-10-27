# Several colours per galaxy, in the generator and the editor

#119 gave every galaxy a ramp of colours (`docs/notes/galaxy-colours.md`); #120 makes them a
choice of the palette. A `Palette` has a `multicolour` flag, on unless a file says otherwise,
so every palette and recipe written before reads as it did.

## What the generator holds

`PaletteGenerator.palette(... multicolour:references:)` draws as before, then, in the free world,
refuses a palette whose ramps break `RampMeasures`:

- **Inside a galaxy**: the turn of hue from its disk colour to its core and to its outskirts
  sits on a harmonious interval (up to 60° analogous, then 120°, 150°, 180°), at most 20° off.
  The ramps are derived from the family's arcs, so this nearly always holds (the 90th percentile
  of the miss is 12°); it is a guard, and a score (`inside`: 1 on an interval, 0 from 30° off).
- **Between galaxies**: the smallest distance, at the common lightness, between one galaxy's disk
  or outskirts and the other's disk or outskirts is at least 0.07. This is the limit that bites:
  most plain palettes of 3 or more galaxies break it. Cores are left out, since they all lean
  toward gold, and knots glow warm in every galaxy.

Palettes still come out for every family, harmony and number of galaxies, except pastel with two
analogous galaxies, which can now find no room (one seed in forty).

The telescope ramps are the pictures' own regions (#125) tinted 30 % by the galaxy's colour, so
two galaxies' ramps are close by design (`apart` 0.01 to 0.04). They are scored, not refused.

## What the scores read

| Score | Part | Weight | Only |
| --- | --- | --- | --- |
| `PaletteScore` | `inside` | 0.10 | free world, multicolour |
| `PaletteScore` | `between` (1 from twice the floor) | 0.15 | multicolour |
| `FrameScore` | `variety` (spread of the lit pixels in the chromatic plane, 1 from 0.08) | 0.10 | when the palette has ramps |

The other parts are renormalised without them, as for `reference`. On three night scenes
(150 k, and 2 M with 2 and 3 galaxies) the free world's ramps spread 0.05 to 0.06 where one
colour spreads 0.03 to 0.05; the telescope's spread is 0.02 either way, so its `variety` is low
whatever the palette, and Auto only compares palettes of the same world.

## In the tools

- **Style editor**: a Multicolore switch in the Palette section. A galaxy with a ramp shows it as
  a bar (core, disk, outskirts, then the young and knot colours) above its colour picker, and the
  proposals show the same bars. The switch starts as the scene's look is: on for a look with
  ramps or without a palette, off for plain colours. Flipping it reshapes every galaxy that is
  not locked and keeps each one's colour, hand-picked or not, then draws the proposals and Auto
  the same way. Annuler puts it back with the saved look.
- **Night**: `style.multicolour` (`false`; Auto is on). Auto picks among multicolour palettes,
  favourites included, and `look --style auto` does the same.
- **Command line**: `--single` on `look --palette`, `look --style auto`, `export --palette`
  and `palettes` draws one colour per galaxy. `palettes --best` prints `inside` and `between`,
  `look --style auto` prints `variety`.

## Checks

`--lookcheck` flips the switch on a take: plain look off, then on with the lock and the chosen
colour kept, proposals with and without ramp scores, and Auto with ramps. `--uishot` writes
`out/ui-style.png` with the ramps.
