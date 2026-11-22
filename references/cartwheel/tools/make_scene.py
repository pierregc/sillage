"""Cartwheel (ESO 350-40) and its intruder G3, from the ring scene-0035 of 2026-11-21.
The base is scene 35 of batch seed 20261121 (scripts/explore-batch.sh --seed 20261121 ...).
usage: make_scene.py <base scene.json> <out folder> [mass ratio] [pericentre kpc] [axis tilt rad]
       [pericentre Myr]"""
import json, math, os, sys
src, out = sys.argv[1], sys.argv[2]
ratio = float(sys.argv[3]) if len(sys.argv) > 3 else 0.33
q = float(sys.argv[4]) if len(sys.argv) > 4 else 1.2
tilt = float(sys.argv[5]) if len(sys.argv) > 5 else 0.2
t = float(sys.argv[6]) if len(sys.argv) > 6 else 300.0
d = json.load(open(src))
d["solver"] = "restricted"
d["name"] = "Cartwheel"
d.pop("draw", None)
big, small = d["galaxies"]
big["name"], small["name"] = "Cartwheel", "G3"
big["starFormingFraction"] = 0.05
small.update({k: big[k] for k in ("armPitch", "armStreaming", "diskThickness", "patternShare",
                                   "outskirtFraction", "dissipationTime")})
small.update(kind="spiral", bulgeFraction=0.08, bulgeExtent=0.12, starFormingFraction=0.06,
             dustFraction=0.15, dustMassFraction=0.12, armStrength=0.6, armIrregularity=0.45)
# compact like scene-0035's globular intruder: a diffuse one tears itself apart and rings nothing
k = (ratio * big["potential"]["mass"] / small["potential"]["mass"]) ** (1 / 3)
small["potential"]["mass"] = ratio * big["potential"]["mass"]
small["potential"]["scaleRadius"] *= k
small["diskScaleLength"] = 1.8
small["diskTruncation"] = 4.0
small["particleShare"] = ratio / (1 + ratio)
big["particleShare"] = 1 - small["particleShare"]
d["encounters"] = [{
    "primary": 0, "secondary": 1, "pericentre": q, "eccentricity": 1.2, "massRatio": ratio,
    "pericentreTime": t,
    "primaryDisk": {"inclination": math.pi / 2 - tilt, "argument": math.pi, "spin": "prograde"},
    "secondaryDisk": {"inclination": 0.9, "argument": 0.5, "spin": "prograde"},
    "planeTilt": math.pi / 2, "planeTurn": 0.0, "pericentreAngle": 0.0}]
os.makedirs(out, exist_ok=True)
json.dump(d, open(os.path.join(out, "scene.json"), "w"), indent=2, sort_keys=True)
