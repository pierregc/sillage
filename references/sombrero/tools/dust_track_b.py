#!/usr/bin/env python3
"""dust_track_b.py: Hubble's statistics imposed on the Sombrero's dust ring (#490, track B).

Hubble's near-lane apparent-opacity map (texture.py, 6144 grid, 4.3 pc a pixel) is the exemplar. The
ring is a circle of RC about the nucleus whose mid-plane is warped (a few Fourier terms of height
against azimuth) so that its centre line lands on Hubble's near lane and its inner rim on the far line.

A field is a texture X on a carrier grid, mapped by rank onto Hubble's opacity quantiles at each radius
(so the lane's profile is Hubble's), turned into the bench's column and drawn as weighted grains:

  carrier "cart"   the plane in (x, y), cells 4.3 pc x 41.3/c pc: with c = 1 a sky pixel per cell, the thin
                   layer taken literally (across the lane is radius). Faithful on the sky, but every
                   across-lane feature becomes a streak along our line of sight in the plane.
  carrier "polar"  (azimuth, radius), cells 4.35 pc along the ring x 41.3/c pc in radius: the texture
                   follows the ring. With c > 1 the plane texture is c times shorter in radius than the
                   sky implies, and the across-lane structure has to come from height (thickness `sz0`,
                   `sz1`, a corrugated mid-plane `corr`).

Textures: "gauss" (random phases, Hubble's spectrum and histogram), "hb" (Heeger-Bergen: every band of a
steerable pyramid matched in histogram), "ps" (also the bands' magnitudes, their correlation with the
parent band and the relative phase, as Portilla and Simoncelli), "quilt" (blocks of Hubble's own map,
EXEMPLAR: Hubble's pixels), "paste" (Hubble's map de-projected in place, near side only, a reference).

  dust_track_b.py SPEC.json [--width 3072|6144] [--out DIR]    # render, score, close-ups, top view
"""
import argparse
import csv
import hashlib
import json
import math
import os
import pickle
import sys
import time
from concurrent.futures import ProcessPoolExecutor

import numpy as np
from PIL import Image, ImageDraw
from scipy.ndimage import gaussian_filter, map_coordinates
from scipy.special import erfinv
from scipy.stats import qmc

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import dust_bench as D  # noqa: E402
import light_model  # noqa: E402
import texture as T  # noqa: E402

SOM = os.environ.get("SOMBRERO", os.path.expanduser("~/claude-workspace/sombrero"))  # the working folder
OUT = os.environ.get("TRACK_B_OUT", f"{SOM}/banc/490")
CLEAN = f"{SOM}/banc/487/cache/hubble-6144-clean.png"
SIN, COS = math.sin(D.INC), math.cos(D.INC)
DX, DY = D.NUCLEUS
PX = T.FRAME_KPC / 6144              # kpc, a sky pixel of the 6144 grid
ROW = PX / SIN                       # kpc of radius a sky pixel spans across the lane (41.3 pc)

R0, R1 = 4.6, 11.0                   # kpc, the polar grid
NR, NT = 312, 21504                  # 20.5 pc x 2.2 pc (at 7.4 kpc): twice the sky's pixel each way
NL = 9600                            # polar texture columns: 4.35 pc at RC
RC = 6.64                            # kpc: the near lane's centre line at theta = -90 degrees
D_IN = 1.39                          # kpc: the dense band's top edge inside the centre line (v +0.145)
U_CENTRE = 4.7                       # kpc: the score's centre region
BASE = dict(share="depth", centre="nucleus", blur=0.15, n=24_000_000, k=0.19, redden=9.0, grey=0.8)


def axes(nr=NR, nt=NT, r0=R0, r1=R1):
    """Cell centres (radii, azimuths) of a polar array; theta = -pi/2 is the near side's centre."""
    return r0 + (np.arange(nr) + 0.5) * (r1 - r0) / nr, -math.pi + (np.arange(nt) + 0.5) * 2 * math.pi / nt


def _cache(name):
    path = os.path.join(OUT, "cache", name)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    return path


def hubble_map(w=6144):
    """Hubble's near-lane apparent opacity at grid w (point sources removed), cached."""
    path = _cache(f"hubble-A-{w}.npy")
    if not os.path.exists(path):
        np.save(path, T.opacity(Image.open(CLEAN), w).A.astype(np.float32))
    return np.load(path), T.grid(w)


# ---------------------------------------------------------------- geometry: a circle on a warped plane

def _z_on(th, line, r):
    x, y = r * math.cos(th), r * math.sin(th)
    return (line(x + DX) - DY - y * SIN) / COS


_WARP = {}


def warp_coeffs(order=4):
    """Fourier coefficients of the mid-plane's height z0(theta), kpc: the ring is a circle of RC about the
    nucleus, its mid-plane rising or sinking so that the centre line lands on Hubble's near lane (theta
    -140 to -40 degrees) and the inner rim (RC - D_IN) on Hubble's far line (50 to 130 degrees). Hubble's
    lane is flatter than a 6-degree circle: read as a warp, not an ellipse, the ring stays round from above."""
    if order not in _WARP:
        th, z = [], []
        for d in range(-140, -39, 5):
            th.append(math.radians(d)); z.append(_z_on(math.radians(d), T.centre, RC))
        for d in range(50, 131, 5):
            th.append(math.radians(d)); z.append(_z_on(math.radians(d), T.far_centre, RC - D_IN))
        th, z = np.array(th), np.array(z)
        X = np.stack([np.ones_like(th)] + sum([[np.cos(k * th), np.sin(k * th)] for k in range(1, order + 1)], []), 1)
        _WARP[order] = np.linalg.lstsq(X, z, rcond=None)[0]
    return _WARP[order]


def warp(th, order=4):
    c = warp_coeffs(order)
    out = c[0] + 0 * th
    for k in range(1, order + 1):
        out = out + c[2 * k - 1] * np.cos(k * th) + c[2 * k] * np.sin(k * th)
    return out


def deproject(A, g, nr=NR, nt=NT, order=3, warped=False):
    """A (lane coords of grid g) -> (nr, nt) on the polar grid, a thin layer on the (warped) mid-plane,
    NaN where the band has no data."""
    rs, ts = axes(nr, nt)
    TH, R = np.meshgrid(ts, rs)
    x, y = R * np.cos(TH), R * np.sin(TH)
    u = x + DX
    v = y * SIN + (warp(TH) * COS if warped else 0) + DY - T.centre(u)
    ui, vi = (u - g.us[0]) / g.px, (v - g.v[0]) / g.px
    ok = (y < 0) & (ui >= 0) & (ui <= len(g.us) - 1) & (vi >= 0) & (vi <= len(g.v) - 1)
    P = map_coordinates(A, [np.clip(vi, 0, len(g.v) - 1), np.clip(ui, 0, len(g.us) - 1)], order=order)
    return np.where(ok, P, np.nan).astype(np.float32)


def quantiles_by_radius(nq=129, half=27.0):
    """Hubble's opacity quantiles at each radius of the polar grid (NR, nq), from the near half de-projected
    on the warped plane, |theta + 90| < `half` degrees. Inside the band's reach the rows repeat the
    nearest measured row, fading to nothing over 0.4 kpc beyond it."""
    path = _cache(f"rowq-{nq}-{half}-flat.npy")
    if os.path.exists(path):
        return np.load(path)
    A, g = hubble_map()
    P = deproject(A, g)
    rs, ts = axes()
    sec = np.abs(np.degrees(ts) + 90) < half
    q = np.linspace(0, 1, nq)
    Q = np.zeros((NR, nq), np.float32)
    good = np.zeros(NR, bool)
    for i in range(NR):
        row = P[i, sec]
        if np.isfinite(row).mean() > 0.95:
            Q[i], good[i] = np.quantile(row[np.isfinite(row)], q), True
    idx = np.nonzero(good)[0]
    for i in range(NR):
        if not good[i]:
            j = idx[np.argmin(np.abs(idx - i))]
            Q[i] = Q[j] * max(0.0, 1 - abs(rs[i] - rs[j]) / 0.4)
    np.save(path, Q)
    return Q


# ---------------------------------------------------------------- A (nats) -> bench column N

def a_to_n(A, par, b=0.97):
    """The column N that dims the luminance by exp(-A) under the bench's law (texture_proofs.lay does it
    for green; with `redden` 9 red dims far less than green, so luminance it is), `b` the share of light
    behind the dust (a number or an array like A): t = (1 - b) + b g(tau), g the luminance's own curve."""
    k = par["k"]
    tau = np.linspace(0, 40, 8001)[:, None]
    a_c = 1 + par["redden"] / (1 + par["grey"] * tau) * D.CHANNELS[None, :]
    g = (np.exp(-tau * a_c) @ T.LUMA)
    b = np.asarray(b, np.float32)
    t = np.exp(-np.maximum(A, 0))
    gt = np.clip((t - (1 - b)) / b, g[-1] * 1.0001, 1)
    return (np.interp(-gt, -g, tau[:, 0]) / k).astype(np.float32)


def a_to_n_hubble(A, par, b, q):
    """a_to_n under law=hubble (#500): green optical depth tau = k N (1 + 0.22 redden), red and blue a share
    of it tending to 1 in thick dust, rim class `q` (0 to 1, the share of the column in the inner rim) grey.
    Inverted on luminance for q = 0 and q = 1 and blended."""
    k = par["k"]
    tau = np.linspace(0, 40, 8001)[:, None]
    lk = par.get("leak", 0.0)
    out = []
    for rim in (False, True):
        a, t = ((par["rim_r"], par["rim_b"]), par["rim_t"]) if rim else ((par["dif_r"], par["dif_b"]), par["dif_t"])
        ratio = 1 + (np.array([a[0], 1.0, a[1]])[None, :] - 1) / (1 + tau / t)
        g = (lk + (1 - lk) * np.exp(-tau * ratio)) @ T.LUMA
        tt = np.exp(-np.maximum(A, 0))
        gt = np.clip((tt - (1 - np.asarray(b, np.float32))) / np.asarray(b, np.float32), g[-1] * 1.0001, 1)
        out.append(np.interp(-gt, -g, tau[:, 0]) / (k * (1 + par["redden"] * D.CHANNELS[1])))
    return ((1 - q) * out[0] + q * out[1]).astype(np.float32)


def share_map(par):
    """The bench's share of light behind each cell of the polar grid, on the warped mid-plane (share
    "depth", light_model.py): about 0.97-1 over the near side's centre, 0.5-0.7 at the tips, 0-0.03 on
    the far side over the core."""
    path = _cache("share-polar.npy")
    if not os.path.exists(path):
        rs, ts = axes()
        TH, R = np.meshgrid(ts, rs)
        p = D.light_params(dict(D.DEFAULTS, **par))
        out = np.stack([light_model.share(p, R[i] * np.cos(TH[i]), R[i] * np.sin(TH[i]), warp(TH[i]))
                        for i in range(NR)])
        np.save(path, out.astype(np.float32))
    return np.load(path)


# ---------------------------------------------------------------- grains

def lookup(F, r, th, interp=0):
    """F (dict: array A over radii r0..r1 by rows, the full circle by columns) at (r, theta)."""
    a = F["A"]
    nr, nt = a.shape
    ri = (r - F["r0"]) / (F["r1"] - F["r0"]) * nr - 0.5
    ti = (th + math.pi) / (2 * math.pi) * nt - 0.5
    v = map_coordinates(a, [np.clip(ri, 0, nr - 1), ti % nt], order=interp, mode="grid-wrap")
    return np.where((ri < -0.5) | (ri > nr - 0.5), 0, v).astype(np.float32)


def thickness(r, spec):
    """Gaussian sigma of the layer (kpc): `sz0` at 5.5 kpc, `sz1` at 8.8, linear between."""
    s0 = spec.get("sz0", 0.002)
    s1 = spec.get("sz1", s0)
    return s0 + (s1 - s0) * np.clip((r - 5.5) / 3.3, 0, 1)


def corrugation(spec):
    """A smooth random height field on (azimuth, radius): octaves of Gaussian-filtered noise, the first
    of rms `corr` kpc and lengths `corr_l` (along the ring) and `corr_lr` (in radius), each next octave
    half as long and `corr_gain` as tall. Returns (array, nt, nr) on a periodic-in-azimuth grid."""
    L, Lr = spec.get("corr_l", 0.1), spec.get("corr_lr", spec.get("corr_l", 0.1))
    octs, gain = spec.get("corr_oct", 1), spec.get("corr_gain", 0.5)
    cell = min(L, Lr) / 2 ** (octs - 1) / 3
    nt, nr = int(2 * math.pi * RC / cell), int((R1 - R0) / cell) + 1
    rng = np.random.default_rng(spec.get("seed", 1) * 31 + 7)
    f = np.zeros((nr, nt), np.float32)
    amp = 1.0
    for o in range(octs):
        s = [Lr / 2 ** o / cell / 2, L / 2 ** o / cell / 2]
        n = gaussian_filter(rng.standard_normal((nr, nt)).astype(np.float32), s, mode=["nearest", "wrap"])
        f += amp * n / n.std()
        amp *= gain
    return f / f.std() * spec.get("corr", 0.0)


def midplane(r, th, spec, corr=None):
    z = warp(th) if spec.get("warp", False) else 0.0 * th
    if corr is not None:
        nr, nt = corr.shape
        ri = (r - R0) / (R1 - R0) * (nr - 1)
        ti = (th + math.pi) / (2 * math.pi) * nt
        z = z + map_coordinates(corr, [ri, ti % nt], order=1, mode="grid-wrap")
    return z


def _grains(args):
    F, spec, n, seed, width = args
    par = spec["par"]
    rng = np.random.default_rng(seed)
    u = qmc.Sobol(4, scramble=True, seed=rng.integers(1 << 31)).random(n)
    r = np.sqrt(R0 * R0 + u[:, 0] * (R1 * R1 - R0 * R0))          # uniform over the annulus' area
    th = -math.pi + u[:, 1] * 2 * math.pi
    w = lookup(F, r, th, spec.get("interp", 0))
    corr = corrugation(spec) if spec.get("corr", 0) > 0 else None
    z = np.sqrt(2) * erfinv(np.clip(2 * u[:, 2] - 1, -1 + 1e-7, 1 - 1e-7)) * thickness(r, spec)
    z = (z + midplane(r, th, spec, corr)).astype(np.float32)
    x, y = r * np.cos(th), r * np.sin(th)
    return D.project(x, y, z, w, par, width), float(w.sum()), D.face_hist(x, y, w)


def render(F, spec, light, width=3072, pool=None):
    """dust_bench.render with grains drawn from the field F (bench column N): the column is scaled so
    that F's values are the sky's column on a thin layer (the plane's density over sin i)."""
    par = dict(D.DEFAULTS, **BASE, **spec.get("par", {}))
    spec = dict(spec, par=par)
    light = D.recentre(light, par)
    n = par["n"]
    parts = max(4, -(-n // 3_000_000))
    if par["share"] == "depth":
        light_model.load_table(D.light_params(par))
    jobs = [(F, spec, n // parts, spec.get("seed", 1) * 1000 + i, width) for i in range(parts)]
    res = list(pool.map(_grains, jobs)) if pool else [_grains(j) for j in jobs]
    maps = [sum(r[0][k] for r in res) for k in range(len(res[0][0]))]
    total, face = sum(r[1] for r in res), sum(r[2] for r in res)
    area = math.pi * (R1 * R1 - R0 * R0)
    par["mass"] = spec.get("gain", 1.0) * total / n * area * SIN / 100.0
    maps = [D.to_column(m, total, par, width) for m in maps]
    near, far = maps[:2]
    shares = (D.mean_share(maps[2], near), D.mean_share(maps[3], far)) if par["share"] == "depth" else None
    if par.get("law", "old") == "hubble":       # #500: the column in the inner rim (inner x rim kpc) goes grey
        im = Image.fromarray(D.attenuate(light, near, far, par, shares, tuple(maps[-2:])))
    else:
        im = Image.fromarray(D.attenuate(light, near, far, par, shares))
    im.face_column = face / total / (D.FACE_KPC / D.FACE_PX) ** 2 * 100.0 * par["mass"]
    im.par = par
    return im


_LIGHT = {}


def light(width=3072):
    if width not in _LIGHT:
        lt, _ = D.load_light("origin", width)
        _LIGHT[width] = D.clean_light(lt)
    return _LIGHT[width]


# ---------------------------------------------------------------- statistics of the exemplar

def exemplar():
    """Hubble's map over the centre (|u| < 4.7 kpc), rows flipped to grow with radius: (179, 2180)."""
    A, g = hubble_map()
    return np.ascontiguousarray(A[::-1, np.abs(g.us) < U_CENTRE]).astype(np.float32)


def standardise(E, smooth=3.0):
    mu = gaussian_filter(E.mean(1), smooth)[:, None]
    sd = gaussian_filter(E.std(1), smooth)[:, None]
    return (E - mu) / np.maximum(sd, 1e-3)


def match_hist(x, target_q):
    """Approximate histogram matching: x's own quantiles mapped piecewise-linearly onto target_q."""
    q = np.linspace(0, 1, len(target_q))
    own = np.quantile(x, q)
    own = own + np.arange(len(own)) * 1e-7 * (abs(own[-1] - own[0]) + 1e-6)
    return np.interp(x, own, target_q).astype(x.dtype)


class Pyramid:
    """J octave bands x K orientations, complex (analytic), with high and low residuals; a tight frame."""

    def __init__(self, shape, J=6, K=4):
        fy, fx = np.fft.fftfreq(shape[0])[:, None], np.fft.fftfreq(shape[1])[None, :]
        rho = np.hypot(fy, fx)
        rho[0, 0] = 1e-9
        x, al = np.log2(rho), np.arctan2(fy, fx)
        self.J, self.K = J, K
        self.h = [np.where(np.abs(x + 1 + j) < 1, np.cos(np.pi / 2 * (x + 1 + j)), 0).astype(np.float32)
                  for j in range(J)]
        d0, dl = x + 1.0, x + J
        self.hi = np.where(d0 >= 1, 1, np.where(d0 > 0, np.sin(np.pi / 2 * d0), 0)).astype(np.float32)
        self.lo = np.where(dl <= -1, 1, np.where(dl < 0, np.sin(-np.pi / 2 * dl), 0)).astype(np.float32)
        a = [np.abs(np.cos(al - k * np.pi / K)) ** (K - 1) for k in range(K)]
        s = np.sqrt(sum(ak ** 2 for ak in a))
        self.a = [(ak / s).astype(np.float32) for ak in a]
        self.m = [(2.0 * (np.cos(al - k * np.pi / K) > 0)).astype(np.float32) for k in range(K)]

    def analyse(self, X):
        F = np.fft.fft2(X.astype(np.complex64))
        return F, [[np.fft.ifft2(F * (self.h[j] * self.a[k] * self.m[k])).astype(np.complex64)
                    for k in range(self.K)] for j in range(self.J)]

    def synthesise(self, F, bands):
        acc = F * (self.hi ** 2 + self.lo ** 2)
        for j in range(self.J):
            for k in range(self.K):
                acc += np.fft.fft2(bands[j][k].real) * (self.h[j] * self.a[k])
        return np.fft.ifft2(acc).real.astype(np.float32)


def _parent(p):
    """The parent band with its phase doubled, so it oscillates at the child's frequency."""
    m = np.abs(p)
    return np.where(m > 1e-9, p * p / np.maximum(m, 1e-9), 0)


def measure_stats(X, J=6, K=4, nq=65):
    """Statistics of a standardised exemplar: pixel quantiles; per band the quantiles of the real part
    and of the magnitude, the correlation of the magnitude with the parent band's, the relative phase
    (mean of the band times conj of the phase-doubled parent, over the parent's power); the spectrum."""
    P = np.concatenate([X, X[::-1]], 0)
    P = np.concatenate([P, P[:, ::-1]], 1)
    sy, sx = slice(0, X.shape[0]), slice(0, X.shape[1])
    pyr = Pyramid(P.shape, J, K)
    F, b = pyr.analyse(P)
    q = np.linspace(0, 1, nq)
    st = {"J": J, "K": K, "pix": np.quantile(X, q), "re": {}, "mag": {}, "corr": {}, "rel": {}}
    for j in range(J):
        for k in range(K):
            c = b[j][k][sy, sx]
            st["re"][j, k], st["mag"][j, k] = np.quantile(c.real, q), np.quantile(np.abs(c), q)
            if j + 1 < J:
                p = b[j + 1][k][sy, sx]
                st["corr"][j, k] = float(np.corrcoef(np.abs(c).ravel(), np.abs(p).ravel())[0, 1])
                pt = _parent(p)
                st["rel"][j, k] = complex(np.mean(c * np.conj(pt)) / max(np.mean(np.abs(pt) ** 2), 1e-12))
    st["power"], st["pshape"] = np.abs(F) ** 2 / P.size, P.shape
    return st


_STATS = {}


BAND = (-0.28, 0.18)   # kpc, sky rows where the lane holds dust: the exemplar's rows for statistics and quilting


def gaussianised(win=None, region="centre", band=BAND):
    """The exemplar through the inverse of to_sky_profile: each pixel's rank within Hubble's local
    quantiles (its window and row), as a standard normal. What the syntheses imitate; to_sky_profile
    turns their result back into opacity, so the two transforms cancel on Hubble's own map."""
    from scipy.special import ndtri
    A, g = hubble_map()
    Q = sky_quantiles(win=win)
    nw, nv, nq = Q.shape
    cols = np.abs(g.us) < U_CENTRE if region == "centre" else np.abs(g.us) >= U_CENTRE
    wi = np.clip((g.us[cols] + T.U_MAX) / (2 * T.U_MAX) * nw - 0.5, 0, nw - 1)
    w0 = np.floor(wi).astype(int)
    w1, f = np.minimum(w0 + 1, nw - 1), (wi - np.floor(wi))[:, None]
    Z = np.empty((nv, cols.sum()), np.float32)
    for i in range(nv):
        Ql = Q[w0, i] * (1 - f) + Q[w1, i] * f                     # (cols, nq)
        a = A[i, cols][:, None]
        k = np.clip((Ql < a).sum(1), 1, nq - 1)
        lo, hi = Ql[np.arange(len(k)), k - 1], Ql[np.arange(len(k)), k]
        r = (k - 1 + np.clip((A[i, cols] - lo) / np.maximum(hi - lo, 1e-6), 0, 1)) / (nq - 1)
        Z[i] = ndtri(np.clip(r, 0.002, 0.998))
    rows = (g.v >= band[0]) & (g.v <= band[1]) if band else np.ones(nv, bool)
    return Z[rows][::-1].copy()


def stats(J=6, K=4, win=None, region="centre"):
    """Statistics of the gaussianised exemplar: the centre (|u| < 4.7 kpc) or the two tips side by side."""
    key = (J, K, win, region)
    if key not in _STATS:
        path = _cache(f"stats-{J}-{K}-{win}{'' if region == 'centre' else '-' + region}-band.pkl")
        if not os.path.exists(path):
            pickle.dump(measure_stats(gaussianised(win, region), J, K), open(path, "wb"))
        _STATS[key] = pickle.load(open(path, "rb"))
    return _STATS[key]


def spectrum_on(st, shape, smooth=2.0):
    """The exemplar's power spectrum, smoothed, read at the frequencies of a field of `shape`."""
    S = np.fft.fftshift(gaussian_filter(np.fft.fftshift(st["power"]), smooth))
    py, px = st["pshape"]
    fy = np.fft.fftfreq(shape[0])[:, None] * py
    fx = np.fft.fftfreq(shape[1])[None, :] * px
    S = np.fft.fftshift(S)
    return map_coordinates(S, [np.broadcast_to(fy + py // 2, shape), np.broadcast_to(fx + px // 2, shape)],
                           order=1, mode="constant", cval=0.0).astype(np.float32)


def gaussian_field(st, shape, rng):
    S = spectrum_on(st, shape)
    w = np.fft.fft2(rng.standard_normal(shape).astype(np.float32))
    X = np.fft.ifft2(w * np.sqrt(S)).real.astype(np.float32)
    return match_hist((X - X.mean()) / X.std(), st["pix"])


def synthesise(st, shape, rng, iters=6, mode="hb", stat_keys=("corr", "rel", "mag")):
    """Iterative synthesis on a periodic field of `shape`. "hb": Heeger-Bergen, each band's real part and
    the pixels matched to the exemplar's histograms. "ps": also (stat_keys) the magnitudes' histograms,
    their correlation with the parent band and the relative phase with it, imposed by projection."""
    J, K = st["J"], st["K"]
    X = gaussian_field(st, shape, rng)
    pyr = Pyramid(shape, J, K)
    gam = {key: 0.0 for key in st["corr"]}
    for _ in range(iters):
        F, b = pyr.analyse(X)
        orig = [[c.copy() for c in row] for row in b] if mode == "ps" else None
        for j in range(J - 1, -1, -1):
            for k in range(K):
                c = b[j][k]
                if mode == "ps" and j + 1 < J:
                    p = orig[j + 1][k]
                    if "corr" in stat_keys:
                        mp = np.abs(p)
                        cur = float(np.corrcoef(np.abs(c).ravel()[::7], mp.ravel()[::7])[0, 1])
                        gam[j, k] = float(np.clip(gam[j, k] + 1.5 * (st["corr"][j, k] - cur), -1, 3))
                        c = c * (mp / max(mp.mean(), 1e-9)) ** gam[j, k]
                    if "rel" in stat_keys:
                        pt = _parent(p)
                        c = c + (st["rel"][j, k] - np.mean(c * np.conj(pt)) /
                                 max(np.mean(np.abs(pt) ** 2), 1e-12)) * pt
                    if "mag" in stat_keys:
                        m = np.abs(c)
                        c = c * (match_hist(m, st["mag"][j, k]) / np.maximum(m, 1e-9))
                b[j][k] = (match_hist(c.real, st["re"][j, k]) + 1j * c.imag).astype(np.complex64)
        X = match_hist(pyr.synthesise(F, b), st["pix"])
    return X


# ---------------------------------------------------------------- carriers: a texture laid on the ring

CART_X = 22.08                       # kpc across, the cart carrier (5120 columns of 4.3 pc)


def cart_shape(c=1.0):
    return int(round(CART_X / (ROW / c) / 2)) * 2, 5120


def polar_shape(c=1.0):
    return int(round((R1 - R0) / (ROW / c))), NL


def carry(X, carrier, c=1.0):
    """Texture X on its carrier -> polar array (NR, NT) by linear interpolation."""
    rs, ts = axes()
    TH, R = np.meshgrid(ts, rs)
    if carrier == "cart":
        ny, nx = X.shape
        xi = (R * np.cos(TH) + CART_X / 2) / (CART_X / nx) - 0.5
        yi = (R * np.sin(TH) + ny * ROW / c / 2) / (ROW / c) - 0.5
        return map_coordinates(X, [yi, xi], order=1, mode="wrap").astype(np.float32)
    ny, nx = X.shape
    ri = (R - R0) / (ROW / c) - 0.5
    ti = (TH + math.pi) / (2 * math.pi) * nx - 0.5
    return map_coordinates(X, [np.clip(ri, 0, ny - 1), ti % nx], order=1, mode="grid-wrap").astype(np.float32)


def blend_tips(Xc, Xt, carrier, c=1.0, x0=4.2, x1=5.2):
    """The centre's texture, the tips' beyond |x| = x0 .. x1 kpc (the plane's x, the sky's u), variance kept."""
    ny, nx = Xc.shape
    if carrier == "cart":
        x = (np.arange(nx) + 0.5) * CART_X / nx - CART_X / 2
        w = np.broadcast_to(np.clip((np.abs(x) - x0) / (x1 - x0), 0, 1)[None, :], Xc.shape)
    else:
        th = -math.pi + (np.arange(nx) + 0.5) * 2 * math.pi / nx
        r = R0 + (np.arange(ny) + 0.5) * ROW / c
        x = r[:, None] * np.cos(th)[None, :]
        w = np.clip((np.abs(x) - x0) / (x1 - x0), 0, 1)
    w = w * w * (3 - 2 * w)
    return ((1 - w) * Xc + w * Xt) / np.sqrt((1 - w) ** 2 + w ** 2)


def to_profile(Xp, Q):
    """Each radius' row of the polar texture mapped by rank onto Hubble's quantiles at that radius."""
    out = np.empty_like(Xp)
    for i in range(Xp.shape[0]):
        out[i] = match_hist(Xp[i], Q[i])
    return out


WIN = 1.875          # kpc: windows along the lane for the local histograms (8 over the lane)


def sky_quantiles(nq=65, win=None, vsmooth=2.0):
    """Hubble's opacity quantiles by window along the lane (`win` kpc) and sky row, smoothed over
    `vsmooth` rows: (windows, rows, nq). Coarse on purpose: a table of 0.5 kpc windows is Hubble's map at
    that resolution and copies its strata (horizontal streaks on the ring)."""
    win = win or WIN
    path = _cache(f"skyq-{nq}-{win}-{vsmooth}.npy")
    if os.path.exists(path):
        return np.load(path)
    A, g = hubble_map()
    nw = int(round(2 * T.U_MAX / win))
    cols = np.array_split(np.arange(len(g.us)), nw)
    q = np.linspace(0, 1, nq)
    Q = np.stack([np.quantile(A[:, c], q, axis=1).T for c in cols]).astype(np.float32)
    Q = gaussian_filter(Q, [0, vsmooth, 0], mode="nearest") if vsmooth > 0 else Q
    np.save(path, Q)
    return Q


FAR_SHIFT = 0.85     # kpc: the far half reads the near side's quantiles this much further out (at theta 90),
                     # so its inner rim lands on Hubble's far line (0.45 kpc over CORE): the ring's centre
                     # sits 0.4 kpc beyond the nucleus, as the far line and the near lane's top edge ask


def edge_jitter(ts, rag, length, seed):
    """A smooth random shift of the lane's rows against azimuth (sky px, rms `rag`, correlation `length`
    kpc along the ring at RC): the profile's edges wander as Hubble's do (texture.py's edges: the upper
    edge ragged by 19 pc over 56 pc)."""
    n = 2 ** int(math.ceil(math.log2(2 * math.pi * RC / (length / 8))))
    rng = np.random.default_rng(seed * 101 + 13)
    f = gaussian_filter(rng.standard_normal(n), length / (2 * math.pi * RC / n) / 2, mode="wrap")
    f *= rag / f.std()
    return np.interp((ts + math.pi) / (2 * math.pi) * n, np.arange(n + 1), np.r_[f, f[:1]])


def to_sky_profile(Xp, fade=(9.4, 10.2), win=None, far_shift=FAR_SHIFT, far_scale=1.0, warped=False,
                   rag=0.0, rag_len=0.056, seed=1):
    """The polar texture's global rank mapped, cell by cell, onto Hubble's quantiles at the sky place the
    cell takes on the near side (its lane window and row on a thin layer over the warped mid-plane; the
    far half as its mirror image, y -> -y). One-point statistics by place: the lane's profile, depth and
    left-right difference are Hubble's, the ring becomes slightly oval where the tips ask it."""
    Q = sky_quantiles(win=win)
    nw, nv, nq = Q.shape
    g = T.grid(6144)
    rs, ts = axes(*Xp.shape)
    TH, R = np.meshgrid(ts, rs)
    far = np.sin(TH) > 0
    sn = np.sin(TH)
    rin = RC - D_IN + 0.07      # the near band's top edge (5.32 kpc): the far half's radii scale about it
    Rn = np.where(far, rin + (R + far_shift * sn - rin) * (1 + (far_scale - 1) * sn), R)
    x, y = Rn * np.cos(TH), -np.abs(Rn * np.sin(TH))
    th_near = np.arctan2(y, x)
    u = x + DX
    v = y * SIN + (warp(th_near) * COS if warped else 0) + DY - T.centre(u)
    wi = np.clip((u + T.U_MAX) / (2 * T.U_MAX) * nw - 0.5, 0, nw - 1)
    vi = (v - g.v[0]) / g.px
    if rag > 0:
        vi = vi + edge_jitter(ts, rag, rag_len, seed)[None, :]
    knots = np.quantile(Xp[::3, ::7], np.linspace(0, 1, 1025))
    rank = np.interp(Xp, knots + np.arange(1025) * 1e-9, np.linspace(0, 1, 1025)) * (nq - 1)
    Qp = np.concatenate([np.zeros((nw, 1, nq), np.float32), Q, np.zeros((nw, 1, nq), np.float32)], 1)
    A = map_coordinates(Qp, [wi, np.clip(vi + 1, 0, nv + 1), rank], order=1, mode="nearest")
    A = np.where((vi < -1) | (vi > nv), 0, A)
    return (A * np.clip((fade[1] - R) / (fade[1] - fade[0]), 0, 1)).astype(np.float32)


# ---------------------------------------------------------------- exemplar families (Hubble's pixels)

def quilt(spec, rng):
    """EXEMPLAR. Image quilting along the azimuth of Hubble's map de-projected on the warped plane:
    blocks `block` kpc of arc, full radial height, taken from the near half (|theta + 90| < `half`),
    each the best of `cands` random candidates on the overlap (`overlap` kpc) plus a penalty on source
    positions already used nearby, mirrored in azimuth with probability `flip`, shifted by up to `rshift`
    kpc in radius, joined along a minimum-error seam. Returns the polar array (NR, NT) of A."""
    A, g = hubble_map()
    P = deproject(A, g)
    rs, ts = axes()
    half = spec.get("half", 30.0)
    sec = np.nonzero(np.abs(np.degrees(ts) + 90) < half)[0]
    rows = np.isfinite(P[:, sec]).mean(1) > 0.97
    S = np.nan_to_num(P[:, sec], nan=0.0)
    S[~rows] = 0
    dt = 2 * math.pi * 7.4 / NT
    B = int(spec.get("block", 1.0) / dt)
    O = int(spec.get("overlap", 0.25) / dt)
    cands, flip, rsh = spec.get("cands", 40), spec.get("flip", 0.5), spec.get("rshift", 0.0)
    rmax = int(round(rsh / ((R1 - R0) / NR)))
    out = np.zeros((NR, NT + B), np.float32)
    used = []
    pos, first = 0, True
    while pos < NT:
        best, bscore = None, np.inf
        for _ in range(cands if not first else 1):
            s0 = rng.integers(0, S.shape[1] - B)
            blk = S[:, s0:s0 + B]
            fl = rng.random() < flip
            if fl:
                blk = blk[:, ::-1]
            sh = int(rng.integers(-rmax, rmax + 1)) if rmax else 0
            if sh:
                blk = np.roll(blk, sh, 0)
            e = 0.0 if first else float(np.mean((blk[:, :O] - out[:, pos:pos + O]) ** 2))
            e += sum(0.02 for (s, p) in used if abs(s - s0) < B and abs(p - pos) < 6 * B)
            if e < bscore:
                best, bscore, bs0 = blk, e, s0
        if first:
            out[:, :B] = best
        else:
            err = (best[:, :O] - out[:, pos:pos + O]) ** 2
            cost = err.copy()
            for i in range(1, NR):
                prev = cost[i - 1]
                m = np.minimum(prev, np.minimum(np.r_[np.inf, prev[:-1]], np.r_[prev[1:], np.inf]))
                cost[i] += m
            seam = np.zeros(NR, int)
            seam[-1] = int(np.argmin(cost[-1]))
            for i in range(NR - 2, -1, -1):
                j = seam[i + 1]
                lo, hi = max(j - 1, 0), min(j + 2, O)
                seam[i] = lo + int(np.argmin(cost[i, lo:hi]))
            mask = np.arange(O)[None, :] >= seam[:, None]
            out[:, pos:pos + O] = np.where(mask, best[:, :O], out[:, pos:pos + O])
            out[:, pos + O:pos + B] = best[:, O:]
        used.append((bs0, pos))
        pos += B - O
        first = False
    res = out[:, :NT].copy()
    # close the ring: blend the last overlap into the first columns
    w = np.linspace(0, 1, O)[None, :]
    res[:, :O] = (1 - w) * out[:, NT:NT + O] + w * res[:, :O]
    return res


def _seam(err):
    """Minimum-error path down the rows of err (rows, overlap): per row, the first column taken from the
    new block."""
    n, o = err.shape
    cost = err.copy()
    for i in range(1, n):
        p = cost[i - 1]
        cost[i] += np.minimum(p, np.minimum(np.r_[np.inf, p[:-1]], np.r_[p[1:], np.inf]))
    seam = np.zeros(n, int)
    seam[-1] = int(np.argmin(cost[-1]))
    for i in range(n - 2, -1, -1):
        j = seam[i + 1]
        lo, hi = max(j - 1, 0), min(j + 2, o)
        seam[i] = lo + int(np.argmin(cost[i, lo:hi]))
    return seam


def quilt2d(E, shape, rng, block=64, overlap=16, cands=300, flip=0.5, tol=0.1):
    """EXEMPLAR. Efros-Freeman quilting of E into a field of `shape`: square blocks, each picked at random
    among the candidates within (1 + tol) of the best overlap error, mirrored left-right with
    probability `flip`, joined along minimum-error seams. Periodic in columns (the ring)."""
    Ef = E[:, ::-1]
    step = block - overlap
    ny, nx = shape
    nby, nbx = -(-(ny - overlap) // step), -(-nx // step)
    H, W = nby * step + overlap, nbx * step + overlap
    out = np.zeros((H, W), np.float32)
    ey, ex = E.shape
    for by in range(nby):
        for bx in range(nbx):
            y0, x0 = by * step, bx * step
            cy = rng.integers(0, ey - block, cands)
            cx = rng.integers(0, ex - block, cands)
            fl = rng.random(cands) < flip
            pats = np.stack([(Ef if f else E)[a:a + block, b:b + block] for a, b, f in zip(cy, cx, fl)])
            err = np.zeros(cands)
            if bx:
                err += ((pats[:, :, :overlap] - out[y0:y0 + block, x0:x0 + overlap]) ** 2).sum((1, 2))
            if by:
                err += ((pats[:, :overlap, :] - out[y0:y0 + overlap, x0:x0 + block]) ** 2).sum((1, 2))
            ok = np.nonzero(err <= err.min() * (1 + tol) + 1e-9)[0]
            pat = pats[rng.choice(ok)]
            mask = np.ones((block, block), bool)
            if bx:
                sv = _seam((pat[:, :overlap] - out[y0:y0 + block, x0:x0 + overlap]) ** 2)
                mask[:, :overlap] &= np.arange(overlap)[None, :] >= sv[:, None]
            if by:
                sh = _seam(((pat[:overlap, :] - out[y0:y0 + overlap, x0:x0 + block]) ** 2).T)
                mask[:overlap, :] &= (np.arange(overlap)[:, None] >= sh[None, :])
            region = out[y0:y0 + block, x0:x0 + block]
            out[y0:y0 + block, x0:x0 + block] = np.where(mask, pat, region)
    res = out[:ny, :nx].copy()
    w = np.linspace(0, 1, overlap)[None, :]                     # close the ring in azimuth
    res[:, :overlap] = (1 - w) * out[:ny, nx:nx + overlap] + w * res[:, :overlap]
    return res


# ---------------------------------------------------------------- fields from a spec

FIELD_VERSION = 4
SYNTH_KEYS = ["family", "carrier", "c", "seed", "iters", "J", "K", "keys", "half", "block", "overlap",
              "cands", "flip", "rshift", "prof", "win", "tips", "tol", "far_shift", "far_scale", "rag", "rag_len"]


def texture_field(spec):
    """The ring's apparent opacity A (nats, sky values on a thin layer) on the polar grid (NR, NT)."""
    key = json.dumps(dict({k: spec.get(k) for k in SYNTH_KEYS}, _v=FIELD_VERSION), sort_keys=True)
    path = _cache("fields/" + hashlib.md5(key.encode()).hexdigest()[:12] + ".npy")
    if os.path.exists(path):
        return np.load(path)
    fam, rng = spec["family"], np.random.default_rng(spec.get("seed", 1))
    if fam == "paste":
        A, g = hubble_map()
        out = np.nan_to_num(deproject(A, g), nan=0.0)
    elif fam == "quilt":
        out = quilt(spec, rng)
    elif fam == "zquilt":     # EXEMPLAR: Hubble's gaussianised pixels quilted on a carrier, then the profile
        carrier, c = spec.get("carrier", "cart"), spec.get("c", 1.0)
        shape = cart_shape(c) if carrier == "cart" else polar_shape(c)
        E = gaussianised(spec.get("win"))
        X = quilt2d(E, shape, rng, spec.get("block", 64), spec.get("overlap", 16), spec.get("cands", 300),
                    spec.get("flip", 0.5), spec.get("tol", 0.1))
        if spec.get("tips", True):
            Xt = quilt2d(gaussianised(spec.get("win"), "tips"), shape, rng, spec.get("block", 64),
                         spec.get("overlap", 16), spec.get("cands", 300), spec.get("flip", 0.5), spec.get("tol", 0.1))
            X = blend_tips(X, Xt, carrier, c)
        Xp = carry(X, carrier, c)
        out = to_sky_profile(Xp, win=spec.get("win"), far_shift=spec.get("far_shift", FAR_SHIFT),
                             far_scale=spec.get("far_scale", 1.0), rag=spec.get("rag", 0.0),
                             rag_len=spec.get("rag_len", 0.056), seed=spec.get("seed", 1))
    else:
        carrier, c = spec.get("carrier", "cart"), spec.get("c", 1.0)
        shape = cart_shape(c) if carrier == "cart" else polar_shape(c)
        X = None
        for region in (("centre", "tips") if spec.get("tips", True) else ("centre",)):
            st = stats(spec.get("J", 6), spec.get("K", 4), spec.get("win"), region)
            if fam == "gauss":
                Xr = gaussian_field(st, shape, rng)
            else:
                Xr = synthesise(st, shape, rng, spec.get("iters", 6), fam,
                                stat_keys=spec.get("keys", ("corr", "rel", "mag")))
            if X is None:
                X = Xr
            else:                   # the tips' own statistics where the ring is seen along (|x| > 4.7 kpc)
                X = blend_tips(X, Xr, carrier, c)
        Xp = carry(X, carrier, c)
        out = (to_sky_profile(Xp, win=spec.get("win"), far_shift=spec.get("far_shift", FAR_SHIFT),
                              far_scale=spec.get("far_scale", 1.0), rag=spec.get("rag", 0.0),
                              rag_len=spec.get("rag_len", 0.056), seed=spec.get("seed", 1))
               if spec.get("prof", "sky") == "sky"
               else to_profile(Xp, quantiles_by_radius()))
    np.save(path, out.astype(np.float32))
    return out


def field(spec):
    """The bench column N on the polar grid, as lookup() takes it."""
    A = texture_field(spec)
    par = dict(D.DEFAULTS, **BASE, **spec.get("par", {}))
    b = 0.97
    if spec.get("calib", "none") == "share":    # the column Hubble's A asks for, given the light behind it
        _, ts = axes()
        bm = share_map(par)
        b = np.where(np.sin(ts)[None, :] < 0, np.clip(bm, spec.get("b_min", 0.45), 0.97), 0.97)
    A = np.maximum(A, 0) * spec.get("contrast", 1.0)
    if par.get("law", "old") == "hubble":        # the same opacity field, its column read through the new law
        rs, _ = axes()
        q = np.broadcast_to(D.rim_share(rs, par)[:, None], A.shape)
        return {"A": a_to_n_hubble(A, par, b, q), "r0": R0, "r1": R1}
    return {"A": a_to_n(A, par, b), "r0": R0, "r1": R1}


# ---------------------------------------------------------------- scoring, top view, logging

BARS = T.WINDOW_FIGS + T.LANE_FIGS


def bars_of(d):
    return {k: round(d.get(k, float("nan")), 2) for k in ["summary"] + BARS if k in d}


def score(im):
    s = T.score(im, grid_w=6144)
    return s, bars_of(s["distance"])


def sky_map(A, warped=False):
    """A polar array of A seen on a thin layer on the warped mid-plane, straight into lane coordinates
    of the 6144 grid (no grains, no light): a quick screen; the bench reads the same for a thin layer."""
    g = T.grid(6144)
    U, V = np.meshgrid(g.us, g.v)
    x, sy = U - DX, T.centre(U) + V - DY
    y = sy / SIN
    for _ in range(3 if warped else 0):
        y = (sy - warp(np.arctan2(y, x)) * COS) / SIN
    return lookup({"A": A, "r0": R0, "r1": R1}, np.hypot(x, y), np.arctan2(y, x), 1)


def quick(A, warped=False):
    s = T.score_lane(sky_map(A, warped), T.grid(6144))
    return s, bars_of(s["distance"])


def map_strip(As, path, u0=-1.5, u1=1.5, a_max=2.5, scale=1):
    """Lane maps (6144 grid) stacked over u0..u1, the core's side up, white 0 to black a_max nats."""
    g = T.grid(6144)
    cols = (g.us >= u0) & (g.us < u1)
    ims = []
    for A in As:
        t = np.clip(1 - A[::-1][:, cols] / a_max, 0, 1) ** 0.8
        im = Image.fromarray((t * 255).astype(np.uint8))
        ims.append(im.resize((im.width * scale, im.height * scale), Image.NEAREST))
    out = Image.new("L", (ims[0].width, sum(i.height + 4 for i in ims)), 0)
    y = 0
    for i in ims:
        out.paste(i, (0, y))
        y += i.height + 4
    out.save(path, quality=90)


def top_view(spec, path, label=""):
    """dust_bench.face_linear for our field: the optical depth k N seen from above (the plane's column is the
    thin layer's sky column times sin i), 20 kpc across, linear 0 to 1, read straight from the field."""
    F = field(spec)
    par = dict(D.DEFAULTS, **BASE, **spec.get("par", {}))
    c = (np.arange(D.FACE_PX) + 0.5) / D.FACE_PX * D.FACE_KPC - D.FACE_KPC / 2
    X, Y = np.meshgrid(c, -c)
    col = lookup(F, np.hypot(X, Y), np.arctan2(Y, X), 1) * SIN * spec.get("gain", 1.0)
    D.face_linear(col, par["k"], label).save(path, quality=90)


def top_zoom(A, path, cx=0.0, cy=-7.0, half=1.5, px=900):
    """The field from above, a `2 half` kpc square at 3.3 pc a pixel (A in nats, linear 0 to 2.5)."""
    xs, ys = np.linspace(cx - half, cx + half, px), np.linspace(cy + half, cy - half, px)
    X, Y = np.meshgrid(xs, ys)
    v = lookup({"A": A, "r0": R0, "r1": R1}, np.hypot(X, Y), np.arctan2(Y, X), 1)
    t = np.clip(v / 2.5, 0, 1)
    Image.fromarray((236 + (40 - 236) * t).astype(np.uint8)).save(path, quality=90)


LOG_KEYS = ["id", "family", "kind", "label", "spec", "seed", "summary"] + BARS + [
    "far_offset", "far_width", "far_depth", "width", "seconds"]


def log(row, path=None):
    path = path or os.path.join(OUT, "trials.csv")
    new = not os.path.exists(path)
    with open(path, "a", newline="") as f:
        w = csv.DictWriter(f, LOG_KEYS, extrasaction="ignore")
        if new:
            w.writeheader()
        w.writerow(row)


KIND = {"paste": "exemplar", "quilt": "exemplar", "zquilt": "exemplar", "gauss": "statistics", "hb": "statistics", "ps": "statistics"}


def run(spec, width=3072, pool=None, save=None, tid=None):
    t = time.time()
    F = field(spec)
    im = render(F, spec, light(width), width, pool)
    s, bars = score(im)
    fig = D.figures(im)
    if save:
        im.save(save)
    row = dict(id=tid, family=spec["family"] + ("-" + spec.get("carrier", "cart") if spec["family"] in
                                                ("gauss", "hb", "ps", "zquilt") else ""),
               kind=KIND[spec["family"]], label=spec.get("label", ""),
               spec=json.dumps({k: v for k, v in spec.items() if k != "label"}, sort_keys=True),
               seed=spec.get("seed", 1), **bars, far_offset=round(fig.get("far offset") or float("nan"), 3),
               far_width=round(fig.get("far width") or float("nan"), 3),
               far_depth=round(fig.get("far depth") or float("nan"), 4), width=width,
               seconds=round(time.time() - t, 1))
    if tid:
        log(row)
    return im, s, row


def contact(path, frames, labels, box=None, scale=6144):
    """The near lane's centre (closeup.py's centre box) of Hubble and of each frame, stacked, same scale."""
    import closeup
    import hubble_ref
    box = box or closeup.BOXES[1]
    srcs = [("Hubble", hubble_ref.load())] + [(lab, hubble_ref.Source(Image.open(f).convert("RGB")))
                                               for lab, f in zip(labels, frames)]
    rows = []
    for lab, src in srcs:
        im = hubble_ref.flat_region(src, box, scale)
        bar = Image.new("RGB", (im.width, 40), "black")
        ImageDraw.Draw(bar).text((8, 6), lab, font=D.font(26), fill="white")
        rows += [bar, im]
    sheet = Image.new("RGB", (rows[1].width, sum(r.height for r in rows)), "black")
    y = 0
    for r in rows:
        sheet.paste(r, (0, y))
        y += r.height
    sheet.save(path, quality=90)


INNER_CUT = RC - D_IN + 0.07     # kpc: the near band's top edge, the ring's inner cut for law=hubble (#500)


def finalist(spec, out, width=6144, law=None, frame=None):
    """Everything a finalist folder holds. `law` "hubble": drawn again with the colour law measured on
    Hubble, its inner rim at INNER_CUT (inner x rim), files suffixed -hubble-law. `frame`: an existing
    render of this spec at `width` (the frame is then only scored and sheeted, not drawn again)."""
    import shutil
    import subprocess
    os.makedirs(out, exist_ok=True)
    sfx = "-hubble-law" if law == "hubble" else ""
    if law == "hubble":
        spec = dict(spec, par=dict(spec.get("par", {}), law="hubble", rim=8.8, inner=round(INNER_CUT / 8.8, 4)))
    path = os.path.join(out, f"frame-{width}{sfx}.png")
    if frame:
        shutil.copyfile(frame, path)
        im = Image.open(path)
        s, bars = score(im)
        fig = D.figures(im)
        row = dict(bars, far_offset=fig.get("far offset"), far_width=fig.get("far width"), far_depth=fig.get("far depth"))
    else:
        with ProcessPoolExecutor(4) as pool:
            im, s, row = run(spec, width, pool, path)
    res = {k: v for k, v in s.items() if not k.startswith("_")}
    res["far"] = {k: v for k, v in s["far"].items() if not k.startswith("_")}
    res["bench_figures"] = {k: row[k] for k in ("far_offset", "far_width", "far_depth")}
    json.dump(res, open(os.path.join(out, f"texture{sfx}.json"), "w"), indent=1, default=float)
    T.panel(s, spec.get("label", "")).save(os.path.join(out, f"panel{sfx}.jpg"), quality=90)
    if not sfx:
        top_view(spec, os.path.join(out, "top.jpg"), spec.get("label", ""))
        top_zoom(texture_field(spec), os.path.join(out, "top-zoom.jpg"))
    subprocess.run([sys.executable, os.path.join(HERE, "closeup.py"), os.path.join(out, f"closeup{sfx}.jpg"), path,
                    "--labels", spec.get("label", "bench")], check=True, capture_output=True)
    return {k: row[k] for k in ["summary"] + BARS + ["far_offset", "far_width", "far_depth"] if k in row}


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("spec", nargs="?")
    p.add_argument("--width", type=int, default=6144)
    p.add_argument("--out")
    p.add_argument("--law", choices=["old", "hubble"], default="old")
    p.add_argument("--frame", help="an existing render of the spec: score and sheet it, do not draw again")
    p.add_argument("--contact", nargs="+", help="OUT.jpg then label=frame.png ...: the centres side by side")
    g = p.parse_args()
    if g.contact:
        pairs = [a.split("=", 1) for a in g.contact[1:]]
        contact(g.contact[0], [b for _, b in pairs], [a for a, _ in pairs])
        return
    spec = json.load(open(g.spec))
    spec.pop("command", None)
    print(json.dumps(finalist(spec, g.out, g.width, g.law if g.law == "hubble" else None, g.frame), default=float))


if __name__ == "__main__":
    main()
