#!/usr/bin/env python3
"""Checks the rules read off the probe against every case: python3 rules.py <probe directory>

A point of size s at clip position (x, y, z, w) in a frame of W x H pixels:
  1. is dropped whole when z < 0 or z > w, when |x| > 1.5 w or |y| > 1.5 w, or when s <= 0;
  2. has its size clamped to 511;
  3. stands at c = ((x / w + 1) W / 2, (1 - y / w) H / 2), and its square runs from
     round(256 (c - s / 2)) / 256 to round(256 (c + s / 2)) / 256 on each axis;
  4. covers the pixels whose centre is in that square, the first edge included and the last not;
  5. gives a pixel point_coord = (pixel centre - first edge) / span on each axis, the span
     being the square's side with its two edges rounded to a sixteenth of a pixel instead:
     (round(16 (c + s / 2)) - round(16 (c - s / 2))) / 16.
"""
import json, sys
import numpy as np

folder = sys.argv[1]
manifest = json.load(open(f"{folder}/manifest.json"))
f32 = np.float32
failures = 0
worst = 0.0
for case in manifest["cases"]:
    W, H = case["width"], case["height"]
    x, y, z, w = (f32(v) for v in case["clip"])
    s = min(f32(case["size"]), f32(511))
    dropped = z < 0 or z > w or abs(x) > f32(1.5) * w or abs(y) > f32(1.5) * w or s <= 0
    cover = np.zeros((H, W), bool)
    if not dropped:
        cx = (x / w + f32(1)) * f32(W) / f32(2)
        cy = (f32(1) - y / w) * f32(H) / f32(2)
        snap = lambda v: np.round(np.float64(v) * 256) / 256
        x0, x1, y0, y1 = snap(cx - s / 2), snap(cx + s / 2), snap(cy - s / 2), snap(cy + s / 2)
        px, py = np.arange(W) + 0.5, np.arange(H) + 0.5
        inx, iny = (px >= x0) & (px < x1), (py >= y0) & (py < y1)
        cover = iny[:, None] & inx[None, :]
        span = lambda c: (np.round(np.float64(c + s / 2) * 16) - np.round(np.float64(c - s / 2) * 16)) / 16
        u, v = (px - x0) / span(cx), (py - y0) / span(cy)
    if int(cover.sum()) != case["covered"]:
        failures += 1
        print(f"{case['name']}: {case['covered']} pixels covered, the rules give {int(cover.sum())}")
        continue
    if case.get("file"):
        got = np.fromfile(f"{folder}/{case['file']}", dtype=f32).reshape(H, W, 4)
        if not ((got[..., 2] > 0) == cover).all():
            failures += 1
            print(f"{case['name']}: the covered pixels are not the ones the rules give")
            continue
        if cover.any():
            error = max(np.abs(got[..., 0] - u[None, :])[cover].max(), np.abs(got[..., 1] - v[:, None])[cover].max())
            worst = max(worst, float(error))
            if error > 1e-5:
                failures += 1
                print(f"{case['name']}: point_coord off by {error:.3g}")
print(f"{len(manifest['cases'])} cases, {failures} off the rules, point_coord within {worst:.2g}")
sys.exit(1 if failures else 0)
