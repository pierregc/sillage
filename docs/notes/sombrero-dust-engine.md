# Sombrero dust in the engine: handover (#506)

Branch `feat/506-sombrero-engine` (worktree `~/claude-workspace/sillage-wt-506`), cut from `feat/485-dust-texture`, `slabs-479` merged in (c639cf7). Working files in `~/claude-workspace/sombrero/out/506/s2/` (`S2` below); images in `~/claude-workspace/sombrero/banc/506/`.

## Build and run
- Build: `scripts/dev.sh build` in the worktree (about 2 min) gives `.build/dev/sillage-render`. Run it through `~/claude-workspace/sombrero/sr506.sh` (cd to the worktree, DYLD_LIBRARY_PATH set). Never rebuild while a take or render runs: it replaces the running binary.
- Lint: `scripts/dev.sh lint` (swift format; `swift format --in-place <files>` fixes it).
- Every GPU job goes through `scripts/gpu-lock.sh run <label> <cmd...>`, `dev.sh check/test` included (check takes about 4 min).
- Take: put `scene.json` and `clip.json` (copied from `lib/sombrero-8m-s7`) in a folder, then `gpu-lock.sh run L sr506.sh hires <folder> --particles 8000000 --frames 52|240 --no-video`. 52 frames reach 12.6 Myr (1.7 min); 240 reach 60.5 Myr (7.3 min, 4.1 GB). Peak memory 5.9 GB. `S2/cloudtake.sh <name> <frames> '<clouds json>'` writes `lib/sombrero-8m-<name>` from c1's scene with the clouds block updated.
- Freeze frame (4K, about 5 s): `S2/draw.sh <name> <scene folder> <look> <flight> [export opts]` writes `S2/<name>.png`. Use absolute paths (it cd's into the worktree).
- Sheets: `S2/show2.sh <name> <prefix> [label]` writes `<prefix>-cut.jpg`, `-pair.jpg` and `-closeup-film.jpg` (near lane only) to banc/506 and prints the lane figures and the texture score (grid 3072). It is built on `references/sombrero/tools/film_split.py` (`split`, `framing`, `sheet`) and `closeup.py --scale 3840`.
- Clips (1080p HEVC, 7 s, about 5 min each): `gpu-lock.sh run L sr506.sh export <take> --look <look> --flight S2/clip-cotton-{hubble,tilt}.flight.json --preset 1080p --out <mp4>`. Flights run 0.5 to 60 Myr. Hubble: 800 kpc, 6 deg, 26.5 kpc across, roll 0.1. Tilt: 30 deg elevation, 34 kpc across. `S2/cotton-runs.sh` does both clips plus the edge-on still.
- Edge on: `export ... --flight S2/s-edge-{whole,close}-cotton.flight.json --flight-keys <dir> --flight-at 0 --preset 4k` (whole galaxy from 800 kpc; near ring from (0,-14,0) disk axes, aim (0,-7,0), fov 0.1). Sheet via `S2/tools/sheets.py`.
- Lane depth vs Hubble: `S2/tools/lane.py <frame-hf.png>`, the opacity across the near lane. Hubble: sum 62, tips 57.
- Colour excess by depth: `S2/tools/colour.py`.
- Layer thickness: `S2/tools/layer.py <take> <myr>`. Clumping and thickness over time: `S2/tools/clump.py <take>`.

## Options added (all off by default)
Flight file `inside.dustScreen` (Metal only, inside library). Struct `DustScreenRef` in `Sources/SillageRender/DustScreen.swift`; field in `InsideSettings` (`Inside.swift`):
- `tile` (path to a `.tile.json`), `galaxy` 0, `rest` 0 (Myr: the moment the tile lies as written), `depth` 1 (dust per unit of the tile).
- `law` absent: `{diffuse:[r,b,t], rim:[r,b,t], rimRadii:[a,b]}`, the per-channel share of green depth tending to 1 past t.
- `renew` 0 (Myr period). `front` absent (`[a,b]`: keep the screen by the radial share of the line of sight).
- Tile JSON (`DustScreenTile`): `width`, `height`, `radii`, `data` (raw f32), optional `lut {data, width, range}` (the tile then holds normal scores).

Code locations:
- `Shaders.swift`:
  - `webGrain`: the screen galaxy's grains all go to the carrier at every angle.
  - `webCarrier`: no x2 widening for the screen galaxy.
  - `screenRealization`, `screenAt`, `screenFront`, `screenResolved`, and `webResolveFragment`'s extra `buffer(2)`, `texture(3)` and `texture(4)`.
  - `screenExtinction`: the law, called in `splatFragment` and `pointStarFragment` under function constant 21.
  - `InsideUniforms.screenGalaxy` (appended, mirrored in `Inside.swift`).
- `DustWebMetal.swift`: `Pass(coarse:)`; the carrier is at full resolution when a screen is on.
- `InsideMetal.swift`: `webPass(coarse:)`, `screenTile()`.
- `Renderer.swift`: `ScreenUniforms` and `ScreenLaw` bindings in `.webResolve` and `.stars`; `additive(screenLaw:)`.

Behaviour:
- Without `front`, a ray that never meets the plane gives a flat veil; this is why the screen breaks edge on.
- With `front`, grazing rays (|cos| < 0.03 to 0.07) give way to the grains.

Sampler, `scene.json` `dustRing.clouds` (needs `sheet` > 0):
- `GalaxyConfig.DustRing.Clouds` in `Sources/SillageCore/GalaxyConfig.swift`.
- `DiskSampler.ringClouds`, `ringsRadius`, and the placement branch in the per-particle loop (`if sheeted, let ring, let clouds`).
- Fields and defaults: `rings` [[r, sigma, peak]] (required), `share` 0.75, `length` [0.1,0.3] kpc, `aspect` [2.5,4], `count` 5000, `slope` 1, `knots` 4, `knotSpread` 0.3, `grainSpread` 0.35.
- Cloud grains get a random swing phase and no lift ripple: no strata edge on.

## Values per image
- 04-b6, 05-b1, 06-c7: tiles `b6`, `b1` (`screen_tile.py b`) and `c7` (`screen_tile.py c`).
  - depth 0.45 / 0.5 / 0.32, rest 12.
  - law diffuse [0.55,1.47,10], rim [0.7,1.2,0.25]; rimRadii [6.09,6.86] (C7 [6.57,7.34]).
- 09-b1: tile `b1r` (`screen_tile.py b references/sombrero/dust-tracks/b/f1-ring.json`), depth 0.5, the same law. The turns are `np.roll` of the tile.
- 10-b1-renew: tile `b1z` (`screen_tile.py bz f1-ring.json`), the same values plus `renew` 16.
- 12-cotton-only: take c4 (stills) / c4f (60 Myr), `S2/freeze-far.flight.json` (no screen, `dustSlabs` 1.2).
- 12-cotton-front and the clips: b1z, depth 0.5, rest 12, the same law, `front` [0.5,0.9]; the clips add `renew` 16.
- Camera everywhere since stage 2: 800 kpc, fov 0.018632 (26.5 kpc across a 16:9 frame), roll 0.10. Look: `S2/looks/sombrero-506.look.json`, v6's unchanged.

Takes in `~/claude-workspace/sombrero/lib/`:

| take | contents | span | images |
|---|---|---|---|
| sombrero-8m-v6 | threads | 0-450 Myr | 01, 02 |
| sombrero-8m-s7 | smooth sheet, `references/sombrero/scene-screen.json` | 0-60 Myr | 03-10 |
| sombrero-8m-c1 … c4 | cloud trials | 12.6 Myr | 12 stills (c4) |
| sombrero-8m-c4f | clouds, `references/sombrero/scene-clouds.json` | 0-60 Myr | 12 clips, edge on |

## Cotton clouds (c4)
- `dustRing`: radius 6.85, width 1.5, thickness 0.02, sheet 1, cotton 0.
- `clouds`: rings [[6.1,0.48,1.5],[7.9,0.25,2.5],[8.75,0.18,2.5],[6.85,1.5,0.6]], share 0.75, length [0.3,0.8], slope 2, aspect [2,4], count 2500, knots 16, knotSpread 0.35, grainSpread 0.2.
- How a grain is placed:
  - complexes by area; centres drawn from the rings (weight sigma x peak x r);
  - knots Gaussian at knotSpread x size, weighted by a log-normal count;
  - grains Gaussian at grainSpread x size round a knot, the along-rotation offset divided by r for the angle.
- 1.2 M dust grains at 8 M (`dustFraction` 0.6 of the disk). Raising it changes the disk's star count, which is the light.
- Trial history: c1 (5000 one-size clouds) read as confetti; c2 smeared; c3 sparse flakes; c4 is the first band.

## Screen tile
- `references/sombrero/tools/screen_tile.py b|bz|c SPEC OUT`.
- Polar grid: 312 radii from 4.6 to 11 kpc by 16384 azimuths. theta runs from -pi to pi; -pi/2 is the disk's -v axis, the near side seen from Hubble's axis.
- Values: the sky column N x sin 6.
- `bz`: per-radius normal scores of track B's texture, plus a lut (256 columns over [-4,4]) mapping score to column per radius. It needs `carrier: polar`, `prof: radius`, `tips: false`.
- `c`: track C drawn at 6 deg, near and far halves read back apart. It is right at 6 deg and a flat sheet elsewhere.
- Renewal: two copies, s = (t-rest)/P + k/2, weight cos^2(pi u), age u·P, a random rigid azimuth per cycle (id 0 is the tile as written). Scores are blended as sum(w z)/sqrt(sum w^2), then the lut. The still at rest is identical to no renewal.

## Dust over time (measured from the takes)
- Layer rms at 12 Myr: v6 threads 24 pc; s7 sheet 7-15 pc (FWHM 17-38); c4f 10.5 (0) -> 11.3 (12) -> 18 (30) -> 35 pc (60).
- Clumping <n(n-1)>/<n>^2 in 25 pc cells: c4f 1.6 -> 1.7 -> 2.4 -> 3.5 (100 pc cells: 1.55 -> 2.3). Clouds never blur; they bead.
- Shear draws them into trailing arcs, hairlines by 45-60 Myr.
- **The ring falls inward** in both s7 and c4f:
  - median radius steady to 12 Myr, then -0.19 kpc at 30 and -0.73 kpc at 60;
  - ring peaks 6.07/7.92/8.77 -> 5.22/6.97/7.97;
  - about -12 km/s mean by the end, rms spread 0.26 kpc.
  - It is the cold launch on `equilibrium.circularSpeed` against the real potential, not the clouds. Track A must fix it.
- Disk plane steady (< 0.1 deg). The bulge's centre drifts +0.22 kpc in z over 60 Myr.

## Pitfalls
- Camera: from 80 kpc the near lane sits 50-60 pc low against Hubble. Use 800 kpc with a tenth of the fov.
- Hubble's nucleus is `dust_bench.NUCLEUS` from `hubble_ref.CORE` (15 px right, 7 down at 3840 px). `film_split.py` uses it.
- `texture.py` needs Hubble's framing (`film_split.py framing`); a 4K frame scores at grid 3072 only.
- These fail with or without this code (checked on c639cf7): `metalDrawsTheInsideFrame` (125 / 3188 bytes) and `aMeasuringRunDoesNotCheckpoint`.
- `SamplingTests.theRingThickensToItsRim` timed out the type checker; it is split now.
- `dust_track_c`'s process pool needs a `__main__` guard (spawn), or it hangs silently.
- zsh does not split `set -- $v`; write loops in bash scripts.
- The bench colour law reddens 1.8x too much in the engine. The grey rim must stay tied to `front`, or a grey ring shows all round in the pair.
- The ring-tied B texture draws radial strokes at the tips (its cells are 4.35 pc along by 27.5 pc in radius). No tile tuning fixes that.
- Pierre judges the near lane only; the far half is too white to read.
