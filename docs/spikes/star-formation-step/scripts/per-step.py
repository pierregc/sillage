#!/usr/bin/env python3
"""Stars each step formed in a hires, off its take (every knot carries its step's start time).
usage: per-step.py <scene folder with take.sillage and hires.json> <out.csv>"""
import json, os, struct, sys
import numpy as np
folder, out = sys.argv[1], sys.argv[2]
hires = json.load(open(os.path.join(folder, "hires.json")))
path = os.path.join(folder, "take.sillage")
with open(path, "rb") as f:
    f.read(16)
    (length,) = struct.unpack("<Q", f.read(8))
    header = json.loads(f.read(length))
n = header["particleCount"]
born = np.asarray(np.memmap(path, dtype="<f4", mode="r", offset=24 + length + 8 * n, shape=(n,)))
born = born[(born >= 0) & (born < 1e8)]
dt = np.float32(float("%.9g" % hires["timeStep"]))
total = hires["settle"] + hires["steps"]
times = np.zeros(total, dtype=np.float32)
t = np.float32(0)
for i in range(1, total):
    t = np.float32(t + dt)
    times[i] = t
values, counts = np.unique(born, return_counts=True)
per = dict(zip(values.tolist(), counts.tolist()))
with open(out, "w") as handle:
    handle.write("step,time_myr,formed\n")
    for i, x in enumerate(times):
        handle.write(f"{i},{float(x) * 4.71:.4f},{per.get(float(x), 0)}\n")
print(out, sum(per.get(float(x), 0) for x in times), born.size)
