#!/usr/bin/env python3
"""How far two runs of the solver check drift apart (#274).

Each run is a folder holding `curves.csv` and `density.npy` (README.md). Two runs of one chaotic
system that start a bit apart do not stay together, so a second engine is not judged against
zero but against the scale chaos alone gives: how far Metal drifts from itself when one
particle's position moves by its last bit.

    compare.py A B                      A against B, along the run
    compare.py A --scale S1 S2 S3 --test T
                                        T against A, beside the envelope of S1, S2, S3 against A

Distances between the galaxy centres (kpc), each disk's thickness and axis, the total momentum
and the centre of mass; and for each density map the chi-square a cell against Poisson noise,
cells binned 4x4 and 8x8 and kept from 20 counts, as `scripts/tracer-drift.py` scores two maps,
with the share of the stars that sits elsewhere (half the summed absolute difference).

Where both folders hold `particles-<step>.bin` or `accelerations-<step>.bin`, the distance
between the two runs' positions particle by particle (kpc) and the relative difference of their
accelerations, at those steps.
"""

import argparse
import csv
import glob
import os
import re

import numpy as np


def load(folder):
    with open(f"{folder}/curves.csv") as handle:
        rows = list(csv.DictReader(handle))
    curves = {name: np.array([float(row[name]) for row in rows]) for name in rows[0]}
    maps = np.load(f"{folder}/density.npy").astype(np.float64)
    return curves, maps


def binned(maps, factor):
    n, size, _ = maps.shape
    return maps.reshape(n, size // factor, factor, size // factor, factor).sum(axis=(2, 4))


def chi2(a, b, floor=20):
    """Counts of two samples of the same size: (a - b)^2 / (a + b) a cell, averaged."""
    keep = (a + b) >= floor
    if not keep.any():
        return 0.0
    return float((((a - b) ** 2) / np.maximum(a + b, 1e-12))[keep].sum() / keep.sum())


def norm(curves, other, names):
    return np.sqrt(sum((curves[name] - other[name]) ** 2 for name in names))


def metrics(a, b, visible):
    curves_a, maps_a = a
    curves_b, maps_b = b
    galaxies = sum(1 for name in curves_a if name.startswith("cx_"))
    found = {}
    for g in range(galaxies):
        found[f"centre {g} kpc"] = norm(curves_a, curves_b, [f"cx_{g}", f"cy_{g}", f"cz_{g}"])
        found[f"thickness {g}"] = np.abs(curves_a[f"thickness_{g}"] - curves_b[f"thickness_{g}"])
        dot = sum(curves_a[f"{k}_{g}"] * curves_b[f"{k}_{g}"] for k in ("ax", "ay", "az"))
        found[f"axis {g} deg"] = np.degrees(np.arccos(np.clip(dot, -1, 1)))
    found["momentum"] = norm(curves_a, curves_b, ["px", "py", "pz"])
    found["mass centre kpc"] = norm(curves_a, curves_b, ["mx", "my", "mz"])
    found["formed"] = np.abs(curves_a["formed"] - curves_b["formed"])
    scored = {}
    for factor in (4, 8):
        counts_a = binned(maps_a, factor) * visible
        counts_b = binned(maps_b, factor) * visible
        scored[f"chi2 {factor}x{factor}"] = np.array(
            [chi2(counts_a[i], counts_b[i]) for i in range(maps_a.shape[0])]
        )
    scored["elsewhere %"] = np.array(
        [50 * np.abs(maps_a[i] - maps_b[i]).sum() for i in range(maps_a.shape[0])]
    )
    return curves_a["step"], found, scored


def snapshots(folder, name):
    found = {}
    for path in glob.glob(f"{folder}/{name}-*.bin"):
        found[int(re.search(r"-(\d+)\.bin$", path).group(1))] = path
    return found


def quantiles(values):
    return np.median(values), np.quantile(values, 0.99), values.max()


def particles(a, b, visible):
    """Per step both runs kept: how far apart each particle sits, visible then halo, and how
    far apart the accelerations are, relative to their own length."""
    lines = []
    files_a, files_b = snapshots(a, "particles"), snapshots(b, "particles")
    for step in sorted(set(files_a) & set(files_b)):
        count = os.path.getsize(files_a[step]) // 36
        pa = np.fromfile(files_a[step], dtype="<f4", count=count * 4).reshape(count, 4)[:, :3]
        pb = np.fromfile(files_b[step], dtype="<f4", count=count * 4).reshape(count, 4)[:, :3]
        apart = np.linalg.norm(pa.astype(np.float64) - pb, axis=1)
        lines.append((step, "positions kpc, visible") + quantiles(apart[:visible]))
        lines.append((step, "positions kpc, halo") + quantiles(apart[visible:]))
    files_a, files_b = snapshots(a, "accelerations"), snapshots(b, "accelerations")
    for step in sorted(set(files_a) & set(files_b)):
        fa = np.fromfile(files_a[step], dtype="<f4").reshape(-1, 4)[:, :3].astype(np.float64)
        fb = np.fromfile(files_b[step], dtype="<f4").reshape(-1, 4)[:, :3].astype(np.float64)
        relative = np.linalg.norm(fa - fb, axis=1) / np.maximum(np.linalg.norm(fa, axis=1), 1e-30)
        lines.append((step, "accelerations, relative") + quantiles(relative))
    if not lines:
        return
    print(f"particle by particle, {b} against {a}")
    print("  " + "step".rjust(6) + "  " + "what".ljust(26) + "median".rjust(14) + "99 %".rjust(14) + "max".rjust(14))
    for step, what, median, high, most in lines:
        print("  " + f"{step:6d}  " + what.ljust(26) + f"{median:14.6g}{high:14.6g}{most:14.6g}")
    print()


def table(title, steps, columns, rows):
    print(title)
    print("  " + "step".rjust(6) + "".join(name.rjust(18) for name in columns))
    for index in rows:
        cells = "".join(f"{values[index]:18.6g}" for values in columns.values())
        print("  " + f"{int(steps[index]):6d}" + cells)
    print("  " + "max".rjust(6) + "".join(f"{values.max():18.6g}" for values in columns.values()))
    print()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    parser.add_argument("base")
    parser.add_argument("other", nargs="?")
    parser.add_argument("--scale", nargs="+", default=[])
    parser.add_argument("--test")
    parser.add_argument("--visible", type=int, help="stars counted in a map (read from the first map otherwise)")
    parser.add_argument("--every", type=int, default=250, help="steps between the lines printed")
    args = parser.parse_args()

    base = load(args.base)
    positive = base[1][0][base[1][0] > 0]
    visible = args.visible or int(round(1 / positive.min()))
    steps = base[0]["step"]
    rows = [i for i, step in enumerate(steps) if int(step) % args.every == 0]
    map_steps = np.linspace(steps[0], steps[-1], base[1].shape[0])
    map_rows = range(base[1].shape[0])
    print(f"{visible} stars a map, {len(steps)} sampled steps, {base[1].shape[0]} maps\n")

    if args.other:
        _, found, scored = metrics(base, load(args.other), visible)
        table(f"{args.other} against {args.base}", steps, found, rows)
        table("density maps", map_steps, scored, map_rows)
        particles(args.base, args.other, visible)
        return

    scale = [metrics(base, load(folder), visible) for folder in args.scale]
    test = metrics(base, load(args.test), visible) if args.test else None
    for part, at, lines in ((1, steps, rows), (2, map_steps, map_rows)):
        for name in scale[0][part]:
            columns = {}
            if test:
                columns[args.test] = test[part][name]
            envelope = np.max([run[part][name] for run in scale], axis=0)
            columns["chaos envelope"] = envelope
            for folder, run in zip(args.scale, scale):
                columns[folder] = run[part][name]
            table(name, at, columns, lines)
            if test:
                worst = test[part][name].max()
                print(f"  {name}: {args.test} reaches {worst:.6g}, chaos alone {envelope.max():.6g}\n")
    for folder in ([args.test] if args.test else []) + args.scale:
        particles(args.base, folder, visible)


if __name__ == "__main__":
    main()
