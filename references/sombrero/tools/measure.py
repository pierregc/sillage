#!/usr/bin/env python3
"""measure.py <frame> [<frame> ...] [--kpc 26.5] [--crop x,y,w,h] [--roll deg]
measure.py --halves [--width 0] [<frame> ...]    the near and far lanes column by column (#495)

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
from scipy.ndimage import gaussian_filter1d

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


BANDS = np.arange(-6.5, 6.51, 0.5)  # kpc along the major axis, centres of the columns `halves` reads
SIN_I = math.sin(math.radians(6))


def flat_strip(src, scale, reach=7.5, depth=1.7):
    """Display luminance and red over green of the frame laid flat about Hubble's core (rolled 5.63
    degrees), `reach` kpc either side along the disk and `depth` kpc over and under, `scale` px across
    the whole frame. Returns lum, rg, the core's row and column, px per kpc."""
    k, (cx, cy) = 1 / HUBBLE_KPC, hubble_ref.CORE
    im = hubble_ref.flat_region(src, (cx - reach * k, cy - depth * k, cx + reach * k, cy + depth * k), scale)
    rgb = np.asarray(im).astype(np.float32) / 255
    ppk = scale / HUBBLE_KPC
    return rgb @ LUMA.astype(np.float32), rgb[..., 0] / np.maximum(rgb[..., 1], 1e-3), depth * ppk, im.width / 2, ppk


def _upper_baseline(d, prof, sel, deg, rounds=6):
    """The light without the lane: a polynomial in log light over `sel`, refitted on the points that
    are not more than half a scatter under it, so dark dips do not pull it down."""
    x, y = d[sel], np.log(np.maximum(prof[sel], 1e-4))
    keep = np.ones_like(x, bool)
    for _ in range(rounds):
        p = np.polyfit(x[keep], y[keep], deg)
        res = y - np.polyval(p, x)
        keep = res > -0.5 * np.std(res[keep])
    return np.exp(np.polyval(p, d))


def lane_profile(d, prof, rg, sign, ppk, lo=0.2, hi=1.4, deg=3):
    """One half (sign 1 over the core, -1 under) of a column's profile against its upper baseline (fitted
    from 0.12 to 1.65 kpc): the darkest height in lo..hi kpc, the width at half depth, the depth (1 - light
    left), the half-depth edge facing the core, and the red over green there."""
    sel = (sign * d >= 0.12) & (sign * d <= 1.65)
    ratio = prof / _upper_baseline(d, prof, sel, deg)
    ratio = gaussian_filter1d(ratio, max(0.01 * ppk, 0.5))
    idx = np.nonzero((sign * d >= lo) & (sign * d <= hi))[0]
    k = idx[np.argmin(ratio[idx])]
    depth = 1 - ratio[k]
    up = down = k
    while up > 0 and ratio[up] < 1 - depth / 2:
        up -= 1
    while down < len(d) - 1 and ratio[down] < 1 - depth / 2:
        down += 1
    inner = min(abs(d[up]), abs(d[down]))
    return dict(offset=abs(d[k]), width=(down - up) / ppk, depth=depth, inner=inner, rg=float(rg[k]))


def halves(src, scale=None, band=0.5, deg=3, far=(0.2, 1.4), near=(0.2, 1.4)):
    """Near (under the core) and far (over it) lanes, column by column along the disk (BANDS, `band` kpc
    wide), on `src` (a hubble_ref source in Hubble's framing) at `scale` px across (default its own)."""
    lum, rg, row0, col0, ppk = flat_strip(src, scale or src.width)
    d = (row0 - np.arange(lum.shape[0])) / ppk
    out = []
    for x in BANDS:
        a, b = round(col0 + (x - band / 2) * ppk), round(col0 + (x + band / 2) * ppk)
        prof, red = lum[:, a:b].mean(1), rg[:, a:b].mean(1)
        out.append(dict(x=float(x), near=lane_profile(d, prof, red, -1, ppk, *near, deg=deg),
                        far=lane_profile(d, prof, red, 1, ppk, *far, deg=deg)))
    return out


NUCLEUS = -0.04  # kpc: Hubble's nucleus lies this far under the core's row (CORE), measured on the full frame


def ring_fit(xs, offsets, z0=None):
    """Radius r and height z0 (kpc) of a circle seen 6 degrees from edge on whose projection
    sqrt(r^2 - x^2) sin i + z0 passes nearest the offsets: what radius a lane's line follows.
    A given z0 fixes the circle's centre (NUCLEUS: Hubble's nucleus, for a far lane over the core)."""
    best, fixed = None, z0
    for r in np.arange(3.0, 10.01, 0.02):
        proj = np.sqrt(np.clip(r * r - xs * xs, 0, None)) * SIN_I
        z0 = float(np.mean(offsets - proj)) if fixed is None else fixed
        err = float(np.sqrt(np.mean((offsets - proj - z0) ** 2)))
        if best is None or err < best[2]:
            best = (float(r), z0, err)
    return best


FAR_SPAN = (1.0, 4.5)  # |x| kpc where the far lane is read: clear of the core's inner dust, short of the tips


def far_summary(rows, z0=NUCLEUS):
    """Medians of the far lane over FAR_SPAN, with two noise figures: left against right (half their
    difference) and the scatter of the columns over sqrt(count); and the rings its line and the near
    lane's inner edge follow, about a centre z0 kpc over the core's row (NUCLEUS for Hubble, 0 for a bench)."""
    sel = [r for r in rows if FAR_SPAN[0] <= abs(r["x"]) <= FAR_SPAN[1]]
    out = {}
    for key in ("offset", "width", "depth", "inner"):
        v = np.array([r["far"][key] for r in sel])
        left = np.median([r["far"][key] for r in sel if r["x"] < 0])
        right = np.median([r["far"][key] for r in sel if r["x"] > 0])
        out[f"far {key}"] = float(np.median(v))
        out[f"far {key} lr"] = float(abs(left - right) / 2)
        out[f"far {key} sem"] = float(np.std(v) / math.sqrt(len(v)))
    xs = np.array([r["x"] for r in sel])
    far = np.array([r["far"]["offset"] for r in sel])
    out["far ring r"], _, out["far ring rms"] = ring_fit(xs, far, z0)
    # the near lane's edge facing the core, the far lane's mirror (heights counted down from the core's row)
    edge = np.array([r["near"]["inner"] for r in sel])
    out["near edge ring r"], _, out["near edge ring rms"] = ring_fit(xs, edge, -z0)
    out["near inner"] = float(np.median(edge))
    out["near offset"] = float(np.median([r["near"]["offset"] for r in sel]))
    out["near width"] = float(np.median([r["near"]["width"] for r in sel]))
    return out


def print_halves(rows, name):
    print(f"{name}: lanes by column (kpc from the core's row; depth = 1 - light left)")
    print(f"{'x':>6} | {'near off':>8} {'inner':>6} {'width':>6} {'depth':>6} | {'far off':>7} {'inner':>6} {'width':>6} {'depth':>6} {'r/g':>5}")
    for r in rows:
        n, f = r["near"], r["far"]
        print(f"{r['x']:+6.1f} | {n['offset']:8.2f} {n['inner']:6.2f} {n['width']:6.2f} {n['depth']:6.2f} | "
              f"{f['offset']:7.2f} {f['inner']:6.2f} {f['width']:6.2f} {f['depth']:6.3f} {f['rg']:5.2f}")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("frames", nargs="*")
    p.add_argument("--kpc", type=float, default=HUBBLE_KPC)
    p.add_argument("--roll", type=float)
    p.add_argument("--crop")
    p.add_argument("--width", type=int, help=f"px across the frames are measured at (default {WIDTH})")
    p.add_argument("--hubble", help="Hubble's full frame (default $SOMBRERO_HUBBLE, the local copy, "
                                    "then the lane strip of assets/478-sombrero)")
    p.add_argument("--halves", action="store_true",
                   help="the near and far lanes column by column (frames in Hubble's framing, at their own "
                        "width; Hubble at --width, 0 for its full 14319 px), the far lane's figures and noise")
    g = p.parse_args()
    width = g.width or WIDTH
    crop = [int(v) for v in g.crop.split(",")] if g.crop else None
    hub = hubble_ref.load(g.hubble)
    if g.halves:
        sources = [(f"Hubble at {width or hub.width} px", hub, width or hub.width)]
        sources += [(os.path.basename(f), hubble_ref.Source(Image.open(f)), None) for f in g.frames]
        for name, src, scale in sources:
            rows = halves(src, scale)
            print_halves(rows, name)
            degs = (2, 3, 4) if src is hub else (3,)
            for deg in degs:
                s = far_summary(rows if deg == 3 else halves(src, scale, deg=deg), NUCLEUS if src is hub else 0.0)
                print(f"  far lane over |x| {FAR_SPAN[0]:g}-{FAR_SPAN[1]:g} kpc, baseline degree {deg}: "
                      + "  ".join(f"{k} {s[k]:.2f} (lr {s[k + ' lr']:.3f}, sem {s[k + ' sem']:.3f})"
                                  for k in ("far offset", "far width", "far depth", "far inner")))
                print(f"    ring of the far line {s['far ring r']:.2f} kpc (rms {s['far ring rms']:.3f}); of the near "
                      f"lane's inner edge {s['near edge ring r']:.2f} kpc (rms {s['near edge ring rms']:.3f}); "
                      f"near offset {s['near offset']:.2f}, inner edge {s['near inner']:.2f}, width {s['near width']:.2f}")
        return
    if not g.frames and not g.halves:
        p.error("no frame")
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
