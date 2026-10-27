# Favourite palettes

A heart on a palette in the style editor (#116) keeps it in `palettes/<name>.palette.json`,
next to `looks/`. The file is a `Palette` as `look --palette <file>` already reads it: world,
family, harmony, seed and the colours.

## Choices

- **The name is the file.** The heart asks for a name once; it becomes a slug (`Soir d'Été` →
  `soir-d-été`). A name never overwrites another favourite. Clicking a full heart deletes the
  file, so the repository's history is the undo.
- **A favourite fits a scene by its world and its galaxy count.** One with more colours than
  galaxies keeps its first ones; one with fewer is left out (`FavouritePalettes.fitting`). The
  heart recognises a cut favourite as itself.
- **In the editor** the favourites that fit come first in the proposals, ahead of the six best
  of the round; a generated palette equal to a favourite is not shown twice.
- **In the night and in Auto** a favourite is a candidate drawn before the generated ones, so it
  wins a tie (`PaletteAuto.ranked(favourites:)`). It does not win by being a favourite: the
  score still decides, or a night of picks would all get the same palette. Auto (editor and
  `look --style auto`) tries the fitting favourites among its palettes.
- **A night names one**: `style.palette: "soir"`, or `look --palette soir`. Its world is the
  pick's, as for a family. A favourite wins over a family of the same name.
- **A file that does not decode is skipped**, and the test that decodes every file in
  `palettes/` is what catches it.

## Checks

`--lookcheck` drives the heart in a temporary folder (never `palettes/`): the name is asked,
the file written, the favourite first among the proposals, absent from the other world, then
removed by a second click.
