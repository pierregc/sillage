"""plan.py <out.csv> <count> <seed> [name=lo:hi ...]: a Latin hypercube of scenes round Karl et al. 2010 at
eccentricity 0.95 (#524), one row a scene: its name and make_scene.py's overrides. Without ranges, round 1's.
plan.py <out.csv> <count> <seed> --around <sweep.csv> <best n> <shrink>: round 2, the same hypercube packed
round each of the best n rows of a sweep (ranges shrunk by <shrink> about each)."""
import csv, sys
import numpy as np

ROUND1 = {"pericentre": (7, 14), "eccentricity": (0.92, 0.98), "i1": (40, 80), "i2": (40, 80),
          "w1": (0, 60), "w2": (30, 90), "massRatio": (0.8, 1.0), "diskScale": (0.5, 1.0)}
FIXED = {"node": "descending"}
FAMILY = 0.25  # scenes closer than this in the unit hypercube (rms over the parameters) are one family

def distance(a, b):
    return float(np.sqrt(np.mean([((float(a[k]) - float(b[k])) / (hi - lo)) ** 2 for k, (lo, hi) in ROUND1.items()])))

def hypercube(n, ranges, rng):
    keys = list(ranges); u = np.empty((n, len(keys)))
    for j in range(len(keys)):
        u[:, j] = (rng.permutation(n) + rng.random(n)) / n
    return [{k: round(ranges[k][0] + u[i, j] * (ranges[k][1] - ranges[k][0]), 4) for j, k in enumerate(keys)} for i in range(n)]

def main(argv):
    out, count, seed = argv[0], int(argv[1]), int(argv[2]); rng = np.random.default_rng(seed); rows = []
    if "--around" in argv:
        k = argv.index("--around"); sweep, best, shrink = argv[k + 1], int(argv[k + 2]), float(argv[k + 3])
        ranked = sorted((r for r in csv.DictReader(open(sweep)) if r.get("kept") == "yes"), key=lambda r: -float(r["score"]))
        top = []
        for r in ranked:  # the best of different families
            if len(top) < best and all(distance(r, t) > FAMILY for t in top):
                top.append(r)
        for b, r in enumerate(top):
            ranges = {}
            for key, (lo, hi) in ROUND1.items():
                half = (hi - lo) * shrink / 2; c = float(r[key])
                ranges[key] = (max(lo, c - half), min(hi, c + half))
            for i, p in enumerate(hypercube(count // len(top), ranges, rng)):
                rows.append(dict(name=f"r2-{seed}-{b:02d}-{i:02d}", **p, **FIXED))
    else:
        ranges = dict(ROUND1)
        for a in argv[3:]:
            key, span = a.split("="); lo, hi = span.split(":"); ranges[key] = (float(lo), float(hi))
        for i, p in enumerate(hypercube(count, ranges, rng)):
            rows.append(dict(name=f"r1-{seed}-{i:03d}", **p, **FIXED))
    with open(out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0])); w.writeheader(); w.writerows(rows)

if __name__ == "__main__":
    main(sys.argv[1:])
