"""select.py <work dir> finalists <n> <out plan.csv> | select.py <work dir> keep <n> <out.csv>
finalists: the best n scenes of sweep.csv kept by rules 1 and 2, as a plan to run again at 500 k with another seed
(names <name>-f). keep: the finalists ranked on their 500 k score (sweep.csv rows <name>-f), the rules applied again,
at most two a family, the best n kept; a finalist whose score moved between the two runs by more than the gap
between the n-th and the (n+1)-th is flagged (rule 3). Writes <out.csv> with the rank, the family and the flag."""
import csv, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from plan import ROUND1, FAMILY, distance

def rows(work):
    return [r for r in csv.DictReader(open(f"{work}/sweep.csv")) if r.get("status") == "ok"]

def main(work, what, n, out):
    rs = rows(work); by = {r["name"]: r for r in rs}
    if what == "finalists":
        kept = sorted((r for r in rs if r["kept"] == "yes" and not r["name"].endswith("-f")), key=lambda r: -float(r["score"]))[:n]
        with open(out, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=["name"] + list(ROUND1) + ["node", "seed"]); w.writeheader()
            for r in kept:
                w.writerow({"name": r["name"] + "-f", **{k: r[k] for k in ROUND1}, "node": "descending", "seed": 20261128})
        return
    finals = [(by[r["name"][:-2]], r) for r in rs if r["name"].endswith("-f") and r["name"][:-2] in by]
    ok = sorted([p for p in finals if p[1]["kept"] == "yes"], key=lambda p: -float(p[1]["score"]))
    chosen, families = [], []
    for first, again in ok:
        fam = next((i for i, f in enumerate(families) if distance(again, f) <= FAMILY), None)
        if fam is None:
            families.append(again); fam = len(families) - 1
        if sum(1 for c in chosen if c[2] == fam) < 2 and len(chosen) < n:
            chosen.append((first, again, fam))
    scores = sorted((float(a["score"]) for _, a in ok), reverse=True)
    gap = scores[n - 1] - scores[n] if len(scores) > n else (scores[-2] - scores[-1] if len(scores) > 1 else 0)
    fields = ["rank", "name", "family", "score", "score_200k", "noise_flag", "myr", "since_peri1", "since_peri2",
              "elevation", "azimuth", "roll"] + list(ROUND1) + ["tail_n_kpc", "tail_n_pa", "tail_s_kpc", "tail_s_pa", "north_sense", "south_sense"]
    with open(out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields); w.writeheader()
        for k, (first, again, fam) in enumerate(chosen, 1):
            moved = abs(float(again["score"]) - float(first["score"]))
            w.writerow({"rank": k, "name": again["name"], "family": fam + 1, "score": again["score"], "score_200k": first["score"],
                        "noise_flag": "yes" if moved > max(gap, 1e-4) else "", **{x: again[x] for x in fields if x in again and x not in ("name", "score")}})
    dropped = {"finalists": len(finals), "dropped by the rules at 500 k": len(finals) - len(ok), "families": len(families)}
    print(dropped)

if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4])
