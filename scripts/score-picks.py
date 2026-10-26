#!/usr/bin/env python3
"""One-off: turns the entries of a batch's ratings.json written at one instant with rating 0
(what a hand-run night wrote for its picks) into score picks, taking each score from index.csv.

    scripts/score-picks.py library/2026-10-25-night 2026-10-25T21:57:45Z
"""
import csv, json, shutil, sys
from pathlib import Path

batch, at = Path(sys.argv[1]), sys.argv[2]
path = batch / "ratings.json"
shutil.copy(path, path.with_name("ratings.json.bak"))
data = json.loads(path.read_text())
scores = {row["id"]: float(row["score"]) for row in csv.DictReader((batch / "index.csv").open())}
for name, entry in data["scenes"].items():
    if entry.get("updated") == at and entry.get("choice") == "yes" and entry.get("rating") == 0:
        data["scenes"][name] = {"picked": {"by": "score", "score": scores[name], "date": at}}
        print("picked", name, scores[name])
path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
