#!/usr/bin/env python3
"""dust_track_a.py [params.json] [key=value ...] [options]: the Sombrero's dust ring built from parts (#489).

Track A of #485. The ring is a sum of components, each a 3D density in ring coordinates (radius,
azimuth, height) with its own grains and its own job:

  rim     a dense, thin inner rim: grains from a scalloped cut outward over `rim_tail` kpc, clumped by a
          lognormal noise (the grey-blue top band)
  veil    an even layer from the inner cut out to the rim, decaying over `veil_taper` (rising if negative)
  spk     speckle: many small elements (clouds 20 to 100 pc) with lognormal masses, in a thin layer
  fil     filaments: sparse long elements, polylines that wander in pitch and height
  web     cell walls: grains on the walls of a cellular noise of the plane (bubbles)
  str     strata: `str_mode` ringlets (long, tightly wound arcs at their own radii) or sheets (every
          element sits in one of `str_k` layers `str_dz` kpc apart)
  orb     the elements' masses (and every part's height) times exp(orb n), n a band-limited periodic noise
          of the azimuth read along trailing spirals (`orb_wind`): dense and clear stretches, different on
          each side, never a radial spoke from above
  shape   the outer part rising in height (`z_out`), an oval ring (`oval`) or an outer part denser towards
          the tips (`m2`)

Elements (spk, fil, str ringlets) come from a catalogue drawn from the seed: start radius, azimuth
and height, pitch, length, widths and a mass. With `strat=1` each element gets its expected count of
grains, placed by a shifted low-discrepancy set, so the frame converges at 24 M grains instead of
carrying sand (random draws flatter the score at 24 M: it falls from 2.0 to 3.1 as n goes to 96 M).
The grains are projected and laid on the light by dust_bench.py (imported, not changed):
`share=depth centre=nucleus blur=0.15` by default; `law=hubble` reads the inner cut as inner x rim,
which follows r_in / rim here.

  dust_track_a.py a.json --out frame.png --score s.json --top top.jpg
  dust_track_a.py a.json --sweep variants.jsonl --csv trials.csv --family veil   # one trial a line
"""
import argparse
import csv
import json
import math
import os
import sys
import time
from concurrent.futures import ProcessPoolExecutor

import numpy as np
from PIL import Image
from scipy.special import ndtri
from scipy.stats import qmc

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import dust_bench as d  # noqa: E402
import light_model  # noqa: E402

A_DEFAULTS = dict(
    label="", seed=1, n=24_000_000,
    # the ring about the nucleus (kpc): inner cut, rim, the ring's centre moved off_y towards us (near side y < 0)
    r_in=5.7, rim=8.8, off_y=-0.2, fade=0.8, h_flare=1.0, h_scale=1.0,
    # outer heights: the parts' centres spread z_out kpc in height at the rim (growing as the square of the
    # way out); the mid-plane bends by warp kpc at the rim, most at azimuth warp_az (degrees)
    z_out=0.0, warp=0.0, warp_az=180.0,
    # the ring's shape: x stretched by 1 + oval/2 and y by 1 - oval/2 (an oval along the major axis); the outer
    # part's mass times 1 + m2 outward(r) cos(2 azimuth) (denser at the tips for m2 > 0)
    oval=0.0, m2=0.0,
    # along the orbit: mass times exp(orb n), n of wavelengths orb_len to orb_max kpc at 7 kpc (0: the whole
    # orbit); height times exp(orb_h n2)
    orb=0.5, orb_len=2.0, orb_max=0.0, orb_wind=0.0, orb_h=0.3, tip_wide=0.0, tip_w=25.0,
    # grains per part: a share of n (relative); mass: a share of the dust (relative)
    m_rim=1.0, g_rim=1.0, m_veil=1.0, g_veil=1.0, m_spk=1.0, g_spk=1.0, m_fil=0.0, g_fil=0.5, m_str=0.0, g_str=0.5,
    m_web=0.0, g_web=1.0,
    beta=0.5, importance=0, qmc_fields=1,
    # strat 1: each element's grains on a shifted low-discrepancy set (no sand); 0: drawn at random (trials s01-s19)
    strat=0,
    # rim: cut scalloped by rim_scal kpc in lumps rim_scal_len kpc; grains over rim_tail kpc outward; height rim_h;
    # clumped by exp(rim_s z), z an fBm of rim_lu x rim_lv x rim_lw kpc, rim_oct octaves
    rim_tail=0.35, rim_h=0.015, rim_scal=0.15, rim_scal_len=0.2, rim_s=1.0, rim_lu=0.4, rim_lv=0.15, rim_lw=0.03,
    rim_oct=4,
    # veil: decays over veil_taper kpc outward, height veil_h, contrast exp(veil_s z)
    veil_taper=1.5, veil_h=0.03, veil_s=0.4, veil_lu=1.0, veil_lv=0.4, veil_lw=0.1, veil_oct=3,
    # veil_soft > 0: a threshold instead, dust where z > veil_thr (a smooth step veil_soft wide) over a floor veil_floor
    veil_soft=0.0, veil_thr=0.0, veil_floor=0.1,
    # speckle: spk_n elements, centres decaying over spk_taper kpc; length spk_len (twice the sd along, lognormal spk_lsig), radial
    # width spk_wid, height spk_h, centres' height spread spk_zs; masses lognormal spk_sig; pitch spk_pitch (rad)
    # in spk_fam families (1: one sign, 2: both), spread spk_pspread; tilt in height spk_tilt; spk_cl clusters
    # the centres on a coarse field of spk_clen kpc
    spk_n=60000, spk_taper=2.0, spk_len=0.08, spk_lsig=0.5, spk_wid=0.02, spk_h=0.012, spk_zs=0.02, spk_sig=1.2,
    spk_pitch=0.0, spk_fam=2, spk_pspread=0.4, spk_tilt=0.0, spk_cl=0.0, spk_clen=0.6,
    # filaments: the same, polylines of fil_k nodes whose pitch wanders by fil_curl (rad over the length) and
    # height by fil_zwalk (kpc); beads along them exp(fil_bead n)
    fil_n=6000, fil_taper=2.0, fil_len=0.6, fil_lsig=0.5, fil_wid=0.02, fil_h=0.006, fil_zs=0.02, fil_sig=1.0,
    fil_pitch=0.15, fil_fam=2, fil_pspread=0.15, fil_curl=0.4, fil_zwalk=0.01, fil_bead=0.8, fil_k=8,
    fil_cl=0.0, fil_clen=0.6,
    # strata: "none", "ringlets" (str_n arcs str_len kpc long, pitch str_pitch, width str_w, height str_h, at
    # radii from r_in to rim) or "sheets" (elements in str_k layers str_dz kpc apart, wandering by str_wz)
    str_mode="none", str_n=16, str_len=3.0, str_pitch=0.03, str_w=0.05, str_h=0.008, str_sig=0.6, str_bead=0.8,
    str_k=3, str_dz=0.025, str_wz=0.01,
    # web: the walls of cells (cellular noise) in the plane, cells web_u kpc along the orbit and web_r kpc across,
    # the lattice sheared by web_shear (cells tilted in pitch), walls web_w of a cell thick, each wall's mass
    # lognormal web_sig, height web_h; radii decay over web_taper; web_fill: share of each cell's mass kept
    # inside it (a blob) rather than on its walls; web_oct 2 adds a second lattice web_lac times finer
    web_u=0.4, web_r=0.25, web_shear=0.0, web_w=0.08, web_sig=0.8, web_h=0.006, web_taper=-4.0, web_fill=0.0,
    web_oct=1, web_lac=2.5, web_gain=0.5,
    # this wave's bench settings
    share="depth", centre="nucleus", blur=0.15, mass=1.0,
)
PARTS = ["rim", "veil", "spk", "fil", "str", "web"]
FIGS = ["spectrum along", "spectrum across", "histogram", "phase", "skewness", "intermittency", "shape",
        "filaments", "multiscale", "minkowski", "blobs", "anisotropy", "strata", "edges", "profile",
        "stationarity", "symmetry", "colour"]


def params(*sources):
    """The bench's defaults, this track's, then each source. The bench's `inner` (read only by law=hubble, for
    the inner cut) follows r_in / rim unless a source sets it."""
    par = dict(d.DEFAULTS)
    par.update(A_DEFAULTS)
    inner = None
    for s in sources:
        for k, v in s.items():
            if k.startswith("_"):   # notes, such as the command that renders a finalist
                continue
            if k not in par:
                raise SystemExit(f"unknown parameter {k}")
            par[k] = v
            inner = v if k == "inner" else inner
    par["inner"] = inner if inner is not None else par["r_in"] / par["rim"]
    return par


# ---------------------------------------------------------------- slow fields

def orbit_noise(theta, seed, wavelength, r=7.0, longest=None):
    """A periodic noise of the azimuth, unit variance, wavelengths from `wavelength` to `longest` kpc at radius r."""
    kmax = max(1, int(2 * math.pi * r / max(wavelength, 1e-3)))
    kmin = 1 if not longest else min(max(1, int(round(2 * math.pi * r / longest))), kmax)
    rng = np.random.default_rng(seed)
    k = np.arange(kmin, kmax + 1)
    amp = k ** -0.5
    amp = amp / math.sqrt((amp ** 2).sum() / 2)
    ph = rng.uniform(0, 2 * math.pi, len(k))
    out = np.zeros_like(theta, dtype=np.float32)
    for a, kk, p in zip(amp, k, ph):
        out += (a * np.cos(kk * theta + p)).astype(np.float32)
    return out


def wound(theta, r, par):
    """The azimuth read along trailing spirals: a stretch of the orbit modulation is tilted by
    atan(1 / orb_wind) from the orbit, so it is not a radial spoke seen from above."""
    return theta if r is None or not par["orb_wind"] else theta + par["orb_wind"] * np.log(np.maximum(r, 0.5) / 7.0)


def orbit_mass(theta, par, r=None):
    theta = wound(theta, r, par)
    return np.exp(par["orb"] * orbit_noise(theta, par["seed"] * 101 + 1, par["orb_len"], longest=par["orb_max"]) - 0.5 * par["orb"] ** 2)


def orbit_height(theta, par, r=None):
    h = np.exp(par["orb_h"] * orbit_noise(wound(theta, r, par), par["seed"] * 101 + 2, par["orb_len"], longest=par["orb_max"])) \
        if par["orb_h"] else np.ones_like(theta)
    if par["tip_wide"]:   # the left tip (azimuth pi) broad and fanned
        dd = (np.degrees(theta) - 180 + 180) % 360 - 180
        h = h * (1 + par["tip_wide"] * np.exp(-0.5 * (dd / par["tip_w"]) ** 2))
    return h


def flare(r, par):
    """Every part's height grows outward by h_flare (times h_scale)."""
    t = np.clip((r - par["r_in"]) / (par["rim"] - par["r_in"]), 0, 1)
    return (1 + par["h_flare"] * t) * par["h_scale"]


def outward(r, par):
    return np.clip((r - par["r_in"]) / (par["rim"] - par["r_in"]), 0, 1) ** 2


def mid_plane(r, theta, par):
    if par["warp"] == 0:
        return 0.0
    return par["warp"] * outward(r, par) * np.cos(theta - math.radians(par["warp_az"]))


def fbm(theta, r, z, par, seed, lu, lv, lw, octs):
    q = dict(par, octaves=octs, lacunarity=2.0, gain=0.55)
    return d.octaves(theta, r, z, q, seed, lu, lv, lw, "fbm")


def outer_fade(r, par):
    return 1 - d.smoothstep(par["rim"] - par["fade"], par["rim"], r)


def cut(theta, par):
    """The inner cut's radius, scalloped along the azimuth."""
    if par["rim_scal"] <= 0:
        return np.full_like(theta, par["r_in"])
    cells = max(int(round(2 * math.pi * par["r_in"] / par["rim_scal_len"])), 4)
    p = np.stack([theta / (2 * np.pi) * cells, np.full_like(theta, 0.5), np.full_like(theta, 0.5)], -1).astype(np.float32)
    n = d.perlin(p, cells, par["seed"] * 7 + 3) + 0.5 * d.perlin(p * 2.0, 2 * cells, par["seed"] * 7 + 4)
    return par["r_in"] + par["rim_scal"] * np.clip(n, -1, 1)


def radial_draw(u, par, taper, lo=None):
    """Radii from lo (default r_in) to the rim, surface density exp(-(r - lo) / taper) times the outer fade."""
    lo = par["r_in"] if lo is None else lo
    grid = np.linspace(lo, par["rim"], 2000)
    taper = taper if abs(taper) > 1e-3 else 1e-3   # a negative taper rises outward
    pdf = np.exp(-(grid - lo) / taper) * outer_fade(grid, par) * grid
    cdf = np.cumsum(pdf)
    cdf /= cdf[-1]
    return np.interp(u, cdf, grid)


# ---------------------------------------------------------------- field parts

def rim_part(u, par):
    th = u[:, 0] * 2 * np.pi
    c = cut(th, par)
    r = c + par["rim_tail"] * -np.log(np.clip(1 - u[:, 1], 1e-7, 1))
    r = np.minimum(r, par["rim"])
    h = par["rim_h"] * par["h_scale"] * orbit_height(th, par, r)
    z = ndtri(np.clip(u[:, 2], 1e-7, 1 - 1e-7)) * h
    n = fbm(th, r, z, par, par["seed"] * 13 + 11, par["rim_lu"], par["rim_lv"], par["rim_lw"], par["rim_oct"])
    w = np.exp(par["rim_s"] * n / max(float(n.std()), 1e-6))
    return r, th, z, w


def veil_part(u, par):
    th = u[:, 0] * 2 * np.pi
    r = radial_draw(u[:, 1], par, par["veil_taper"]) + (cut(th, par) - par["r_in"])
    h = par["veil_h"] * flare(r, par) * orbit_height(th, par, r)
    h = np.sqrt(h ** 2 + (par["z_out"] * outward(r, par)) ** 2)
    z = ndtri(np.clip(u[:, 2], 1e-7, 1 - 1e-7)) * h + mid_plane(r, th, par)
    n = fbm(th, r, z, par, par["seed"] * 13 + 21, par["veil_lu"], par["veil_lv"], par["veil_lw"], par["veil_oct"])
    n = n / max(float(n.std()), 1e-6)
    if par["veil_soft"] > 0:
        w = par["veil_floor"] + 1 / (1 + np.exp(-(n - par["veil_thr"]) / par["veil_soft"]))
    else:
        w = np.exp(par["veil_s"] * n)
    return r, th, z, w


# ---------------------------------------------------------------- elements

_CAT = {}


def catalogue(par, kind):
    """Elements of a part: nodes (N, K, 3) of radius, azimuth, height; masses (N,); widths (N,) radial and
    in height; bead seeds. Drawn from the seed alone, so every worker builds the same."""
    key = (kind, json.dumps({k: v for k, v in par.items() if not k.startswith("_")}, sort_keys=True, default=str))
    if key in _CAT:
        return _CAT[key]
    seed = par["seed"] * 1009 + {"spk": 1, "fil": 2, "str": 3}[kind]
    rng = np.random.default_rng(seed)
    if kind == "str":
        n, k = int(par["str_n"]), 24
        length = np.full(n, par["str_len"]) * np.exp(0.3 * rng.standard_normal(n))
        r0 = par["r_in"] + (par["rim"] - par["r_in"]) * rng.random(n) ** 1.3
        th0 = rng.uniform(0, 2 * np.pi, n)
        z0 = 0.3 * par["str_h"] * rng.standard_normal(n)
        pitch = par["str_pitch"] * (1 + 0.3 * rng.standard_normal(n))
        curl, zwalk, tilt = 0.02, 0.0, 0.0
        mass = np.exp(par["str_sig"] * rng.standard_normal(n))
        wid, hgt = np.full(n, par["str_w"]), np.full(n, par["str_h"] * par["h_scale"])
    else:
        p = lambda name: par[f"{kind}_{name}"]
        n = int(p("n"))
        k = 2 if kind == "spk" else int(p("k"))
        m = n * 4 if p("cl") > 0 else n
        r0 = radial_draw(rng.random(m), par, p("taper"), lo=par["r_in"] - 0.1)
        th0 = rng.uniform(0, 2 * np.pi, m)
        if p("cl") > 0:   # clustered placement: keep candidates in proportion to exp(cl * coarse field)
            f = fbm(th0, r0, np.zeros_like(r0), par, seed + 77, p("clen"), p("clen") * 0.5, 1.0, 3)
            wgt = np.exp(p("cl") * f / max(float(f.std()), 1e-6))
            keep = rng.choice(m, n, replace=False, p=wgt / wgt.sum())
            r0, th0 = r0[keep], th0[keep]
        r0 = r0 + (cut(th0, par) - par["r_in"])
        hz = flare(r0, par) * orbit_height(th0, par, r0)
        zs = np.sqrt((p("zs") * hz) ** 2 + (par["z_out"] * outward(r0, par)) ** 2)
        z0 = zs * rng.standard_normal(n) + mid_plane(r0, th0, par)
        length = p("len") * np.exp(p("lsig") * rng.standard_normal(n) - 0.5 * p("lsig") ** 2)
        sign = np.where(rng.random(n) < 0.5, -1.0, 1.0) if p("fam") == 2 else 1.0
        pitch = sign * p("pitch") + p("pspread") * rng.standard_normal(n)
        curl = par["fil_curl"] if kind == "fil" else 0.0
        zwalk = par["fil_zwalk"] if kind == "fil" else 0.0
        mass = np.exp(p("sig") * rng.standard_normal(n))
        wid, hgt = np.full(n, p("wid")), p("h") * hz
        tilt = par["spk_tilt"] * rng.standard_normal(n) if kind == "spk" else 0.0
    mass = mass * orbit_mass(th0, par, r0)
    if par["str_mode"] == "sheets" and kind != "str":
        layer = rng.integers(0, int(par["str_k"]), n)
        wz = np.zeros(n, np.float32)
        for q in range(int(par["str_k"])):
            sel = layer == q
            wz[sel] = orbit_noise(th0[sel], par["seed"] * 101 + 7 + q, 1.5)
        mid = mid_plane(r0, th0, par)
        z0 = (z0 - mid) * 0.3 + mid + (layer - (par["str_k"] - 1) / 2) * par["str_dz"] * flare(r0, par) + par["str_wz"] * wz
    nodes = np.empty((n, k, 3), np.float32)
    r, th, z, ps = r0.copy(), th0.copy(), z0.copy(), pitch.copy()
    ds = length / (k - 1)
    for j in range(k):
        nodes[:, j] = np.stack([r, th, z], -1)
        if j == k - 1:
            break
        r = r + ds * np.sin(ps)
        th = th + ds * np.cos(ps) / np.maximum(r, 1.0)
        z = z + ds * tilt + zwalk * math.sqrt(1 / (k - 1)) * rng.standard_normal(n)
        ps = ps + curl * math.sqrt(1 / (k - 1)) * rng.standard_normal(n)
    # centre each element on its start point (the polyline runs both ways from it)
    mid = nodes[:, (k - 1) // 2: (k - 1) // 2 + 1] if k > 2 else 0.5 * (nodes[:, :1] + nodes[:, 1:2])
    nodes[:, :, 0] += (nodes[:, :1, 0] - mid[..., 0])
    nodes[:, :, 1] += (nodes[:, :1, 1] - mid[..., 1])
    nodes[:, :, 2] += (nodes[:, :1, 2] - mid[..., 2])
    keep = (nodes[:, :, 0].max(1) < par["rim"] + 0.05)
    nodes, mass, wid, hgt = nodes[keep], mass[keep], wid[keep], hgt[keep]
    out = dict(nodes=nodes, mass=mass.astype(np.float64), wid=wid.astype(np.float32), hgt=hgt.astype(np.float32))
    _CAT[key] = out
    return out


# ---------------------------------------------------------------- web (cell walls)

def _h32(i, j, seed):
    h = (i.astype(np.int64) * 73856093 ^ j.astype(np.int64) * 19349663 ^ (seed * 83492791)) & 0xFFFFFFFF
    h = h.astype(np.uint64)
    h = (h ^ (h >> np.uint64(16))) * np.uint64(0x45D9F3B) & np.uint64(0xFFFFFFFF)
    h = (h ^ (h >> np.uint64(16))) * np.uint64(0x45D9F3B) & np.uint64(0xFFFFFFFF)
    return (h ^ (h >> np.uint64(16))).astype(np.float64) / 4294967296.0


def cells(theta, r, par, lu, lr, seed):
    """Cellular noise of the plane: distance to the nearest and second nearest jittered point of a lattice
    (lu kpc along the orbit at 7 kpc, lr across, sheared by web_shear), in cell units, and the nearest cell's
    and the second's indices (for a wall's own mass)."""
    nu = max(int(round(2 * math.pi * 7.0 / lu)), 8)
    a = theta / (2 * np.pi) * nu
    b = r / lr + par["web_shear"] * a
    ia, ib = np.floor(a), np.floor(b)
    f1 = np.full(a.shape, 9.0)
    f2 = np.full(a.shape, 9.0)
    c1 = np.zeros(a.shape, np.int64)
    c2 = np.zeros(a.shape, np.int64)
    for da in (-1, 0, 1):
        for db in (-1, 0, 1):
            ca = np.mod(ia + da, nu)
            cb = ib + db
            px = ia + da + _h32(ca, cb, seed)
            py = cb + _h32(ca, cb, seed + 1)
            dist = np.hypot(a - px, b - py)
            cid = (ca.astype(np.int64) << 20) + cb.astype(np.int64)
            closer = dist < f1
            f2 = np.where(closer, f1, np.minimum(f2, dist))
            c2 = np.where(closer, c1, np.where(dist < f2, cid, c2))
            f1 = np.where(closer, dist, f1)
            c1 = np.where(closer, cid, c1)
    return f1, f2, c1, c2


def web_part(u, par, seed):
    """Grains on cell walls: candidates drawn from the radial envelope, kept with the wall's profile."""
    th = u[:, 0] * 2 * np.pi
    r = radial_draw(u[:, 1], par, par["web_taper"]) + (cut(th, par) - par["r_in"])
    keep = np.zeros(len(th), bool)
    w = np.zeros(len(th))
    lu, lr, amp = par["web_u"], par["web_r"], 1.0
    rng = np.random.default_rng(seed)
    for o in range(int(par["web_oct"])):
        f1, f2, c1, c2 = cells(th, r, par, lu, lr, par["seed"] * 7919 + 11 * o)
        wall = np.exp(-((f2 - f1) / par["web_w"]) ** 2)
        if par["web_fill"] > 0:
            wall = (1 - par["web_fill"]) * wall + par["web_fill"] * np.exp(-(f1 / 0.35) ** 2)
        pair = np.minimum(c1, c2) * 7 + np.maximum(c1, c2)
        gm = ndtri(np.clip(_h32(pair & 0xFFFFF, pair >> 20, par["seed"] + 31 * o), 1e-6, 1 - 1e-6))
        m = amp * np.exp(par["web_sig"] * gm)
        take = (rng.random(len(th)) < wall) & ~keep
        w = np.where(take, m, w)
        keep |= take
        lu, lr, amp = lu / par["web_lac"], lr / par["web_lac"], amp * par["web_gain"]
    th, r, w = th[keep], r[keep], w[keep]
    h = par["web_h"] * flare(r, par) * orbit_height(th, par, r)
    zs = par["z_out"] * outward(r, par)
    # each patch of wall (about 0.18 kpc along, 0.08 across) at its own height, spread z_out at the rim
    patch = _h32((th * 40).astype(np.int64), (r * 12).astype(np.int64), par["seed"] + 5)
    z = ndtri(np.clip(u[keep, 2], 1e-7, 1 - 1e-7)) * h + zs * 1.7 * (2 * patch - 1) + mid_plane(r, th, par)
    return r, th, z, w * orbit_mass(th, par, r)


def element_part(u, par, kind, i=None, per=None):
    """Grains of a part's elements: u (n, 4) places them; i, the element of each grain (None: drawn from
    u[:, 0] with probability mass^beta); per, each grain's weight before the taper (None: mass^(1 - beta))."""
    cat = catalogue(par, kind)
    nodes, mass = cat["nodes"], cat["mass"]
    beta = par["beta"]
    if i is None:
        pick = mass ** beta
        cdf = np.cumsum(pick)
        cdf /= cdf[-1]
        i = np.minimum(np.searchsorted(cdf, u[:, 0]), len(mass) - 1)
        per = mass[i] ** (1 - beta)
    k = nodes.shape[1]
    if kind == "spk":   # a Gaussian blob along its axis: sd half the length
        s = 0.5 + 0.5 * ndtri(np.clip(u[:, 1], 1e-7, 1 - 1e-7))
        taper = 1.0
    else:
        s = u[:, 1]
        taper = np.sin(np.pi * s) ** 0.5
    f = s * (k - 1)
    j = np.minimum(f.astype(np.int64), k - 2)
    t = (f - j)[:, None]
    p = nodes[i, j] * (1 - t) + nodes[i, j + 1] * t
    r = p[:, 0] + cat["wid"][i] * ndtri(np.clip(u[:, 2], 1e-7, 1 - 1e-7))
    z = p[:, 2] + cat["hgt"][i] * ndtri(np.clip(u[:, 3], 1e-7, 1 - 1e-7))
    th = p[:, 1]
    w = per * taper
    bead = par["fil_bead"] if kind == "fil" else par["str_bead"] if kind == "str" else 0.0
    if bead > 0:   # beads along the element: a 1D noise of its own position along it
        q = np.stack([s * 6 + i * 0.37, (i % 977) * 1.7 + np.zeros_like(s), np.zeros_like(s)], -1).astype(np.float32)
        w = w * np.exp(bead * d.perlin(q, 1 << 20, par["seed"] * 31 + 5))
    ok = (r > 0.5) & (r < par["rim"])
    return r, th, z, w * ok


def strat_elements(par, kind, n, idx, parts, seed):
    """Elements without sand: this chunk takes every parts-th element; element i gets about n parts
    mass_i^beta / sum(mass^beta) grains (dithered), placed by the first points of one scrambled Sobol
    sequence shifted by the element's own random offset (Cranley-Patterson), each weighing mass_i over
    its expected count."""
    cat = catalogue(par, kind)
    mass = cat["mass"]
    pick = mass ** par["beta"]
    expect = n * parts * pick / pick.sum()
    ids = np.arange(idx, len(mass), parts)
    rng = np.random.default_rng(seed)
    counts = np.floor(expect[ids] + rng.random(len(ids))).astype(np.int64)
    ids, counts = ids[counts > 0], counts[counts > 0]
    i = np.repeat(ids, counts)
    start = np.repeat(np.cumsum(counts) - counts, counts)
    j = np.arange(len(i)) - start
    table = qmc.Sobol(4, scramble=True, seed=par["seed"] * 3 + 1).random(int(counts.max()) if len(counts) else 1)
    rot = np.random.default_rng(par["seed"] * 1009 + 55).random((len(mass), 4))
    u = np.mod(table[j] + rot[i], 1.0)
    u[:, 1] = np.clip(u[:, 1], 1e-6, 1 - 1e-6)
    return element_part(u, par, kind, i=i, per=mass[i] / expect[i])


# ---------------------------------------------------------------- grains

def field_grains(part, n, par, seed, q=0.99):
    """n grains of a weighted field, drawn where its weight is: candidates on a scrambled Sobol sequence
    (stratified), kept with probability min(w / c, 1), c the weights' q quantile, and weighted max(w / c, 1).
    Heavy weights on few grains would show as sand and make each chunk's share depend on a handful of grains."""
    rng = np.random.default_rng(seed + 99)
    out, got, c, rate, m, k = [], 0, None, 1.0, n, 0
    while got < n and k < 4:
        u = qmc.Sobol(4, scramble=True, seed=seed + 7 * k).random(int(m))
        r, th, z, w = part(u, par)
        c = float(np.quantile(w, q)) if c is None else c
        keep = rng.random(len(w)) < np.minimum(w / c, 1)
        out.append((r[keep], th[keep], z[keep], np.maximum(w[keep] / c, 1)))
        got += int(keep.sum())
        rate = max(keep.mean(), 0.02)
        m = min((n - got) / rate * 1.05 + 1000, 8 * n)
        k += 1
    return tuple(np.concatenate([o[i] for o in out])[:n] for i in range(4))


def part_grains(name, n, par, seed, idx=0, parts=1):
    if n <= 0:
        return None
    if name in ("rim", "veil"):
        part = rim_part if name == "rim" else veil_part
        if par["importance"]:
            return field_grains(part, n, par, seed)
        if par["qmc_fields"]:
            return part(qmc.Sobol(4, scramble=True, seed=seed).random(n), par)
        return part(np.random.default_rng(seed).random((n, 4)), par)
    else:   # random for elements: a narrow slice of a Sobol sequence lies on lines in the other dimensions
        u = np.random.default_rng(seed).random((n, 4))
    if name == "web":
        return web_part(np.random.default_rng(seed).random((n * 5, 4)), par, seed)
    if name == "str" and par["str_mode"] != "ringlets":
        return None
    if par["strat"]:
        return strat_elements(par, name, n, idx, parts, seed)
    return element_part(u, par, name)


def shares(par):
    mass = {p: par[f"m_{p}"] for p in PARTS}
    if par["str_mode"] != "ringlets":
        mass["str"] = 0.0
    grains = {p: par[f"g_{p}"] if mass[p] > 0 else 0.0 for p in PARTS}
    return mass, grains


def _chunk(args):
    par, idx, parts, width, only = args
    mass, grains = shares(par)
    gsum = sum(grains.values())
    maps, face, total = None, None, 0.0
    for name in PARTS:
        if mass[name] <= 0 or (only and name not in only):
            continue
        n = int(par["n"] * grains[name] / gsum / parts)
        g = part_grains(name, n, par, par["seed"] * 1000 + idx * 17 + PARTS.index(name), idx, parts)
        if g is None:
            continue
        r, th, z, w = g
        if par["m2"]:
            w = w * np.maximum(1 + par["m2"] * outward(r, par) * np.cos(2 * th), 0)
        w = w / max(float(w.sum()), 1e-30) * mass[name] / parts
        total += float(w.sum())
        x = r * np.cos(th) * (1 + par["oval"] / 2)
        y = r * np.sin(th) * (1 - par["oval"] / 2) + par["off_y"]
        m = d.project(x, y, z, w.astype(np.float32), par, width)
        f = d.face_hist(x, y, w)
        maps = m if maps is None else [a + b for a, b in zip(maps, m)]
        face = f if face is None else face + f
    return maps, total, face


def columns(par, width, pool=None, only=None):
    if par["share"] == "depth":
        light_model.load_table(d.light_params(par))
    parts = max(4, -(-par["n"] // 3_000_000))
    jobs = [(par, i, parts, width, only) for i in range(parts)]
    res = list(pool.map(_chunk, jobs)) if pool else [_chunk(j) for j in jobs]
    maps = [sum(r[0][k] for r in res) for k in range(len(res[0][0]))]
    return maps, sum(r[1] for r in res), sum(r[2] for r in res)


def render(par, light, width=d.BASE_W, pool=None, only=None):
    """As dust_bench.render, with this track's grains."""
    light = d.recentre(light, par)
    maps, total, face = columns(par, width, pool, only)
    maps = [d.to_column(m, total, par, width) for m in maps]
    near, far = maps[:2]
    sh = (d.mean_share(maps[2], near), d.mean_share(maps[3], far)) if par["share"] == "depth" else None
    rims = tuple(maps[-2:]) if par["law"] == "hubble" else None
    im = Image.fromarray(d.attenuate(light, near, far, par, sh, rims))
    im.face_column = face / total / (d.FACE_KPC / d.FACE_PX) ** 2 * 100.0 * par["mass"]
    return im


_LIGHT = {}


def light_at(width):
    if width not in _LIGHT:
        light, _ = d.load_light(None, width)
        _LIGHT[width] = d.clean_light(light)
    return _LIGHT[width]


# ---------------------------------------------------------------- trials

def score_frame(im):
    import texture
    r = texture.score(im, 6144)
    fig = d.figures(im)
    return r, fig


def trial_row(tid, family, par, r, fig, seconds, src):
    dist = r["distance"]
    row = {"id": tid, "family": family, "seed": par["seed"], "summary": round(dist["summary"], 3)}
    for k in FIGS:
        row[k] = round(dist.get(k, float("nan")), 2)
    for key, name in (("far offset", "far_h"), ("far width", "far_w"), ("far depth", "far_depth"),
                      ("near lane left", "near_left"), ("near lane width", "near_width")):
        v = fig.get(key)
        row[name] = round(v, 3) if v is not None else ""
    row["seconds"] = round(seconds, 1)
    row["params"] = src
    return row


def append_csv(path, row):
    new = not os.path.exists(path)
    with open(path, "a", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(row))
        if new:
            w.writeheader()
        w.writerow(row)


def run(par, width, pool, out=None, score=None, top=None, crop=None, panel=None):
    t = time.time()
    im = render(par, light_at(width), width, pool)
    secs = time.time() - t
    if out:
        im.save(out)
    if top:
        d.face_linear(im.face_column, par["k"], par.get("label", "")).save(top, quality=92)
    if crop:
        lane_crop(im).save(crop, quality=90)
    r, fig = score_frame(im)
    if panel:
        import texture
        texture.panel(r, par.get("label") or os.path.basename(out or "")).save(panel, quality=90)
    if score:
        import texture
        json.dump(dict(texture.public(r), far_figures={k: v for k, v in fig.items() if k.startswith("far")}),
                  open(score, "w"), indent=1)
    return im, r, fig, secs


def lane_crop(im):
    """The centre of the near lane, its left tip and its right tip (closeup.py's boxes), laid flat, 1200 px wide."""
    import closeup
    import hubble_ref
    src = hubble_ref.Source(im)
    tiles = [d.panel(src, b, 1200) for b in (closeup.BOXES[1], closeup.BOXES[0], closeup.BOXES[2])]
    out = Image.new("RGB", (1200, sum(t.height for t in tiles)), "black")
    y = 0
    for t in tiles:
        out.paste(t, (0, y))
        y += t.height
    return out


def parse_value(v):
    try:
        return float(v) if any(c in v for c in ".e") else int(v)
    except ValueError:
        return v


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("args", nargs="*", help="params.json and key=value")
    p.add_argument("--width", type=int, default=d.BASE_W)
    p.add_argument("--out", help="the frame (PNG)")
    p.add_argument("--score", help="texture.py's result at the 6144 grid, with the far lane's figures (JSON)")
    p.add_argument("--top", help="top view of the grains, optical depth, linear (JPG)")
    p.add_argument("--crop", help="centre and tips of the near lane, laid flat (JPG)")
    p.add_argument("--panel", help="texture.py's panel: the lane's opacity and the bars (JPG)")
    p.add_argument("--sweep", help="JSONL: one trial a line, each a dict of overrides (and an optional id)")
    p.add_argument("--csv", help="append one row a trial")
    p.add_argument("--family", default="")
    p.add_argument("--id", default="")
    p.add_argument("--crops", help="with --sweep: a folder for each trial's lane crop")
    p.add_argument("--scores", help="with --sweep: a folder for each trial's score (JSON)")
    g = p.parse_args()
    base = {}
    for a in g.args:
        if "=" in a:
            k, v = a.split("=", 1)
            base[k] = parse_value(v)
        else:
            base.update(json.load(open(a)))
    pool = ProcessPoolExecutor(4)
    trials = [(g.id or "trial", {})]
    if g.sweep:
        trials = []
        for i, line in enumerate(open(g.sweep)):
            if line.strip():
                o = json.loads(line)
                trials.append((o.pop("id", f"{os.path.splitext(os.path.basename(g.sweep))[0]}-{i}"), o))
    for tid, over in trials:
        par = params(base, over)
        crop = os.path.join(g.crops, tid + ".jpg") if g.crops else g.crop
        score = os.path.join(g.scores, tid + ".json") if g.scores else g.score
        im, r, fig, secs = run(par, g.width, pool, g.out if not g.sweep else None, score,
                               g.top if not g.sweep else None, crop, g.panel if not g.sweep else None)
        dist = r["distance"]
        worst = sorted(((v, k) for k, v in dist.items() if k not in ("summary", "colour")), reverse=True)[:4]
        print(f"{tid}  summary {dist['summary']:.2f}  " + "  ".join(f"{k} {v:.1f}" for v, k in worst)
              + f"  | far h {fig.get('far offset', 0):.2f} w {fig.get('far width', 0):.2f} "
              f"depth {fig.get('far depth', 0):.3f}  ({secs:.0f} s)", flush=True)
        if g.csv:
            src = json.dumps(dict(base, **over), separators=(",", ":"))
            append_csv(g.csv, trial_row(tid, g.family, par, r, fig, secs, src))


if __name__ == "__main__":
    main()
