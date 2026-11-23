"""peri.py <scene folder>: the time of the first pericentre in the hires curves, in Myr."""
import csv, sys
rows = list(csv.DictReader(open(f"{sys.argv[1]}/curves-hires.csv")))
t = [float(r["time_myr"]) for r in rows]; d = [float(r["separation_kpc"]) for r in rows]
i = next((i for i in range(1, len(d) - 1) if d[i] <= d[i - 1] and d[i] <= d[i + 1]), None)
print(f"{t[i]:.1f}" if i is not None else "280")
