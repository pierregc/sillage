"""clock.py <scene folder> [--json]: the orbit's clock from curves-hires.csv: every pericentre (a minimum
of the separation that the bodies climb at least 2 kpc out of), the merger (the first time the separation
stays under 3 kpc) and when the remnant settles (its extent within 5 % of its final value from then on)."""
import csv, json, sys

def clock(folder, climb=2.0, merged=3.0, steady=0.05):
    rows = list(csv.DictReader(open(f"{folder}/curves-hires.csv")))
    t = [float(r["time_myr"]) for r in rows]
    d = [float(r["separation_kpc"]) for r in rows]
    x = [float(r["extent_kpc"]) for r in rows]
    merge = next((i for i in range(len(d)) if all(v < merged for v in d[i:])), None)
    end = merge if merge is not None else len(d)
    peris, lo, rising = [], 0, False
    for i in range(1, end):
        if d[i] < d[lo] and not rising:
            lo = i
        elif not rising and d[i] > d[lo] + climb:
            peris.append(lo); rising = True; hi = i
        elif rising:
            if d[i] > d[hi]:
                hi = i
            elif d[i] < d[hi] - climb:
                rising = False; lo = i
    settle = None
    if merge is not None:
        final = sum(x[-20:]) / len(x[-20:])
        settle = next((i for i in range(merge, len(x)) if all(abs(v - final) <= steady * final for v in x[i:])), None)
    return {
        "pericentres": [{"myr": round(t[i], 1), "kpc": round(d[i], 2)} for i in peris],
        "merger_myr": round(t[merge], 1) if merge is not None else None,
        "settled_myr": round(t[settle], 1) if settle is not None else None,
        "settled_extent_kpc": round(x[settle], 1) if settle is not None else None,
        "start_myr": round(t[0], 1),
        "end_myr": round(t[-1], 1),
    }

if __name__ == "__main__":
    c = clock(sys.argv[1])
    if "--json" in sys.argv:
        print(json.dumps(c, indent=1))
    else:
        p = c["pericentres"]
        gaps = [round(b["myr"] - a["myr"]) for a, b in zip(p, p[1:])]
        print(" ".join(f"peri {q['myr']} Myr at {q['kpc']} kpc" for q in p),
              f"| between {gaps} | merger {c['merger_myr']} | settled {c['settled_myr']} ({c['settled_extent_kpc']} kpc) | end {c['end_myr']}")
