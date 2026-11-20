#!/usr/bin/env python3
"""Plots the curves of `sillage-render black-hole run --metrics` against the time in periods of
the most bound debris (#334): the share bound, how circular the flow is, its eccentricity, its
height over its radius, and the share of the bound within 2 and 6 pericentres.

    gas-curves.py out.png label=run.csv [label=run.csv ...]
"""

import csv
import math
import sys

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt

PANELS = [
    ("bound", "share of the tracers that are bound", None),
    ("circularised", "ε / ε of the circular orbit, mean over the flow", (0, 1.1)),
    ("eccentricity", "mean eccentricity within 6 R_p", (0, 1)),
    ("thickness", "height over radius, 3 to 36 r_s", (0, 0.08)),
    ("in2", "share of the bound within 2 R_p", (0, 0.6)),
    ("swallowed", "share swallowed", None),
]


def main():
    output, runs = sys.argv[1], sys.argv[2:]
    figure, axes = plt.subplots(2, 3, figsize=(15, 8), constrained_layout=True)
    for spec in runs:
        label, path = spec.split("=", 1)
        with open(path) as handle:
            rows = list(csv.DictReader(handle))
        for axis, (key, title, limits) in zip(axes.flat, PANELS):
            # Nothing within 6 R_p yet, before the first return: no value, not zero.
            blank = key in ("circularised", "eccentricity", "thickness")
            values = [float(row[key]) or (math.nan if blank else 0.0) for row in rows]
            axis.plot([float(row["periods"]) for row in rows], values, label=label)
            axis.set_title(title, fontsize=10)
            axis.set_xlabel("time in P*")
            if limits:
                axis.set_ylim(*limits)
            axis.grid(alpha=0.3)
    axes.flat[0].set_xlim(left=-0.1)
    axes.flat[0].legend(fontsize=8)
    figure.savefig(output, dpi=110)


if __name__ == "__main__":
    main()
