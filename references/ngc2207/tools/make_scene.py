"""NGC 2207 and IC 2163, after Struck et al. 2005 (MNRAS 364, 69), from the two spirals of the
Antennae archetype scene-0023 of 2026-11-21.
usage: make_scene.py <out folder> [ratio] [pericentre kpc] [eccentricity]
                     [NGC 2207 inclination rad] [IC 2163 inclination rad] [NGC arg] [IC arg] [pericentre Myr]
                     [NGC 2207 bulge fraction] [IC 2163 bulge fraction]
NGC 2207 is the primary, retrograde to the orbit; IC 2163 the secondary, prograde."""
import json, os, sys
src = os.path.expanduser("~/claude-workspace/sillage/library/2026-11-21/scene-0023/scene.json")
a = sys.argv[1:] + [None] * 11
out = a[0]
num = lambda v, d: float(v) if v is not None else d
ratio, q, e = num(a[1], 0.73), num(a[2], 20.0), num(a[3], 0.5)
inc1, inc2 = num(a[4], 0.5), num(a[5], 0.7)
arg1, arg2 = num(a[6], 0.0), num(a[7], 0.0)
t = num(a[8], 260.0)
bulge1, bulge2 = num(a[9], 0.09), num(a[10], 0.06)
d = json.load(open(src))
d["solver"] = "restricted"
d["name"] = "NGC 2207 and IC 2163"
d.pop("draw", None)
ngc, ic = d["galaxies"]
ngc["name"], ic["name"] = "NGC 2207", "IC 2163"
# Struck's rotation peaks: 160-170 km/s for NGC 2207, 140 for IC 2163 (Table 3)
ngc["potential"] = {"mass": 30.0, "profile": "hernquist", "scaleRadius": 10.0}
ic["potential"] = {"mass": 30.0 * ratio, "profile": "hernquist", "scaleRadius": 10.0 * ratio ** 0.5}
# the picture at 35 Mpc: Webb sees NGC 2207's dust out to about 20 kpc (Struck's gas disk, 19.6),
# IC 2163's eye and its far arm to about 12 before the tail
ngc.update(diskScaleLength=5.0, diskTruncation=4.0, armCount=2, bulgeFraction=bulge1, bulgeExtent=0.1,
           starFormingFraction=0.05, armStrength=0.75, armIrregularity=0.45)
ic.update(diskScaleLength=3.2, diskTruncation=3.8, armCount=2, bulgeFraction=bulge2, bulgeExtent=0.1,
          starFormingFraction=0.05, armStrength=0.6, armIrregularity=0.5)
ic["particleShare"] = round(0.75 * ratio / (1 + 0.75 * ratio), 5)
ngc["particleShare"] = round(1 - ic["particleShare"], 5)
d["encounters"] = [{
    "primary": 0, "secondary": 1, "pericentre": q, "eccentricity": e, "massRatio": ratio,
    "pericentreTime": t,
    "primaryDisk": {"inclination": inc1, "argument": arg1, "spin": "retrograde"},
    "secondaryDisk": {"inclination": inc2, "argument": arg2, "spin": "prograde"},
    "planeTilt": 0.0, "planeTurn": 0.0, "pericentreAngle": 0.0}]
os.makedirs(out, exist_ok=True)
json.dump(d, open(os.path.join(out, "scene.json"), "w"), indent=2, sort_keys=True)
