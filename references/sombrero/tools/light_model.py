#!/usr/bin/env python3
"""light_model.py: a 3D model of the Sombrero's light, for the share of light behind a dust grain (#495).

The bench's light frame is Sillage's render with the dust off: a display picture, the energy under it
run through the look's log stretch and white point (Shaders.swift, compositePixel). `to_energy` undoes
that curve (sombrero-v6.look.json: stretch 1.1, white point 13; bloom and saturation left out) and
`from_energy` redoes it, so dust can dim the light the renderer dims, before its curve.

The model is an oblate Sersic bulge (effective radius `re`, index `n`, axis ratio `q`) and a disk
whose radial profile is free (linear between knots every kpc) and whose height is sech^2(z / hz). It is
fitted to the light frame's energy, seen as Hubble frames it; `share(x, y, z)` is then the share of the
model's light along the line of sight through a point that lies behind it.

  light_model.py fit [--light PATH] [--out light-model.json] [--sheet check.jpg]
"""
import argparse
import hashlib
import json
import math
import os
import sys

import numpy as np
from scipy.ndimage import map_coordinates
from scipy.optimize import minimize, nnls

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import hubble_ref  # noqa: E402

KPC, CORE = hubble_ref.KPC, hubble_ref.CORE
INC, ROLL = math.radians(6), math.radians(5.63)
LUMA = np.array([0.2126, 0.7152, 0.0722], np.float32)
DEFAULT = os.path.join(HERE, "light-model.json")
KNOTS = np.arange(0.0, 13.0, 1.0)  # kpc, the disk's radial profile


# ---------------------------------------------------------------- the renderer's curve

def to_energy(lin, stretch, white):
    """Display light made linear (display ** gamma, H x W x 3) back to the renderer's energy."""
    luma = np.clip(lin @ LUMA, 1e-6, None)
    t = np.clip(luma, 1e-6, 0.999)
    a = 1 / white ** 2
    lifted = (-(1 - t) + np.sqrt((1 - t) ** 2 + 4 * a * t)) / (2 * a)
    lifted_rgb = lin * (lifted / luma)[..., None]
    return (np.exp(lifted_rgb * math.log1p(stretch)) - 1) / stretch


def from_energy(energy, stretch, white):
    """The inverse of `to_energy`: energy to display light made linear."""
    lifted = np.log1p(np.maximum(energy, 0) * stretch) / math.log1p(stretch)
    luma = np.clip(lifted @ LUMA, 1e-6, None)
    toned = luma * (1 + luma / white ** 2) / (1 + luma)
    return lifted * (toned / luma)[..., None]


# ---------------------------------------------------------------- the model

def sersic_b(n):
    return 2 * n - 1 / 3 + 0.009876 / n


def bulge(m, re, n):
    """Prugniel-Simien emissivity: its projection is a Sersic profile of index n, effective radius re."""
    p = 1 - 0.6097 / n + 0.05463 / n ** 2
    s = np.maximum(m, 0.01) / re
    return s ** -p * np.exp(-sersic_b(n) * s ** (1 / n))


def hat(r, k):
    """Linear interpolation weight of knot k at radius r."""
    return np.clip(1 - np.abs(r - KNOTS[k]) / (KNOTS[1] - KNOTS[0]), 0, 1)


def galaxy_xyz(sx, sy, t):
    """Galaxy coordinates of a point on the sky at (sx, sy) kpc from the core (disk's axis laid flat),
    t kpc toward the observer (dust_bench.project: near half y < 0)."""
    y = sy * math.sin(INC) - t * math.cos(INC)
    z = sy * math.cos(INC) + t * math.sin(INC)
    return sx, y, z


def depth_of(y, z):
    return -y * math.cos(INC) + z * math.sin(INC)


def emissivity(p, x, y, z):
    r = np.hypot(x, y)
    m = np.sqrt(r * r + (z / p["q"]) ** 2)
    j = p["bulge"] * bulge(m, p["re"], p["n"])
    v = 1 / np.cosh(z / p["hz"]) ** 2
    for k, amp in enumerate(p["disk"]):
        if amp > 0:
            j = j + amp * hat(r, k) * v
    return j


def bases(r, z, dt, re, n, q, hz):
    """Projected images (summed along the last axis, the line of sight) of the bulge and of each disk
    knot, unit amplitudes."""
    out = [bulge(np.sqrt(r ** 2 + (z / q) ** 2), re, n).sum(-1) * dt]
    v = 1 / np.cosh(z / hz) ** 2
    out += [(hat(r, k) * v).sum(-1) * dt for k in range(len(KNOTS))]
    return np.stack(out, -1)


# ---------------------------------------------------------------- fit

def sky_coords(width, height):
    kpp = KPC / width
    yy, xx = np.mgrid[0:height, 0:width].astype(np.float32)
    ux, uy = (xx + 0.5 - CORE[0] * width) * kpp, -(yy + 0.5 - CORE[1] * width) * kpp
    return ux * math.cos(ROLL) - uy * math.sin(ROLL), ux * math.sin(ROLL) + uy * math.cos(ROLL)


def fit(light_lin, stretch, white, block=12, reach=12.0, height=3.5, core_cut=0.25, verbose=True):
    """Fits the model to the energy of a light frame (display light made linear, H x W x 3)."""
    energy = to_energy(light_lin, stretch, white) @ LUMA
    h, w = energy.shape
    h2, w2 = h // block, w // block
    e = energy[:h2 * block, :w2 * block].reshape(h2, block, w2, block).mean((1, 3))
    sx, sy = sky_coords(w2, h2)
    keep = (np.abs(sx) < reach) & (np.abs(sy) < height) & (np.hypot(sx, sy) > core_cut)
    ex, ey, ev = sx[keep], sy[keep], e[keep]
    t = np.arange(-16, 16, 0.05)
    S, T = np.meshgrid(ex, t, indexing="ij")
    Y = np.broadcast_to(ey[:, None], S.shape)
    x, y, z = galaxy_xyz(S, Y, T)
    r = np.hypot(x, y)
    wts = 1 / np.maximum(ev, 1e-4)  # relative error

    def solve(v):
        re, n, q, hz = math.exp(v[0]), v[1], v[2], math.exp(v[3])
        if not (0.5 <= n <= 8 and 0.2 <= q <= 1.0 and 0.02 <= hz <= 1.5 and 0.2 <= re <= 15):
            return 1e9, None
        a = bases(r, z, t[1] - t[0], re, n, q, hz)
        amps, _ = nnls(a * wts[:, None], ev * wts)
        res = (a @ amps - ev) * wts
        return float(np.sqrt(np.mean(res ** 2))), amps

    best = minimize(lambda v: solve(v)[0], [math.log(2.0), 3.0, 0.7, math.log(0.25)], method="Nelder-Mead",
                    options=dict(xatol=1e-3, fatol=1e-5, maxiter=160))
    err, amps = solve(best.x)
    p = dict(re=math.exp(best.x[0]), n=float(best.x[1]), q=float(best.x[2]), hz=math.exp(best.x[3]),
             bulge=float(amps[0]), disk=[float(a) for a in amps[1:]], stretch=stretch, white=white,
             fit_rms=err)
    if verbose:
        print(f"fit: re {p['re']:.2f} kpc, n {p['n']:.2f}, q {p['q']:.2f}, hz {p['hz']:.3f} kpc, "
              f"relative rms {err:.3f} over {ev.size} blocks", file=sys.stderr)
    return p


# ---------------------------------------------------------------- the share behind a point

SX = np.arange(-12.5, 12.51, 0.1)
SY = np.arange(-2.5, 2.501, 0.025)
TT = np.arange(-16.0, 16.001, 0.04)


def share_table(p):
    """F[sx, sy, t]: the share of the model's light along the line of sight at (sx, sy) that lies
    behind depth t (t toward the observer). Built one column of sx at a time."""
    out = np.empty((len(SX), len(SY), len(TT)), np.float32)
    for i, s in enumerate(SX):
        S, Y, T = np.meshgrid([s], SY, TT, indexing="ij")
        x, y, z = galaxy_xyz(S, Y, T)
        j = emissivity(p, x, y, z)[0]
        c = np.cumsum(j, -1)
        out[i] = c / np.maximum(c[:, -1:], 1e-30)
    return out


_TABLES = {}


def table_path(p):
    key = hashlib.md5(json.dumps(p, sort_keys=True).encode()).hexdigest()[:12]
    return os.path.join("/tmp", "dust_bench_assets", f"share-{key}.npy")


def load_table(p):
    """The share table of model p, cached on disk (built once, read by every worker)."""
    path = table_path(p)
    if path not in _TABLES:
        if not os.path.exists(path):
            os.makedirs(os.path.dirname(path), exist_ok=True)
            tmp = path + f".{os.getpid()}.npy"
            np.save(tmp, share_table(p))
            os.replace(tmp, path)
        _TABLES[path] = np.load(path, mmap_mode="r")
    return _TABLES[path]


def share(p, x, y, z):
    """Share of the light behind each point (galaxy coordinates, kpc)."""
    tab = load_table(p)
    sx = x
    sy = y * math.sin(INC) + z * math.cos(INC)
    t = depth_of(y, z)
    coords = np.stack([(sx - SX[0]) / (SX[1] - SX[0]), (sy - SY[0]) / (SY[1] - SY[0]), (t - TT[0]) / (TT[1] - TT[0])])
    return map_coordinates(tab, coords, order=1, mode="nearest").astype(np.float32)


def load(path=None):
    return json.load(open(path or DEFAULT))


def model_image(p, width, height, step=0.05):
    """The model's energy on a frame `width` px across (for checking the fit)."""
    sx, sy = sky_coords(width, height)
    t = np.arange(-16, 16, step)
    out = np.zeros((height, width), np.float32)
    for r in range(height):
        S, T = np.meshgrid(sx[r], t, indexing="ij")
        Y = np.broadcast_to(sy[r][:, None], S.shape)
        out[r] = emissivity(p, *galaxy_xyz(S, Y, T)).sum(-1) * step
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", choices=["fit"])
    ap.add_argument("--light", help="the light frame (default: bench-light-12myr-26.5.png of assets/478-sombrero)")
    ap.add_argument("--stretch", type=float, default=1.1)
    ap.add_argument("--white", type=float, default=13.0)
    ap.add_argument("--out", default=DEFAULT)
    ap.add_argument("--sheet", help="JPG: the light's energy against the model's, profiles")
    g = ap.parse_args()
    import dust_bench
    light, _ = dust_bench.load_light(g.light, dust_bench.BASE_W)
    light = dust_bench.clean_light(light)
    lin = (light.astype(np.float32) / 255) ** 2.2
    p = fit(lin, g.stretch, g.white)
    json.dump(p, open(g.out, "w"), indent=1)
    print("wrote", g.out)
    if g.sheet:
        check_sheet(p, lin, g.sheet)


def check_sheet(p, lin, path):
    """Profiles of the light's energy and of the model's along the minor axis and three cuts."""
    from PIL import Image, ImageDraw
    import dust_bench
    energy = to_energy(lin, p["stretch"], p["white"]) @ LUMA
    w = 384
    h = round(w * energy.shape[0] / energy.shape[1])
    b = energy.shape[1] // w
    e = energy[:h * b, :w * b].reshape(h, b, w, b).mean((1, 3))
    m = model_image(p, w, h)
    sx, sy = sky_coords(w, h)
    W, H = 1200, 1050
    im = Image.new("RGB", (W, H), "white")
    d = ImageDraw.Draw(im)
    cuts = [("minor axis, over the core", np.abs(sx) < 0.15, sy, (0, 5)),
            ("major axis", np.abs(sy) < 0.07, np.abs(sx), (0, 12)),
            ("0.5 kpc over the axis", np.abs(sy - 0.5) < 0.07, np.abs(sx), (0, 12)),
            ("1.5 kpc over the axis", np.abs(sy - 1.5) < 0.07, np.abs(sx), (0, 12))]
    f = dust_bench.font(20)
    for k, (title, sel, coord, (lo, hi)) in enumerate(cuts):
        ox, oy, pw, ph = 60 + (k % 2) * 580, 40 + (k // 2) * 430, 520, 360
        d.rectangle((ox, oy, ox + pw, oy + ph), outline=(160, 160, 160))
        d.text((ox, oy - 26), title + " (energy; black: light, red: model)", font=f, fill=(0, 0, 0))
        for v in range(-2, 4):
            y_ = oy + ph - (v + 2) / 5 * ph
            d.line((ox - 6, y_, ox, y_), fill=(0, 0, 0))
            d.text((ox - 56, y_ - 10), f"{10.0 ** v:g}", font=dust_bench.font(16), fill=(0, 0, 0))
        for v in range(lo, hi + 1, 1 if hi - lo <= 6 else 2):
            x_ = ox + (v - lo) / (hi - lo) * pw
            d.line((x_, oy + ph, x_, oy + ph + 6), fill=(0, 0, 0))
            d.text((x_ - 6, oy + ph + 8), f"{v}", font=dust_bench.font(16), fill=(0, 0, 0))
        c = coord[sel]
        good = (c >= lo) & (c <= hi)
        for vals, col in ((e[sel], (0, 0, 0)), (m[sel], (200, 30, 30))):
            v = np.log10(np.maximum(vals[good], 1e-3))
            xs = ox + (c[good] - lo) / (hi - lo) * pw
            ys = oy + ph - (v + 2) / 5 * ph   # 0.01 to 1000
            for x_, y_ in zip(xs, ys):
                d.ellipse((x_ - 2, y_ - 2, x_ + 2, y_ + 2), fill=col)
    lines = [f"bulge: Sersic re {p['re']:.2f} kpc, n {p['n']:.2f}, axis ratio {p['q']:.2f};  disk: sech^2 height "
             f"{p['hz']:.3f} kpc, profile by knot (kpc: amplitude) " + ", ".join(
                 f"{k:.0f}: {a:.2f}" for k, a in zip(KNOTS, p["disk"]) if a > 0.005),
             f"fit on the light's energy (stretch {p['stretch']}, white {p['white']}), |x| < 12, |y| < 3.5 kpc, "
             f"relative rms {p['fit_rms']:.3f}; x axes in kpc from the core",
             "share of light behind a grain at height 0 on the ring (near half / far half), by x along the disk:"]
    for r in (5.0, 6.5, 8.5):
        xs = np.array([x for x in (0, 2, 4, 6, 8) if x < r] + [r - 0.2])
        y = np.sqrt(r * r - xs * xs)
        bn, bf = share(p, xs, -y, 0 * xs), share(p, xs, y, 0 * xs)
        lines.append(f"  r {r:.1f} kpc: " + "   ".join(f"x {x:.1f}: {a:.2f} / {b:.2f}" for x, a, b in zip(xs, bn, bf)))
    for k, line in enumerate(lines):
        d.text((60, H - 150 + 24 * k), line, font=dust_bench.font(17), fill=(0, 0, 0))
    im.save(path, quality=90)
    print("sheet", path)


if __name__ == "__main__":
    main()
