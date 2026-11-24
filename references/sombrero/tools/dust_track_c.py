#!/usr/bin/env python3
"""dust_track_c.py [params.json ...] [key=value ...] [options]: the Sombrero's dust ring as clumps
wound by differential rotation (#491, track C of #485).

The ring is a list of clouds, not a noise formula. Each clump has a birth place in the ring (radius,
azimuth, height), a mass and a size drawn from wide laws, an age, and a fixed internal hierarchy of
sub-clumps (K per level, `levels` levels, each `subf` the size of its parent, masses log-normal of
spread `subsig`; `ball` 1 makes the finest level a uniform ball, sharp-edged). A grain picks a clump
(grains per clump as mass^alloc * area^(1 - alloc)), a path down its hierarchy (`pick` 1: each child
drawn in proportion to its mass, so grains weigh the same and show less sand), and lands at the
clump's birth offset; then the rotation curve winds it for the clump's age: its azimuth moves by
spin * Omega(R) * age at its own radius R, so a clump of radial size dR trails into an arc
R |dOmega/dR| age dR long. Flat curve by default, vc = 350 km/s (at 7 kpc a turn takes 123 Myr; a
100 pc clump is stretched 2.6 to 1 after 50 Myr and 10 to 1 after 200 Myr); `vslope` tilts it.
dust_bench's own `myr` does the same for a grain file, one rigid age for every grain (each grain's
azimuth moved by its own v / r): it cannot give clumps their own ages, hence this generator.

- Births: an inner rim (share `rim_f`, at `r_in` - `lop` sin(azimuth), scalloped by `scallop` kpc in
  lumps `scallop_len` long, `rim_w` kpc deep) and a body decaying outward over `taper` kpc (0 flat,
  negative rising) to the rim `rim`, faded over its last `body_fade` kpc. Along the orbit the births
  are thinned by a log-normal intensity exp(clus * G), G a random field of plane waves in (azimuth,
  radius) of length `clus_len` along and `clus_rad` across, plus `asym` cos(azimuth - asym_az). With
  `ncx` > 0 clumps gather in that many complexes (cx_size kpc along, cx_q of it across, cx_z in
  height, masses log-normal cx_sig), a share cx_free left in the field.
- Clumps: masses from a power law dN/dm ~ m^-alpha over [1, mrange] (mlaw "power") or a log-normal
  of spread msig (mlaw "lognormal"); in-plane size s0 m^sbeta (capped at smax), height size qz s
  (capped at zcap), both times 1 + sgrow (R - r_in) / (rim - r_in). `fil_frac` of a clump's grains
  lie on fil_n branches from its hub (see filaments). Ages: `gens`, a list of [share, tmin, tmax]
  (Myr) or [share, tmin, tmax, size factor]; `fade_t` (Myr, 0 off) dims a clump as
  exp(-age / fade_t). `disp` (km/s) spreads a clump radially as it ages, which lengthens its arc.
- Height: centres N(0, hc), times 1 + flare (R - r_in) / (rim - r_in); the layer is corrugated by
  `corr` kpc in waves `corr_len` kpc long (a field of the present position, so arcs follow it).
- Holes: `nb` bubbles (radius log-normal about `rb` kpc, spread rb_sig; ages uniform to `bt` Myr) in
  the body. Clumps older than a bubble that sat inside it when it blew are pushed to its shell (then
  wound on with the rest); `shell_n` new clumps per 0.1 kpc of shell radius are born on it, as old
  as the bubble or younger, `bz` the shell's height over its radius.
- A diffuse share `diffuse` of the mass in a smooth layer `hd` kpc thick over the same envelope.

Grains go through dust_bench.project (share=depth and centre=nucleus by default, as wave 2 asks),
then dust_bench's column, light and compositing steps, copied from dust_bench.render.

  dust_track_c.py f1.json --width 6144 --out frame.png --face-linear top.jpg --json t.json --panel p.jpg
  dust_track_c.py f1.json seed=2 nb=0 --width 3072 --log trials.csv --id t001 --family clumps

Options: --width (3072), --out PNG, --face-linear JPG (top view, optical depth 0 to 1, 20 kpc),
--json/--panel (texture.py at --grid, 6144 by default), --log CSV (one row a trial), --id, --family.
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

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import dust_bench as db  # noqa: E402
import texture  # noqa: E402

KMS = 1.0227e-3   # kpc per Myr in one km/s

DEFAULTS = dict(
    seed=1, n=24_000_000,
    # rotation: v(R) = vc (R / 7)^vslope km/s; spin +1 or -1 (which way the arcs trail)
    vc=350.0, vslope=0.0, spin=1,
    # envelope of births
    rim=8.8, r_in=5.6, lop=0.0, rim_f=0.25, rim_w=0.12, scallop=0.1, scallop_len=0.6, taper=2.0, body_fade=0.5,
    # clustering along the orbit
    clus=1.0, clus_len=1.5, clus_rad=0.8, asym=0.3, asym_az=30.0,
    # complexes: ncx centres (0 off), clumps scattered cx_size kpc about them (cx_q across, cx_z in height),
    # complex masses log-normal cx_sig, a share cx_free of clumps left in the field
    ncx=0, cx_size=0.15, cx_q=0.5, cx_z=0.0, cx_sig=0.5, cx_free=0.2,
    # clumps
    nclump=60000, mlaw="power", alpha=1.8, mrange=300.0, msig=1.0,
    s0=0.03, sbeta=0.4, smax=0.25, qz=0.5, zcap=0.03, sgrow=0.0,
    levels=2, K=4, subf=0.4, subsig=0.6, ball=0,
    # sampling: pick 1 draws sub-clumps in proportion to their mass (equal-weight grains, less sand);
    # grains per clump go as mass^alloc * area^(1 - alloc)
    pick=0, alloc=0.0,
    # filamentary clumps: a share fil_frac of each clump's grains on fil_n branches from its hub (see filaments)
    fil_frac=0.0, fil_n=4, fil_len=2.0, fil_w=0.08, fil_q=1.0, fil_z=0.3, fil_bend=0.5, fil_pow=1.0,
    gens=[[1.0, 0.0, 200.0]], fade_t=0.0, disp=0.0,
    # height
    hc=0.008, flare=1.0, corr=0.0, corr_len=1.0,
    # holes and shells
    nb=0, rb=0.15, rb_sig=0.4, bt=60.0, shell_n=3.0, bz=0.1, shell_sq=0.7,
    # diffuse share
    diffuse=0.0, hd=0.03,
    # bench settings (wave 2: share=depth centre=nucleus blur=0.15 n=24000000)
    share="depth", centre="nucleus", blur=0.15, mass=1.0, k=0.19, redden=3.0, grey=0.0,
    behind=0.95, behind_far=0.18, gamma_light=2.2, stretch=0.0, white=13.0, splat=1, light_model="",
    # colour law: "old" or "hubble" (dust_bench.py; its inner rim is read from r_in, see bench_par)
    law="old",
)
BENCH_KEYS = ["share", "centre", "blur", "mass", "k", "redden", "grey", "behind", "behind_far",
              "gamma_light", "stretch", "white", "splat", "light_model", "law"]


# ---------------------------------------------------------------- fields and hashes

def omega(r, par):
    """Angular speed, rad/Myr."""
    v = par["vc"] * (np.maximum(r, 0.05) / 7.0) ** par["vslope"] * KMS
    return v / np.maximum(r, 0.05)


def waves(seed, n, len_along, len_rad, r0=7.0):
    """A random field of n plane waves in (azimuth, radius), unit variance, periodic in azimuth."""
    rng = np.random.default_rng(seed)
    m = np.maximum(1, np.rint(np.abs(rng.normal(0, 2 * np.pi * r0 / len_along, n)))).astype(float)
    m *= rng.choice([-1, 1], n)
    q = rng.normal(0, 1 / len_rad, n) if len_rad > 0 else np.zeros(n)
    p = rng.uniform(0, 2 * np.pi, n)

    def field(r, a):
        out = np.zeros(np.shape(a), np.float64)
        for mi, qi, pi in zip(m, q, p):
            out += np.cos(mi * a + qi * r + pi)
        return out * math.sqrt(2.0 / n)
    return field


M1, M2 = np.uint64(0xbf58476d1ce4e5b9), np.uint64(0x94d049bb133111eb)


def _mix(x):
    x = x ^ (x >> np.uint64(30))
    x = x * M1
    x = x ^ (x >> np.uint64(27))
    x = x * M2
    return x ^ (x >> np.uint64(31))


def hash_gauss(idx, path, tag, seed):
    """A fixed N(0, 1) for each (clump, path down its hierarchy, tag)."""
    key = (idx.astype(np.uint64) * np.uint64(0x9E3779B97F4A7C15) + path.astype(np.uint64) * np.uint64(0xC2B2AE3D27D4EB4F)
           + np.uint64(tag * 1000003 + seed * 7919))
    a, b = _mix(key), _mix(key ^ np.uint64(0x5851F42D4C957F2D))
    u1 = ((a >> np.uint64(11)).astype(np.float64) + 0.5) / 2.0 ** 53
    u2 = (b >> np.uint64(11)).astype(np.float64) / 2.0 ** 53
    return np.sqrt(-2 * np.log(u1)) * np.cos(2 * np.pi * u2)


def smoothstep(a, b, x):
    t = np.clip((x - a) / max(b - a, 1e-9), 0, 1)
    return t * t * (3 - 2 * t)


# ---------------------------------------------------------------- clumps

def inner_cut(a, par):
    f = waves(par["seed"] * 101 + 7, 24, par["scallop_len"], 0)
    return par["r_in"] - par["lop"] * np.sin(a) + par["scallop"] * np.clip(f(np.zeros_like(a), a), -2.5, 2.5) / 1.5


def draw_births(par, n, rng, field):
    """n clump births (R, azimuth) from the envelope, thinned along the orbit by exp(clus G)."""
    out_r, out_a = [], []
    got = 0
    gmax = 2.5
    while got < n:
        m = max(4 * (n - got), 10000)
        a = rng.uniform(0, 2 * np.pi, m)
        cut = inner_cut(a, par)
        rim = rng.random(m) < par["rim_f"]
        r_rim = cut + np.abs(rng.normal(0, 1, m)) * par["rim_w"]
        span = np.maximum(par["rim"] - cut, 1e-3)
        u = rng.random(m)
        t = par["taper"]
        r_body = cut - t * np.log(1 - u * (1 - np.exp(-span / t))) if t != 0 else cut + u * span
        r = np.where(rim, r_rim, r_body)
        keep = (r <= par["rim"]) & (rng.random(m) < 1 - smoothstep(par["rim"] - par["body_fade"], par["rim"], r))
        g = field(r, a) + par["asym"] * np.cos(a - math.radians(par["asym_az"]))
        keep &= rng.random(m) < np.exp(par["clus"] * (np.minimum(g, gmax) - gmax))
        out_r.append(r[keep])
        out_a.append(a[keep])
        got += int(keep.sum())
    return np.concatenate(out_r)[:n], np.concatenate(out_a)[:n]


def draw_masses(par, n, rng):
    if par["mlaw"] == "lognormal":
        return np.exp(rng.normal(0, par["msig"], n))
    al, top = par["alpha"], par["mrange"]
    u = rng.random(n)
    if abs(al - 1) < 1e-6:
        return top ** u
    return (1 - u * (1 - top ** (1 - al))) ** (1 / (1 - al))


def clumps(par):
    """The clump table: dict of arrays R, a (present azimuth of the centre), z, s, sz, m, age."""
    rng = np.random.default_rng(par["seed"])
    field = waves(par["seed"] * 31 + 3, 64, par["clus_len"], par["clus_rad"])
    n = int(par["nclump"])
    gens = np.array([g + [1.0] * (4 - len(g)) for g in par["gens"]], float)
    gi = rng.choice(len(gens), n, p=gens[:, 0] / gens[:, 0].sum())
    age = rng.uniform(gens[gi, 1], gens[gi, 2])
    sfac = gens[gi, 3]
    if par["ncx"] > 0:   # clumps gathered in complexes (a Neyman-Scott process): births of the complexes,
        nc = int(par["ncx"])   # clumps scattered about them by cx_size along, cx_size * cx_q across
        rc, ac = draw_births(par, nc, rng, field)
        wc = np.exp(rng.normal(0, par["cx_sig"], nc))
        ci = rng.choice(nc, n, p=wc / wc.sum())
        free = rng.random(n) < par["cx_free"]
        rf, af = draw_births(par, int(free.sum()), rng, field)
        r = rc[ci] + rng.normal(0, 1, n) * par["cx_size"] * par["cx_q"]
        a = ac[ci] + rng.normal(0, 1, n) * par["cx_size"] / rc[ci]
        r[free], a[free] = rf, af
        zcx = np.where(free, 0.0, rng.normal(0, 1, nc)[ci] * par["cx_z"])
    else:
        r, a = draw_births(par, n, rng, field)
        zcx = np.zeros(n)
    m = draw_masses(par, n, rng)

    # holes: clumps older than a bubble, inside it when it blew, go to its shell; new clumps on the shell
    nsh = 0
    if par["nb"] > 0:
        nb = int(par["nb"])
        rbub, abub = draw_births(dict(par, rim_f=0.0), nb, rng, field)
        rad = par["rb"] * np.exp(rng.normal(0, par["rb_sig"], nb))
        tb = rng.uniform(0, par["bt"], nb)
        order = np.argsort(-tb)            # oldest first
        sq = np.ones(n)
        for b in order:
            rb, ab, rr, t = rbub[b], abub[b], rad[b], tb[b]
            sel = np.nonzero((np.abs(r - rb) < rr) & (age > t))[0]
            if len(sel) == 0:
                continue
            spin = par["spin"]
            a_then = a[sel] - spin * omega(r[sel], par) * t
            ab_then = ab - spin * omega(rb, par) * t
            dx = ((a_then - ab_then + np.pi) % (2 * np.pi) - np.pi) * rb
            dy = r[sel] - rb
            d = np.hypot(dx, dy)
            ins = d < rr
            if not ins.any():
                continue
            k = sel[ins]
            f = rr * (1 + 0.15 * rng.normal(0, 1, len(k))) / np.maximum(d[ins], 1e-4)
            r_new = rb + dy[ins] * f
            a_new = ab_then + dx[ins] * f / rb
            r[k] = r_new
            a[k] = a_new + spin * omega(r_new, par) * t
            sq[k] *= par["shell_sq"]
        # shell-born clumps
        ns = np.maximum(0, rng.poisson(par["shell_n"] * rad / 0.1))
        bi = np.repeat(np.arange(nb), ns)
        nsh = k = len(bi)
        if k:
            ages = tb[bi] * rng.uniform(0.3, 1.0, k)
            th = rng.uniform(0, 2 * np.pi, k)
            rr = rad[bi] * (1 + 0.15 * rng.normal(0, 1, k))
            # the bubble's centre when the clump was born, the clump on its rim, then wound to now
            ab_born = abub[bi] - par["spin"] * omega(rbub[bi], par) * ages
            r_s = rbub[bi] + rr * np.sin(th)
            a_s = ab_born + rr * np.cos(th) / rbub[bi]
            a_s = a_s + par["spin"] * omega(r_s, par) * ages
            r = np.concatenate([r, r_s])
            a = np.concatenate([a, a_s])
            age = np.concatenate([age, ages])
            sfac = np.concatenate([sfac, np.full(k, par["shell_sq"])])
            m = np.concatenate([m, draw_masses(par, k, rng)])
            sq = np.concatenate([sq, np.ones(k)])
            zb = rr * par["bz"] * rng.uniform(-1, 1, k)
        sfac = sfac * sq
    n = len(r)
    frac = np.clip((r - par["r_in"]) / (par["rim"] - par["r_in"]), 0, 1)
    grow = 1 + par["sgrow"] * frac   # clumps grow outward
    s = np.minimum(par["s0"] * m ** par["sbeta"], par["smax"]) * sfac * grow
    sz = np.minimum(s * par["qz"], par["zcap"] * grow)
    z = rng.normal(0, 1, n) * par["hc"] * (1 + par["flare"] * frac)
    z[:len(zcx)] += zcx
    if par["nb"] > 0 and nsh:
        z[-nsh:] += zb
    w = m * (np.exp(-age / par["fade_t"]) if par["fade_t"] > 0 else 1.0)
    keep = (r > 0.5) & (r < par["rim"] + 0.3)
    t = {"R": r, "a": a % (2 * np.pi), "z": z, "s": s, "sz": sz, "m": w, "age": age}
    return {key: v[keep].astype(np.float64) for key, v in t.items()}


def spread_r(t, par):
    return np.sqrt(t["s"] ** 2 + (par["disp"] * KMS * t["age"]) ** 2)


def allocate(t, par, n_clump_grains, rng):
    """Grains per clump: in proportion to the area it covers now (in-plane size times its arc's length)."""
    sr = spread_r(t, par)
    dom = par["vc"] * KMS / np.maximum(t["R"], 0.1) * (1 - par["vslope"])   # R |dOmega/dR|
    length = np.hypot(t["s"], sr * dom * t["age"])
    area = length * np.maximum(t["sz"], 0.002)
    share = (t["m"] / t["m"].sum()) ** par["alloc"] * (area / area.sum()) ** (1 - par["alloc"])
    exp = share / share.sum() * n_clump_grains
    base = np.floor(exp)
    return (base + (rng.random(len(exp)) < exp - base)).astype(np.int64)


# ---------------------------------------------------------------- grains

_T = {}


def _init(table, par):
    _T["t"], _T["par"] = table, par


def grains_of(lo, hi, seed):
    """Grains of clumps lo..hi (and, for lo < 0, the diffuse share): x, y, z, w."""
    t, par = _T["t"], _T["par"]
    rng = np.random.default_rng(seed)
    if lo < 0:
        return diffuse_grains(-lo, par, rng)
    cnt = t["count"][lo:hi]
    idx = np.repeat(np.arange(lo, hi), cnt)
    n = len(idx)
    off = np.zeros((n, 3))
    w = np.ones(n)
    path = np.zeros(n, np.int64)
    K, L, f = int(par["K"]), int(par["levels"]), par["subf"]
    for lev in range(L):
        if par["subsig"] > 0 and par["pick"]:   # a child picked in proportion to its mass: grains of equal weight
            cw = np.stack([np.exp(par["subsig"] * hash_gauss(idx, path * K + j + 1, 10 * lev + 3, par["seed"]))
                           for j in range(K)], -1)
            cw = np.cumsum(cw, 1)
            j = (rng.random(n)[:, None] * cw[:, -1:] > cw).sum(1)
            path = path * K + j + 1
        else:
            path = path * K + rng.integers(0, K, n) + 1
            if par["subsig"] > 0:
                w *= np.exp(par["subsig"] * hash_gauss(idx, path, 10 * lev + 3, par["seed"]) - par["subsig"] ** 2 / 2)
        for c in range(3):
            off[:, c] += hash_gauss(idx, path, 10 * lev + c, par["seed"]) * f ** lev
    if par["ball"]:   # the finest level a uniform ball of the same spread: sharp-edged cloudlets
        g = rng.standard_normal((n, 3))
        g *= (rng.random(n) ** (1 / 3) * math.sqrt(5) / np.linalg.norm(g, axis=1))[:, None]
        off += g * f ** L
    else:
        off += rng.standard_normal((n, 3)) * f ** L
    norm = math.sqrt(sum(f ** (2 * i) for i in range(L + 1)))
    off /= norm
    R0, a0, age = t["R"][idx], t["a"][idx], t["age"][idx]
    s, sz = t["s"][idx], t["sz"][idx]
    sr = spread_r({"s": s, "age": age}, par)
    d_al, d_r, d_z = off[:, 0] * s, off[:, 1] * sr, off[:, 2] * sz
    if par["fil_frac"] > 0:
        fm = np.nonzero(rng.random(n) < par["fil_frac"])[0]
        da, dr, dz, wf = filaments(idx[fm], s[fm], rng, par)
        d_al[fm], d_r[fm], d_z[fm] = da, dr + (sr[fm] - s[fm]) * rng.standard_normal(len(fm)), dz
        w[fm] = wf
    r = np.maximum(R0 + d_r, 0.1)
    a = a0 + d_al / R0 + par["spin"] * (omega(r, par) - omega(R0, par)) * age
    z = t["z"][idx] + d_z
    z = z + corrugation(r, a, par)
    w = w * (t["m"] / np.maximum(t["count"], 1))[idx]
    return r * np.cos(a), r * np.sin(a), z, w


def filaments(idx, s, rng, par):
    """Hub and branches: each clump has fil_n branches from its centre, fil_len s long (log-normal 0.5), in a
    fixed direction weighted fil_q radially and fil_z in height (1 along the orbit), bent by fil_bend, fil_w s
    wide; grains spread along a branch as t^fil_pow from the hub. Offsets in kpc (along, radial, up) and weights."""
    n = len(idx)
    j = rng.integers(0, int(par["fil_n"]), n) + 1
    seed = par["seed"]
    d = np.stack([hash_gauss(idx, j, 50, seed), hash_gauss(idx, j, 51, seed) * par["fil_q"],
                  hash_gauss(idx, j, 52, seed) * par["fil_z"]], -1)
    d /= np.maximum(np.linalg.norm(d, axis=1, keepdims=True), 1e-9)
    b = np.stack([hash_gauss(idx, j, 53 + c, seed) for c in range(3)], -1)
    b -= (b * d).sum(1, keepdims=True) * d
    b /= np.maximum(np.linalg.norm(b, axis=1, keepdims=True), 1e-9)
    length = s * par["fil_len"] * np.exp(0.5 * hash_gauss(idx, j, 56, seed))
    tt = rng.random(n) ** par["fil_pow"]
    pos = (tt * length)[:, None] * d + (par["fil_bend"] * length * tt * (1 - tt))[:, None] * b
    pos += rng.standard_normal((n, 3)) * (par["fil_w"] * s)[:, None]
    w = np.exp(par["subsig"] * hash_gauss(idx, j, 57, seed) - par["subsig"] ** 2 / 2) if par["subsig"] > 0 else np.ones(n)
    return pos[:, 0], pos[:, 1], pos[:, 2], w


def diffuse_grains(n, par, rng):
    a = rng.uniform(0, 2 * np.pi, n)
    cut = inner_cut(a, par)
    span = np.maximum(par["rim"] - cut, 1e-3)
    u = rng.random(n)
    tp = max(par["taper"], 0.3)
    r = cut - tp * np.log(1 - u * (1 - np.exp(-span / tp)))
    frac = np.clip((r - par["r_in"]) / (par["rim"] - par["r_in"]), 0, 1)
    z = rng.normal(0, 1, n) * par["hd"] * (1 + par["flare"] * frac) + corrugation(r, a, par)
    w = (1 - smoothstep(par["rim"] - par["body_fade"], par["rim"], r)) * _T["t"]["wdiff"]
    return r * np.cos(a), r * np.sin(a), z, w


_CORR = {}


def corrugation(r, a, par):
    if par["corr"] <= 0:
        return 0.0
    key = (par["seed"], par["corr_len"])
    if key not in _CORR:
        _CORR[key] = waves(par["seed"] * 53 + 11, 48, par["corr_len"], par["corr_len"] / 7.0)
    return par["corr"] * _CORR[key](r, a)


def _chunk(args):
    lo, hi, seed, width, bpar = args
    x, y, z, w = grains_of(lo, hi, seed)
    w = w.astype(np.float32)
    return db.project(x, y, z, w, bpar, width), float(w.sum()), db.face_hist(x, y, w), len(x)


def bench_par(par):
    """dust_bench's parameters: the bench keys, and for law=hubble the ring's inner cut (`inner` * `rim` = r_in)."""
    b = dict(db.DEFAULTS)
    b.update({k: par[k] for k in BENCH_KEYS})
    b["rim"], b["inner"] = par["rim"], par["r_in"] / par["rim"]
    return b


def build_table(par):
    t = clumps(par)
    rng = np.random.default_rng(par["seed"] + 99)
    n_d = int(par["n"] * min(max(par["diffuse"], 0), 0.9))
    t["count"] = allocate(t, par, par["n"] - n_d, rng)
    t["n_diffuse"] = n_d
    mc = t["m"].sum()
    # the diffuse grains carry diffuse / (1 - diffuse) of the clumps' mass between them
    t["wdiff"] = (par["diffuse"] / max(1 - par["diffuse"], 1e-6) * mc / n_d) if n_d else 0.0
    return t


def jobs_of(t, par, width, per=3_000_000):
    cum = np.cumsum(t["count"])
    bp = bench_par(par)
    jobs, lo = [], 0
    nc = len(cum)
    while lo < nc:
        start = cum[lo - 1] if lo else 0
        hi = int(np.searchsorted(cum, start + per, side="right"))
        hi = max(hi, lo + 1)
        jobs.append((lo, min(hi, nc), par["seed"] * 1000 + len(jobs), width, bp))
        lo = hi
    nd = t["n_diffuse"]
    while nd > 0:
        k = min(per, nd)
        jobs.append((-k, 0, par["seed"] * 1000 + len(jobs), width, bp))
        nd -= k
    return jobs


def render(par, light, width=3072, workers=4):
    """Renders the ring on `light` (uint8, already cleaned, at `width`): a PIL image with .face_column."""
    t = build_table(par)
    bp = bench_par(par)
    if bp["share"] == "depth":
        db.light_model.load_table(db.light_params(bp))
    jobs = jobs_of(t, par, width)
    maps, total, face, ng = None, 0.0, None, 0
    with ProcessPoolExecutor(workers, initializer=_init, initargs=(t, par)) as pool:
        for mp, wt, fc, k in pool.map(_chunk, jobs):
            maps = mp if maps is None else [a + b for a, b in zip(maps, mp)]
            total += wt
            face = fc if face is None else face + fc
            ng += k
    light = db.recentre(light, bp)
    maps = [db.to_column(m, total, bp, width) for m in maps]
    near, far = maps[:2]
    shares = (db.mean_share(maps[2], near), db.mean_share(maps[3], far)) if bp["share"] == "depth" else None
    rims = tuple(maps[-2:]) if bp["law"] == "hubble" else None
    im = Image.fromarray(db.attenuate(light, near, far, bp, shares, rims))
    im.face_column = face / total / (db.FACE_KPC / db.FACE_PX) ** 2 * 100.0 * bp["mass"]
    im.stats = {"clumps": int(len(t["R"])), "grains": int(ng)}
    return im


_LIGHT = {}


def light_at(width):
    if width not in _LIGHT:
        light, _ = db.load_light("origin", width)
        _LIGHT[width] = db.clean_light(light)
    return _LIGHT[width]


# ---------------------------------------------------------------- trials

FIGS = texture.WINDOW_FIGS + texture.LANE_FIGS


def load_par(args):
    par = json.loads(json.dumps(DEFAULTS))
    for a in args:
        if "=" not in a:
            data = json.load(open(a))
            data.pop("label", None)
            data.pop("command", None)
            for k in data:
                if k not in DEFAULTS:
                    sys.exit(f"unknown parameter {k} in {a}")
            par.update(data)
        else:
            k, v = a.split("=", 1)
            if k not in DEFAULTS:
                sys.exit(f"unknown parameter {k}")
            par[k] = json.loads(v) if v[:1] in "[{" else db.parse_value(v)
    return par


def run(par, width=3072, grid=6144, out=None, face_linear=None, json_out=None, panel=None, label=""):
    t0 = time.time()
    im = render(par, light_at(width), width)
    t1 = time.time()
    if out:
        im.save(out)
    if face_linear:
        db.face_linear(im.face_column, par["k"], label).save(face_linear, quality=92)
    res = texture.score(im, grid)
    if json_out:
        json.dump(dict(texture.public(res), params=par), open(json_out, "w"), indent=1)
    if panel:
        texture.panel(res, label).save(panel, quality=88)
    res["_im"] = im
    res["_secs"] = (round(t1 - t0, 1), round(time.time() - t1, 1))
    return res


def log_row(path, tid, family, par, res, pjson, width):
    d = res["distance"]
    row = {"id": tid, "family": family, "seed": par["seed"], "params": pjson, "width": width,
           "summary": round(d["summary"], 3)}
    for k in FIGS:
        row[k] = round(d.get(k, float("nan")), 2)
    row["far_mean_A"] = round(res["far"]["mean"], 4)
    new = not os.path.exists(path)
    with open(path, "a", newline="") as f:
        wr = csv.DictWriter(f, fieldnames=list(row))
        if new:
            wr.writeheader()
        wr.writerow(row)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("args", nargs="*")
    p.add_argument("--width", type=int, default=3072)
    p.add_argument("--grid", type=int, default=6144)
    p.add_argument("--out")
    p.add_argument("--face-linear")
    p.add_argument("--json")
    p.add_argument("--panel")
    p.add_argument("--log")
    p.add_argument("--id", default="")
    p.add_argument("--family", default="")
    p.add_argument("--save-params", help="write the full parameters here")
    g = p.parse_args()
    par = load_par(g.args)
    if g.save_params:
        json.dump(par, open(g.save_params, "w"), indent=1)
    res = run(par, g.width, g.grid, g.out, g.face_linear, g.json, g.panel, g.id or g.family)
    d = res["distance"]
    print(f"{g.id} summary {d['summary']:.2f}  ({res['_secs'][0]} s render, {res['_secs'][1]} s score, "
          f"{res['_im'].stats['clumps']} clumps, {res['_im'].stats['grains']} grains)")
    print("   " + "  ".join(f"{k} {v:.1f}" for k, v in d.items() if k != "summary"))
    if g.log:
        log_row(g.log, g.id, g.family, par, res, g.save_params or " ".join(g.args), g.width)


if __name__ == "__main__":
    main()
