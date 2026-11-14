#!/usr/bin/env python3
"""The plot for #306: what the curves counted, and what formed, at 3.5, 7 and 14."""
import csv
import json
import os
import struct
import sys

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

O = os.path.expanduser("~/claude-workspace/epic-304-out/306")
P307 = os.path.expanduser("~/claude-workspace/epic-304-out/307/runs")
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(O, "star-formation-step.png")
WIDTH = 25.0
END = 887.0

SURFACE, INK, INK2, GRID = "#fcfcfb", "#0b0b0b", "#52514e", "#e4e3df"
BLUE, ORANGE, AQUA = "#2a78d6", "#eb6834", "#1baf7a"
STYLE = {
    "3.5": dict(color=BLUE, lw=1.6, ls="-"),
    "floor": dict(color=BLUE, lw=1.1, ls=(0, (3, 2))),
    "7": dict(color=ORANGE, lw=1.6, ls="-"),
    "14": dict(color=AQUA, lw=1.6, ls="-"),
}
LABEL = {"3.5": "3.5", "floor": "3.5, second galaxy 1 pc off", "7": "7", "14": "14"}
edges = np.arange(0, END + 1e-6, WIDTH)
centres = 0.5 * (edges[:-1] + edges[1:])


def curves(folder):
    rows = list(csv.DictReader(open(os.path.join(folder, "curves.csv"))))
    t = np.array([float(r["time_myr"]) for r in rows])
    f = np.array([float(r["formed"]) for r in rows])
    return np.histogram(t, bins=edges, weights=f)[0] / WIDTH


def reservoir(folder):
    rows = list(csv.DictReader(open(os.path.join(folder, "leaves.csv"))))
    t = np.array([float(r["time_myr"]) for r in rows])
    gas = np.array([float(r["gas"]) for r in rows])
    g = np.interp(edges, t, gas)
    return -np.diff(g) / WIDTH


def take(path):
    with open(path, "rb") as handle:
        handle.read(16)
        (length,) = struct.unpack("<Q", handle.read(8))
        header = json.loads(handle.read(length))
    n = header["particleCount"]
    born = np.asarray(np.memmap(path, dtype="<f4", mode="r", offset=24 + length + 8 * n, shape=(n,)))
    born = born[(born >= 0) & (born < 1e8)] * 4.71
    return np.histogram(born, bins=edges)[0] / WIDTH


def panel(ax, title, series, ylabel=None):
    ax.set_facecolor(SURFACE)
    for key, values in series.items():
        ax.plot(centres, values, label=LABEL[key], **STYLE[key])
    ax.set_title(title, color=INK, fontsize=10.5, loc="left", pad=8)
    ax.set_xlim(0, END)
    ax.set_ylim(bottom=0)
    ax.set_xlabel("megayears", color=INK2, fontsize=9)
    if ylabel:
        ax.set_ylabel(ylabel, color=INK2, fontsize=9)
    ax.grid(True, color=GRID, lw=0.8)
    ax.set_axisbelow(True)
    for side in ("top", "right"):
        ax.spines[side].set_visible(False)
    for side in ("left", "bottom"):
        ax.spines[side].set_color(GRID)
    ax.tick_params(colors=INK2, labelsize=8.5, length=0)
    ax.axvline(305, color=INK2, lw=0.8, alpha=0.5)
    ax.text(309, ax.get_ylim()[1] * 0.97, "pericentre", color=INK2, fontsize=7.5, va="top")
    legend = ax.legend(frameon=False, fontsize=8, loc="upper left", labelcolor=INK)
    return legend


diag = os.path.join(O, "runs/diag")
fig, axes = plt.subplots(1, 3, figsize=(13.5, 4.0), dpi=150, facecolor=SURFACE)
explore = {k: curves(os.path.join(diag, f"scene-{k}")) for k in ("3.5", "7", "14")}
formed = {
    "3.5": reservoir(os.path.join(diag, "scene-3.5")),
    "floor": reservoir(os.path.join(diag, "scene-3.5b")),
    "7": reservoir(os.path.join(diag, "scene-7")),
    "14": reservoir(os.path.join(diag, "scene-14")),
}
top = max(max(v.max() for v in explore.values()), max(v.max() for v in formed.values())) * 1.12
panel(axes[0], "What the curves counted before #306, 200 000 particles", explore, "stars formed a megayear")
for key, note, offset in (
    ("3.5", "3.5: 3 steps of a frame's 4", 3.6), ("7", "7: 1 of 2", -2.0), ("14", "14: 0 of 1", 0.8)
):
    level = explore[key][(centres > 640) & (centres < 760)].mean()
    axes[0].text(865, level + offset, note, color=INK2, fontsize=8, ha="right", va="center")
axes[0].lines[2].set_zorder(5)
axes[0].lines[2].set_clip_on(False)
panel(axes[1], "What formed, read off the gas left, 200 000", formed)
for ax in axes[:2]:
    ax.set_ylim(0, top)
hires = {}
for key, path in (
    ("3.5", os.path.join(P307, "a-dt35/scene-0031/take.sillage")),
    ("floor", os.path.join(P307, "b-floor/scene-0031/take.sillage")),
    ("7", os.path.join(O, "runs/hires-7/scene-0031/take.sillage")),
    ("14", os.path.join(O, "runs/hires-14/scene-0031/take.sillage")),
):
    if os.path.exists(path):
        hires[key] = take(path)
panel(axes[2], "What formed, hires of 8 M drawn from 2 M", hires)
axes[2].set_ylim(0, max(v.max() for v in hires.values()) * 1.15)
axes[2].legend(frameon=False, fontsize=8, loc="lower left", bbox_to_anchor=(0.12, 0.0), labelcolor=INK)
for ax in axes:
    ax.texts[0].set_y(ax.get_ylim()[1] * 0.97)
fig.text(
    0.01, 0.01,
    "scene-0031 of 2026-10-30-b; 25 Myr bins. Each knot carries its step's start time, and the old curves "
    "counted (frame start, frame end]: a frame of k steps showed k - 1 of them.",
    color=INK2, fontsize=8)
fig.tight_layout(rect=(0, 0.04, 1, 1))
fig.savefig(OUT, facecolor=SURFACE)
print(OUT, {k: round(float(v.sum() * WIDTH)) for k, v in hires.items()})
