#!/usr/bin/env python3
"""Draws a ring's dust alone, with no run and no GPU: a first dust bench (#478).

    dust_map.py grains.f32 out-prefix [strength] [megayears]

`grains.f32` comes from the sampler (docs/notes/sombrero-dust-sheet.md): seven floats a grain,
position, opacity, velocity. Writes `<prefix>-face.jpg`, the column face on over 20 kpc, and
`<prefix>-hubble.jpg`, the lane 6 degrees from edge on over 19 kpc on a stand-in for the
galaxy's light (a glow and a flat disk, not Sillage's frame). `megayears` turns each grain on
its circle for that long first, to see what the shear does. Needs NumPy, SciPy and Pillow.
"""
import sys, numpy as np
from PIL import Image
from scipy.ndimage import gaussian_filter
src, out = sys.argv[1], sys.argv[2]
kappa = float(sys.argv[3]) if len(sys.argv) > 3 else 1.0
t = float(sys.argv[4]) if len(sys.argv) > 4 else 0.0
a = np.fromfile(src, dtype=np.float32).reshape(-1, 7)
x, y, z, lum, vx, vy, vz = a.T
if t > 0:
    r = np.hypot(x, y); v = np.hypot(vx, vy); w = v / r
    ph = np.arctan2(y, x) + np.sign(x * vy - y * vx) * w * t / 4.71
    x, y = r * np.cos(ph), r * np.sin(ph)
n = len(x)
print('grains', n, 'r percentiles', np.percentile(np.hypot(x, y), [2, 10, 25, 50, 75, 90, 98]).round(2), 'z rms', z.std().round(4))
scale = 1_200_000 / n

def tau(X, Y, wgt, half, px, blur):
    h, _, _ = np.histogram2d(Y, X, bins=[int(px * half[1] / half[0]), px], range=[[-half[1], half[1]], [-half[0], half[0]]], weights=wgt)
    cell = (2 * half[0] / px) ** 2
    return gaussian_filter(h, blur) / cell

# face on, 20 kpc across
tf = tau(x, y, lum, (10, 10), 1400, 1.2) * scale
cream = np.array([236, 226, 205.0])
def paint(tr, back=cream):
    red = np.stack([tr ** 0.75, tr ** 1.0, tr ** 1.35], -1)
    return (back * red).clip(0, 255).astype(np.uint8)
k = kappa * 6e-5
Image.fromarray(paint(np.exp(-k * tf))[::-1]).save(out + '-face.jpg', quality=90)

# Hubble view: 6 degrees above the plane, near side y < 0 below the core
inc = np.radians(6)
X = x; Y = y * np.sin(inc) + z * np.cos(inc)
half = (9.5, 2.2); px = 2400
near = y < 0
tn = tau(X[near], Y[near], lum[near], half, px, 1.0) * scale
tfar = tau(X[~near], Y[~near], lum[~near], half, px, 1.0) * scale
# light behind the near dust: all of the bulge and disk; behind the far dust: half
k2 = kappa * 6e-5 * np.sin(inc) * 3
yy, xx = np.mgrid[-half[1]:half[1]:tn.shape[0] * 1j, -half[0]:half[0]:px * 1j]
rr = np.hypot(xx, yy / 0.7)
glow = 0.25 + 0.75 / (1 + (rr / 1.2) ** 1.6)
disk = (np.abs(xx) < 8.6) * np.exp(-0.5 * (yy / (0.12 + np.sqrt(np.clip(1 - (xx / 8.6) ** 2, 0, 1)) * 8.6 * np.sin(inc))) ** 6)
light = np.clip(glow + 0.45 * disk, 0, 1.15)
tr = np.exp(-k2 * tn) * (0.5 + 0.5 * np.exp(-k2 * tfar))
img = paint(tr, back=np.array([255, 246, 228.0]))
img = (img * light[..., None]).clip(0, 255).astype(np.uint8)
Image.fromarray(img[::-1]).save(out + '-hubble.jpg', quality=92)
