"""plots.py <work dir> <out.png>: the window match's score over each parameter for every scene of sweep.csv, the
scenes the rules kept in colour, those they dropped in grey, the finalists' 500 k scores ringed."""
import csv, os, sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from plan import ROUND1

rows = [r for r in csv.DictReader(open(f"{sys.argv[1]}/sweep.csv")) if r.get("status") == "ok"]
first = [r for r in rows if not r["name"].endswith("-f")]; again = [r for r in rows if r["name"].endswith("-f")]
fig, axes = plt.subplots(2, 4, figsize=(16, 7.5), sharey=True)
for ax, key in zip(axes.flat, ROUND1):
    for group, colour, label in ((["no"], "#bbbbbb", "dropped by a rule"), (["yes"], "#2a6fdb", "kept")):
        pts = [(float(r[key]), float(r["score"])) for r in first if r["kept"] in group]
        if pts:
            ax.scatter(*zip(*pts), s=10, c=colour, label=label)
    pts = [(float(r[key]), float(r["score"])) for r in again]
    if pts:
        ax.scatter(*zip(*pts), s=40, facecolors="none", edgecolors="#d9480f", label="finalist at 500 k")
    ax.set_xlabel(key); ax.grid(alpha=0.3)
axes[0, 0].set_ylabel("window match score"); axes[1, 0].set_ylabel("window match score"); axes[0, 0].legend(fontsize=8)
fig.suptitle(f"Antennae #525: {len(first)} previews round Karl et al. 2010")
fig.tight_layout(); fig.savefig(sys.argv[2], dpi=110)
