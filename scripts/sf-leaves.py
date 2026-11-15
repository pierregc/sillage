#!/usr/bin/env python3
"""Star formation of runs side by side, window by window, from `--sf-leaves` (#306).

    scripts/sf-leaves.py <edges in Myr, comma separated> <reference run> <run>...

A run is a folder holding the `leaves.csv` that `sillage-render --sf-leaves` or
`probe-disk --sf-leaves` wrote. For each window it prints, against the reference:

- formed: stars formed a megayear, read off the gas the leaves still hold, since every star that
  forms takes one gas particle out for good; the curves are not needed and cannot mislead;
- density and compression: what the rule's two terms are worth, formations a megayear, as the
  rule reads the leaves at each frame;
- free fall: the free-fall rate of the dense leaves, weighted by their gas (the density);
- above 15, above 45: the share of the gas in dense leaves whose flow converges faster than
  that many free-fall rates, and below -45 the share diverging as fast (the convergence).
"""
import csv
import os
import sys

import numpy as np

EDGES = [-100, -45, -15, -5, 0, 5, 15, 45, 100, 300, 1000]


def load(folder):
    with open(os.path.join(folder, "leaves.csv")) as handle:
        rows = list(csv.DictReader(handle))
    return {key: np.array([float(row[key]) for row in rows]) for key in rows[0]}


def window(run, lo, hi):
    t = run["time_myr"]
    inside = (t > lo) & (t <= hi)
    if not inside.any() or lo < t[0] - (t[-1] - t[0]) / max(len(t) - 1, 1):
        return None
    gas = np.interp([lo, hi], t, run["gas"])
    measured = max(run["measured_gas"][inside].sum(), 1)
    binned = np.array([run[f"bg{k}"][inside].sum() for k in range(len(EDGES) + 1)])
    return {
        "formed": (gas[0] - gas[1]) / (hi - lo),
        "density": run["density_rate"][inside].mean(),
        "compression": run["compression_rate"][inside].mean(),
        "free fall": run["gas_free_fall"][inside].sum() / measured,
        "above 15": binned[EDGES.index(15) + 1:].sum() / measured,
        "above 45": binned[EDGES.index(45) + 1:].sum() / measured,
        "below -45": binned[:EDGES.index(-45) + 1].sum() / measured,
    }


def main(arguments):
    if len(arguments) < 3:
        sys.exit(__doc__)
    edges = [float(value) for value in arguments[0].split(",")]
    folders = arguments[1:]
    runs = [load(folder) for folder in folders]
    names = [os.path.basename(folder.rstrip("/")) for folder in folders]
    keys = ["formed", "density", "compression", "free fall", "above 15", "above 45", "below -45"]
    for key in keys:
        print(f"\n{key}, {names[0]} and the others over it")
        print("| window | " + " | ".join(names) + " |")
        print("| --- |" + " ---: |" * len(names))
        totals = [0.0] * len(runs)
        for lo, hi in zip(edges[:-1], edges[1:]):
            windows = [window(run, lo, hi) for run in runs]
            if any(found is None for found in windows):
                continue
            values = [found[key] for found in windows]
            reference = values[0]
            cells = [f"{reference:.4g}"] + [
                f"{value / reference:.3f}" if reference else "" for value in values[1:]]
            print(f"| {lo:.0f} to {hi:.0f} | " + " | ".join(cells) + " |")
            for index, value in enumerate(values):
                totals[index] += value * (hi - lo)
        if key == "formed":
            cells = [f"{totals[0]:.0f}"] + [f"{total / totals[0]:.3f}" for total in totals[1:]]
            print("| all | " + " | ".join(cells) + " |")


if __name__ == "__main__":
    main(sys.argv[1:])
