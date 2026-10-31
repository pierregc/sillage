# The calm-disk probe: one galaxy alone, measured as it settles

`sillage-render probe-disk <scene.json | scene folder> <galaxy index>` (#169) takes one galaxy out
of a scene, runs it alone on the self-gravitating solver and writes, for every captured frame,
the numbers that say whether it is settling, how much structure its particles hold, how lumpy
it is and whether its pattern keeps its shape as it turns. Both stability spikes (#170, #171)
and the dust spike (#173) measure with it, so the definitions live here.

```
./scripts/dev.sh probe-disk library/2026-10-30-b/scene-0031 0 --particles 200000 --myr 1000
./scripts/dev.sh probe-disk library/2026-10-30-b/scene-0031 1 --clumpiness 0.12 --out out/probe/calm
python3 scripts/probe-report.py table library/2026-10-30-b/scene-0031/probe/*
python3 scripts/probe-report.py compare <run a> <run b>
```

Options: `--particles N` (the scene's visible count; the galaxy takes its share), `--myr T`
(1000), `--frame-myr T` (4), `--seed S`, `--dt-scale X`, the overrides `--clumpiness`,
`--toomre-q`, `--arm-strength`, `--arm-count`, `--arm-irregularity`, `--disk-mass-fraction`,
`--dissipation`, `--mass-contrast`, `--streaming`, `--young-clumpiness`, and for the picture `--width`, `--height` (one pane, 720), `--no-clip`,
`--painted` (paint the density wave as the app does), `--stills 0,300,...`, `--lag-myr T` (50).

## What runs

The whole scene is sampled at the count asked for, with the overrides applied to the galaxy
first, and the galaxy's own particles are kept star for star, its halo included: the same
particles, the same clumps, the same pattern seed the scene draws. They are set at rest about
their centre of mass at the origin, and the solver sees one galaxy with the softening and the
time step the whole scene would run with at that count, so the probe measures the disk the
scene shows. `probe.scene.json` holds that one-galaxy scene, `probe.json` what ran and the
summary, `probe.csv` one line a frame, `probe.mov` the clip and `still-<Myr>.png` the stills.

## The disk's own frame

Nothing here is measured against the solver's centre or the natal plane. Each frame the
nucleus is found as the centre of mass of the disk material (stars, young stars and gas)
inside three scale lengths of where it was, taken again until it stops moving, then inside one
and a half; the axis is the angular momentum of the material inside three scale lengths about
that nucleus, and the in-plane axes are the natal pair carried onto it by the shortest rotation
(`DiskFrame.planeAxes`), with `v = axis x u` so the azimuth grows with the rotation for a
retrograde disk as for a prograde one. The solver's own centre, the centre of mass of every
visible particle that the app's camera and the cooling follow, is written beside it
(`sx, sy, sz` against `cx, cy, cz`), and their distance is `centre_offset_kpc`.

The clip has two panes: on the left the disk seen along its own axis from its own nucleus,
on the right what the app frames, the solver's centre seen along the natal axis. The left
pane cannot show camera motion; what moves between the two is the centre.

## The columns of probe.csv

All lengths in kpc unless the name says `_h` (scale lengths), speeds in km/s, angular rates in
radians per megayear. Stars means thin-disk stars (`component` 0); young means HII regions and
gas (dust) together; bulge, outskirts and halo are never counted. The zones are
inner 0.5 to 1.5, mid 1.5 to 3 and outer 3 to 4.5 scale lengths.

- `r10_kpc` to `r90_kpc`: radii holding a tenth to nine tenths of the stars. `r50` is the
  settling curve; its first excursion and breathing are in the summary.
- `z_rms_kpc`, `thickness_ratio`: root mean square height of the stars inside three scale
  lengths, and that over their root mean square radius in the plane. Not the solver's
  `DiskState.thickness`, which divides by the three-dimensional spread.
- `sigma_r_kms_mid`, `sigma_phi_kms_mid`, `sigma_z_kms_mid`, `v_phi_kms_mid`, `v_c_kms_mid`,
  `q_mid`: the stars' dispersions and mean streaming in the middle zone, the equilibrium
  circular speed at its centre (2.25 scale lengths), and the Toomre parameter the measured
  radial dispersion gives there. `sigma_r_vc_<zone>` is the ratio the heating notes quote.
- `n_<zone>`, `n_young_mid`: how many were counted.
- `a1_<zone>` to `a8_<zone>`: Fourier amplitudes of the stars by azimuthal order. Each ring of
  the polar map (40 rings spaced in the logarithm of the radius from 0.5 to 4.5 scale lengths,
  96 sectors) gives |sum e^{im phi}| / n with the expectation of a random sample, 1 / n on the
  square, taken out and the sector binning undone; the zone's figure is the count-weighted
  root mean square over its rings, so a wound spiral is not cancelled by summing across radii.
  In this convention a density 1 + c cos(m phi) reads c / 2: `a2` 0.2 is the contrast
  Elmegreen's S4G Fourier work calls F2 = 0.2, a sinusoid amplitude of 0.4 and an arm to
  interarm ratio of 2.3.
- `young_a1_mid` to `young_a4_mid`: the same for the young population in the middle zone.
- `pattern_angle_rad`: the phase of the pattern mode (the galaxy's arm count, 2 to 6, else 2)
  in the middle zone, as a pattern angle, weighted over the rings by their pattern power.
- `omega_p_rad_myr`: the pattern speed, from how far each middle ring's pattern turned since
  the last frame, weighted by the ring's pattern power, fitted over the last `lag` megayears;
  nan while the pattern is lost in the noise anywhere in that window. `omega_p_spread_rad_myr`
  is the spread of the rings' own rates about the zone's over the last frame: near zero for one
  rigid pattern, up to the shear for structure carried by the material. `omega_2h_rad_myr` is
  the equilibrium angular rate at two scale lengths, `omega_mat_mid_rad_myr` the measured mean
  rate of the middle zone, and `corotation_h` where the equilibrium curve turns at the
  pattern's speed.
- `coh_pattern`, `coh_material`, `coh_static`: how much the face-on map of the stars looks
  like itself `lag` megayears earlier, as a weighted correlation of the two maps' contrasts
  (each ring against its own mean), the later map turned back by the pattern speed times the
  lag, by each ring's own material rotation times the lag, or not at all. The two maps are
  built from the two interleaved halves of the sample, so no star meets its own earlier place
  and shot noise riding with the stars does not read as carried structure; the variances are
  corrected for the halves' own noise. A density wave reads high in the pattern frame and lower
  in the material one; clumps sheared with the flow read the other way round; noise reads near
  zero everywhere. `map_snr` is the map's structure over its noise; below about 1 the
  coherences mean little.
- `lump_stars`, `lump_young`: lumpiness, the root mean square contrast of the face-on map (128
  cells of 0.07 scale lengths a side over the disk) once its azimuthal mean is taken out and a
  box of a fifth of a scale length is subtracted, read between 0.5 and 4 scale lengths whatever
  the count, weighted by the stars expected in each cell and with the cells' Poisson noise
  taken out. It is structure below a fifth of a scale length: the sampler's clumps and the
  knots, not arms, and not a bar either, which are 0.3 to 0.5 scale lengths across and go
  with the box (a box of half a scale length was tried first and read a bar as lumps).
  `lump_polar` reads a coarser thing on the polar map: the power of the azimuthal orders
  shorter than half a scale length on each ring that can resolve it, so spurs and sharpened
  arms count there.
- `outer_offset_h`: how far the outer zone's centroid sits from the nucleus, in scale lengths;
  the lopsidedness as a displacement.
- `axis_tilt_deg`: the angle between the measured axis and the natal one.
- `step_ms`, `measure_ms`: what a solver step and the measurement cost.

Every amplitude and the lumpiness are corrected for the sample's shot noise, which is what lets
a run at fifty thousand particles and one at a million read on the same scale: the tests pin
that a Poisson disk reads as smooth at both counts and that seeded clumps read the same at
both. What the correction leaves is noise of its own, about the fourth root of the zone's ring
count over the root of its star count on an amplitude: 0.006 in the inner and middle zones and
0.014 in the sparse outer one for a galaxy of 200 000 stars, twice that at 50 000. An amplitude
at that level is not there. The corrected powers are summed signed over a zone's rings and
clipped at zero once, not ring by ring, or the clipping alone would read as structure.

## The summary in probe.json

`firstExcursion` is the largest departure of `r50` from its start within 300 Myr, the figure
`breathing-core.md` quotes (5.9 % with the arms off, 11 to 13 % with them on); `breathing` is
the peak to trough over the same stretch. `settledMyr` is from when `r50` stays within 2 % of
its final mean. The `Late` figures are means over the last 500 Myr. `nucleusJitterKpc` and
`solverCentreJitterKpc` are the root mean square displacement of each centre from one frame
to the next. `facts` holds what the galaxy's equilibrium says before anything moves: Toomre's
swing-amplification parameter for two arms at one, two and three scale lengths
(X = kappa^2 R / (4 pi G Sigma); strong amplification needs X between about 1 and 3, and the disk
prefers the arm count that puts X near 2), the painted pattern speed with its corotation and
inner Lindblad radii, the rotation and epicyclic periods at two scale lengths.

## Reading the numbers against real galaxies

From the literature gathered for the spikes (Elmegreen et al. 2011 and Kendall et al. 2011,
2015 at 3.6 um; Bournaud et al. 2005 and Zaritsky et al. 2013 for lopsidedness; Bottema 1993,
the DiskMass survey and Bland-Hawthorn & Gerhard 2016 for the kinematics; Williams et al. 2021
and Tamburro et al. 2008 for the pattern speeds):

| figure | old stars of real spirals |
| --- | --- |
| `a2_mid` (this convention) | grand design 0.15 to 0.3, multi-armed about 0.12, flocculent 0.05 to 0.1; falling or lost past 2 to 2.5 scale lengths |
| `a1_mid`, `a1_outer` | mean 0.11 at 1.5 to 2.5 scale lengths, growing outward; a third of disks above 0.2 further out |
| `sigma_r_vc_mid` | 0.15 to 0.18 at two scale lengths; 0.2 is a thick disk |
| `z_rms_kpc` / scale length | 0.1 to 0.14 |
| `q_mid` (stars alone) | 2 to 3 |
| `omega_p_rad_myr` / `omega_2h_rad_myr` | 0.6 to 1 (corotation at 2 to 3.3 scale lengths); the painted 0.5 puts it at 4 |
| `lump_stars` | about 0: the old disk carries no knots; all lumpiness lives in the young tracers |

## Baseline: scene-0031, and what two runs may differ by

Both galaxies of library `2026-10-30-b/scene-0031` run alone for 1 Gyr at the explore count
(200 000 a scene: 108 000 and 92 000 stars, 270 000 and 230 000 particles with the halo) in
53 and 47 s, 9.3 and 8.3 ms a step of 0.198 Myr, the measurement 6 ms a frame on top; at the
hires count (2 M a scene: 1 078 000 and 921 000 stars, 2.7 M and 2.3 M particles) in 628 and 531 s,
63 and 53 ms a step of 0.105 Myr, the measurement 60 ms a frame. Both galaxies at both counts
went through the same gigayear: the same first excursion within 2 points (13.3 % against
15.1 %, 10.5 against 8.8), the same heating at 300 Myr within the seed spread (0.224 against
0.213, 0.162 against 0.150), a bar by 300 Myr on Première at every count, a late a2 of 0.2 to
0.3 on both; what the count changes is the knots formed (in proportion to it) and the floor
under the amplitudes. The `facts` of Première: X_2 2.75, 3.65 and 5.3 at one,
two and three scale lengths, 3.6 preferred arms at two, the painted pattern at 0.0121 rad/Myr
with corotation at 4.3 scale lengths and the inner Lindblad resonance at 1.0, v_c 315 km/s,
a rotation of 217 Myr and an epicycle of 153 Myr at two scale lengths.

| | Première 108 k | seed 2 | Deuxième 92 k | seed 2 |
| --- | --- | --- | --- | --- |
| first excursion | 15.1 % at 289 Myr | 14.5 % at 265 | 8.8 % at 91 | 7.7 % at 99 |
| r50, 0 / 300 / 1000 Myr | 8.52 / 7.25 / 6.04 | 8.19 / 7.48 / 6.90 | 6.99 / 6.43 / 6.25 | 6.88 / 6.44 / 6.04 |
| sigma_R / v_c, 0 / 300 / 1000 | 0.135 / 0.213 / 0.158 | 0.131 / 0.180 / 0.157 | 0.134 / 0.150 / 0.115 | 0.132 / 0.143 / 0.157 |
| a2 mid, 0 / 400 / 1000 | 0.36 / 0.55 / 0.46 | 0.41 / 0.52 / 0.29 | 0.36 / 0.24 / 0.17 | |
| a1 mid, 0 / 1000 | 0.21 / 0.41 | 0.11 / 0.19 | 0.10 / 0.13 | |
| lump stars, 0 / 16 / 1000 | 0.23 / 0.08 / 0.82 | 0.23 / 0.06 / 0.63 | 0.19 / 0.08 / 0.43 | |

**The same seed gives the same run**: Première run again for 300 Myr matched the first run on
every column to the printed digits on all 77 frames, GPU included. **Another seed is another
galaxy.**
The two samplings of Première agree over the first 300 Myr to 5 % on `r50` (worst 8 %), 2 %
on `r90`, 0.02 on `sigma_R / v_c`, 0.1 on `a2_mid` and 0.07 on `a1_mid`; after the bar forms
(at 257 Myr on one, 475 on the other) they part for good: 17 % on `r50`, 0.37 on `a2_mid`,
0.32 on `a1_mid`. That is the spread a comparison of two runs has to beat, and it is why the
spikes read the first 300 Myr and the late means rather than one late frame, and why the two
seeds are run for every finding that matters. The percent on the deciles quoted in
`state-and-known-limitations.md` is for one sampling at two time steps, a different question.
