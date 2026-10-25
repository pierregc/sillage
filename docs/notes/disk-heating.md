# What was actually cooking the disk

A viewer said the galaxy fell apart and never grew arms. Measured on an isolated disk over
800 Myr, the first two suspicions were both wrong and worth recording as such.

    r50           6.21 -> 5.95 kpc      it does not spread
    thickness     0.272 -> 0.301 kpc    it does not puff
    sigma_R / vc  0.136 -> 0.552        it cooks

A real spiral lives at 0.10 to 0.15. At 0.55 the disk amplifies nothing, and the m = 2
amplitude — the only honest measure of whether arms exist in the *particles* rather than in the
paint — collapsed from 0.29 to between 0.02 and 0.12.

Three things measured innocent before the culprit was found, none of them obvious:

- **The dissipation was not switched off by the gates added for mergers.** The disruption
  ratchet reads 0.00 and the coherence holds at its reference for the whole run, exactly as it
  should on a galaxy with nothing near it.
- **The dissipation is not the answer to radial heating either.** With it and without it the
  radial dispersion lands in the same place, 0.54 against 0.51. What it does control is the
  thickness, 0.27 against 0.41. It damps a peculiar velocity isotropically, but only the
  vertical part stays damped; the radial part is re-excited as fast as it is removed.
- **It is not the halo's graininess.** Halo particles carry 2.4 times a disk particle's mass,
  which is the classic recipe for numerically heating a disk, and making them 3.3 times lighter
  changed the heating by four per cent.

**It is the clumpiness of the initial conditions, and it was set at 0.30.** Clumps are
self-gravitating overdensities that dissolve over the first few hundred megayears and scatter
everything they pass. At 300 Myr the radial dispersion reads 0.156 at zero, 0.185 at 0.12 and
0.309 at 0.30.

**And lowering it is not the trade it looks like at 300 Myr.** At that horizon zero clumpiness
also means no arms at all — m = 2 of 0.001 — which reads as a straight choice between a cool
disk and a structured one. It is not. Run to 800 Myr at 0.12 and the disk stays cool enough
long enough to swing-amplify, and grows its own m = 2 to between 0.16 and 0.38, which is
grand-design. The old 0.30 never got there because it had cooked itself by 300 Myr. Less
heating buys *more* structure, not less.

The default is 0.12. A short measurement answered the opposite of the long one here, and the
long one is the true one.

**A heavier disk is the other lever and it is a real trade.** At `diskMassFraction` 0.40 the
m = 2 response doubles by 300 Myr, because a sub-maximal disk amplifies weakly — but Q of 1.4
over a heavier disk needs more dispersion to begin with, so it starts at 0.229 rather than
0.136 and is warm from the first frame. Left at 0.22, which is the honest figure for a real
disk, and exposed on a slider for anyone who wants the stronger response.
