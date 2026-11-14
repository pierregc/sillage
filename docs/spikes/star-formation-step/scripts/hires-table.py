#!/usr/bin/env python3
"""Stars formed per window in the hires takes, 3.5 and its floor (#307's runs, #225's to the bit), 7 and 14."""
import json, os, struct
import numpy as np
O = os.path.expanduser("~/claude-workspace/epic-304-out/306/runs")
P = os.path.expanduser("~/claude-workspace/epic-304-out/307/runs")
runs = {"3.5": f"{P}/a-dt35/scene-0031", "floor": f"{P}/b-floor/scene-0031",
        "7": f"{O}/hires-7/scene-0031", "14": f"{O}/hires-14/scene-0031"}
edges = [0, 156.67, 305, 420, 510, 700, 887.03]
def take(folder):
    path = os.path.join(folder, "take.sillage")
    if not os.path.exists(path) or not os.path.exists(os.path.join(folder, "hires.json")):
        return None
    with open(path, "rb") as f:
        f.read(16); (length,) = struct.unpack("<Q", f.read(8)); header = json.loads(f.read(length))
    n = header["particleCount"]
    born = np.asarray(np.memmap(path, dtype="<f4", mode="r", offset=24 + length + 8 * n, shape=(n,)))
    return born[(born >= 0) & (born < 1e8)] * 4.71
data = {k: take(v) for k, v in runs.items()}
data = {k: v for k, v in data.items() if v is not None}
print("| Myr | " + " | ".join(data) + " |")
base = np.histogram(data["3.5"], bins=edges)[0]
for i, (lo, hi) in enumerate(zip(edges[:-1], edges[1:])):
    cells = [f"{base[i] / (hi - lo):.0f}"]
    for k, v in data.items():
        if k == "3.5": continue
        c = np.histogram(v, bins=edges)[0][i]
        cells.append(f"{c / base[i]:.3f}")
    print(f"| {lo:.0f} to {hi:.0f} | " + " | ".join(cells) + f" |  sigma {1/np.sqrt(base[i]):.4f}")
tot = {k: ((v >= edges[1]) & (v < edges[-1])).sum() for k, v in data.items()}
print("clip totals", tot, {k: round(t / tot["3.5"], 4) for k, t in tot.items()})
alls = {k: v.size for k, v in data.items()}
print("whole run", alls, {k: round(t / alls["3.5"], 4) for k, t in alls.items()})
