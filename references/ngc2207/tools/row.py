"""row.py <scene folder>: name, score, moment, time since the first pericentre, separation then, view."""
import csv, json, os, sys
s = sys.argv[1]; n = os.path.basename(s.rstrip("/"))
try:
    m = json.load(open(f"{s}/match/ngc2207.json")); v = m["view"]
except Exception:
    print(f"{n},failed"); sys.exit()
rows = list(csv.DictReader(open(f"{s}/curves-hires.csv")))
t = [float(r["time_myr"]) for r in rows]; d = [float(r["separation_kpc"]) for r in rows]
peri = next((i for i in range(1, len(d) - 1) if d[i] <= d[i - 1] and d[i] <= d[i + 1]), None)
at = min(range(len(t)), key=lambda i: abs(t[i] - m["megayears"]))
since = m["megayears"] - t[peri] if peri is not None else float("nan")
q = d[peri] if peri is not None else float("nan")
try:
    f = json.load(open(f"{s}/match/ngc2207-free.json")); free = f"{f['score']:.4f},{f['megayears']:.1f}"
except Exception:
    free = ","
print(f"{n},{m['score']:.4f},{m['megayears']:.1f},{since:.0f},{q:.1f},{d[at]:.1f},"
      f"{v['elevation']:.1f},{v['azimuth']:.1f},{v['roll']:.1f},{free}")
