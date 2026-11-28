"""row.py <work dir> <scene folder> [key=value ...]: the scene's row for sweep.csv: its overrides, its clock, its
matches, the tails and the rules of #525. Rule 1 (plain disks): the free match's moment must fall inside the
window, from 20 Myr after the first pericentre to the merger. Rule 2 (the mirror): seen from the matched view,
the disk on the north nucleus must turn clockwise and the southern one counter-clockwise, as both papers'
models do from their views (docs/notes/antennae.md); a disk seen within 10 degrees of edge on passes."""
import csv, io, json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from clock import clock
from spin import senses
from tails import measure, read_frame, place

KEYS = ["pericentre", "eccentricity", "i1", "i2", "w1", "w2", "massRatio", "diskScale", "seed"]
FIELDS = ["name", "status"] + KEYS + ["peri1", "peri1_kpc", "peri2", "merger", "settled", "score", "myr", "since_peri1",
          "since_peri2", "elevation", "azimuth", "roll", "free_score", "free_myr", "north_sense", "south_sense",
          "tail_n_kpc", "tail_n_pa", "tail_s_kpc", "tail_s_pa", "rule1", "rule2", "kept"]

def row(work, s, overrides):
    o = dict(a.split("=", 1) for a in overrides)
    r = {"name": os.path.basename(s.rstrip("/")), "status": "ok", **{k: o.get(k, "") for k in KEYS}}
    c = clock(s); p = c["pericentres"]
    r.update(peri1=p[0]["myr"], peri1_kpc=p[0]["kpc"], peri2=p[1]["myr"] if len(p) > 1 else "",
             merger=c["merger_myr"] or "", settled=c["settled_myr"] or "")
    m = json.load(open(f"{s}/match/antennae.json")); f = json.load(open(f"{s}/match/antennae-free.json")); v = m["view"]
    r.update(score=round(m["score"], 4), myr=round(m["megayears"], 1), since_peri1=round(m["megayears"] - p[0]["myr"], 1),
             since_peri2=round(m["megayears"] - p[1]["myr"], 1) if len(p) > 1 else "",
             elevation=round(v["elevation"], 1), azimuth=round(v["azimuth"], 1), roll=round(v["roll"], 1),
             free_score=round(f["score"], 4), free_myr=round(f["megayears"], 1))
    end = c["merger_myr"] or c["end_myr"]
    r["rule1"] = "pass" if p[0]["myr"] + 20 - 5 <= f["megayears"] <= end + 5 else "plain disks" if f["megayears"] < p[0]["myr"] else "after merger"
    sense = senses(s, v, m["megayears"])
    _, xyz, comp, galaxy = read_frame(s, m["megayears"])
    ys = [place(xyz[(galaxy == k) & (comp == 4)].mean(0, keepdims=True), v)[1][0] for k in range(2)]
    north, south = (0, 1) if ys[0] <= ys[1] else (1, 0)
    r.update(north_sense=round(sense[north], 2), south_sense=round(sense[south], 2))
    edge = 0.17  # sin 10 degrees
    r["rule2"] = "pass" if sense[north] < edge and sense[south] > -edge else "mirror"
    _, tips, _, _ = measure(s, m, m["megayears"], f"{work}/ref/antennae.map.json")
    r.update(tail_n_kpc=round(tips["north"][0], 1), tail_n_pa=round(tips["north"][1]), tail_s_kpc=round(tips["south"][0], 1), tail_s_pa=round(tips["south"][1]))
    r["kept"] = "yes" if r["rule1"] == "pass" and r["rule2"] == "pass" else "no"
    return r

if __name__ == "__main__":
    work, s = sys.argv[1], sys.argv[2]
    try:
        r = row(work, s, sys.argv[3:])
    except Exception as e:
        r = {"name": os.path.basename(s.rstrip("/")), "status": f"failed: {type(e).__name__}"}
    path = f"{work}/sweep.csv"
    out = io.StringIO(); w = csv.DictWriter(out, fieldnames=FIELDS)
    if not os.path.exists(path) or os.path.getsize(path) == 0:
        w.writeheader()
    w.writerow(r); sys.stdout.write(out.getvalue())
