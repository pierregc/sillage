#!/usr/bin/env python3
"""dust_bench.py [params.json] [key=value ...] [options]: tunes a ring's dust without the galaxy (#478).

Dust = grains drawn from an envelope (radial profile, Gaussian height) and weighted by a noise
(fBm of gradient noise, optional warp, shear, contrast curve), or read from a .f32 file of the
sampler (--grains, 7 floats a grain: x y z opacity vx vy vz). Projected as Hubble frames it
(6 degrees from edge on, roll 5.63, core at 0.492, 0.305 of the width, 26.5 kpc across), near half
(y < 0, below the core) and far half apart, then laid on a light frame: near dust dims the
share `behind` of the light, far dust the share `behind_far` (share=split); or each grain the share
of light behind it along its line of sight, from light_model.py (share=depth); transmission per
channel (1-b) + b exp(-k a_c N). The measure.py figures, the far lane's among them, are printed and
drawn on each variant.

  dust_bench.py p1.json --face /tmp/a-face.jpg --out /tmp/a.png --sheet /tmp/a.jpg
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
import warnings
from concurrent.futures import ProcessPoolExecutor

import numpy as np
from PIL import Image, ImageDraw, ImageFont
from scipy.special import ndtri
from scipy.stats import qmc
from scipy.ndimage import binary_dilation, find_objects, gaussian_filter, label, median_filter, zoom

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import hubble_ref  # noqa: E402
import light_model  # noqa: E402
import measure  # noqa: E402

Image.MAX_IMAGE_PIXELS = None
warnings.filterwarnings("ignore", message=".*balance properties.*")
FRAME_KPC, CORE, BASE_W, BASE_H = hubble_ref.KPC, hubble_ref.CORE, 3072, 1818
INC, ROLL = math.radians(6), math.radians(5.63)

DEFAULTS = dict(
    # envelope: radii in kpc, `inner` a share of the rim; `inward` > 1 thins the dust faster inward
    rim=8.8, inner=0.56, rise=0.5, plateau=0.95, fall=0.35, floor=0.8, inward=1.0,
    thickness=0.04, flare=0.35,
    # noise: lengths in kpc along the orbit (lu), across (lv) and in height (lw) of the first octave
    kind="fbm", octaves=6, lu=1.0, lv=0.5, lw=0.2, lacunarity=2.0, gain=0.55, seed=1,
    warp_along=0.0, warp_across=0.0, warp_height=0.0, warp_lu=3.0, warp_lv=1.5, warp_lw=0.5,
    shear=0.0,
    # contrast: "pow" max(0, z - threshold)^gamma, or "exp"; `veil` is a floor of the density
    curve="pow", threshold=-0.4, gamma=1.5, expk=1.0, veil=0.1,
    # a thin upper veil: share vf of the grains, thicker by vscale, its own noise (kind, scale, contrast)
    vf=0.0, vscale=2.5, vkind="fbm", vlu=1.5, vthr=0.3, vgamma=1.5,
    # ragged top: the upper half's thickness times exp(rag * noise)
    rag=0.0, rag_lu=1.5, rag_lv=0.6,
    # fibres: share of fine ridges laid over the sheet
    fibres=0.0, fibre_lu=1.5, fibre_lv=0.04, fibre_lw=0.1, fibre_width=0.12,
    # the rim: a thin ridge in the last `edge_w` kpc (density share `edge`), the layer thinned there by
    # `edge_thin` (0 to 1); `tipfade` (0 to 1) thins a sector of `tip_w` degrees centred on azimuth `tip_az`, most at the rim
    # `taper` (kpc, 0 off): the whole profile decays as exp(-(r - inner) / taper), densest at the inner cut with a
    # sparse tail to the rim; `wobble` (kpc) scallops the inner cut along the azimuth, in lumps `wobble_len` kpc long
    taper=0.0, wobble=0.0, wobble_len=0.8,
    edge=0.0, edge_w=0.25, edge_thin=0.0, tipfade=0.0, tip_az=180.0, tip_w=35.0,
    # noise lattice: per-octave tilt of the cells (a spiral of up to `twist` radians) and jittered
    # reference radius, so no cell edge lines up with the azimuth/radius axes (twist 0, rjitter 0: as before)
    twist=0.45, rjitter=0.12,
    # grains: quasi-random (Sobol) positions and bilinear splats (qmc 0, splat 0: random, nearest pixel)
    n=6_000_000, myr=0.0, qmc=1, splat=1,
    # light
    mass=1.0, k=0.19, blur=0.6, behind=0.95, behind_far=0.18, redden=3.0, gamma_light=2.2, kernel=1.0,
    # thick dust turns grey: the reddening is divided by 1 + grey * (optical depth k N); 0 keeps it constant
    grey=0.0,
    # share of the light behind the dust: "split", `behind` under the core's row and `behind_far` over it;
    # "depth", each grain's own share along its line of sight, from the 3D light model `light_model`
    # (light_model.py; "" the fitted light-model.json beside this file)
    share="split", light_model="",
    # where the dust dims the light: 0, the display light made linear (light ** gamma_light); > 0, the
    # renderer's energy under its log `stretch` and `white` point (the v6 look: 1.1 and 13)
    stretch=0.0, white=13.0,
)
# Reddening of the renderer (Shaders.swift): exp(-column * (1, 1.22, 1.52)); `redden` scales the excess.
CHANNELS = np.array([0.0, 0.22, 0.52])
KEYS = [("near lane left", "proche"), ("near lane width", "largeur"), ("near lane r/g", "r/g"),
        ("rim solid", "bord plein"), ("far lane left", "lointain"),
        ("far offset", "loin h"), ("far width", "loin l"), ("far depth", "loin creux")]
TABLE = ["lane rim left", "lane rim width", "lane 3/4 left", "lane 1/2 left", "lane 1/2 width",
         "lane rim r/g", "far lane left", "rim solid", "near lane left", "near lane width", "near lane r/g",
         "far offset", "far width", "far depth"]


# ---------------------------------------------------------------- noise

GRADS = np.array([[1, 1, 0], [-1, 1, 0], [1, -1, 0], [-1, -1, 0], [1, 0, 1], [-1, 0, 1],
                  [1, 0, -1], [-1, 0, -1], [0, 1, 1], [0, -1, 1], [0, 1, -1], [0, -1, -1]], np.float32)
U32 = np.uint32


def _hash(iu, iv, iw, seed):
    h = iu.astype(U32) * U32(374761393) + iv.astype(U32) * U32(668265263) + iw.astype(U32) * U32(2246822519) + U32(seed)
    h = (h ^ (h >> U32(13))) * U32(1274126177)
    h ^= h >> U32(16)
    h = h * U32(2654435761)
    h ^= h >> U32(15)
    return h % U32(12)


def perlin(p, period, seed):
    """Gradient noise of p (N, 3), about -1 to 1, periodic along axis 0 (`period` cells)."""
    i = np.floor(p)
    f = (p - i).astype(np.float32)
    iu = np.mod(i[:, 0], period).astype(np.int64)
    iv, iw = i[:, 1].astype(np.int64), i[:, 2].astype(np.int64)
    u = f * f * f * (f * (f * 6 - 15) + 10)
    out = 0
    for dx, dy, dz in itertools.product((0, 1), repeat=3):
        d = GRADS[_hash((iu + dx) % period, iv + dy, iw + dz, seed)]
        dot = d[:, 0] * (f[:, 0] - dx) + d[:, 1] * (f[:, 1] - dy) + d[:, 2] * (f[:, 2] - dz)
        w = ((u[:, 0] if dx else 1 - u[:, 0]) * (u[:, 1] if dy else 1 - u[:, 1])
             * (u[:, 2] if dz else 1 - u[:, 2]))
        out = out + w * dot
    return out * 1.6


def cyl(a, r, z, lu, lv, lw, par, off=0.0, octave=0):
    """Noise coordinates: lattice cells along the orbit (an integer count round the ring), across, in height.
    Each octave reads the ring through its own spiral tilt (still periodic in azimuth) and its own
    reference radius for the cell count, so no lattice line follows an axis or sits at one radius."""
    rref = (0.78 + par["rjitter"] * math.sin(1.7 * octave + 0.3)) * par["rim"]
    cells = max(int(round(2 * math.pi * rref / lu)), 4)
    a = a + par["twist"] * math.sin(2.399 * octave + 0.7) * np.log(np.maximum(r, 1e-3) / par["rim"])
    p = np.stack([a / (2 * np.pi) * cells, r / lv + off, z / lw + off * 0.7], -1).astype(np.float32)
    return p, cells


def octaves(a, r, z, par, seed, lu, lv, lw, kind):
    """Sum of octaves, each lac times finer and `gain` as strong; kind fbm, ridged or billow."""
    total, amp, norm = 0, 1.0, 0.0
    lac = par["lacunarity"]
    for o in range(int(par["octaves"])):
        p, cells = cyl(a, r, z, lu / lac ** o, lv / lac ** o, lw / lac ** o, par, off=o * 13.37, octave=o)
        n = perlin(p, int(round(cells)), seed + 7 * o)
        if kind == "ridged":
            n = 1 - 2 * np.abs(n)
            n = n * n
        elif kind == "billow":
            n = 2 * np.abs(n) - 0.5
        total = total + amp * n
        norm += amp
        amp *= par["gain"]
    return total / norm


def warped(r, a, z, par):
    """Domain warp: the position read through three slow noises, in kpc along, across and up."""
    if par["warp_along"] == par["warp_across"] == par["warp_height"] == 0:
        return r, a, z
    rref = 0.78 * par["rim"]
    d = []
    for k in range(3):
        p, cells = cyl(a, r, z, par["warp_lu"], par["warp_lv"], par["warp_lw"], par, off=40.0 * (k + 1))
        d.append(perlin(p, cells, par["seed"] * 31 + 900 + k))
    return r + par["warp_across"] * d[1], a + par["warp_along"] * d[0] / rref, z + par["warp_height"] * d[2]


def smoothstep(a, b, x):
    t = np.clip((x - a) / np.maximum(b - a, 1e-9), 0, 1)
    return t * t * (3 - 2 * t)


def radial_profile(r, par):
    rim, inner = par["rim"], par["inner"] * par["rim"]
    up = smoothstep(inner - par["wobble"], inner - par["wobble"] + par["rise"], r)
    ramp = smoothstep(inner, par["plateau"] * rim, r) ** par["inward"]
    plateau = par["floor"] + (1 - par["floor"]) * ramp + par["edge"] * rim_ridge(r, par)
    down = 1 - smoothstep(par["plateau"] * rim, rim + par["fall"], r)
    tail = np.exp(-np.maximum(r - inner, 0) / par["taper"]) if par["taper"] > 0 else 1.0
    return up * plateau * down * tail * (r <= rim)   # nothing beyond the rim, whatever `fall` says


def rim_ridge(r, par):
    """1 at the rim, falling inward over `edge_w` kpc."""
    return np.exp(-0.5 * ((par["rim"] - r) / max(par["edge_w"], 1e-3)) ** 2)


def thickness_at(r, par):
    inner = par["inner"] * par["rim"]
    t = np.clip((r - inner) / max(par["rim"] - inner, 1e-9), 0, 1)
    return par["thickness"] * (par["flare"] + (1 - par["flare"]) * t) * (1 - par["edge_thin"] * rim_ridge(r, par))


def sample_envelope(par, n, rng):
    grid = np.linspace(0, par["rim"], 4000)
    pdf = radial_profile(grid, par) * grid
    cdf = np.cumsum(pdf)
    cdf /= cdf[-1]
    if par["qmc"]:   # stratified draws: the sheet is sampled evenly, not by chance
        u = qmc.Sobol(4, scramble=True, seed=rng.integers(1 << 31)).random(n)
    else:
        u = rng.random((n, 4))
    r = np.interp(u[:, 0], cdf, grid)
    th = u[:, 1] * 2 * np.pi
    veil = u[:, 3] < par["vf"]
    z = ndtri(np.clip(u[:, 2], 1e-7, 1 - 1e-7)) * thickness_at(r, par) * np.where(veil, par["vscale"], 1.0)
    if par["rag"] > 0:
        p, cells = cyl(th, r, np.zeros_like(r), par["rag_lu"], par["rag_lv"], 1.0, par)
        rg = np.exp(par["rag"] * perlin(p, cells, par["seed"] * 17 + 5))
        z = np.where(z > 0, z * rg, z)
    return r, th, z, veil


def raw_noise(r, th, z, veil, par):
    """Noise of every grain: the sheet's, a veil's own, and fibres' ridge value."""
    ln = np.log(np.maximum(r, 1e-3) / par["rim"])
    a = th - par["shear"] * ln
    r2, a2, z2 = warped(r, a, z, par)
    n = octaves(a2, r2, z2, par, par["seed"] * 13 + 1, par["lu"], par["lv"], par["lw"], par["kind"])
    if par["vf"] > 0:
        nv = octaves(a2, r2, z2, par, par["seed"] * 13 + 777, par["lu"] * par["vlu"], par["lv"] * par["vlu"],
                     par["lw"] * par["vlu"], par["vkind"])
        n = np.where(veil, nv, n)
    ridge = None
    if par["fibres"] > 0:
        p, cells = cyl(a2, r2, z2, par["fibre_lu"], par["fibre_lv"], par["fibre_lw"], par, off=5.5)
        ridge = np.exp(-(perlin(p, cells, par["seed"] * 13 + 4242) / par["fibre_width"]) ** 2)
    return n, ridge


def contrast(nz, veil, par):
    """z-scored noise to density: a threshold and power, or an exponential."""
    thr = np.where(veil, par["vthr"], par["threshold"])
    gam = np.where(veil, par["vgamma"], par["gamma"])
    if par["curve"] == "exp":
        return np.exp(par["expk"] * nz)
    return np.maximum(nz - thr, 0) ** gam


def weights(par, n, rng, stats):
    r, th, z, veil = sample_envelope(par, n, rng)
    nz, ridge = raw_noise(r, th, z, veil, par)
    w = contrast((nz - np.where(veil, stats["vmean"], stats["mean"])) / np.where(veil, stats["vstd"], stats["std"]),
                 veil, par)
    w = w / np.where(veil, stats["vwmean"], stats["wmean"])
    w = par["veil"] + (1 - par["veil"]) * w
    if par["wobble"] > 0:   # the inner cut's radius wanders with azimuth; sampled at its lowest, trimmed here
        inner = par["inner"] * par["rim"]
        cells = max(int(round(2 * math.pi * inner / par["wobble_len"])), 4)
        p = np.stack([th / (2 * np.pi) * cells, np.full_like(th, 0.5), np.full_like(th, 0.5)], -1).astype(np.float32)
        n = np.clip(perlin(p, cells, par["seed"] * 7 + 3) + 0.5 * perlin(p * 2.0, 2 * cells, par["seed"] * 7 + 4), -1, 1)
        cut = inner + par["wobble"] * n
        up_s = smoothstep(inner - par["wobble"], inner - par["wobble"] + par["rise"], r)
        w = w * smoothstep(cut, cut + par["rise"], r) / np.maximum(up_s, 1e-6)
    if par["tipfade"] > 0:
        d = (np.degrees(th) - par["tip_az"] + 180) % 360 - 180
        outward = 0.3 + 0.7 * smoothstep(0.55 * par["rim"], par["rim"], r)   # the sector thins most at its outer end
        w = w * (1 - par["tipfade"] * np.exp(-0.5 * (d / par["tip_w"]) ** 2) * outward)
    if ridge is not None:
        w = (1 - par["fibres"]) * w + par["fibres"] * ridge / stats["rmean"]
    return r * np.cos(th), r * np.sin(th), z, w.astype(np.float32)


def pilot(par):
    rng = np.random.default_rng(par["seed"] + 5)
    r, th, z, veil = sample_envelope(par, 300_000, rng)
    nz, ridge = raw_noise(r, th, z, veil, par)
    stats = {}
    for name, sel in (("", ~veil), ("v", veil)):
        s = nz[sel] if sel.any() else nz
        mean, std = float(s.mean()), float(max(s.std(), 1e-9))
        v = veil[sel] if sel.any() else veil
        w = contrast((s - mean) / std, v, par)
        stats[name + "mean"], stats[name + "std"] = mean, std
        stats[name + "wmean"] = float(max(w.mean(), 1e-9))
    stats["rmean"] = float(max(ridge.mean(), 1e-9)) if ridge is not None else 1.0
    return stats


# ---------------------------------------------------------------- projection

def project(x, y, z, w, par, width):
    """Column maps (near, far) in units of mass share per kpc^2 times 100, on a width-px frame; with
    share "depth", also (near, far) maps of the column times each grain's share of light behind it."""
    height = round(width * BASE_H / BASE_W)
    kpp = FRAME_KPC / width
    sx = x
    sy = y * math.sin(INC) + z * math.cos(INC)
    ux = sx * math.cos(ROLL) + sy * math.sin(ROLL)
    uy = -sx * math.sin(ROLL) + sy * math.cos(ROLL)
    fx = CORE[0] * width + ux / kpp
    fy = CORE[1] * width - uy / kpp
    maps = []
    for sel in (y < 0, y >= 0):
        maps.append(splat(fx[sel], fy[sel], w[sel], width, height, par["splat"]))
    if par["share"] == "depth":
        b = light_model.share(light_params(par), x, y, z)
        for sel in (y < 0, y >= 0):
            maps.append(splat(fx[sel], fy[sel], w[sel] * b[sel], width, height, par["splat"]))
    elif par["share"] != "split":
        raise SystemExit(f"share is split or depth, not {par['share']}")
    return maps


_LIGHT = {}


def light_params(par):
    path = par["light_model"] or light_model.DEFAULT
    if path not in _LIGHT:
        _LIGHT[path] = light_model.load(path)
    return _LIGHT[path]


def splat(fx, fy, w, width, height, bilinear=1):
    """Drops weights on a width x height grid; bilinear spreads a grain over its four nearest pixels."""
    if not bilinear:
        corners = [(np.rint(fx), np.rint(fy), w)]
    else:
        x0, y0 = np.floor(fx), np.floor(fy)
        tx, ty = fx - x0, fy - y0
        corners = [(x0 + i, y0 + j, w * (tx if i else 1 - tx) * (ty if j else 1 - ty))
                   for i in (0, 1) for j in (0, 1)]
    m = np.zeros(width * height)
    for cx, cy, cw in corners:
        px, py = cx.astype(np.int64), cy.astype(np.int64)
        ok = (px >= 0) & (px < width) & (py >= 0) & (py < height)
        m += np.bincount(py[ok] * width + px[ok], weights=cw[ok], minlength=width * height)
    return m.reshape(height, width).astype(np.float32)


FACE_KPC, FACE_PX = 20.0, 1000


def face_hist(x, y, w):
    return splat((x / FACE_KPC + 0.5) * FACE_PX, (0.5 - y / FACE_KPC) * FACE_PX, w, FACE_PX, FACE_PX)


def _chunk(args):
    par, n, seed, stats, width = args
    x, y, z, w = weights(par, n, np.random.default_rng(seed), stats)
    return project(x, y, z, w, par, width), float(w.sum()), face_hist(x, y, w)


def procedural_columns(par, width, pool=None):
    """Column maps [near, far] (and with share "depth" [near, far, near times share, far times share]),
    total weight, top view."""
    stats = pilot(par)
    if par["share"] == "depth":
        light_model.load_table(light_params(par))   # built once here, read by every worker
    parts = max(4, -(-par["n"] // 3_000_000))   # chunks of at most 3 M grains: bounded memory at any n
    jobs = [(par, par["n"] // parts, par["seed"] * 1000 + i, stats, width) for i in range(parts)]
    res = list(pool.map(_chunk, jobs)) if pool else [_chunk(j) for j in jobs]
    maps = [sum(r[0][k] for r in res) for k in range(len(res[0][0]))]
    return maps, sum(r[1] for r in res), sum(r[2] for r in res)


def grain_columns(path, par, width):
    a = np.fromfile(path, dtype=np.float32).reshape(-1, 7)
    x, y, z, lum, vx, vy, vz = a.T
    if par["myr"] > 0:
        r = np.hypot(x, y)
        ph = np.arctan2(y, x) + np.sign(x * vy - y * vx) * np.hypot(vx, vy) / np.maximum(r, 1e-6) * par["myr"] / 4.71
        x, y = r * np.cos(ph), r * np.sin(ph)
    return project(x, y, z, lum.astype(np.float32), par, width), float(lum.sum()), None


def to_column(m, total, par, width):
    kpp = FRAME_KPC / width
    m = gaussian_filter(m, par["blur"] * width / BASE_W)
    return m / total / kpp ** 2 * 100.0 * par["mass"]


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


fetch_asset = hubble_ref.fetch_asset


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


def clean_light(light, threshold=7.0, peak=16.0, keep_upper=0.45):
    """Replaces the blue knots of young stars (blue excess over a median background) by that background.
    A blue patch is a knot only if it is compact (not three times wider than tall) and its excess
    peaks above `peak`; and knots higher than `keep_upper` kpc above the plane's line (the lane's upper
    edge) stay, as does the faint, wide blue there."""
    h, w = light.shape[:2]
    f = light.astype(np.float32)
    exc = f[..., 2] - 0.5 * (f[..., 0] + f[..., 1])
    q = 4 * max(w // BASE_W, 1) if w >= BASE_W else 2
    small = np.stack([f[::q, ::q, c] for c in range(3)], -1)
    es = exc[::q, ::q]
    size = 21 if w >= BASE_W else 11
    bg_e = median_filter(es, size=size, mode="nearest")
    bg = np.stack([median_filter(small[..., c], size=size, mode="nearest") for c in range(3)], -1)
    up = lambda a: zoom(a, (h / a.shape[0], w / a.shape[1]) + (1,) * (a.ndim - 2), order=1)[:h, :w]
    bg_e, bg = up(bg_e), up(bg)
    pad = lambda a: np.pad(a, ((0, h - a.shape[0]), (0, w - a.shape[1])) + ((0, 0),) * (a.ndim - 2), mode="edge")
    bg_e, bg = pad(bg_e), pad(bg)
    diff = exc - bg_e
    lab, count = label(diff > threshold)
    mask = np.zeros(diff.shape, bool)
    for i, sl in enumerate(find_objects(lab), 1):
        part = lab[sl] == i
        tall, wide = sl[0].stop - sl[0].start, sl[1].stop - sl[1].start
        cy, cx = (sl[0].start + sl[0].stop) / 2, (sl[1].start + sl[1].stop) / 2
        kpp = FRAME_KPC / w
        ux, uy = (cx - CORE[0] * w) * kpp, -(cy - CORE[1] * w) * kpp
        height = ux * math.sin(ROLL) + uy * math.cos(ROLL)
        if diff[sl][part].max() >= peak and wide < 3 * tall and height < keep_upper:
            mask[sl] |= part
    mask = binary_dilation(mask, iterations=max(3, w // 400))
    m = np.clip(gaussian_filter(mask.astype(np.float32), max(1.5, w / 1000)) * 1.6, 0, 1)[..., None]
    out = f * (1 - m) + bg * m
    return np.clip(out + 0.5, 0, 255).astype(np.uint8)


def transmission(col, par):
    tau = par["k"] * col[..., None]
    a = 1 + par["redden"] / (1 + par["grey"] * tau) * CHANNELS   # grey 0: one reddening everywhere
    return np.exp(-tau * a)


def attenuate(light, near, far, par, shares=None):
    """The light dimmed by the near and far columns. `shares` (near, far): each pixel's share of light
    behind its near and far dust (share "depth"); None takes `behind` and `behind_far`."""
    g = par["gamma_light"]
    lin = (light.astype(np.float32) / 255) ** g
    if shares is None and par["stretch"] <= 0:   # as the bench always did
        for col, b in ((near, par["behind"]), (far, par["behind_far"])):
            lin = lin * ((1 - b) + b * transmission(col, par))
        return (np.clip(lin, 0, 1) ** (1 / g) * 255 + 0.5).astype(np.uint8)
    bn, bf = shares if shares is not None else (par["behind"], par["behind_far"])
    bn, bf = np.asarray(bn, np.float32)[..., None], np.asarray(bf, np.float32)[..., None]
    tn, tf = transmission(near, par), transmission(far, par)
    # light behind both layers, between them, in front of both (the far dust lies behind the near)
    t = bf * tn * tf + (bn - bf) * tn + (1 - bn)
    if par["stretch"] > 0:
        energy = light_model.to_energy(lin, par["stretch"], par["white"])
        lin = light_model.from_energy(energy * t, par["stretch"], par["white"])
    else:
        lin = lin * t
    return (np.clip(lin, 0, 1) ** (1 / g) * 255 + 0.5).astype(np.uint8)


def mean_share(weighted, col):
    """A pixel's share of light behind its dust: the column-weighted mean of its grains' shares."""
    return np.where(col > 1e-9, weighted / np.maximum(col, 1e-9), 0.0)


def render(par, light, grains=None, width=BASE_W, pool=None):
    if grains:
        maps, total, face = grain_columns(grains, par, width)
    else:
        maps, total, face = procedural_columns(par, width, pool)
    maps = [to_column(m, total, par, width) for m in maps]
    near, far = maps[:2]
    shares = (mean_share(maps[2], near), mean_share(maps[3], far)) if len(maps) == 4 else None
    im = Image.fromarray(attenuate(light, near, far, par, shares))
    im.shares = shares
    im.columns = (near, far)
    im.face = face
    im.face_column = (face / total / (FACE_KPC / FACE_PX) ** 2 * 100.0 * par["mass"]) if face is not None else None
    return im


# ---------------------------------------------------------------- sheet

def font(size):
    for f in ("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", "/usr/share/fonts/dejavu/DejaVuSans.ttf"):
        if os.path.exists(f):
            return ImageFont.truetype(f, size)
    return ImageFont.load_default()


# Boxes of the frame laid flat, shares of its width: the lane's band, its left end, the core
BOXES = [(0.09, 0.243, 0.90, 0.373), (0.09, 0.260, 0.30, 0.355), (0.40, 0.237, 0.60, 0.355)]


def panel(src, box, width):
    """`box` laid flat (closeup.py's roll about Hubble's core), `width` px across: from the source's
    own pixels, so Hubble comes from the full frame and is never an enlarged copy."""
    im = hubble_ref.flat_region(src, box, width / (box[2] - box[0]))
    h = round(width * (box[3] - box[1]) / (box[2] - box[0]))
    return im if im.size == (width, h) else im.resize((width, h), Image.LANCZOS)


def figures_line(fig):
    return "   ".join(f"{label} {fig[key]:.{3 if key == 'far depth' else 2}f}" for key, label in KEYS
                      if fig.get(key) is not None)


def row(label, im, fig, full_w, wide=True):
    """One row: band, then lane's left end and core, same scale for every row. `im` is a picture of
    Hubble's framing or a hubble_ref source (Hubble's full frame)."""
    src = im if hasattr(im, "region") else hubble_ref.Source(im)
    tw = full_w // 2
    th = round(tw * (BOXES[1][3] - BOXES[1][1]) / (BOXES[1][2] - BOXES[1][0]))
    b = panel(src, BOXES[0], full_w)
    f = font(30)
    out = Image.new("RGB", (full_w, 44 + b.height + (th if wide else 0)), "black")
    d = ImageDraw.Draw(out)
    d.text((10, 5), label + (("    " + figures_line(fig)) if fig else ""), font=f, fill="white")
    out.paste(b, (0, 44))
    if wide:
        for k, box in enumerate(BOXES[1:]):
            out.paste(panel(src, box, tw).resize((tw, th), Image.LANCZOS), (k * tw, 44 + b.height))
    return out


def make_sheet(path, items, hubble_fig, full_w=2400, wide=True, hub=None):
    hub = hub or hubble_ref.load()
    rows = [row("Hubble", hub, hubble_fig, full_w, wide)]
    rows += [row(label, im, fig, full_w, wide) for label, im, fig in items]
    sheet = Image.new("RGB", (full_w, sum(r.height for r in rows)), "black")
    y = 0
    for r in rows:
        sheet.paste(r, (0, y))
        y += r.height
    sheet.save(path, quality=90)
    return sheet


def face_linear(column, k, label=""):
    """Faithful top view: optical depth k N laid out linearly, 0 (pale ground) to 1 (full dust), nothing stretched."""
    t = np.clip(gaussian_filter(column, 1.2) * k, 0, 1)
    ground, dust = np.array([236, 230, 220.0]), np.array([58, 36, 22.0])
    im = Image.fromarray((ground + (dust - ground) * t[..., None]).astype(np.uint8))
    d = ImageDraw.Draw(im)
    d.text((10, 6), label, font=font(26), fill=(20, 20, 20))
    d.text((10, FACE_PX - 32), "vue de dessus, 20 kpc, profondeur optique lineaire 0-1", font=font(22), fill=(60, 60, 60))
    return im


def face_image(hist, label=""):
    """The ring seen from above: dust dark on a pale ground, scaled to its own 99.5th percentile."""
    h = gaussian_filter(hist, 1.2)
    t = np.clip(h / max(np.percentile(h[h > 0], 99.5), 1e-9), 0, 1) ** 0.6
    ground, dust = np.array([236, 230, 220.0]), np.array([58, 36, 22.0])
    im = Image.fromarray((ground + (dust - ground) * t[..., None]).astype(np.uint8))
    d = ImageDraw.Draw(im)
    d.text((10, 6), label, font=font(26), fill=(20, 20, 20))
    d.text((10, FACE_PX - 32), "vue de dessus, 20 kpc", font=font(22), fill=(60, 60, 60))
    return im


# ---------------------------------------------------------------- main

def parse_value(v):
    try:
        return float(v) if any(c in v for c in ".e") else int(v)
    except ValueError:
        return v


def figures(im):
    """measure.py's figures, and the far lane's (measure.halves, over |x| 1 to 4.5 kpc, at the frame's width)."""
    out = measure.measure(im, FRAME_KPC)
    out.update(measure.far_summary(measure.halves(hubble_ref.Source(im)), 0.0))
    return out


def hubble_figures(hub):
    out = measure.measure(hub.frame(measure.WIDTH), FRAME_KPC, width=measure.WIDTH)
    out.update(measure.far_summary(measure.halves(hub, measure.WIDTH)))
    return out


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("args", nargs="*", help="params.json and key=value (a comma list makes a grid)")
    p.add_argument("--grains")
    p.add_argument("--light")
    p.add_argument("--clean-light", dest="clean", choices=["on", "off", "auto"], default="auto",
                   help="remove the blue knots of the light (auto: on for procedural dust)")
    p.add_argument("--width", type=int)
    p.add_argument("--out")
    p.add_argument("--sheet")
    p.add_argument("--face", help="JPG of the ring seen from above (20 kpc across), procedural dust only")
    p.add_argument("--face-linear", help="JPG of the top view in optical depth, linear, no stretch")
    p.add_argument("--ref", action="append", default=[])
    p.add_argument("--hubble", help="Hubble's full frame (default $SOMBRERO_HUBBLE, the local copy, "
                                    "then the lane strip of assets/478-sombrero)")
    p.add_argument("--label", default=None)
    p.add_argument("--table", action="store_true", help="print the calibration figures")
    g = p.parse_args()

    par = dict(DEFAULTS)
    jlabel = None
    sweep = {}
    for a in g.args:
        if "=" not in a:
            data = json.load(open(a))
            jlabel = data.pop("label", None)
            par.update(data)
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
    if g.clean == "on" or (g.clean == "auto" and not g.grains):
        light = clean_light(light)
        light_name += ", knots removed"
    print("light:", light_name, file=sys.stderr)

    variants = []
    for v in values:
        q = dict(par)
        q.update(dict(zip(names, v)))
        label = g.label or jlabel or ("grains" if g.grains else "banc")
        variants.append((label + ("  " + " ".join(f"{k}={x}" for k, x in zip(names, v)) if names else ""), q))

    pool = ProcessPoolExecutor(4) if not g.grains else None
    items = []
    for label, q in variants:
        im = render(q, light, g.grains, width, pool)
        if len(variants) == 1 and g.out:
            im.save(g.out)
        if len(variants) == 1 and g.face and im.face is not None:
            face_image(im.face, label).save(g.face, quality=92)
        if len(variants) == 1 and g.face_linear and im.face_column is not None:
            face_linear(im.face_column, q["k"], label).save(g.face_linear, quality=92)
        items.append((label, im, figures(im)))
    for r in g.ref:
        label, path = r.split("=", 1)
        im = Image.open(path).convert("RGB")
        items.append((label, im, figures(im)))
    hub = hubble_ref.load(g.hubble)
    hub_fig = hubble_figures(hub)

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
        make_sheet(g.sheet, items, hub_fig, 2400 if wide else 2000, wide, hub)
        print("sheet", g.sheet)


if __name__ == "__main__":
    main()
