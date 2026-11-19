#!/usr/bin/env python3
"""Frame-to-frame change over the galaxies, as the #315 note measured its clip.

    flicker.py <prefix> <first> <last> [peak_first peak_last]

Frames <prefix><n>.png, read at 1920 px. Each frame's mean |F - (prev + next) / 2| over the
galaxies (ruler's galaxy mask), in 0-255; the whole clip, the peak window, and the 99.9th centile
of the per-pixel change in the peak window.
"""
import sys
import numpy as np
from PIL import Image
sys.path.insert(0, __import__("os").path.expanduser("~/claude-workspace/sillage-wt-340/scripts"))
import importlib.util
spec = importlib.util.spec_from_file_location("ruler", __import__("os").path.expanduser("~/claude-workspace/sillage-wt-340/scripts/photo-ruler.py"))
ruler = importlib.util.module_from_spec(spec); spec.loader.exec_module(ruler)

prefix, first, last = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
peak = (int(sys.argv[4]), int(sys.argv[5])) if len(sys.argv) > 5 else (161, 198)

def load(n):
    im = Image.open(prefix % n if "%" in prefix else f"{prefix}{n}.png").convert("RGB")
    if im.width != 1920:
        im = im.resize((1920, round(im.height * 1920 / im.width)), Image.LANCZOS)
    return np.asarray(im, dtype=np.float64)

frames = {}
def get(n):
    if n not in frames:
        frames[n] = load(n)
        for k in list(frames):
            if k < n - 2: del frames[k]
    return frames[n]

per, peak_pixels, levels = {}, [], {}
for n in range(first + 1, last):
    f = get(n)
    d = np.abs(f - 0.5 * (get(n - 1) + get(n + 1))).mean(axis=2)
    L = ruler.oklab(ruler.srgb_to_linear(f / 255.0))[..., 0]
    sky = np.percentile(ruler.blur(L, 8), 5)
    galaxy = (L > sky + 0.10) & (ruler.blur(L, 32) > sky + 0.10)
    per[n] = d[galaxy].mean()
    levels[n] = (np.median(L[L > sky + 0.10]), np.percentile(L[L > sky + 0.10], 99))
    if peak[0] <= n <= peak[1]:
        peak_pixels.append(d[galaxy])
values = np.array(list(per.values()))
inpeak = np.array([v for n, v in per.items() if peak[0] <= n <= peak[1]])
l50 = np.array([v[0] for v in levels.values()]); l99 = np.array([v[1] for v in levels.values()])
print(f"clip {values.mean():.2f}  peak {peak[0]}-{peak[1]} {inpeak.mean():.2f}  p99.9 {np.percentile(np.concatenate(peak_pixels), 99.9):.0f}"
      f"  L50 {l50.min():.3f}-{l50.max():.3f} step {np.abs(np.diff(l50)).max():.4f}  L99 {l99.min():.3f}-{l99.max():.3f} step {np.abs(np.diff(l99)).max():.4f}")
