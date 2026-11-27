"""view2key.py <match json> [fov rad] [at s] [myr]: a flight key whose 16:9 frame holds the wide panel's
height (115.3 kpc for 102.5 across), centred on the panel, from a match; prints the key."""
import json, math, sys
m = json.load(open(sys.argv[1])); v = m["view"]
fov = float(sys.argv[2]) if len(sys.argv) > 2 else 0.15
at = float(sys.argv[3]) if len(sys.argv) > 3 else 0.0
myr = float(sys.argv[4]) if len(sys.argv) > 4 else m["megayears"]
e, a, r = (math.radians(v[k]) for k in ("elevation", "azimuth", "roll"))
k = v["kpcPerWidth"]; aspect = 288 / 256  # the panel's map, height over width
t = (math.sin(a) * math.cos(e), -math.cos(a) * math.cos(e), math.sin(e))
R = (math.cos(a), math.sin(a), 0.0)
Dn = (math.sin(a) * math.sin(e), -math.cos(a) * math.sin(e), -math.cos(e))
cx, cy = 0.5 - v["origin"][0], 0.5 * aspect - v["origin"][1]
sx = k * (math.cos(r) * cx + math.sin(r) * cy)
sy = k * (-math.sin(r) * cx + math.cos(r) * cy)
P = [sx * R[i] + sy * Dn[i] for i in range(3)]
D = (k * aspect / 2) / math.tan(fov / 2)
eye = [P[i] + D * t[i] for i in range(3)]
print(json.dumps({"at": at, "myr": round(myr, 4), "eye": [round(x, 3) for x in eye],
                  "aim": [round(x, 3) for x in P], "fov": fov, "roll": round(r, 4)}))
