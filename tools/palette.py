#!/usr/bin/env python3
"""palette.py <out.look.json> <base.look.json> core=L,a,b disk=... outskirts=... young=... knot=... [blend=x] [key=value...]
Every galaxy gets the same ramp, colours given in OKLab and stored at unit luminance."""
import json, sys

def rgb(lab):
    L, a, b = lab
    l = (L + 0.3963377774 * a + 0.2158037573 * b) ** 3
    m = (L - 0.1055613458 * a - 0.0638541728 * b) ** 3
    s = (L - 0.0894841775 * a - 1.2914855480 * b) ** 3
    c = [4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
         -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
         -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s]
    c = [max(x, 0) for x in c]
    y = 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
    return [round(x / max(y, 1e-4), 5) for x in c]

HUBBLE = {"core": (0.7477, 0.0454, 0.0862), "disk": (0.4927, 0.0064, 0.0023),
          "outskirts": (0.2739, -0.0173, -0.0149), "young": (0.6821, -0.0216, -0.0732),
          "knot": (0.6574, 0.0853, 0.0351)}

out, base_path, args = sys.argv[1], sys.argv[2], sys.argv[3:]
base = json.load(open(base_path))
tones = dict(HUBBLE)
blend = 0.75
extra = []
for a in args:
    k, v = a.split("=", 1)
    if k in tones:
        tones[k] = tuple(float(x) for x in v.split(","))
    elif k == "blend":
        blend = float(v)
    else:
        extra.append((k, v))
ramp = {"blend": blend, "mapping": "mix", **{k: rgb(v) for k, v in tones.items()}}
ramp["colour"] = ramp["disk"]
n = max(len(base.get("palette", [])), 2)
base["palette"] = [dict(ramp) for _ in range(n)]
base["look"]["galaxyTint"] = 0
for k, v in extra:
    target = base
    parts = k.split(".")
    for p in parts[:-1]:
        target = target.setdefault(p, {})
    target[parts[-1]] = json.loads(v)
json.dump(base, open(out, "w"), indent=2)
