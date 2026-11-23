"""A flight key that frames the picture across the whole width of a 16:9 frame, from a match.
usage: view2key.py <match json> [fov rad] [at s] -> prints the key"""
import json, math, sys
m = json.load(open(sys.argv[1])); v = m["view"]
fov = float(sys.argv[2]) if len(sys.argv) > 2 else 0.15
at = float(sys.argv[3]) if len(sys.argv) > 3 else 0.0
e, a, r = (math.radians(v[k]) for k in ("elevation", "azimuth", "roll"))
k = v["kpcPerWidth"]; aspect = 2983 / 6353
t = (math.sin(a) * math.cos(e), -math.cos(a) * math.cos(e), math.sin(e))
R = (math.cos(a), math.sin(a), 0.0)
Dn = (math.sin(a) * math.sin(e), -math.cos(a) * math.sin(e), -math.cos(e))
cx, cy = 0.5 - v["origin"][0], 0.5 * aspect - v["origin"][1]
sx = k * (math.cos(r) * cx + math.sin(r) * cy)   # Rot(-r)
sy = k * (-math.sin(r) * cx + math.cos(r) * cy)
P = [sx * R[i] + sy * Dn[i] for i in range(3)]
D = (k * 9 / 16 / 2) / math.tan(fov / 2)
eye = [P[i] + D * t[i] for i in range(3)]
key = {"at": at, "myr": round(m["megayears"], 4), "eye": [round(x, 3) for x in eye],
       "aim": [round(x, 3) for x in P], "fov": fov, "roll": round(r, 4)}
print(json.dumps(key))
