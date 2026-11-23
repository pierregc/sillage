#!/usr/bin/env python3
"""measure.py <frame> [<frame> ...] [--kpc 26.5] [--crop x,y,w,h] [--roll deg]

Figures of a Sombrero frame beside the same figures of Hubble's picture (heic2506a), all in
display values (0 to 1), so that a look is judged on numbers. A frame is taken to be --kpc
across; the picture is 26.5 (9.54 arcminutes at 9.55 Mpc). The disk's long axis is found and laid
flat unless --roll is given.

  halo N     light N kpc over the centre, on the minor axis (far side, clear of the lane)
  side N     light N kpc along the major axis, 3 kpc over the plane
  corners    the sky
  halo r/g, b/g   the halo's colour 4 kpc over the centre
  disk       the stellar disk 4 kpc either side of the centre
  white      share of the frame above 0.97
  near/far lane: offset from the major axis, width at half depth, light left (1 = no lane),
                 its red over green, medians over cuts 2.5 to 6.5 kpc either side of the centre
"""
import argparse
import math
import os

import numpy as np
from PIL import Image, ImageFilter

LUMA = np.array([0.2126, 0.7152, 0.0722])
HUBBLE = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..", "catalogue", "images", "heic2506a.jpg")
WIDTH = 1024
HUBBLE_KPC = 26.5


def measure(im, kpc, roll=None):
    im = im.convert("RGB").resize((WIDTH, round(im.height * WIDTH / im.width)), Image.LANCZOS)
    lum = (np.asarray(im).astype(float) / 255) @ LUMA
    px = kpc / WIDTH
    soft = np.asarray(
        Image.fromarray((lum * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(6))).astype(float)
    cy, cx = np.unravel_index(np.argmax(soft), soft.shape)
    if roll is None:
        ys, xs = np.nonzero(soft > np.quantile(soft, 0.96))
        _, vecs = np.linalg.eigh(np.cov(np.vstack([xs - xs.mean(), ys - ys.mean()])))
        roll = math.degrees(math.atan2(vecs[1, 1], vecs[0, 1]))
        roll = (roll + 90) % 180 - 90
    im = im.rotate(roll, resample=Image.BICUBIC, center=(float(cx), float(cy)))
    rgb = np.asarray(im).astype(float) / 255
    lum = rgb @ LUMA
    height, width = lum.shape

    def at(dx, dy, half=0.4):
        x, y, r = round(cx + dx / px), round(cy - dy / px), max(int(half / px), 1)
        if not (r <= x < width - r and r <= y < height - r):
            return None
        return np.median(rgb[y - r:y + r + 1, x - r:x + r + 1].reshape(-1, 3), axis=0)

    def light(dx, dy, half=0.4):
        v = at(dx, dy, half)
        return None if v is None else float(v @ LUMA)

    out = {"roll": roll}
    for d in (1, 2, 3, 4, 5, 6, 7):
        out[f"halo {d}"] = light(0, d)
    for d in (3, 5, 7.5, 10, 12):
        both = [v for v in (light(-d, 3), light(d, 3)) if v is not None]
        out[f"side {d:g}"] = sum(both) / len(both) if both else None
    corners = [lum[:40, :60], lum[:40, -60:], lum[-40:, :60], lum[-40:, -60:]]
    out["corners"] = float(np.median([c.mean() for c in corners]))
    halo = at(0, 4)
    out["halo r/g"], out["halo b/g"] = float(halo[0] / halo[1]), float(halo[2] / halo[1])
    out["disk"] = (light(-4, 0, 0.2) + light(4, 0, 0.2)) / 2
    out["white"] = float((lum > 0.97).mean())

    reach = int(0.65 / px)
    for name, sign in (("near", 1), ("far", -1)):
        found = []
        for dx in (-6.5, -5, -4, -2.5, 2.5, 4, 5, 6.5):
            x, r = round(cx + dx / px), int(0.3 / px)
            col = lum[:, x - r:x + r + 1].mean(axis=1)
            red = (rgb[:, x - r:x + r + 1, 0] / np.maximum(rgb[:, x - r:x + r + 1, 1], 1e-3)).mean(axis=1)
            best = None
            for k in range(int(0.2 / px), int(1.6 / px)):
                y = cy + sign * k
                if not (reach <= y < height - reach):
                    continue
                edge = min(col[y - reach:y].max(), col[y + 1:y + reach + 1].max())
                left = col[y] / max(edge, 1e-3)
                if best is None or left < best[0]:
                    best = (left, y, edge, k)
            if best is None:
                continue
            left, y, edge, k = best
            half = (col[y] + edge) / 2
            up = y
            while up > 0 and col[up] < half:
                up -= 1
            down = y
            while down < height - 1 and col[down] < half:
                down += 1
            found.append((k * px, (down - up) * px, left, red[y]))
        f = np.median(np.array(found), axis=0)
        out[f"{name} lane offset"], out[f"{name} lane width"] = float(f[0]), float(f[1])
        out[f"{name} lane left"], out[f"{name} lane r/g"] = float(f[2]), float(f[3])
    return out


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("frames", nargs="+")
    p.add_argument("--kpc", type=float, default=HUBBLE_KPC)
    p.add_argument("--roll", type=float)
    p.add_argument("--crop")
    g = p.parse_args()
    crop = [int(v) for v in g.crop.split(",")] if g.crop else None
    columns = [("Hubble", measure(Image.open(HUBBLE), HUBBLE_KPC))]
    for path in g.frames:
        im = Image.open(path)
        if crop:
            im = im.crop((crop[0], crop[1], crop[0] + crop[2], crop[1] + crop[3]))
        columns.append((os.path.splitext(os.path.basename(path))[0][-18:], measure(im, g.kpc, g.roll)))
    print(f"{'':18}" + "".join(f"{name:>19}" for name, _ in columns))
    for key in columns[0][1]:
        cells = "".join(
            f"{'':>19}" if c[key] is None else f"{c[key]:>19.2f}" for _, c in columns)
        print(f"{key:18}" + cells)


if __name__ == "__main__":
    main()
