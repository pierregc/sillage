#!/usr/bin/env python3
"""Stars formed per window from a take's formation times (version 2 and up): the exact count.
usage: take-formed.py <take.sillage> <edges Myr comma separated>"""
import json, struct, sys
import numpy as np
MYR = 4.71
path, edges = sys.argv[1], [float(x) for x in sys.argv[2].split(",")]
with open(path, "rb") as f:
    magic = f.read(16)
    (length,) = struct.unpack("<Q", f.read(8))
    header = json.loads(f.read(length))
n = header["particleCount"]
offset = 24 + length + 2 * 4 * n
formation = np.memmap(path, dtype="<f4", mode="r", offset=offset, shape=(n,))
times = np.asarray(formation, dtype=np.float64)
born = times[(times >= 0) & (times < 1e8)] * MYR
print(f"particles {n}, formed during the run {born.size}")
counts, _ = np.histogram(born, bins=edges)
for lo, hi, c in zip(edges[:-1], edges[1:], counts):
    print(f"{lo:.0f}-{hi:.0f} {c} {c / (hi - lo):.2f}/Myr")
