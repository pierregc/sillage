#!/usr/bin/env python3
"""dust_bench.py [params.json] [key=value ...] [options]: tunes a ring's dust without the galaxy (#478).

Dust = grains drawn from an envelope (radial profile, Gaussian height) and weighted by a noise
(fBm of gradient noise, optional warp, shear, contrast curve), or read from a .f32 file of the
sampler (--grains, 7 floats a grain: x y z opacity vx vy vz). Projected as Hubble frames it
(6 degrees from edge on, roll 5.63, core at 504,312 of 1024 x 606, 26.5 kpc across), near half
(y < 0, below the core) and far half apart, then laid on a light frame: near dust dims the
share `behind` of the light, far dust the share `behind_far`; transmission per channel
(1-b) + b exp(-k a_c N). The measure.py figures are printed and drawn on each variant.

  dust_bench.py rim_solid.json --out /tmp/a.png --sheet /tmp/a.jpg
  dust_bench.py --grains /tmp/v6.f32 --sheet /tmp/v6.jpg --ref "Sillage v6 (rendu réel)=real.png"
  dust_bench.py scale=0.3,0.6,1.2 warp=0,0.5,1 --sheet /tmp/grid.jpg      # a grid, 9 variants

Options: --light PATH|origin|standin (origin: bench-light-12myr-26.5.png of branch
origin/assets/478-sombrero; default origin if fetched, else the stand-in), --width PX (3072; a
grid uses 1536), --out PNG, --sheet JPG, --ref LABEL=PNG (a rendered frame, repeatable), --label.
Parameters (key=value, or in the JSON), with defaults: see DEFAULTS.
"""
import argparse
import itertools
import json
import math
import os
import subprocess
import sys
from concurrent.futures import ProcessPoolExecutor

import numpy as np
from PIL import Image, ImageDraw, ImageFont
from scipy.ndimage import gaussian_filter

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import measure  # noqa: E402

Image.MAX_IMAGE_PIXELS = None
FRAME_KPC, CORE, BASE_W, BASE_H = 26.5, (504 / 1024, 312 / 1024), 3072, 1818
INC, ROLL = math.radians(6), math.radians(5.63)

DEFAULTS = dict(
    # envelope
    rim=8.8, inner=0.56, rise=0.5, plateau=0.95, fall=0.35, thickness=0.04, flare=0.35,
    # noise
    octaves=6, scale=0.9, gain=0.55, warp=0.0, warp_scale=2.0, threshold=-0.4, gamma=1.5,
    curve="pow", expk=1.0, veil=0.1, shear=0.0, threads=0.0, thread_width=0.12, seed=1,
    # grains
    n=6_000_000, myr=0.0,
    # light
    k=0.19, blur=0.6, behind=0.95, behind_far=0.18, redden=3.0, gamma_light=2.2, kernel=1.0,
)
# Reddening of the renderer (Shaders.swift): exp(-column * (1, 1.22, 1.52)); `redden` scales the excess.
CHANNELS = np.array([0.0, 0.22, 0.52])
KEYS = [("near lane left", "proche"), ("near lane width", "largeur"), ("near lane r/g", "r/g"),
        ("rim solid", "bord plein"), ("far lane left", "lointain")]
TABLE = ["lane rim left", "lane rim width", "lane 3/4 left", "lane 1/2 left", "lane 1/2 width",
         "lane rim r/g", "far lane left", "rim solid", "near lane left", "near lane width", "near lane r/g"]


# ---------------------------------------------------------------- noise

def _tables(seed):
    rng = np.random.default_rng(seed)
    perm = rng.permutation(256).astype(np.int32)
    perm = np.concatenate([perm, perm])
    g = np.array([[1, 1, 0], [-1, 1, 0], [1, -1, 0], [-1, -1, 0], [1, 0, 1], [-1, 0, 1],
                  [1, 0, -1], [-1, 0, -1], [0, 1, 1], [0, -1, 1], [0, 1, -1], [0, -1, -1]], np.float32)
    return perm, g


def perlin(p, tab):
    """Improved Perlin noise, vectorised over the rows of p (N, 3), about -1 to 1."""
    perm, grads = tab
    i = np.floor(p)
    f = (p - i).astype(np.float32)
    i = i.astype(np.int64) & 255
    u = f * f * f * (f * (f * 6 - 15) + 10)
    out = 0
    for dx, dy, dz in itertools.product((0, 1), repeat=3):
        h = perm[perm[perm[i[:, 0] + dx] + i[:, 1] + dy] + i[:, 2] + dz] % 12
        d = grads[h]
        dot = d[:, 0] * (f[:, 0] - dx) + d[:, 1] * (f[:, 1] - dy) + d[:, 2] * (f[:, 2] - dz)
        w = ((u[:, 0] if dx else 1 - u[:, 0]) * (u[:, 1] if dy else 1 - u[:, 1])
             * (u[:, 2] if dz else 1 - u[:, 2]))
        out = out + w * dot
    return out


def fbm(p, par, tab, rots):
    """Octaves twice finer and `gain` as strong, each read through its own rotation and offset so
    the lattice never lines up between octaves."""
    total = 0
    amp = 1.0
    freq = 1.0 / par["scale"]
    for o in range(int(par["octaves"])):
        q = (p @ rots[o]) * freq + o * 17.31
        total = total + amp * perlin(q.astype(np.float32), tab)
        amp *= par["gain"]
        freq *= 2.0
    return total


def _rotations(seed, count):
    rng = np.random.default_rng(seed + 99)
    out = []
    for _ in range(count):
        q, _ = np.linalg.qr(rng.normal(size=(3, 3)))
        out.append(q.astype(np.float32))
    return out


# ---------------------------------------------------------------- dust

def smoothstep(a, b, x):
    t = np.clip((x - a) / max(b - a, 1e-9), 0, 1)
    return t * t * (3 - 2 * t)


def radial_profile(r, par):
    rim, inner = par["rim"], par["inner"] * par["rim"]
    up = smoothstep(inner, inner + par["rise"], r)
    plateau = 0.8 + 0.2 * smoothstep(inner, par["plateau"] * rim, r)
    down = 1 - smoothstep(par["plateau"] * rim, rim + par["fall"], r)
    return up * plateau * down


def thickness_at(r, par):
    inner = par["inner"] * par["rim"]
    t = np.clip((r - inner) / max(par["rim"] - inner, 1e-9), 0, 1)
    return par["thickness"] * (par["flare"] + (1 - par["flare"]) * t)


def sample_envelope(par, n, rng):
    grid = np.linspace(0, par["rim"] + 3 * par["fall"] + 0.5, 4000)
    pdf = radial_profile(grid, par) * grid
    cdf = np.cumsum(pdf)
    cdf /= cdf[-1]
    r = np.interp(rng.random(n), cdf, grid)
    th = rng.random(n) * 2 * np.pi
    z = rng.normal(size=n) * thickness_at(r, par)
    return r, th, z


def raw_noise(r, th, z, par, tab, rots):
    ln = np.log(np.maximum(r, 1e-3) / par["rim"])
    a = th - par["shear"] * ln
    p = np.stack([r * np.cos(a), r * np.sin(a), z], -1).astype(np.float32)
    if par["warp"] > 0:
        s = par["scale"] * par["warp_scale"]
        q = p / s
        dx = np.stack([perlin(q + o, tab) for o in (0.0, 31.4, 71.7)], -1)
        p = p + par["warp"] * par["scale"] * dx
    n = fbm(p, par, tab, rots)
    if par["threads"] > 0:
        # thin concentric-ish threads: ridges of a noise of the radius, wavering with the angle
        q = np.stack([r / (par["scale"] * 0.12), 0.6 * np.cos(a) + 5.0, 0.6 * np.sin(a)], -1).astype(np.float32)
        ridge = np.exp(-(perlin(q, tab) / par["thread_width"]) ** 2)
        return n, ridge
    return n, None


def contrast(n, par, stats):
    mean, std = stats["mean"], stats["std"]
    z = (n - mean) / std
    if par["curve"] == "exp":
        w = np.exp(par["expk"] * z)
    else:
        w = np.maximum(z - par["threshold"], 0) ** par["gamma"]
    return w


def weights(par, n, rng, tab, rots, stats):
    r, th, z = sample_envelope(par, n, rng)
    nz, ridge = raw_noise(r, th, z, par, tab, rots)
    w = contrast(nz, par, stats) / stats["wmean"]
    w = par["veil"] + (1 - par["veil"]) * w
    if ridge is not None:
        w = (1 - par["threads"]) * w + par["threads"] * ridge / stats["rmean"]
    return r * np.cos(th), r * np.sin(th), z, w.astype(np.float32)


def pilot(par, tab, rots):
    rng = np.random.default_rng(par["seed"] + 5)
    r, th, z = sample_envelope(par, 200_000, rng)
    nz, ridge = raw_noise(r, th, z, par, tab, rots)
    stats = dict(mean=float(nz.mean()), std=float(nz.std()))
    w = contrast(nz, par, dict(stats, wmean=1))
    stats["wmean"] = float(max(w.mean(), 1e-9))
    stats["rmean"] = float(max(ridge.mean(), 1e-9)) if ridge is not None else 1.0
    return stats


# ---------------------------------------------------------------- projection

def project(x, y, z, w, par, width):
    """Column maps (near, far) in units of mass share per kpc^2 times 100, on a width-px frame."""
    height = round(width * BASE_H / BASE_W)
    kpp = FRAME_KPC / width
    sx = x
    sy = y * math.sin(INC) + z * math.cos(INC)
    ux = sx * math.cos(ROLL) + sy * math.sin(ROLL)
    uy = -sx * math.sin(ROLL) + sy * math.cos(ROLL)
    px = np.rint(CORE[0] * width + ux / kpp).astype(np.int64)
    py = np.rint(CORE[1] * width - uy / kpp).astype(np.int64)
    maps = []
    for sel in (y < 0, y >= 0):
        ok = sel & (px >= 0) & (px < width) & (py >= 0) & (py < height)
        m = np.bincount(py[ok] * width + px[ok], weights=w[ok], minlength=width * height)
        maps.append(m.reshape(height, width).astype(np.float32))
    return maps


def _chunk(args):
    par, n, seed, stats, width = args
    tab, rots = _tables(par["seed"]), _rotations(par["seed"], int(par["octaves"]))
    x, y, z, w = weights(par, n, np.random.default_rng(seed), tab, rots, stats)
    return project(x, y, z, w, par, width), float(w.sum())


def procedural_columns(par, width, pool=None):
    tab, rots = _tables(par["seed"]), _rotations(par["seed"], int(par["octaves"]))
    stats = pilot(par, tab, rots)
    parts = 4
    jobs = [(par, par["n"] // parts, par["seed"] * 1000 + i, stats, width) for i in range(parts)]
    res = list(pool.map(_chunk, jobs)) if pool else [_chunk(j) for j in jobs]
    near = sum(r[0][0] for r in res)
    far = sum(r[0][1] for r in res)
    return near, far, sum(r[1] for r in res)


def grain_columns(path, par, width):
    a = np.fromfile(path, dtype=np.float32).reshape(-1, 7)
    x, y, z, lum, vx, vy, vz = a.T
    if par["myr"] > 0:
        r = np.hypot(x, y)
        ph = np.arctan2(y, x) + np.sign(x * vy - y * vx) * np.hypot(vx, vy) / np.maximum(r, 1e-6) * par["myr"] / 4.71
        x, y = r * np.cos(ph), r * np.sin(ph)
    near, far = project(x, y, z, lum.astype(np.float32), par, width)
    return near, far, float(lum.sum())


def to_column(m, total, par, width):
    kpp = FRAME_KPC / width
    m = gaussian_filter(m, par["blur"] * width / BASE_W)
    return m / total / kpp ** 2 * 100.0


# ---------------------------------------------------------------- light

def stand_in_light(width):
    """STAND-IN, not Sillage's frame: dust_map.py's glow and flat disk laid on the rolled frame."""
    height = round(width * BASE_H / BASE_W)
    kpp = FRAME_KPC / width
    yy, xx = np.mgrid[0:height, 0:width].astype(np.float32)
    ux, uy = (xx - CORE[0] * width) * kpp, -(yy - CORE[1] * width) * kpp
    sx = ux * math.cos(ROLL) - uy * math.sin(ROLL)
    sy = ux * math.sin(ROLL) + uy * math.cos(ROLL)
    rr = np.hypot(sx, sy / 0.7)
    glow = 0.25 + 0.75 / (1 + (rr / 1.2) ** 1.6)
    edge = np.sqrt(np.clip(1 - (sx / 8.6) ** 2, 0, 1)) * 8.6 * math.sin(INC)
    disk = (np.abs(sx) < 8.6) * np.exp(-0.5 * (sy / (0.12 + edge)) ** 6)
    lum = np.clip(glow + 0.45 * disk, 0, 1.15) * 0.85 * np.exp(-(np.hypot(sx, sy) / 14) ** 2 * 0.6)
    colour = np.array([1.0, 0.96, 0.89])
    return (np.clip(lum[..., None] * colour, 0, 1) * 255).astype(np.uint8)


def fetch_asset(name):
    cache = os.path.join("/tmp", "dust_bench_assets")
    os.makedirs(cache, exist_ok=True)
    dest = os.path.join(cache, name)
    if not os.path.exists(dest):
        root = os.path.join(HERE, "..", "..", "..")
        subprocess.run(["git", "-C", root, "fetch", "origin", "assets/478-sombrero"], check=False,
                       capture_output=True)
        blob = subprocess.run(["git", "-C", root, "show", f"origin/assets/478-sombrero:{name}"],
                              capture_output=True)
        if blob.returncode:
            return None
        open(dest, "wb").write(blob.stdout)
    return dest


def load_light(spec, width):
    """Returns (rgb uint8 at width, name of the light used)."""
    path = None
    if spec in (None, "origin"):
        path = fetch_asset("bench-light-12myr-26.5.png")
    elif spec != "standin":
        path = spec
    if path is None:
        return stand_in_light(width), "stand-in"
    im = Image.open(path).convert("RGB")
    height = round(width * BASE_H / BASE_W)
    if im.size != (width, height):
        im = im.resize((width, height), Image.LANCZOS)
    return np.asarray(im), "rendu réel"


def attenuate(light, near, far, par):
    a = 1 + par["redden"] * CHANNELS
    g = par["gamma_light"]
    lin = (light.astype(np.float32) / 255) ** g
    k = par["k"]
    for col, b in ((near, par["behind"]), (far, par["behind_far"])):
        t = (1 - b) + b * np.exp(-k * col[..., None] * a)
        lin = lin * t
    return (np.clip(lin, 0, 1) ** (1 / g) * 255 + 0.5).astype(np.uint8)


def render(par, light, grains=None, width=BASE_W, pool=None):
    if grains:
        near, far, total = grain_columns(grains, par, width)
    else:
        near, far, total = procedural_columns(par, width, pool)
    near, far = to_column(near, total, par, width), to_column(far, total, par, width)
    return Image.fromarray(attenuate(light, near, far, par))


# ---------------------------------------------------------------- sheet

def font(size):
    for f in ("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", "/usr/share/fonts/dejavu/DejaVuSans.ttf"):
        if os.path.exists(f):
            return ImageFont.truetype(f, size)
    return ImageFont.load_default()


def flat(im, width=BASE_W):
    """closeup.py's laying flat: scaled to width, rotated about Hubble's core."""
    h = round(width * 606 / 1024)
    im = im.convert("RGB").resize((width, h), Image.LANCZOS)
    return im.rotate(5.63, resample=Image.BICUBIC, center=(504 * width / 1024, 312 * width / 1024))


BOXES = [(0.09, 0.41, 0.90, 0.63), (0.09, 0.44, 0.30, 0.60), (0.40, 0.40, 0.60, 0.60)]


def crops(im, width=BASE_W):
    h = round(width * 606 / 1024)
    return [im.crop((round(a * width), round(b * h), round(c * width), round(d * h))) for a, b, c, d in BOXES]


def figures_line(fig):
    return "   ".join(f"{label} {fig[key]:.2f}" for key, label in KEYS if fig.get(key) is not None)


def row(label, im, fig, full_w, wide=True):
    """One row: band, then lane's left end and core, same scale for every row."""
    b, l, c = crops(flat(im, BASE_W))
    tw = full_w // 2
    th = round(l.height * tw / l.width)
    bh = round(b.height * full_w / b.width)
    f = font(30)
    out = Image.new("RGB", (full_w, 44 + bh + (th if wide else 0)), "black")
    d = ImageDraw.Draw(out)
    d.text((10, 5), label + (("    " + figures_line(fig)) if fig else ""), font=f, fill="white")
    out.paste(b.resize((full_w, bh), Image.LANCZOS), (0, 44))
    if wide:
        out.paste(l.resize((tw, th), Image.LANCZOS), (0, 44 + bh))
        out.paste(c.resize((tw, th), Image.LANCZOS), (tw, 44 + bh))
    return out


def make_sheet(path, items, hubble_fig, full_w=2400, wide=True):
    hub = Image.open(measure.HUBBLE)
    rows = [row("Hubble   " if True else "", hub, hubble_fig, full_w, wide)]
    rows += [row(label, im, fig, full_w, wide) for label, im, fig in items]
    sheet = Image.new("RGB", (full_w, sum(r.height for r in rows)), "black")
    y = 0
    for r in rows:
        sheet.paste(r, (0, y))
        y += r.height
    sheet.save(path, quality=90)
    return sheet


# ---------------------------------------------------------------- main

def parse_value(v):
    try:
        return float(v) if any(c in v for c in ".e") else int(v)
    except ValueError:
        return v


def figures(im):
    return measure.measure(im, FRAME_KPC)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("args", nargs="*", help="params.json and key=value (a comma list makes a grid)")
    p.add_argument("--grains")
    p.add_argument("--light")
    p.add_argument("--width", type=int)
    p.add_argument("--out")
    p.add_argument("--sheet")
    p.add_argument("--ref", action="append", default=[])
    p.add_argument("--label", default=None)
    p.add_argument("--table", action="store_true", help="print the calibration figures")
    g = p.parse_args()

    par = dict(DEFAULTS)
    sweep = {}
    for a in g.args:
        if "=" not in a:
            par.update(json.load(open(a)))
        else:
            k, v = a.split("=", 1)
            if k not in DEFAULTS:
                sys.exit(f"unknown parameter {k}")
            if "," in v:
                sweep[k] = [parse_value(x) for x in v.split(",")]
            else:
                par[k] = parse_value(v)
    names, values = list(sweep), list(itertools.product(*sweep.values())) if sweep else [()]
    if len(values) > 12:
        sys.exit("a grid is 12 variants at most")
    width = g.width or (1536 if sweep else BASE_W)
    light, light_name = load_light(g.light, width)
    print("light:", light_name, file=sys.stderr)

    variants = []
    for v in values:
        q = dict(par)
        q.update(dict(zip(names, v)))
        label = g.label or ("grains" if g.grains else "banc")
        variants.append((label + ("  " + " ".join(f"{k}={x}" for k, x in zip(names, v)) if names else ""), q))

    pool = ProcessPoolExecutor(4) if not g.grains else None
    items = []
    for label, q in variants:
        im = render(q, light, g.grains, width, pool)
        if len(variants) == 1 and g.out:
            im.save(g.out)
        items.append((label, im, figures(im)))
    for r in g.ref:
        label, path = r.split("=", 1)
        im = Image.open(path).convert("RGB")
        items.append((label, im, figures(im)))
    hub_fig = figures(Image.open(measure.HUBBLE))

    if g.table:
        print(f"{'':16}{'Hubble':>10}" + "".join(f"{i[0][:12]:>14}" for i in items))
        for key in TABLE:
            cells = [hub_fig.get(key)] + [i[2].get(key) for i in items]
            print(f"{key:16}" + "".join(f"{c:>14.2f}" if c is not None else f"{'':>14}" for c in cells))
    for label, _, fig in items:
        print(label, "|", figures_line(fig))
    print("Hubble |", figures_line(hub_fig))
    if g.sheet:
        wide = len(items) <= 4
        make_sheet(g.sheet, items, hub_fig, 2400 if wide else 2000, wide)
        print("sheet", g.sheet)


if __name__ == "__main__":
    main()
