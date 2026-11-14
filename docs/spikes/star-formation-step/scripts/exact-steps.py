#!/usr/bin/env python3
"""Checks a run's curves against its take, step by step: which steps' knots the curves counted.
usage: exact-steps.py <scene folder with take.sillage, curves-hires.csv, hires.json>"""
import csv, json, os, struct, sys
import numpy as np
folder = sys.argv[1]
hires = json.load(open(os.path.join(folder, "hires.json")))
path = os.path.join(folder, "take.sillage")
with open(path, "rb") as f:
    f.read(16)
    (length,) = struct.unpack("<Q", f.read(8))
    header = json.loads(f.read(length))
n = header["particleCount"]
born = np.memmap(path, dtype="<f4", mode="r", offset=24 + length + 8 * n, shape=(n,))
born = np.asarray(born)
born = born[(born >= 0) & (born < 1e8)]
dt = np.float32(float("%.9g" % hires["timeStep"]))
settle, steps, frames = hires["settle"], hires["steps"], hires["frames"]
k = steps // frames
times = np.zeros(settle + steps + 1, dtype=np.float32)
t = np.float32(0)
for i in range(1, settle + steps + 1):
    t = np.float32(t + dt)
    times[i] = t
# stamps are exactly the times[i] at the start of each step
values, counts = np.unique(born, return_counts=True)
per_step = dict(zip(values.tolist(), counts.tolist()))
lookup = np.array([per_step.get(float(x), 0) for x in times[:-1]])
matched = lookup.sum()
print(f"formed {born.size}, matched to a step {matched}, steps a frame {k}, dt {dt}")
rows = list(csv.DictReader(open(os.path.join(folder, "curves-hires.csv"))))
curves = np.array([int(r["formed"]) for r in rows])
first = np.array([lookup[settle + f * k] for f in range(frames)])
rest = np.array([lookup[settle + f * k + 1: settle + (f + 1) * k].sum() for f in range(frames)])
print("frames where the curves equal the last k-1 steps exactly:", int((curves == rest).sum()), "of", frames)
print("frames where the curves equal all k steps exactly:", int((curves == first + rest).sum()), "of", frames)
print(f"curves total {curves.sum()}, every step {first.sum() + rest.sum()}, first steps {first.sum()} ({first.sum() / (first.sum() + rest.sum()):.4f})")
