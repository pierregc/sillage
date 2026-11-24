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

import hubble_ref

LUMA = np.array([0.2126, 0.7152, 0.0722])
HUBBLE_KPC = hubble_ref.KPC
WIDTH = 3072  # the width every frame is brought to, the bench's own; --width, or hubble_ref's full frame
# Lengths once counted in pixels of the old small copy, now shares of the width
BLUR = 0.00586  # the smoothing that finds the core
CORNER_W, CORNER_H = 0.0586, 0.0391  # the sky patches
STEP = 0.1  # kpc between the columns of the rim's solidity


def measure(im, kpc, roll=None, width=None):
    """Figures of `im` (a picture `kpc` across), brought to `width` px across (WIDTH) unless it is
    that already; a larger width keeps more of the lane's grain."""
    width_px = width or WIDTH
    if im.width != width_px:
        im = im.convert("RGB").resize((width_px, round(im.height * width_px / im.width)),
                                      Image.LANCZOS)
    im = im.convert("RGB")
    lum = (np.asarray(im).astype(float) / 255) @ LUMA
    px = kpc / width_px
    soft = np.asarray(Image.fromarray((lum * 255).astype(np.uint8)).filter(
        ImageFilter.GaussianBlur(BLUR * width_px))).astype(float)
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
    ch, cw = round(CORNER_H * width_px), round(CORNER_W * width_px)
    corners = [lum[:ch, :cw], lum[:ch, -cw:], lum[-ch:, :cw], lum[-ch:, -cw:]]
    out["corners"] = float(np.median([c.mean() for c in corners]))
    halo = at(0, 4)
    out["halo r/g"], out["halo b/g"] = float(halo[0] / halo[1]), float(halo[2] / halo[1])
    out["disk"] = (light(-4, 0, 0.2) + light(4, 0, 0.2)) / 2
    out["white"] = float((lum > 0.97).mean())

    reach = int(0.65 / px)

    def lane(dx, sign, half_width=0.3):
        """The darkest row under (sign 1) or over the core at dx kpc along the disk: the light left
        there against the brighter of the light just over and under it, the lane's width at half
        depth, its red over green, its offset from the axis, and the column and rows it spans."""
        x, r = round(cx + dx / px), max(int(half_width / px), 1)
        if not (r <= x < width - r):
            return None
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
            return None
        left, y, edge, k = best
        half = (col[y] + edge) / 2
        up = y
        while up > 0 and col[up] < half:
            up -= 1
        down = y
        while down < height - 1 and col[down] < half:
            down += 1
        return k * px, (down - up) * px, left, red[y], x, up, down, edge

    for name, sign in (("near", 1), ("far", -1)):
        found = [f[:4] for f in (lane(dx, sign) for dx in (-6.5, -5, -4, -2.5, 2.5, 4, 5, 6.5)) if f]
        f = np.median(np.array(found), axis=0)
        out[f"{name} lane offset"], out[f"{name} lane width"] = float(f[0]), float(f[1])
        out[f"{name} lane left"], out[f"{name} lane r/g"] = float(f[2]), float(f[3])

    # The near lane along the major axis (#478): at the rim, three quarters and half of the ring's
    # radius (7.5 kpc), both sides, narrow columns: how deep, how wide and how red it is there.
    for label, at in (("rim", 7.0), ("3/4", 5.6), ("1/2", 3.75)):
        found = [f[:4] for f in (lane(s * at, 1, 0.12) for s in (-1, 1)) if f]
        if found:
            f = np.mean(np.array(found), axis=0)
            out[f"lane {label} left"], out[f"lane {label} width"], out[f"lane {label} r/g"] = (
                float(f[2]), float(f[1]), float(f[3]))
        else:
            out[f"lane {label} left"] = out[f"lane {label} width"] = out[f"lane {label} r/g"] = None
    # How solid the near lane is at the rim: over columns 5 to 7 kpc out on both sides, the share
    # of pixels within the lane's half-depth band that hold under 0.7 of the light round it.
    dark, total = 0, 0
    for s in (-1, 1):
        for dx in np.arange(5.0, 7.0, STEP):
            f = lane(s * dx, 1, 0.02)
            if not f:
                continue
            _, _, _, _, x, up, down, edge = f
            band = lum[up:down + 1, x]
            dark += int((band < 0.7 * edge).sum()); total += band.size
    out["rim solid"] = dark / total if total else None
    return out


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("frames", nargs="+")
    p.add_argument("--kpc", type=float, default=HUBBLE_KPC)
    p.add_argument("--roll", type=float)
    p.add_argument("--crop")
    p.add_argument("--width", type=int, help=f"px across the frames are measured at (default {WIDTH})")
    p.add_argument("--hubble", help="Hubble's full frame (default $SOMBRERO_HUBBLE, the local copy, "
                                    "then the lane strip of assets/478-sombrero)")
    g = p.parse_args()
    width = g.width or WIDTH
    crop = [int(v) for v in g.crop.split(",")] if g.crop else None
    hub = hubble_ref.load(g.hubble)
    columns = [("Hubble", measure(hub.frame(width), HUBBLE_KPC, width=width))]
    for path in g.frames:
        im = Image.open(path)
        if crop:
            im = im.crop((crop[0], crop[1], crop[0] + crop[2], crop[1] + crop[3]))
        columns.append((os.path.splitext(os.path.basename(path))[0][-18:], measure(im, g.kpc, g.roll, width)))
    print(f"{'':18}" + "".join(f"{name:>19}" for name, _ in columns))
    for key in columns[0][1]:
        cells = "".join(
            f"{'':>19}" if c[key] is None else f"{c[key]:>19.2f}" for _, c in columns)
        print(f"{key:18}" + cells)


if __name__ == "__main__":
    main()
