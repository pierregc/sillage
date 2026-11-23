"""The Sombrero (M104) alone: a disk of stars and a ring of dust inside a large, bright bulge.
usage: make_scene.py <out folder> [bulge fraction] [bulge extent] [ring width kpc] [disk thickness kpc]
                     [bulge flattening] [ring radius kpc]
Figures at 9.55 Mpc (McQuinn et al. 2016), 1 arcsec = 46.3 pc: dust ring at 145 arcsec (6.7 kpc),
sigma 23 arcsec (1.06 kpc), inner dust disk scale length 2.2 kpc (Bendo et al. 2006, Table 3);
flat rotation about 350 km/s (Bajaja et al. 1984; Jardel et al. 2011: 376 km/s asymptotic)."""
import json, os, sys
a = sys.argv[1:] + [None] * 7
out = a[0]
num = lambda v, d: float(v) if v is not None else d
bulge, extent, width = num(a[1], 0.75), num(a[2], 1.25), num(a[3], 1.06)
thick, flat, radius = num(a[4], 0.2), num(a[5], 0.65), num(a[6], 6.7)
src = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "ngc2207", "scene.json")
d = json.load(open(src))
g = d["galaxies"][0]
for k in ():
    g.pop(k, None)
g.update(
    name="M104", kind="spiral", spin="prograde", inclination=0.0, positionAngle=0.0, position=[0, 0, 0], velocity=[0, 0, 0],
    # 10^12 solar masses in a Hernquist halo of 20 kpc and a fifth of it in stars, 2 x 10^11:
    # about 350 km/s at the ring with the bulge
    potential={"mass": 100.0, "profile": "hernquist", "scaleRadius": 20.0},
    diskMassFraction=0.2, haloExtent=12, haloParticleRatio=1.5,
    diskScaleLength=2.2, diskTruncation=3.4, diskThickness=thick,
    bulgeFraction=bulge, bulgeExtent=extent, bulgeFlattening=flat,
    armCount=2, armPitch=0.12, armStrength=0.3, armIrregularity=0.3, armMassContrast=0.2,
    dustFraction=0.3, dustMassFraction=0.02, starFormingFraction=0.02, clumpiness=0.02,
    outskirtFraction=0.05, particleShare=1.0,
    dustRing={"radius": radius, "width": width})
d.update(name="Sombrero (M104)", galaxies=[g], encounters=[], seed=478104)
os.makedirs(out, exist_ok=True)
json.dump(d, open(os.path.join(out, "scene.json"), "w"), indent=2, sort_keys=True)
