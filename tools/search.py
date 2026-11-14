#!/usr/bin/env python3
"""search.py <tag> <look.json> <L50 target> key=value...: brightness so the passage frame's lit median hits the target."""
import json, math, os, subprocess, sys
here = os.path.dirname(os.path.abspath(__file__))
tag, source, target, extra = sys.argv[1], sys.argv[2], float(sys.argv[3]), sys.argv[4:]

def run(b):
    subprocess.run([sys.executable, f"{here}/tool.py", "looks", tag, source, *extra, f"look.brightness={b}"], check=True)
    subprocess.run([sys.executable, f"{here}/tool.py", "render", tag], check=True, capture_output=True)
    out = subprocess.run([sys.executable, f"{here}/tool.py", "measure", tag], check=True, capture_output=True, text=True).stdout
    rows = {l.split()[0]: dict(zip(l.split()[1::2], map(float, l.split()[2::2]))) for l in out.splitlines()}
    return rows

b = json.load(open(source))["look"]["brightness"]
lo, hi = None, None
for i in range(6):
    rows = run(b)
    l50 = rows[f"mice/{tag}/passage"]["L50"]
    if abs(l50 - target) < 0.012:
        break
    if l50 < target:
        lo = b
        b = b * 1.6 if hi is None else math.sqrt(b * hi)
    else:
        hi = b
        b = b / 1.6 if lo is None else math.sqrt(b * lo)
print(tag, "brightness", round(b, 4))
for k, v in rows.items():
    print(k, "  ".join(f"{a} {x}" for a, x in v.items()))
