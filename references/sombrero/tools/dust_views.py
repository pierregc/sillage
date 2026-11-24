#!/usr/bin/env python3
"""dust_views.py: a dust finalist from above, through time and at a grazing angle (#504, epic #485).

The finalists of #489-#491 were tuned at Hubble's angle (6 degrees from edge on) and at one instant.
The film (#478) also shows the ring from the zenith with time flowing, then flies low over the dust.
This tool reads a finalist's grains and draws, measures and scores it there. It judges; it changes
nothing in the rings.

  dust_views.py prepare c f1 references/sombrero/dust-tracks/c/f1.json     # track C: grains from its generator
  dust_views.py prepare a f3 grains.f32 --bench a/f3.json [key=value ...]   # any track: a grain file
  dust_views.py run c f1 [--times -40,-20,-10,0,10,20,40] [--rigid 20,40]
  dust_views.py reverse c f1 [--T 10,20,40] [--sigma 2,5,10]
  dust_views.py sheets c

`prepare` writes OUT/<track>/<name>/grains.f32 (7 float32 a grain: x y z opacity vx vy vz, kpc, the
velocities in Sillage's units of 207 km/s as dust_bench --grains reads them) and bench.json (the
bench parameters the finalist is rendered with: its own, plus `law=hubble` as the finalists' commands
give). A grain file from another track needs only x y z opacity; with no velocities (or `--curve`), the
grains turn on circular orbits of `--curve vc=350,vslope=0,spin=1`, v = vc (R / 7 kpc)^vslope.
`run` writes, per time, the view from above (`top`), the frame at Hubble's angle at 3072 px scored with
texture.py on the 6144 grid (`frame`, `score`), and the centre close-up; then the measures from above
(`above.json`), the grazing view and the vertical cut (`volume.json`), all in OUT/<track>/<name>/.
`reverse` checks the reverse recipe (track C: through its own generator) and blurs the grains with a
velocity dispersion over T. `sheets` draws <track>-above.jpg, -time.jpg, -time-hubble.jpg, -grazing.jpg.

Wraps, does not edit: dust_bench.project / to_column / attenuate (the frame, as dust_track_c.render
does), dust_track_c's clump table and grains_of (track C's grains), light_model's emissivity (the light
from above). Memory: one 3072 render at a time per process, four workers, chunks of 3 M grains.
"""
import argparse
import json
import math
import os
import sys
import time
from concurrent.futures import ProcessPoolExecutor

import numpy as np
from PIL import Image, ImageDraw
from scipy.ndimage import gaussian_filter, label, find_objects, map_coordinates

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import dust_bench as db  # noqa: E402
import dust_track_c as dct  # noqa: E402
import texture  # noqa: E402
import hubble_ref  # noqa: E402
import closeup  # noqa: E402
import light_model  # noqa: E402

OUT = "/Users/pierregc/claude-workspace/sombrero/banc/504"
KMS = dct.KMS                  # kpc per Myr in one km/s
SILLAGE_T = 4.71               # Myr: Sillage's time unit; its velocity unit is a kpc per 4.71 Myr
TIMES = [-40, -20, -10, 0, 10, 20, 40]
WIDTH = 3072
GRID = 6144
CHUNK = 3_000_000
WORKERS = 4

TOP_KPC, TOP_PX = 20.0, 2000   # the view from above: 10 pc a pixel
CUT_ARC = 0.3                  # kpc of arc the vertical cut sums over
GRAZE = dict(R0=7.5, phi0=-90.0, elev=2.5, width=2.0, depth=1.0, height=0.4, px=1000)
CUT = dict(phi0=-90.0, r0=5.0, r1=10.5, z=0.25, px=5e-3)


# ---------------------------------------------------------------- grains

def grain_path(track, name):
    return os.path.join(OUT, track, name, "grains.f32")


def open_grains(path):
    return np.memmap(path, dtype=np.float32, mode="r").reshape(-1, 7)


def _gen_c(args):
    lo, hi, seed = args
    x, y, z, w = dct.grains_of(lo, hi, seed)
    return x.astype(np.float32), y.astype(np.float32), z.astype(np.float32), w.astype(np.float32)


def prepare_c(par, path):
    """Track C's grains, as dust_track_c.render draws them (same table, same chunks, same seeds),
    written with their circular velocities spin * Omega(R) * R."""
    t = dct.build_table(par)
    jobs = [(lo, hi, seed) for lo, hi, seed, _, _ in dct.jobs_of(t, par, WIDTH)]
    n = int(t["count"].sum()) + int(t["n_diffuse"])
    out = np.memmap(path, dtype=np.float32, mode="w+", shape=(n, 7))
    at = 0
    with ProcessPoolExecutor(WORKERS, initializer=dct._init, initargs=(t, par)) as pool:
        for x, y, z, w in pool.map(_gen_c, jobs):
            k = len(x)
            r = np.hypot(x, y).astype(np.float64)
            v = par["spin"] * dct.omega(r, par) * r * SILLAGE_T   # kpc per Sillage time unit
            out[at:at + k, 0], out[at:at + k, 1], out[at:at + k, 2], out[at:at + k, 3] = x, y, z, w
            out[at:at + k, 4] = -v * y / np.maximum(r, 1e-9)
            out[at:at + k, 5] = v * x / np.maximum(r, 1e-9)
            out[at:at + k, 6] = 0
            at += k
    out.flush()
    return at


def _gen_b(args):
    """Track B's grains, as dust_track_b._grains draws them (copied: that function returns maps, not grains)."""
    import dust_track_b as dtb
    from scipy.special import erfinv
    from scipy.stats import qmc
    F, spec, n, seed = args
    rng = np.random.default_rng(seed)
    u = qmc.Sobol(4, scramble=True, seed=rng.integers(1 << 31)).random(n)
    r = np.sqrt(dtb.R0 * dtb.R0 + u[:, 0] * (dtb.R1 * dtb.R1 - dtb.R0 * dtb.R0))
    th = -math.pi + u[:, 1] * 2 * math.pi
    w = dtb.lookup(F, r, th, spec.get("interp", 0))
    corr = dtb.corrugation(spec) if spec.get("corr", 0) > 0 else None
    z = np.sqrt(2) * erfinv(np.clip(2 * u[:, 2] - 1, -1 + 1e-7, 1 - 1e-7)) * dtb.thickness(r, spec)
    z = z + dtb.midplane(r, th, spec, corr)
    return (r * np.cos(th)).astype(np.float32), (r * np.sin(th)).astype(np.float32), z.astype(np.float32), w.astype(np.float32)


def prepare_b(spec_path, path):
    """Track B's field drawn as grains with law=hubble, as dust_track_b.finalist(law="hubble") renders
    it; no velocities (the fields carry none). Returns the grain count and the bench parameters, with
    the `mass` dust_track_b.render sets from the grains' total."""
    import dust_track_b as dtb
    spec = json.load(open(spec_path))
    spec.pop("command", None)
    spec = dict(spec, par=dict(spec.get("par", {}), law="hubble", rim=8.8, inner=round(dtb.INNER_CUT / 8.8, 4)))
    F = dtb.field(spec)
    par = dict(db.DEFAULTS, **dtb.BASE, **spec["par"])
    n = par["n"]
    parts = max(4, -(-n // 3_000_000))
    jobs = [(F, spec, n // parts, spec.get("seed", 1) * 1000 + i) for i in range(parts)]
    out = np.memmap(path, dtype=np.float32, mode="w+", shape=(parts * (n // parts), 7))
    at, total = 0, 0.0
    with ProcessPoolExecutor(WORKERS) as pool:
        for x, y, z, w in pool.map(_gen_b, jobs):
            k = len(x)
            out[at:at + k, 0], out[at:at + k, 1], out[at:at + k, 2], out[at:at + k, 3] = x, y, z, w
            out[at:at + k, 4:] = 0
            total += float(w.sum(dtype=np.float64))
            at += k
    out.flush()
    area = math.pi * (dtb.R1 * dtb.R1 - dtb.R0 * dtb.R0)
    par["mass"] = spec.get("gain", 1.0) * total / (parts * (n // parts)) * area * dtb.SIN / 100.0
    return at, par, spec.get("label", "")


def _gen_a(args):
    """Track A's grains, as dust_track_a._chunk draws them (copied: that function returns maps)."""
    import dust_track_a as dta
    par, idx, parts = args
    mass, grains = dta.shares(par)
    gsum = sum(grains.values())
    out = []
    for name in dta.PARTS:
        if mass[name] <= 0:
            continue
        n = int(par["n"] * grains[name] / gsum / parts)
        g = dta.part_grains(name, n, par, par["seed"] * 1000 + idx * 17 + dta.PARTS.index(name), idx, parts)
        if g is None:
            continue
        r, th, z, w = g
        if par["m2"]:
            w = w * np.maximum(1 + par["m2"] * dta.outward(r, par) * np.cos(2 * th), 0)
        w = w / max(float(w.sum()), 1e-30) * mass[name] / parts
        x = r * np.cos(th) * (1 + par["oval"] / 2)
        y = r * np.sin(th) * (1 - par["oval"] / 2) + par["off_y"]
        out.append(np.stack([x, y, z, w], 1).astype(np.float32))
    return np.concatenate(out)


def prepare_a(src, params, path):
    """Track A's finalist as its command renders it (seed 2, law=hubble), grains written in order."""
    import dust_track_a as dta
    data = json.load(open(src))
    extra = {"seed": 2, "law": "hubble"}
    for kv in params:
        k, v = kv.split("=", 1)
        extra[k] = db.parse_value(v)
    par = dta.params(data, extra)
    parts = max(4, -(-par["n"] // 3_000_000))
    chunks = []
    with ProcessPoolExecutor(WORKERS) as pool:
        for a in pool.map(_gen_a, [(par, i, parts) for i in range(parts)]):
            chunks.append(a)
    n = sum(len(a) for a in chunks)
    out = np.memmap(path, dtype=np.float32, mode="w+", shape=(n, 7))
    at = 0
    for a in chunks:
        out[at:at + len(a), :4] = a
        out[at:at + len(a), 4:] = 0
        at += len(a)
    out.flush()
    bp = {k: v for k, v in par.items() if k in db.DEFAULTS}
    return n, bp, data.get("label", "")


def curve_omega(r, curve):
    """Signed angular speed, rad/Myr, of v = vc (R / 7)^vslope km/s."""
    v = curve["vc"] * (np.maximum(r, 0.05) / 7.0) ** curve["vslope"] * KMS
    return curve["spin"] * v / np.maximum(r, 0.05)


def grain_omega(g, curve=None):
    """Each grain's signed angular speed (rad/Myr): from its velocity, or from `curve`."""
    x, y = g[:, 0].astype(np.float64), g[:, 1].astype(np.float64)
    r2 = np.maximum(x * x + y * y, 1e-12)
    if curve is None:
        return (x * g[:, 5] - y * g[:, 4]) / r2 / SILLAGE_T
    return curve_omega(np.sqrt(r2), curve)


# ---------------------------------------------------------------- the light from above

_FACE = {}


def face_light(p):
    """Axisymmetric light seen from the zenith: E(R) (energy per kpc^2, the bench's units) and the share
    of the light under height z at radius R, from light_model's fitted emissivity."""
    key = id(p)
    if key in _FACE:
        return _FACE[key]
    R = np.arange(0.0, 14.01, 0.02)
    z = np.concatenate([-np.geomspace(15, 1e-3, 400), np.linspace(-1e-3, 1e-3, 3)[1:-1], np.geomspace(1e-3, 15, 400)])
    j = light_model.emissivity(p, R[:, None], 0 * R[:, None], z[None, :])
    dz = np.gradient(z)
    c = np.cumsum(j * dz, 1)
    E = c[:, -1]
    zt = np.linspace(-1.0, 1.0, 1001)
    below = np.stack([np.interp(zt, z, c[i] / max(E[i], 1e-30)) for i in range(len(R))])
    _FACE[key] = (R, E, zt, below)
    return _FACE[key]


def share_under(p, r, z):
    """Share of the light seen from +z that lies under the grain (behind it, for a view from above)."""
    R, _, zt, below = face_light(p)
    ci = np.clip(r / (R[1] - R[0]), 0, len(R) - 1)
    cj = np.clip((z - zt[0]) / (zt[1] - zt[0]), 0, len(zt) - 1)
    return map_coordinates(below, [ci, cj], order=1, mode="nearest").astype(np.float32)


# ---------------------------------------------------------------- moving the grains

def move(g, mode, curve):
    """x, y, z (float64) of a chunk after `mode`: ("rotate", dt) circular orbits for dt Myr; ("rigid", dt)
    every grain turned by the angle of 7 kpc; ("disperse", T, sigma, nu, seed): unwound by T on circular
    orbits, given a random velocity sigma km/s per component, integrated forward T Myr in the plane (flat or
    power-law curve); in height the kick adds w / nu sin(nu T), nu the vertical frequency per Myr."""
    x, y, z = (g[:, i].astype(np.float64) for i in range(3))
    if mode[0] in ("rotate", "rigid"):
        dt = mode[1]
        if dt == 0:
            return x, y, z
        r = np.hypot(x, y)
        if mode[0] == "rigid":   # the angular speed of the grains near 7 kpc, for all
            near = np.abs(r - 7.0) < 0.1
            om = np.full_like(r, float(np.median(grain_omega(g[near], curve))))
        else:
            om = grain_omega(g, curve)
        ph = np.arctan2(y, x) + om * dt
        return r * np.cos(ph), r * np.sin(ph), z
    _, T, sigma, nu, seed = mode
    om = grain_omega(g, curve)
    r = np.hypot(x, y)
    ph = np.arctan2(y, x) - om * T
    x, y = r * np.cos(ph), r * np.sin(ph)
    vc = om * r                                   # signed circular speed, kpc/Myr
    vx, vy, vz = -vc * np.sin(ph), vc * np.cos(ph), np.zeros_like(r)
    if sigma > 0:
        rng = np.random.default_rng(seed)
        s = sigma * KMS
        vx += rng.normal(0, s, len(r))
        vy += rng.normal(0, s, len(r))
        vz += rng.normal(0, s, len(r))
    vslope = curve["vslope"] if curve else 0.0
    v7 = np.median(np.abs(vc) / np.maximum(r, 1e-6) ** vslope)   # vc(R) = v7 R^vslope, per grain's own curve
    steps = max(1, int(round(abs(T) / 0.25)))
    h = T / steps

    def acc(x, y):
        rr = np.maximum(np.hypot(x, y), 1e-3)
        a = -(v7 * rr ** vslope) ** 2 / rr / rr
        return a * x, a * y
    ax, ay = acc(x, y)
    for _ in range(steps):
        vx += 0.5 * h * ax
        vy += 0.5 * h * ay
        x += h * vx
        y += h * vy
        ax, ay = acc(x, y)
        vx += 0.5 * h * ax
        vy += 0.5 * h * ay
    # height: the layer as drawn (its own vertical motion is not modelled, as in "rotate") plus the kick's
    # harmonic displacement w / nu sin(nu T)
    z = z + vz / nu * np.sin(nu * T)
    return x, y, z


# ---------------------------------------------------------------- one pass over the grains

def top_maps(x, y, z, w, bp, p):
    """From above, 10 pc a pixel: the column, the column times the light's share under each grain, the
    column in the inner rim (law=hubble)."""
    fx = (x / TOP_KPC + 0.5) * TOP_PX
    fy = (0.5 - y / TOP_KPC) * TOP_PX
    r = np.hypot(x, y)
    b = share_under(p, r, z)
    out = [db.splat(fx, fy, w, TOP_PX, TOP_PX), db.splat(fx, fy, w * b, TOP_PX, TOP_PX)]
    if bp["law"] == "hubble":
        out.append(db.splat(fx, fy, w * db.rim_share(r, bp), TOP_PX, TOP_PX))
    return out


def graze_maps(x, y, z, w):
    """Grazing view (orthographic) along the ring's tangent at GRAZE's point, and the vertical cut."""
    G = GRAZE
    R0, ph0, e = G["R0"], math.radians(G["phi0"]), math.radians(G["elev"])
    P = np.array([R0 * math.cos(ph0), R0 * math.sin(ph0), 0.0])
    t = np.array([-math.sin(ph0), math.cos(ph0), 0.0])          # tangent, the way of rotation for spin +1
    rad = np.array([math.cos(ph0), math.sin(ph0), 0.0])
    d = t * math.cos(e) - np.array([0, 0, 1.0]) * math.sin(e)    # looking along the tangent, down by e
    up = t * math.sin(e) + np.array([0, 0, 1.0]) * math.cos(e)
    dx, dy, dz = x - P[0], y - P[1], z - P[2]
    s = dx * d[0] + dy * d[1] + dz * d[2]
    u = dx * rad[0] + dy * rad[1]
    v = dx * up[0] + dy * up[1] + dz * up[2]
    pxk = G["px"] / G["width"]
    hpx = int(round(G["height"] * pxk))
    sel = (np.abs(s) < G["depth"] / 2) & (np.abs(u) < G["width"] / 2) & (np.abs(v) < G["height"] / 2)
    gm = db.splat((u[sel] / G["width"] + 0.5) * G["px"], (0.5 - v[sel] / G["height"]) * hpx, w[sel], G["px"], hpx)
    C = CUT
    r = np.hypot(x, y)
    dphi = (np.arctan2(y, x) - math.radians(C["phi0"]) + np.pi) % (2 * np.pi) - np.pi
    sel = (np.abs(dphi * r) < CUT_ARC / 2) & (r > C["r0"]) & (r < C["r1"]) & (np.abs(z) < C["z"])
    cw, ch = int(round((C["r1"] - C["r0"]) / C["px"])), int(round(2 * C["z"] / C["px"]))
    cm = db.splat((r[sel] - C["r0"]) / C["px"], (C["z"] - z[sel]) / C["px"], w[sel], cw, ch)
    # the layer's vertical profile against radius, from every grain: R bins of 0.25 kpc, z bins of 2 pc
    hz, _, _ = np.histogram2d(r, z, bins=[np.arange(5.0, 10.51, 0.25), np.arange(-0.3, 0.3001, 0.002)], weights=w)
    return gm, cm, hz


def _pass(args):
    path, lo, hi, mode, curve, bp, width, p, extras = args
    g = np.asarray(open_grains(path)[lo:hi])
    x, y, z = move(g, mode, curve)
    w = g[:, 3].astype(np.float32)
    out = {"w": float(w.sum(dtype=np.float64))}
    if width:
        out["frame"] = db.project(x, y, z, w, bp, width)
    out["top"] = top_maps(x, y, z, w, bp, p)
    if extras:
        out["graze"] = graze_maps(x, y, z, w)
    return out


def one_pass(path, mode, curve, bp, width=WIDTH, extras=False, pool=None):
    n = len(open_grains(path))
    p = db.light_params(bp)
    if bp["share"] == "depth":
        light_model.load_table(p)
    jobs = [(path, lo, min(lo + CHUNK, n), mode, curve, bp, width, p, extras) for lo in range(0, n, CHUNK)]
    acc = None
    for res in pool.map(_pass, jobs):
        if acc is None:
            acc = res
            continue
        acc["w"] += res["w"]
        for k in ("frame", "top", "graze"):
            if k in res:
                acc[k] = [a + b for a, b in zip(acc[k], res[k])]
    return acc


_LIGHT = {}


def light_at(width):
    if width not in _LIGHT:
        _LIGHT[width] = dct.light_at(width)
    return _LIGHT[width]


def frame_of(acc, bp, width=WIDTH):
    """The frame at Hubble's angle, as dust_track_c.render composes it."""
    light = db.recentre(light_at(width), bp)
    maps = [db.to_column(m, acc["w"], bp, width) for m in acc["frame"]]
    near, far = maps[:2]
    shares = (db.mean_share(maps[2], near), db.mean_share(maps[3], far)) if bp["share"] == "depth" else None
    rims = tuple(maps[-2:]) if bp["law"] == "hubble" else None
    return Image.fromarray(db.attenuate(light, near, far, bp, shares, rims))


def top_columns(acc, bp):
    """Column (bench units: optical depth k N), share under the dust, rim column, from above."""
    kpp = TOP_KPC / TOP_PX
    to = lambda m: m / acc["w"] / kpp ** 2 * 100.0 * bp["mass"]
    col = to(acc["top"][0])
    b = db.mean_share(to(acc["top"][1]), col)
    rim = to(acc["top"][2]) if bp["law"] == "hubble" else None
    return col, b, rim


# ---------------------------------------------------------------- pictures from above

LIGHT_RGB = np.array([1.0, 0.93, 0.82])


def top_picture(col, b, rim, bp, exposure=None):
    """Dust over light from the zenith: the model's light (axisymmetric, no arms, no young stars) dimmed by
    the column: (1 - b) + b T, T the bench's per-channel transmission, through the v6 look's curve."""
    p = db.light_params(bp)
    R, E, _, _ = face_light(p)
    n = TOP_PX
    c = (np.arange(n) + 0.5) / n * TOP_KPC - TOP_KPC / 2
    rr = np.hypot(c[None, :], c[::-1, None])
    e = np.interp(rr, R, E)
    if exposure is None:   # the light at 7.5 kpc set to energy 0.25 (display about 0.6), the bulge left to burn
        exposure = 0.25 / float(np.interp(7.5, R, E))
    t = db.transmission(gaussian_filter(col, 0.7), bp, None if rim is None else gaussian_filter(rim, 0.7))
    t = (1 - b[..., None]) + b[..., None] * t
    energy = (e * exposure)[..., None] * LIGHT_RGB * t
    lin = light_model.from_energy(energy, p["stretch"], p["white"])
    return Image.fromarray((np.clip(lin, 0, 1) ** (1 / 2.2) * 255 + 0.5).astype(np.uint8))


def transmission_picture(pic, bp, lo=0.8):
    """The picture from above over the same light with no dust (luminance ratio, display made linear):
    the share of light the dust lets through, drawn from `lo` (black) to 1 (white)."""
    zero = np.zeros((TOP_PX, TOP_PX), np.float32)
    clear = top_picture(zero, zero, zero if bp["law"] == "hubble" else None, bp)
    a = (np.asarray(pic.resize(clear.size), np.float32) / 255) ** 2.2 @ light_model.LUMA
    b = (np.asarray(clear, np.float32) / 255) ** 2.2 @ light_model.LUMA
    t = np.clip((a / np.maximum(b, 1e-4) - lo) / (1 - lo), 0, 1)
    return Image.fromarray((t * 255 + 0.5).astype(np.uint8)).convert("RGB")


def linear_picture(col, k):
    """The optical depth k N from above, linear 0 (pale) to 1 (dark brown), as dust_bench --face-linear."""
    t = np.clip(gaussian_filter(col, 0.7) * k, 0, 1)
    ground, dust = np.array([236, 230, 220.0]), np.array([58, 36, 22.0])
    return Image.fromarray((ground + (dust - ground) * t[..., None]).astype(np.uint8))


def crop_kpc(im, x0, y0, x1, y1, kpc=TOP_KPC):
    n = im.width
    f = lambda v: int(round((v / kpc + 0.5) * n))
    g = lambda v: int(round((0.5 - v / kpc) * n))
    return im.crop((f(x0), g(y1), f(x1), g(y0)))


# ---------------------------------------------------------------- measures from above

def polar(tau, r0, r1, dr=0.01, nphi=4096):
    """tau resampled on (R, azimuth): rows R from r0 to r1, columns azimuth 0 to 2 pi."""
    R = np.arange(r0, r1, dr)
    ph = np.arange(nphi) * 2 * np.pi / nphi
    X = R[:, None] * np.cos(ph)[None, :]
    Y = R[:, None] * np.sin(ph)[None, :]
    cx = (X / TOP_KPC + 0.5) * TOP_PX - 0.5
    cy = (0.5 - Y / TOP_KPC) * TOP_PX - 0.5
    return R, ph, map_coordinates(tau, [cy, cx], order=1, mode="constant")


def ring_extent(tau):
    """Radii where the azimuthal mean of tau stays above 15 % of its peak, and the profile."""
    R, ph, P = polar(tau, 0.5, 11.5, 0.05, 1440)
    prof = P.mean(1)
    k = prof >= 0.15 * prof.max()
    idx = np.nonzero(k)[0]
    return float(R[idx[0]]), float(R[idx[-1]]), R, prof


def structure_pitch(tau, spin, r0, r1, sd, si):
    """Pitch of the structures from above (structure tensor of log(1 + 10 tau), derivatives at sd px,
    integrated over si px): signed, positive for arcs that trail the rotation, weighted by coherent energy
    (lambda1 - lambda2). Returns weights and pitches (degrees) inside the ring."""
    f = np.log1p(10 * tau)
    f = f - gaussian_filter(f, 4 * si)                  # the ring's envelope out: its edges are not structures
    gx = gaussian_filter(f, sd, order=(0, 1))
    gy = -gaussian_filter(f, sd, order=(1, 0))          # y up
    jxx, jyy, jxy = (gaussian_filter(a, si) for a in (gx * gx, gy * gy, gx * gy))
    tr, det = jxx + jyy, jxx * jyy - jxy ** 2
    disc = np.sqrt(np.maximum(tr * tr / 4 - det, 0))
    wgt = 2 * disc                                      # lambda1 - lambda2
    ang = 0.5 * np.arctan2(2 * jxy, jxx - jyy) + np.pi / 2   # direction along the structure
    n = TOP_PX
    c = (np.arange(n) + 0.5) / n * TOP_KPC - TOP_KPC / 2
    X, Y = np.meshgrid(c, c[::-1])
    rr = np.hypot(X, Y)
    phi = np.arctan2(Y, X)
    dxs, dys = np.cos(ang), np.sin(ang)
    dR = dxs * np.cos(phi) + dys * np.sin(phi)
    dP = (-dxs * np.sin(phi) + dys * np.cos(phi)) * spin   # along the motion
    pitch = np.degrees(np.arctan2(-dR * np.sign(dP), np.abs(dP)))   # + trailing (outward while backward)
    m = (rr > r0) & (rr < r1)
    coh = float(wgt[m].sum() / max(tr[m].sum(), 1e-30))   # 0 for round speckle, 1 for parallel streaks
    # share of the structure within 15 degrees of the sky's y axis, the line of sight laid on the plane
    # (17 % for orientations at random): a texture tied to the 6 degree view, whatever the azimuth
    los = float(wgt[m][np.abs(np.cos(ang[m])) < math.sin(math.radians(15))].sum() / max(wgt[m].sum(), 1e-30))
    return wgt[m].ravel(), pitch[m].ravel(), coh, los


def wquant(x, w, q):
    o = np.argsort(x)
    c = np.cumsum(w[o])
    return float(np.interp(q * c[-1], c, x[o]))


def components(tau, r0, r1, kpp=TOP_KPC / TOP_PX, hp=0.3, pct=85, spin=1):
    """Dark structures from above: tau minus its 0.3 kpc blur above its 85th percentile in the ring,
    connected, at least 6 px. Length and width (uniform-bar equivalents, sqrt(12 lambda)), pitch."""
    f = tau - gaussian_filter(tau, hp / kpp)
    n = tau.shape[0]
    c = (np.arange(n) + 0.5) / n * TOP_KPC - TOP_KPC / 2
    X, Y = np.meshgrid(c, c[::-1])
    rr = np.hypot(X, Y)
    ring = (rr > r0) & (rr < r1)
    thr = np.percentile(f[ring], pct)
    lab, cnt = label((f > thr) & ring)
    out = []
    for i, sl in enumerate(find_objects(lab), 1):
        part = lab[sl] == i
        if part.sum() < 6:
            continue
        yy, xx = np.nonzero(part)
        wt = f[sl][part]
        px, py = (xx + sl[1].start) , (yy + sl[0].start)
        mx, my = np.average(px, weights=wt), np.average(py, weights=wt)
        cxx = np.average((px - mx) ** 2, weights=wt) + 1 / 12
        cyy = np.average((py - my) ** 2, weights=wt) + 1 / 12
        cxy = np.average((px - mx) * (py - my), weights=wt)
        tr, det = cxx + cyy, cxx * cyy - cxy ** 2
        l1 = tr / 2 + math.sqrt(max(tr * tr / 4 - det, 0))
        l2 = max(tr / 2 - math.sqrt(max(tr * tr / 4 - det, 0)), 1 / 12)
        ang = 0.5 * math.atan2(-2 * cxy, cxx - cyy)        # image y down: flip for y up
        X0, Y0 = c[0] + mx * kpp, -(c[0] + my * kpp)
        phi = math.atan2(Y0, X0)
        dR = math.cos(ang) * math.cos(phi) + math.sin(ang) * math.sin(phi)
        dP = (-math.cos(ang) * math.sin(phi) + math.sin(ang) * math.cos(phi)) * spin
        pitch = math.degrees(math.atan2(-dR * (1 if dP >= 0 else -1), abs(dP)))
        out.append((math.sqrt(12 * l1) * kpp, math.sqrt(12 * l2) * kpp, pitch, float(wt.sum())))
    return np.array(out) if out else np.zeros((0, 4))


def acf_lengths(tau, r0, r1):
    """Correlation lengths (1/e) of the 0.3 kpc high pass along the orbit and across it, kpc."""
    R, ph, P = polar(tau, r0, r1, 0.01, 4096)
    from scipy.ndimage import gaussian_filter1d
    hp = P - gaussian_filter1d(gaussian_filter1d(P, 30, axis=0, mode="nearest"), 30 * 4096 / (2 * np.pi * R.mean() / 0.01), axis=1, mode="wrap")
    F = np.fft.rfft(hp, axis=1)
    ac = np.fft.irfft(np.abs(F) ** 2, axis=1)
    ac /= np.maximum(ac[:, :1], 1e-30)
    along = []
    for i, r in enumerate(R):
        k = np.nonzero(ac[i, :2048] < 1 / math.e)[0]
        if len(k):
            along.append(k[0] * 2 * np.pi * r / 4096)
    hpc = hp - hp.mean(0)
    Fc = np.fft.rfft(np.vstack([hpc, np.zeros_like(hpc)]), axis=0)
    acr = np.fft.irfft(np.abs(Fc) ** 2, axis=0)[:len(R)]
    acr = acr.mean(1)
    acr /= acr[0]
    k = np.nonzero(acr < 1 / math.e)[0]
    across = k[0] * 0.01 if len(k) else float("nan")
    return float(np.median(along)), float(across)


def coverage(tau, r0, r1):
    """From above: the azimuthal profile of the ring's column (bins of 0.5 degree), its share of bins under
    a quarter of the median (gaps), its m = 1 and 2 amplitudes, and its highest autocorrelation at 10 to
    180 degrees (a repeat)."""
    R, ph, P = polar(tau, r0, r1, 0.02, 720)
    prof = (P * R[:, None]).sum(0)
    med = np.median(prof)
    gaps = float(np.mean(prof < 0.25 * med))
    F = np.fft.rfft(prof)
    a1, a2 = (float(2 * abs(F[m]) / abs(F[0])) for m in (1, 2))
    q = prof - prof.mean()
    ac = np.fft.irfft(np.abs(np.fft.rfft(q)) ** 2)
    ac /= ac[0]
    rep = float(ac[20:361].max())
    return dict(gaps=gaps, m1=a1, m2=a2, repeat=rep)


def above_measures(col, k, spin):
    tau = col * k
    r0, r1, R, prof = ring_extent(tau)
    out = dict(ring_r=[round(r0, 2), round(r1, 2)])
    for name, sd, si in (("pitch50", 2.0, 5.0), ("pitch200", 6.0, 20.0)):
        w, p, coh, los = structure_pitch(tau, spin, r0, r1, sd, si)
        ap = np.abs(p)
        out[name] = dict(coherence=round(coh, 3), line_of_sight=round(los, 3), median_abs=round(wquant(ap, w, 0.5), 1), trailing=round(float(w[p > 0].sum() / w.sum()), 2),
                         radial=round(float(w[ap > 45].sum() / w.sum()), 3), aligned=round(float(w[ap < 10].sum() / w.sum()), 2))
    comp = components(tau, r0, r1, spin=spin)
    if len(comp):
        L, W, P, wt = comp.T
        e = L / W
        out["structures"] = dict(n=int(len(comp)), lw_median=round(float(np.median(e)), 2),
                                 lw_p90=round(float(np.percentile(e, 90)), 1),
                                 length_median_pc=round(float(np.median(L)) * 1000), length_p90_pc=round(float(np.percentile(L, 90)) * 1000),
                                 width_median_pc=round(float(np.median(W)) * 1000),
                                 share_lw_over_10=round(float(np.mean(e > 10)), 3),
                                 long_pitch_median=round(float(np.median(np.abs(P[e > 4]))), 1) if (e > 4).any() else None,
                                 long_trailing=round(float(np.mean(P[e > 4] > 0)), 2) if (e > 4).any() else None)
    a, c = acf_lengths(tau, r0, r1)
    out["acf_pc"] = dict(along=round(a * 1000), across=round(c * 1000), ratio=round(a / c, 2))
    out["coverage"] = {kk: round(v, 3) for kk, v in coverage(tau, r0, r1).items()}
    rr = _radius_grid()
    out["tau_ring_median"] = round(float(np.median(tau[(rr > r0) & (rr < r1)])), 4)
    return out


_RG = {}


def _radius_grid():
    if "r" not in _RG:
        c = (np.arange(TOP_PX) + 0.5) / TOP_PX * TOP_KPC - TOP_KPC / 2
        _RG["r"] = np.hypot(c[None, :], c[::-1, None])
    return _RG["r"]


# ---------------------------------------------------------------- volume

def volume_measures(gm, cm, hz, total, bp, kface):
    """The layer's thickness against radius (mass-weighted rms and FWHM of z), how far its mid-plane
    moves (corrugation), and the dark clouds of the vertical cut: height over radial length."""
    zc = np.arange(-0.3, 0.3, 0.002) + 0.001
    Rb = np.arange(5.0, 10.5, 0.25) + 0.125
    rows = []
    for i, r in enumerate(Rb):
        h = hz[i]
        if h.sum() <= 0:
            continue
        m = np.average(zc, weights=h)
        s = math.sqrt(np.average((zc - m) ** 2, weights=h))
        hs = gaussian_filter(h, 1.0)
        above = np.nonzero(hs >= 0.5 * hs.max())[0]
        fw = (above[-1] - above[0] + 1) * 0.002
        rows.append((round(float(r), 3), round(s * 1000, 1), round(fw * 1000, 1), round(float(h.sum() / hz.sum()), 3)))
    C = CUT
    kpp2 = C["px"] * C["px"]
    tau = cm / total / kpp2 * 100.0 * bp["mass"] * kface   # optical depth along the arc
    ts = gaussian_filter(tau, 1.0)
    # mid-plane per 50 pc column and its spread: corrugation of what the cut sees
    zz = (C["z"] - (np.arange(ts.shape[0]) + 0.5) * C["px"])
    colm = ts.sum(0)
    ok = colm > np.percentile(colm, 30)
    zmid = (ts * zz[:, None]).sum(0)[ok] / colm[ok]
    thr = np.percentile(ts[ts > 0], 90) if (ts > 0).any() else 1
    lab, cnt = label(ts > thr)
    hl = []
    for i, sl in enumerate(find_objects(lab), 1):
        part = lab[sl] == i
        if part.sum() < 6:
            continue
        yy, xx = np.nonzero(part)
        wt = ts[sl][part]
        sx = math.sqrt(np.average((xx - np.average(xx, weights=wt)) ** 2, weights=wt) + 1 / 12)
        sy = math.sqrt(np.average((yy - np.average(yy, weights=wt)) ** 2, weights=wt) + 1 / 12)
        hl.append((sy * C["px"] * math.sqrt(12), sx * C["px"] * math.sqrt(12)))
    hl = np.array(hl) if hl else np.zeros((0, 2))
    return dict(layer=rows, corrugation_pc=round(float(np.std(zmid)) * 1000, 1),
                cut_clouds=dict(n=int(len(hl)), height_median_pc=round(float(np.median(hl[:, 0])) * 1000, 1) if len(hl) else None,
                                radial_median_pc=round(float(np.median(hl[:, 1])) * 1000, 1) if len(hl) else None,
                                h_over_radial=round(float(np.median(hl[:, 0] / hl[:, 1])), 2) if len(hl) else None))


def volume_pictures(gm, cm, total, bp):
    """Grazing view and cut as transmissions of a uniform light behind them, exp(-tau_green)."""
    G, C = GRAZE, CUT
    kg = bp["k"] * (1 + bp["redden"] * db.CHANNELS[1])
    pg = G["width"] / G["px"]
    tg = gaussian_filter(gm, 1.2) / total / pg ** 2 * 100.0 * bp["mass"] * kg
    tc = gaussian_filter(cm, 1.0) / total / C["px"] ** 2 * 100.0 * bp["mass"] * kg
    to = lambda t: Image.fromarray((np.exp(-t) ** (1 / 2.2) * 235 + 10).astype(np.uint8)).convert("RGB")
    return to(tg), to(tc), tg, tc


# ---------------------------------------------------------------- run

def load_bench(track, name):
    d = os.path.join(OUT, track, name)
    meta = json.load(open(os.path.join(d, "bench.json")))
    return d, meta["bench"], meta.get("curve"), meta


def hubble_centre(width=WIDTH):
    return hubble_ref.flat_region(hubble_ref.load(), closeup.BOXES[1], width)


def run(track, name, times, rigid, pool):
    d, bp, curve, meta = load_bench(track, name)
    path = os.path.join(d, "grains.f32")
    spin = meta["spin"]
    res = {"times": {}, "rigid": {}}
    rpath = os.path.join(d, "run.json")
    if os.path.exists(rpath):
        res = json.load(open(rpath))
    for t in times:
        key = str(t)
        t0 = time.time()
        acc = one_pass(path, ("rotate", float(t)), curve, bp, WIDTH, extras=(t == 0), pool=pool)
        im = frame_of(acc, bp)
        im.save(os.path.join(d, f"frame-{t:+d}.png"))
        hubble_ref.flat_region(hubble_ref.Source(im), closeup.BOXES[1], WIDTH).save(os.path.join(d, f"centre-{t:+d}.jpg"), quality=92)
        col, b, rim = top_columns(acc, bp)
        np.save(os.path.join(d, f"top-{t:+d}.npy"), col.astype(np.float32))
        top_picture(col, b, rim, bp).save(os.path.join(d, f"top-{t:+d}.jpg"), quality=92)
        linear_picture(col, bp["k"]).save(os.path.join(d, f"top-linear-{t:+d}.jpg"), quality=92)
        sc = texture.score(im, GRID)
        json.dump(texture.public(sc), open(os.path.join(d, f"score-{t:+d}.json"), "w"), indent=1)
        texture.panel(sc, f"{track}/{name} t {t:+d} Myr").save(os.path.join(d, f"panel-{t:+d}.jpg"), quality=85)
        above = above_measures(col, bp["k"], spin)
        res["times"][key] = dict(distance={k: round(v, 3) for k, v in sc["distance"].items()}, above=above)
        if t == 0:
            gm, cm, hz = acc["graze"]
            vol = volume_measures(gm, cm, hz, acc["w"], bp, bp["k"])
            g_im, c_im, tg, tc = volume_pictures(gm, cm, acc["w"], bp)
            g_im.save(os.path.join(d, "grazing.png"))
            c_im.save(os.path.join(d, "cut.png"))
            res["volume"] = vol
        json.dump(res, open(rpath, "w"), indent=1)
        print(f"{track}/{name} t {t:+d}: summary {sc['distance']['summary']:.2f}  pitch50 {above['pitch50']}  "
              f"({time.time() - t0:.0f} s)", flush=True)
    for t in rigid:
        for s in (-t, t):
            acc = one_pass(path, ("rigid", float(s)), curve, bp, WIDTH, pool=pool)
            im = frame_of(acc, bp)
            sc = texture.score(im, GRID)
            res["rigid"][str(s)] = {k: round(v, 3) for k, v in sc["distance"].items()}
            json.dump(res, open(rpath, "w"), indent=1)
            print(f"{track}/{name} rigid {s:+d}: summary {sc['distance']['summary']:.2f}", flush=True)
    return res


def remeasure(track, name):
    """The measures from above again, from the saved columns (top-T.npy), without drawing anything."""
    d, bp, curve, meta = load_bench(track, name)
    rpath = os.path.join(d, "run.json")
    res = json.load(open(rpath))
    for key in res["times"]:
        col = np.load(os.path.join(d, f"top-{int(key):+d}.npy"))
        res["times"][key]["above"] = above_measures(col, bp["k"], meta["spin"])
    json.dump(res, open(rpath, "w"), indent=1)


# ---------------------------------------------------------------- volume, with more grains near the flight

VOL_EXTRA = 6                  # extra realizations of the same field in the wedge (track C and B sources)
VOL_WEDGE = math.radians(12)   # half-width in azimuth about GRAZE's point: holds the slab and the cut


def _in_wedge(x, y, z):
    r = np.hypot(x, y)
    dphi = (np.arctan2(y, x) - math.radians(GRAZE["phi0"]) + np.pi) % (2 * np.pi) - np.pi
    return (np.abs(dphi) < VOL_WEDGE) & (r > CUT["r0"] - 0.2) & (r < CUT["r1"] + 0.2)


def _gen_c_seed(args):
    lo, hi, seed = args
    x, y, z, w = dct.grains_of(lo, hi, seed)
    k = _in_wedge(x, y, z)
    return x[k].astype(np.float32), y[k].astype(np.float32), z[k].astype(np.float32), w[k].astype(np.float32)


def _gen_b_seed(args):
    x, y, z, w = _gen_b(args)
    k = _in_wedge(x, y, z)
    return x[k], y[k], z[k], w[k]


def prepare_volume(track, name):
    """grains-volume.f32: the main grains in the wedge plus VOL_EXTRA realizations of the same clouds or
    field there (other leaf seeds), weights divided by the number of realizations, so the column is the
    same and the sand is finer. A grain file with no generator keeps its own grains only."""
    d, bp, curve, meta = load_bench(track, name)
    src = meta["source"]
    parts = []
    g = open_grains(os.path.join(d, "grains.f32"))
    for lo in range(0, len(g), CHUNK):
        c = np.asarray(g[lo:lo + CHUNK])
        parts.append(c[_in_wedge(c[:, 0], c[:, 1], c[:, 2])])
    extra = 0
    if src.endswith(".json") and track in ("c", "b"):
        extra = VOL_EXTRA
        if track == "c":
            par = dct.load_par([src])
            t = dct.build_table(par)
            jobs = [(lo, hi, seed + 7919 * (k + 1)) for k in range(extra) for lo, hi, seed, _, _ in dct.jobs_of(t, par, WIDTH)]
            with ProcessPoolExecutor(WORKERS, initializer=dct._init, initargs=(t, par)) as pool:
                res = list(pool.map(_gen_c_seed, jobs))
        else:
            import dust_track_b as dtb
            spec = json.load(open(src))
            spec.pop("command", None)
            spec = dict(spec, par=dict(spec.get("par", {}), law="hubble", rim=8.8, inner=round(dtb.INNER_CUT / 8.8, 4)))
            F = dtb.field(spec)
            n = 24_000_000
            nparts = max(4, -(-n // 3_000_000))
            jobs = [(F, spec, n // nparts, spec.get("seed", 1) * 1000 + 7919 * (k + 1) + i) for k in range(extra) for i in range(nparts)]
            with ProcessPoolExecutor(WORKERS) as pool:
                res = list(pool.map(_gen_b_seed, jobs))
        for x, y, z, w in res:
            a = np.zeros((len(x), 7), np.float32)
            a[:, 0], a[:, 1], a[:, 2], a[:, 3] = x, y, z, w
            parts.append(a)
    a = np.concatenate(parts)
    a[:, 3] /= extra + 1
    a.tofile(os.path.join(d, "grains-volume.f32"))
    return len(a), extra


def volume(track, name, pool):
    """The grazing view and the vertical cut at t = 0 from grains-volume.f32; the layer's profile from
    every grain (run's pass at t = 0 keeps it in run.json)."""
    d, bp, curve, meta = load_bench(track, name)
    n, extra = prepare_volume(track, name)
    vpath = os.path.join(d, "grains-volume.f32")
    full = one_pass(os.path.join(d, "grains.f32"), ("rotate", 0.0), curve, bp, 0, extras=True, pool=pool)
    acc = one_pass(vpath, ("rotate", 0.0), curve, bp, 0, extras=True, pool=pool)
    gm, cm, _ = acc["graze"]
    hz = full["graze"][2]
    vol = volume_measures(gm, cm, hz, full["w"], bp, bp["k"])
    vol["realizations"] = extra + 1
    vol["wedge_grains"] = int(n)
    g_im, c_im, tg, tc = volume_pictures(gm, cm, full["w"], bp)
    g_im.save(os.path.join(d, "grazing.png"))
    c_im.save(os.path.join(d, "cut.png"))
    rpath = os.path.join(d, "run.json")
    res = json.load(open(rpath))
    res["volume"] = vol
    json.dump(res, open(rpath, "w"), indent=1)
    print(f"{track}/{name} volume: {n} grains in the wedge, {extra + 1} realizations; layer {vol['layer'][8]}, "
          f"cut clouds {vol['cut_clouds']}", flush=True)


# ---------------------------------------------------------------- reverse recipe

def reverse(track, name, Ts, sigmas, nu, pool, src=None):
    d, bp, curve, meta = load_bench(track, name)
    path = os.path.join(d, "grains.f32")
    out = {"nu_per_myr": nu}
    rp = os.path.join(d, "reverse.json")
    if os.path.exists(rp):
        out.update(json.load(open(rp)))
        out.pop("grains", None)
    g = np.asarray(open_grains(path)[:CHUNK])
    for T in Ts:   # unwound by T then wound by T, on the grains themselves
        x, y, z = move(g, ("rotate", -float(T)), curve)
        gg = g.astype(np.float64)
        da = np.arctan2(y, x) - np.arctan2(g[:, 1], g[:, 0])   # the velocities turn with the grains
        gg[:, 0], gg[:, 1] = x, y
        gg[:, 4] = g[:, 4] * np.cos(da) - g[:, 5] * np.sin(da)
        gg[:, 5] = g[:, 4] * np.sin(da) + g[:, 5] * np.cos(da)
        x2, y2, _ = move(gg, ("rotate", float(T)), curve)
        out.setdefault("grains_max_dxy_pc", {})[str(T)] = float(np.max(np.hypot(x2 - g[:, 0], y2 - g[:, 1]))) * 1000
    if meta.get("source", "").endswith(".json") and track == "c":
        out["generator"] = reverse_c(meta["source"], Ts)
    for T, s in [(20, 0.0)] + [(20, s) for s in sigmas] + [(T, 5.0) for T in Ts if T != 20]:
        key = f"T{T}-s{s:g}"
        if key in out.get("blur", {}):
            continue
        acc = one_pass(path, ("disperse", float(T), float(s), nu, 7 + int(T)), curve, bp, WIDTH, pool=pool)
        im = frame_of(acc, bp)
        im.save(os.path.join(d, f"blur-{key}.png"))
        hubble_ref.flat_region(hubble_ref.Source(im), closeup.BOXES[1], WIDTH).save(os.path.join(d, f"blur-centre-{key}.jpg"), quality=92)
        col, b, rim = top_columns(acc, bp)
        linear_picture(col, bp["k"]).save(os.path.join(d, f"blur-top-{key}.jpg"), quality=92)
        sc = texture.score(im, GRID)
        ref = np.load(os.path.join(d, "top-+0.npy"))
        fine = fine_power(col) / fine_power(ref)
        out.setdefault("blur", {})[key] = dict(distance={k: round(v, 3) for k, v in sc["distance"].items()},
                                              fine_power_kept=[round(float(v), 3) for v in fine])
        json.dump(out, open(rp, "w"), indent=1)
        print(f"{track}/{name} {key}: summary {sc['distance']['summary']:.2f} fine power kept {out['blur'][key]['fine_power_kept']}", flush=True)
    json.dump(out, open(rp, "w"), indent=1)
    return out


def fine_power(col):
    """Power of the view from above in the ring in bands 20-40, 40-80, 80-160 pc (differences of blurs)."""
    rr = _radius_grid()
    m = (rr > 5.8) & (rr < 9.8)
    out = []
    for s in (1.0, 2.0, 4.0):
        b = gaussian_filter(col, s) - gaussian_filter(col, 2 * s)
        out.append(float((b[m] ** 2).mean()))
    return np.array(out)


def reverse_c(src, Ts):
    """Track C's own generator at -T: clump centres turned back by Omega(R) T, ages less T (a clump
    younger than T gets a negative age: it is sheared the other way). Its grains wound forwards by T are
    compared with the tuned ring's, grain for grain, on the first chunk."""
    par = dct.load_par([src])
    t = dct.build_table(par)
    out = {}
    lo, hi, seed = dct.jobs_of(t, par, WIDTH)[0][:3]
    dct._init(t, par)
    x0, y0, z0, w0 = dct.grains_of(lo, hi, seed)
    for T in Ts:
        t2 = dict(t)
        t2["a"] = t["a"] - par["spin"] * dct.omega(t["R"], par) * T
        t2["age"] = t["age"] - T
        dct._init(t2, par)
        x, y, z, w = dct.grains_of(lo, hi, seed)
        r = np.hypot(x, y)
        ph = np.arctan2(y, x) + par["spin"] * dct.omega(r, par) * T
        x, y = r * np.cos(ph), r * np.sin(ph)
        unborn = float(t["m"][t["age"] < T].sum() / t["m"].sum())
        out[str(T)] = dict(max_dxy_pc=float(np.max(np.hypot(x - x0, y - y0)) * 1000),
                           max_dz_pc=round(float(np.max(np.abs(z - z0)) * 1000), 2),
                           rms_dz_pc=round(float(np.sqrt(np.mean((z - z0) ** 2))) * 1000, 2), unborn_mass=round(unborn, 3))
    dct._init(t, par)
    return out


# ---------------------------------------------------------------- sheets

def font(n):
    return db.font(n)


def labelled(im, text, size=22, fill=(235, 235, 235), bg="black", pad=30):
    out = Image.new("RGB", (im.width, im.height + pad), bg)
    out.paste(im, (0, pad))
    ImageDraw.Draw(out).text((6, 3), text, font=font(size), fill=fill)
    return out


def grid_sheet(rows, path, gap=6, bg=(16, 16, 16)):
    wmax = max(sum(c.width for c in r) + gap * (len(r) - 1) for r in rows)
    h = sum(max(c.height for c in r) for r in rows) + gap * (len(rows) - 1)
    sheet = Image.new("RGB", (wmax, h), bg)
    y = 0
    for r in rows:
        x = 0
        for c in r:
            sheet.paste(c, (x, y))
            x += c.width + gap
        y += max(c.height for c in r) + gap
    sheet.save(path, quality=90)
    print(path, sheet.size)


def finalists(track):
    base = os.path.join(OUT, track)
    names = sorted(n for n in os.listdir(base) if os.path.exists(os.path.join(base, n, "run.json")))
    return [(n, os.path.join(base, n)) for n in names]


def sheets(track):
    fs = finalists(track)
    # from above: picture 20 kpc, linear 20 kpc, linear zoom of 4 kpc on the near side
    rows = []
    for n, d in fs:
        r = json.load(open(os.path.join(d, "run.json")))
        a = r["times"]["0"]["above"]
        meta = json.load(open(os.path.join(d, "bench.json")))
        S = 580
        pic = Image.open(os.path.join(d, "top-+0.jpg"))
        trans = transmission_picture(pic, meta["bench"])
        pic = pic.resize((S, S), Image.LANCZOS)
        trans = trans.resize((S, S), Image.LANCZOS)
        lin = Image.open(os.path.join(d, "top-linear-+0.jpg"))
        zoom = crop_kpc(lin, -2.0, -9.5, 2.0, -5.5).resize((S, S), Image.LANCZOS)
        lin = lin.resize((S, S), Image.LANCZOS)
        p50, p200, s, ac, cv = a["pitch50"], a["pitch200"], a.get("structures", {}), a["acf_pc"], a["coverage"]
        head = (f"{track}/{n}  {meta.get('label', '')[:80]}")
        nums = (f"pitch |median| {p50['median_abs']} deg at 50 pc, {p200['median_abs']} at 200 pc; trailing {p50['trailing']:.0%}; "
                f"radial (>45 deg) {p50['radial']:.1%}   structures L/W median {s.get('lw_median')} (p90 {s.get('lw_p90')}), "
                f"length {s.get('length_median_pc')} pc (p90 {s.get('length_p90_pc')})   corr. length along/across "
                f"{ac['along']}/{ac['across']} pc   gaps {cv['gaps']:.1%}  m1 {cv['m1']:.2f}")
        row = [labelled(pic, "dust over the model's light, 20 kpc", size=18),
               labelled(trans, "the same, light divided out, 0.8 (black) to 1", size=18),
               labelled(lin, "optical depth k N, linear 0-1, 20 kpc", size=18),
               labelled(zoom, "k N, 4 kpc on the near side (x -2..2, y -9.5..-5.5)", size=18)]
        band = Image.new("RGB", (sum(c.width for c in row) + 12, 64), "black")
        dr = ImageDraw.Draw(band)
        dr.text((6, 4), head, font=font(26), fill="white")
        dr.text((6, 36), nums, font=font(19), fill=(200, 200, 200))
        rows.append([band])
        rows.append(row)
    grid_sheet(rows, os.path.join(OUT, f"{track}-above.jpg"))

    # through time, from above: a 10 x 10 kpc quarter (x 0..10, y -10..0, the near right quarter)
    for kind, fname in (("top-linear", f"{track}-time.jpg"),):
        rows = []
        times = TIMES
        for n, d in fs:
            r = json.load(open(os.path.join(d, "run.json")))
            if not all(str(t) in r["times"] for t in times):
                continue
            row = []
            top = np.percentile(np.load(os.path.join(d, "top-+0.npy"))[_radius_grid() > 5], 99)
            for t in times:
                if str(t) not in r["times"]:
                    continue
                im = linear_picture(np.load(os.path.join(d, f"top-{t:+d}.npy")), 1 / top)
                im = crop_kpc(im, 0.0, -10.0, 10.0, 0.0).resize((420, 420), Image.LANCZOS)
                a = r["times"][str(t)]["above"]
                row.append(labelled(im, f"{n}  {t:+d} Myr  pitch {a['pitch50']['median_abs']:.0f} deg, trail {a['pitch50']['trailing']:.0%}", size=18))
            rows.append(row)
        head = Image.new("RGB", (900, 40), "black")
        ImageDraw.Draw(head).text((6, 6), f"track {track}: column from above through time, the near right quarter (x 0..10, y -10..0 kpc), each row scaled to its own "
                                  f"99th percentile at 0 Myr; rotation counter-clockwise",
                                  font=font(22), fill="white")
        grid_sheet([[head]] + rows, os.path.join(OUT, fname))

    # through time at Hubble's angle: centre close-ups, Hubble first
    hub = labelled(hubble_centre(), "Hubble", size=20)
    rows = [[hub]]
    for n, d in fs:
        r = json.load(open(os.path.join(d, "run.json")))
        if not all(str(t) in r["times"] for t in TIMES):
            continue
        row = []
        for t in TIMES:
            if str(t) not in r["times"]:
                continue
            im = Image.open(os.path.join(d, f"centre-{t:+d}.jpg"))
            s = r["times"][str(t)]["distance"]
            worst = sorted(((v, k) for k, v in s.items() if k not in ("summary", "colour")), reverse=True)[:2]
            row.append(labelled(im, f"{n} {t:+d} Myr  {s['summary']:.2f}  ({worst[0][1][:5]} {worst[0][0]:.1f}, {worst[1][1][:5]} {worst[1][0]:.1f})", size=17))
        rows.append(row)
    grid_sheet(rows, os.path.join(OUT, f"{track}-time-hubble.jpg"))

    # volume: grazing view and the vertical cut
    rows = []
    for n, d in fs:
        r = json.load(open(os.path.join(d, "run.json")))
        v = r.get("volume", {})
        if "realizations" not in v:
            continue
        lay = {row[0]: row for row in v.get("layer", [])}
        l7 = lay.get(7.125) or lay.get(7.375)
        cc = v.get("cut_clouds", {})
        g = Image.open(os.path.join(d, "grazing.png"))
        c = Image.open(os.path.join(d, "cut.png"))
        c = c.resize((g.width, round(c.height * g.width / c.width)), Image.LANCZOS)
        txt = (f"{n}: layer at 7 kpc rms {l7[1] if l7 else '?'} pc, FWHM {l7[2] if l7 else '?'} pc; mid-plane moves {v.get('corrugation_pc')} pc; "
               f"cut clouds {cc.get('height_median_pc')} pc high, {cc.get('radial_median_pc')} pc in radius")
        rows.append([labelled(g, txt, size=16)])
        rows.append([labelled(c, f"{n}: vertical cut", size=16)])
    head = Image.new("RGB", (1000, 74), "black")
    dr = ImageDraw.Draw(head)
    dr.text((6, 4), f"track {track}. Grazing: orthographic, {GRAZE['elev']} deg above the plane, looking along the ring's tangent at R "
            f"{GRAZE['R0']} kpc (near side),", font=font(16), fill="white")
    dr.text((6, 26), f"{GRAZE['width']} x {GRAZE['height']} kpc, a slab {GRAZE['depth']} kpc deep, light behind. Cut: R {CUT['r0']}-{CUT['r1']} kpc "
            f"(left to right) against z +-{CUT['z']} kpc,", font=font(16), fill="white")
    dr.text((6, 48), f"summed over {CUT_ARC} kpc of arc, same scale in R and z.", font=font(16), fill="white")
    grid_sheet([[head]] + rows, os.path.join(OUT, f"{track}-grazing.jpg"))


# ---------------------------------------------------------------- main

def parse_curve(s):
    if not s:
        return None
    c = dict(vc=350.0, vslope=0.0, spin=1)
    for kv in s.split(","):
        k, v = kv.split("=")
        c[k] = float(v)
    return c


def main():
    global OUT
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", choices=["prepare", "run", "volume", "reverse", "remeasure", "sheets", "all"])
    ap.add_argument("track")
    ap.add_argument("name", nargs="?")
    ap.add_argument("source", nargs="?", help="prepare: a track C parameter file, or a grain file (.f32)")
    ap.add_argument("params", nargs="*", help="prepare: key=value for the bench")
    ap.add_argument("--bench", help="prepare with a grain file: the bench parameters (JSON)")
    ap.add_argument("--curve", help="vc=350,vslope=0,spin=1: turn the grains with this curve, not their velocities")
    ap.add_argument("--times", default=",".join(str(t) for t in TIMES))
    ap.add_argument("--rigid", default="", help="run: also turn the ring rigidly by these Myr (both ways), a control")
    ap.add_argument("--T", default="10,20,40")
    ap.add_argument("--sigma", default="2,5,10")
    ap.add_argument("--nu", type=float, default=0.1, help="reverse: vertical frequency, per Myr")
    ap.add_argument("--out", help=f"output folder (default {OUT})")
    g = ap.parse_args()
    OUT = g.out or OUT
    if g.command == "sheets":
        sheets(g.track)
        return
    if g.command == "remeasure":
        for n in ([g.name] if g.name else [n for n, _ in finalists(g.track)]):
            remeasure(g.track, n)
        return
    d = os.path.join(OUT, g.track, g.name)
    os.makedirs(d, exist_ok=True)
    if g.command in ("prepare", "all"):
        t0 = time.time()
        path = os.path.join(d, "grains.f32")
        if g.source.endswith(".json") and g.track == "c":
            par = dct.load_par([g.source] + g.params)
            n = prepare_c(par, path)
            bp = dct.bench_par(dict(par, law="hubble"))
            curve = parse_curve(g.curve)
            spin = int(par["spin"])
            label = json.load(open(g.source)).get("label", "")
        elif g.source.endswith(".json") and g.track == "a":
            n, bp, label = prepare_a(g.source, g.params, path)
            curve = parse_curve(g.curve) or dict(vc=350.0, vslope=0.0, spin=1)
            spin = int(curve["spin"])
        elif g.source.endswith(".json") and g.track == "b":
            n, bp, label = prepare_b(g.source, path)
            bp.update({kv.split("=", 1)[0]: db.parse_value(kv.split("=", 1)[1]) for kv in g.params})
            curve = parse_curve(g.curve) or dict(vc=350.0, vslope=0.0, spin=1)
            spin = int(curve["spin"])
        else:
            src = np.memmap(g.source, dtype=np.float32, mode="r").reshape(-1, 7)
            n = len(src)
            if os.path.abspath(g.source) != os.path.abspath(path):
                out = np.memmap(path, dtype=np.float32, mode="w+", shape=src.shape)
                for lo in range(0, n, CHUNK):
                    out[lo:lo + CHUNK] = src[lo:lo + CHUNK]
                out.flush()
            bp = dict(db.DEFAULTS, share="depth", centre="nucleus", blur=0.15, law="hubble")
            label = ""
            if g.bench:
                data = json.load(open(g.bench))
                label = data.get("label", "")
                bp.update({k: v for k, v in data.items() if k in db.DEFAULTS})
            for kv in g.params:
                k, v = kv.split("=", 1)
                bp[k] = db.parse_value(v)
            curve = parse_curve(g.curve)
            vmax = float(np.abs(src[:100000, 4:6]).max())
            if curve is None and vmax == 0:
                curve = dict(vc=350.0, vslope=0.0, spin=1)
            spin = int(curve["spin"]) if curve else int(np.sign(np.median(grain_omega(np.asarray(src[:100000])))))
        json.dump(dict(source=g.source, label=label, bench=bp, curve=curve, spin=spin, grains=int(n)),
                  open(os.path.join(d, "bench.json"), "w"), indent=1)
        print(f"{g.track}/{g.name}: {n} grains in {time.time() - t0:.0f} s", flush=True)
    if g.command in ("run", "all", "reverse", "volume"):
        with ProcessPoolExecutor(WORKERS) as pool:
            if g.command == "volume":
                volume(g.track, g.name, pool)
            if g.command in ("run", "all"):
                times = [int(t) for t in g.times.split(",") if t]
                rigid = [int(t) for t in g.rigid.split(",") if t]
                run(g.track, g.name, times, rigid, pool)
            if g.command == "all":
                volume(g.track, g.name, pool)
            if g.command == "reverse":
                reverse(g.track, g.name, [int(t) for t in g.T.split(",")], [float(s) for s in g.sigma.split(",")], g.nu, pool)


if __name__ == "__main__":
    main()
