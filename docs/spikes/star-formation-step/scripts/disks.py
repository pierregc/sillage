#!/usr/bin/env python3
"""Isolated disks of scene-0031 at 3.5, 7, 14 over four draws: formed off the reservoir, the two terms."""
import csv, os
import numpy as np
O = os.path.expanduser("~/claude-workspace/epic-304-out/306/runs")
def load(folder):
    rows = list(csv.DictReader(open(os.path.join(folder, "leaves.csv"))))
    return {k: np.array([float(r[k]) for r in rows]) for k in ("time_myr", "gas", "density_rate", "compression_rate", "gas_free_fall", "measured_gas")}
def folder(g, seed, s):
    return f"{O}/diag/disk-g{g}-{s}" if seed == 0 else f"{O}/fix/disk-g{g}-seed{seed}-{s}"
edges = [0, 200, 400, 600, 800, 1000]
def formed(L, lo, hi):
    g = np.interp([lo, hi], L["time_myr"], L["gas"]); return g[0] - g[1]
def term(L, key, lo, hi):
    m = (L["time_myr"] > lo) & (L["time_myr"] <= hi); return L[key][m].mean()
for g in (0, 1):
    print(f"\ngalaxy {g}")
    ratios = {"7": [], "14": []}
    dens = {"7": [], "14": []}
    win = {s: np.zeros(len(edges) - 1) for s in ("3.5", "7", "14")}
    totals = {s: [] for s in ("3.5", "7", "14")}
    for seed in (0, 2, 3, 4):
        L = {}
        for s in ("3.5", "7", "14"):
            f = folder(g, seed, s)
            if os.path.exists(os.path.join(f, "leaves.csv")):
                L[s] = load(f)
        if len(L) < 3:
            continue
        t = {s: formed(L[s], 0, 1000) for s in L}
        for s in L:
            totals[s].append(t[s])
            win[s] += np.array([formed(L[s], lo, hi) for lo, hi in zip(edges[:-1], edges[1:])])
        for s in ("7", "14"):
            ratios[s].append(t[s] / t["3.5"])
            dens[s].append(term(L[s], "density_rate", 0, 1000) / term(L["3.5"], "density_rate", 0, 1000))
        print(f" seed {seed}: formed 3.5 {t['3.5']:.0f}, 7/3.5 {t['7']/t['3.5']:.3f}, 14/3.5 {t['14']/t['3.5']:.3f}; density term 7 {dens['7'][-1]:.3f} 14 {dens['14'][-1]:.3f}; depletion {L['3.5']['gas'][0]/ (formed(L['3.5'],0,200)/200)/1000:.1f} Gyr then {np.interp(900,L['3.5']['time_myr'],L['3.5']['gas'])/(formed(L['3.5'],800,1000)/200)/1000:.1f}")
    n = len(ratios["7"])
    for s in ("7", "14"):
        r = np.array(ratios[s])
        print(f" {s}/3.5 over {n} draws: mean {r.mean():.3f}, spread {r.std(ddof=1) if n > 1 else 0:.3f}, of all stars {np.sum(totals[s]) / np.sum(totals['3.5']):.3f}")
    sigma = 1 / np.sqrt(np.sum(totals['3.5'])) * np.sqrt(2)
    print(f" Poisson for the sums of two steps: {sigma:.3f}")
    print(" by window, all draws summed:", " ".join(f"{lo}-{hi}: {win['7'][i]/win['3.5'][i]:.3f}/{win['14'][i]/win['3.5'][i]:.3f}" for i, (lo, hi) in enumerate(zip(edges[:-1], edges[1:]))))
