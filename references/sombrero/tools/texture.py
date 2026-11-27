#!/usr/bin/env python3
"""texture.py FRAME [FRAME ...] [--json OUT] [--panel OUT.jpg] [--grid 3072|6144]: texture figures of
the Sombrero's near dust lane, scored against Hubble (#487).

A frame at Hubble's framing (26.5 kpc across, core at 504,312 of 1024, roll 5.63, 6 degrees from
edge on: what dust_bench.py draws) is reduced to a grid (3072 px, 8.6 pc a pixel, or 6144 px, 4.3 pc),
and its near lane unwrapped into u (kpc along the major axis, -7.5 to 7.5) and v (kpc across, from
a centre line fitted on Hubble, v > 0 towards the core). On that strip the apparent opacity
A = ln(I0 / I) is measured on linear light (display values decoded with gamma 2.2), I0 being the
light fitted across the lane on rows above and below it, the same way on every image: no model of
the dust-free galaxy enters the score.

The figures are measured in 16 windows of 0.94 kpc and pooled over two regions apart, the centre
(|u| < 4.7 kpc) and the tips (4.7 to 7.5 kpc, where the line of sight runs along the ring), plus
whole-lane figures (stationarity, symmetry). A figure's distance to Hubble is the rms, over its
components and both regions, of the difference in units of Hubble's own spread: the spread of its
windows, scaled to what an independent lane like Hubble's would show, so such a lane scores about
1 and Hubble's left half against its right half about 2 (the halves really differ). The summary is
the power mean (p = 8) of the figures' distances: close to the worst, so no figure can be traded
away against the others. Hubble's side is cached in texture-ref.json.

The far lane (the ring's far half, over the core) is unwrapped and measured the same way and
reported apart (result["far"]); it is not scored, because on Hubble it holds no structure above
the sensor grain and its depth (a few hundredths of a nat) is below the light fit's own error near
the core. See docs/notes/sombrero-dust-sheet.md.

  texture.py frame.png --json out.json --panel out.jpg
  texture.py --build-ref [--hubble PATH]      # measure Hubble again (hubble_ref.py finds the frame)

Importable: score(image, grid=None) -> dict; opacity(image, grid) -> Lane; figures(lane) -> dict;
score_lane(A, grid) for a map already in lane coordinates; panel(result, label) -> PIL image.
"""
import argparse
import json
import math
import os
import sys
import time

import numpy as np
from PIL import Image, ImageDraw, ImageFont
from scipy.ndimage import (binary_dilation, gaussian_filter, label, map_coordinates, maximum_filter,
                           median_filter)

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import hubble_ref  # noqa: E402

Image.MAX_IMAGE_PIXELS = None
REF_PATH = os.path.join(HERE, "texture-ref.json")

# ---------------------------------------------------------------- geometry

FRAME_KPC, CORE = 26.5, hubble_ref.CORE
INC, ROLL = math.radians(6), math.radians(hubble_ref.ROLL)
GAMMA = 2.2
LUMA = np.array([0.2126, 0.7152, 0.0722])
# Lane centre line, kpc under the major axis against u (kpc): a robust quartic through the dust's
# centroid on Hubble. The left tip sits lower than the right.
CENTRE = [1.24206e-05, 0.000255833, 0.00226523, -0.00935759, -0.734084]
U_MAX = 7.5
# Each side: (band across, kpc), (reference rows under and over it where the dust-free light is
# fitted), core rows |v| under this. v > 0 always points towards the core.
SIDES = {
    "near": ((-0.35, 0.42), ((-0.65, -0.35), (0.42, 0.72)), 0.20),
    # the far half of the ring, over the core: faint (A of a few hundredths), washed out by the bulge
    "far": ((-0.2, 0.2), ((-0.45, -0.2), (0.2, 0.32)), 0.12),
    # a strip 0.9 kpc further out than the far lane, dust-free: only bounds the region cleaned of points
    "control": ((-0.2, 0.2), ((-0.45, -0.2), (0.2, 0.32)), 0.12),
}
V_LO, V_HI = SIDES["near"][0]
REF_LO, REF_HI = SIDES["near"][1]
N_WIN = 16                                      # windows of 0.94 kpc along the lane
TIPS = 3                                        # windows at each end that make the tips
CORE_V = 0.20                                   # kpc: the lane's core rows, |v| under this
GRIDS = (3072, 6144)


def centre(u):
    return np.polyval(CENTRE, u)


# The far lane's centre line, kpc over the major axis: a robust quartic through the faint dips of
# Hubble's light over the core (0.4 kpc at the centre, 0.8 at the tips), weighted by their depth.
CENTRE_FAR = [0.000197103, 0.000131085, -0.00591019, 0.000413119, 0.426175]


def far_centre(u):
    return np.polyval(CENTRE_FAR, u)


def side_line(side, u):
    """sy (kpc over the major axis) of the side's centre line, and the sign that turns sy - line into
    v (towards the core)."""
    if side == "near":
        return centre(u), 1.0
    return far_centre(u) + (0.9 if side == "control" else 0.0), -1.0


class Grid:
    """The analysis grid: a frame `w` px wide, the strip's u and v, windows, regions."""

    def __init__(self, w, side="near"):
        self.side = side
        (self.v_lo, self.v_hi), (self.ref_lo, self.ref_hi), core_v = SIDES[side]
        self.w, self.h = w, round(w * 1818 / 3072)               # the bench's frame height
        self.px = FRAME_KPC / w                                   # kpc a pixel
        self.us = np.arange(-U_MAX, U_MAX, self.px)
        self.vs = np.arange(self.ref_lo[0], self.ref_hi[1] + self.px / 2, self.px)
        self.band = (self.vs >= self.v_lo) & (self.vs < self.v_hi)
        self.v = self.vs[self.band]
        self.core = np.abs(self.v) <= core_v
        self.win = np.array_split(np.arange(len(self.us)), N_WIN)
        idx = np.arange(N_WIN)
        self.regions = ({"centre": idx[TIPS:N_WIN - TIPS], "tips": np.r_[idx[:TIPS], idx[N_WIN - TIPS:]]}
                        if side == "near" else {side: idx})
        self.left = idx < N_WIN // 2

    def k(self, kpc):
        """A length in kpc as pixels of this grid."""
        return kpc / self.px

    def to_grid(self, im):
        """PIL frame -> linear RGB float32 at this grid's size."""
        im = im.convert("RGB")
        if im.size[0] != self.w:                                 # the width sets the scale
            im = im.resize((self.w, round(im.size[1] * self.w / im.size[0])), Image.LANCZOS)
        a = np.asarray(im).astype(np.float32)[:self.h]           # Hubble's frame has a row more
        if a.shape[0] < self.h:
            a = np.pad(a, ((0, self.h - a.shape[0]), (0, 0), (0, 0)), mode="edge")
        return (a / 255) ** GAMMA

    def unwrap(self, lin):
        """Linear RGB frame at this grid -> strip (len(vs), len(us), 3) in lane coordinates."""
        S, V = np.meshgrid(self.us, self.vs)
        line, sign = side_line(self.side, S)
        V = line + sign * V
        ux = S * math.cos(ROLL) + V * math.sin(ROLL)
        uy = -S * math.sin(ROLL) + V * math.cos(ROLL)
        py, px = CORE[1] * self.w - uy / self.px, CORE[0] * self.w + ux / self.px
        return np.stack([map_coordinates(lin[..., c], [py, px], order=1, mode="nearest") for c in range(3)], -1)

    def frame_coords(self):
        """For every pixel of a frame at this grid, its (v, u) position in strip pixels."""
        yy, xx = np.mgrid[0:self.h, 0:self.w].astype(np.float64)
        ux, uy = (xx - CORE[0] * self.w) * self.px, -(yy - CORE[1] * self.w) * self.px
        sx = ux * math.cos(ROLL) - uy * math.sin(ROLL)
        sy = ux * math.sin(ROLL) + uy * math.cos(ROLL)
        line, sign = side_line(self.side, sx)
        return (sign * (sy - line) - self.vs[0]) / self.px, (sx - self.us[0]) / self.px


_GRIDS = {}


def grid(w=3072, side="near"):
    if (w, side) not in _GRIDS:
        _GRIDS[w, side] = Grid(w, side)
    return _GRIDS[w, side]


def pick_grid(width):
    """The finest grid the frame can fill: 6144 for frames 6144 px wide or more, else 3072."""
    return 6144 if width and width >= 6144 else 3072


# ---------------------------------------------------------------- Hubble without its points

def clean_hubble(path=None, widths=GRIDS, max_area=40):
    """Hubble's frame at each grid width, its point sources removed at full resolution: compact
    peaks of the log light over an 11 px median (20 pc), bluer than their surroundings (the ring's
    young stars and small clusters) or very bright (globular clusters, foreground stars), replaced by
    that median. Returns ({width: PIL image}, points found). The bench draws no such points, so
    bench frames are not cleaned."""
    src = hubble_ref.load(path)
    W = src.width
    pk = FRAME_KPC / W
    us = np.linspace(-U_MAX - 0.3, U_MAX + 0.3, 60)
    xs, ys = [], []
    near, ctrl = grid(widths[0]), grid(widths[0], "control")
    for V in (centre(us) + near.vs[0] - 0.08, side_line("control", us)[0] - ctrl.vs[0] + 0.08):
        ux, uy = us * math.cos(ROLL) + V * math.sin(ROLL), -us * math.sin(ROLL) + V * math.cos(ROLL)
        xs += list(CORE[0] * W + ux / pk)
        ys += list(CORE[1] * W - uy / pk)
    x0, x1 = max(int(min(xs)) - 16, 0), min(int(max(xs)) + 16, W)
    y0, y1 = max(int(min(ys)) - 16, 0), min(int(max(ys)) + 16, src.height)
    rows = src.region((0, y0 / W, 1, y1 / W))                  # full width: resized with exact boxes
    full = np.asarray(rows).astype(np.float32) / 255
    a = full[:, x0:x1] ** GAMMA
    lg = np.log(np.maximum(a @ LUMA.astype(np.float32), 1e-5))
    med = median_filter(lg, size=11)
    exc = lg - med
    bg = np.log(np.maximum(a[..., 2], 1e-5)) - np.log(np.maximum(a[..., 1], 1e-5))
    bex = bg - median_filter(bg, size=11)
    peak = (lg == maximum_filter(lg, 5)) & (((exc > 0.3) & (bex > 0.12)) | (exc > 0.9))
    hot = np.zeros_like(peak)
    n = 0
    for y, x in zip(*np.nonzero(peak)):
        ya, xa = max(y - 8, 0), max(x - 8, 0)
        sub = exc[ya:y + 9, xa:x + 9] > 0.5 * exc[y, x]
        lab, _ = label(sub)
        blob = lab == lab[y - ya, x - xa]
        if blob.sum() <= max_area:
            hot[ya:y + 9, xa:x + 9] |= binary_dilation(blob, iterations=2)
            n += 1
    medc = np.stack([median_filter(a[..., c], size=11) for c in range(3)], -1)
    a = np.where(hot[..., None], medc, a)
    full[:, x0:x1] = np.clip(a, 0, 1) ** (1 / GAMMA)
    rows = Image.fromarray((full * 255 + 0.5).astype(np.uint8))
    out = {}
    for w in widths:
        s = W / w
        frame = src.frame(w)
        r0, r1 = math.ceil(y0 / s) + 2, math.floor(y1 / s) - 2
        part = rows.resize((w, r1 - r0), Image.LANCZOS, box=(0, r0 * s - y0, W, r1 * s - y0))
        frame.paste(part, (0, r0))
        out[w] = frame
    return out, n


# ---------------------------------------------------------------- apparent opacity

def light_fit(lg, g, smooth_u=0.25):
    """Dust-free log light across the lane: per column a quadratic in v through the reference rows
    (an upper envelope: rows dimmed by stray dust are dropped), its coefficients smoothed along u
    over 0.25 kpc so the fit's noise draws no stripes."""
    vs = g.vs
    rows = ((vs >= g.ref_lo[0]) & (vs < g.ref_lo[1])) | ((vs >= g.ref_hi[0]) & (vs < g.ref_hi[1]))
    v = vs[rows]
    X = np.stack([np.ones_like(v), v, v * v], 1)
    Y = gaussian_filter(lg, [0, g.k(0.017)])[rows]
    w = np.ones_like(Y)
    for _ in range(4):
        M = np.einsum("ri,rj,rc->cij", X, X, w)                 # weighted normal equations per column
        b = np.einsum("ri,rc->ci", X, w * Y)
        coef = np.linalg.solve(M, b[..., None])[..., 0].T       # (3, nu)
        r = Y - X @ coef
        s = 1.4826 * np.median(np.abs(r), axis=0) + 1e-3
        w = np.where(r < -2 * s, 0.05, 1.0)                     # dust only dims: drop the low rows
    coef = gaussian_filter(coef, [0, g.k(smooth_u)], mode="nearest")
    V = np.stack([np.ones_like(vs), vs, vs * vs], 1)
    return V @ coef


class Lane:
    """Apparent opacity of the near lane: A (luminance) and Ac (per channel), lane coordinates."""

    def __init__(self, strip, g):
        self.g = g
        lg = np.log(np.maximum(strip @ LUMA, 1e-6))
        self.A = (light_fit(lg, g) - lg)[g.band]
        chan = []
        for c in range(3):
            lc = np.log(np.maximum(strip[..., c], 1e-6))
            chan.append((light_fit(lc, g) - lc)[g.band])
        self.Ac = np.stack(chan, -1)
        self.strip = strip


def opacity(image, w=None, side="near", lin=None):
    """Image (PIL or path) -> Lane of that side on grid w (default: the finest the frame fills)."""
    if isinstance(image, str):
        image = Image.open(image)
    g = grid(w or pick_grid(image.size[0]), side)
    return Lane(g.unwrap(lin if lin is not None else g.to_grid(image)), g)


# ---------------------------------------------------------------- figures

PSF = 1.0           # px: one analysis blur for every image, so that the bench's 0.6 px blur and
                    # Hubble's resampling end alike; scales under 4 px are not trusted
HP_KPC = 0.1        # the high pass that leaves the speckle: A minus its 100 pc blur
SCALES = [1, 2, 4, 8]                       # px, the bands G(s) - G(2s)
P_EDGES_PC = [17, 26, 35, 52, 78, 120, 180, 280, 410, 620]
QUANT = [1, 5, 10, 25, 50, 75, 90, 95, 99]
LEVELS = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9]
DEPTHS = [0.2, 0.5, 1.0, 1.5, 3.0]          # nats, bins of A for the colour against depth


def _mom(x):
    x = x.ravel()
    m, s = x.mean(), x.std() + 1e-9
    z = (x - m) / s
    return float((z ** 3).mean()), float((z ** 4).mean() - 3)


def _spectrum(a, axis, g):
    """Mean power (log10) of a along axis in period bins (pc), after a Hann taper; bins under
    4 px or longer than half the stretch are left out, so the vector's length depends on the grid."""
    n = a.shape[axis]
    a = a - a.mean(axis=axis, keepdims=True)
    shape = [1, 1]
    shape[axis] = n
    a = a * np.hanning(n).reshape(shape)
    p = (np.abs(np.fft.rfft(a, axis=axis)) ** 2).mean(axis=1 - axis) / n
    period = n / np.maximum(np.arange(len(p)), 1e-9) * g.px * 1000
    out = []
    for lo, hi in zip(P_EDGES_PC[:-1], P_EDGES_PC[1:]):
        if lo < 4 * g.px * 1000 - 1e-6 or hi > n * g.px * 1000 / 2:
            continue
        sel = (period >= lo) & (period < hi)
        out.append(float(np.log10(p[sel].mean() + 1e-12)) if sel.any() else np.nan)
    return out


def _euler(b):
    """Euler characteristic of a binary image, 8-connected foreground (Gray's 2x2 quad counts)."""
    q = b[:-1, :-1].astype(np.int8) + b[1:, :-1] + b[:-1, 1:] + b[1:, 1:]
    diag = ((b[:-1, :-1] & b[1:, 1:] & ~b[1:, :-1] & ~b[:-1, 1:])
            | (~b[:-1, :-1] & ~b[1:, 1:] & b[1:, :-1] & b[:-1, 1:]))
    return ((q == 1).sum() - (q == 3).sum() - 2 * diag.sum()) / 4


def _perimeter(b):
    return float((b[1:] != b[:-1]).sum() + (b[:, 1:] != b[:, :-1]).sum())


def _hessian(f):
    gy, gx = np.gradient(f)
    gyy, gyx = np.gradient(gy)
    _, gxx = np.gradient(gx)
    return gxx, gyy, gyx


def _eig(gxx, gyy, gxy):
    """Hessian eigenvalues k1 >= k2 and the angle of k2's eigenvector (the direction across a ridge)."""
    tr, d = gxx + gyy, np.sqrt((gxx - gyy) ** 2 + 4 * gxy * gxy)
    k1, k2 = (tr + d) / 2, (tr - d) / 2
    ang = 0.5 * np.arctan2(2 * gxy, gxx - gyy) + np.pi / 2       # eigenvector of k2
    return k1, k2, ang


def _shape_index(f):
    """Koenderink's shape index and curvedness. On A: +1 a dark knot, -1 a clear hole, +1/2 a dark
    streak, -1/2 a clear one, 0 a saddle."""
    k1, k2, _ = _eig(*_hessian(f))
    si = (2 / np.pi) * np.arctan2(-(k1 + k2), k1 - k2 + 1e-12)
    return si, np.sqrt((k1 * k1 + k2 * k2) / 2)


def _orient(f, sigma):
    """Structure tensor of f at scale sigma (integrated over 2 sigma): coherence, angle to the lane."""
    gy, gx = np.gradient(gaussian_filter(f, sigma))
    jxx, jyy, jxy = (gaussian_filter(x, 2 * sigma) for x in (gx * gx, gy * gy, gx * gy))
    tr = jxx + jyy + 1e-12
    coh = np.sqrt((jxx - jyy) ** 2 + 4 * jxy ** 2) / tr
    ang = 0.5 * np.arctan2(2 * jxy, jxx - jyy) + np.pi / 2
    return coh, ang, tr


def _circ(ang, w):
    """Weighted mean |angle| to the lane (deg, 0-90) and spread (deg) of axial angles."""
    c = (w * np.exp(2j * ang)).sum() / (w.sum() + 1e-12)
    spread = math.degrees(0.5 * math.sqrt(max(-2 * math.log(max(abs(c), 1e-9)), 0)))
    folded = np.abs(np.degrees((ang + np.pi / 2) % np.pi - np.pi / 2))
    return float((w * folded).sum() / (w.sum() + 1e-12)), spread


def _acf_len(r, axis):
    """Length (px) where the autocorrelation of r along axis first falls under 1/e."""
    n = r.shape[axis]
    f = np.fft.rfft(r - r.mean(axis=axis, keepdims=True), n=2 * n, axis=axis)
    ac = np.fft.irfft(np.abs(f) ** 2, axis=axis).mean(axis=1 - axis)[:n]
    ac = ac / (ac[0] + 1e-12)
    below = np.nonzero(ac < 1 / math.e)[0]
    if not len(below):
        return float(n)
    k = below[0]
    return float(k - 1 + (ac[k - 1] - 1 / math.e) / (ac[k - 1] - ac[k] + 1e-12))


def _components(mask):
    """Connected parts of mask: pixel count, second moments (yy, xx, xy) per part."""
    lab, n = label(mask, structure=np.ones((3, 3)))
    if not n:
        return None
    ys, xs = np.nonzero(lab)
    ls = lab[ys, xs]
    cnt = np.bincount(ls, minlength=n + 1)[1:].astype(float)
    my = np.bincount(ls, ys, n + 1)[1:] / cnt
    mx = np.bincount(ls, xs, n + 1)[1:] / cnt
    dy, dx = ys - my[ls - 1], xs - mx[ls - 1]
    syy = np.bincount(ls, dy * dy, n + 1)[1:] / cnt + 1 / 12
    sxx = np.bincount(ls, dx * dx, n + 1)[1:] / cnt + 1 / 12
    sxy = np.bincount(ls, dx * dy, n + 1)[1:] / cnt
    tr, det = sxx + syy, sxx * syy - sxy ** 2
    root = np.sqrt(np.maximum(tr ** 2 / 4 - det, 0))
    l1, l2 = tr / 2 + root, np.maximum(tr / 2 - root, 1 / 12)
    return cnt, l1, l2, 0.5 * np.arctan2(2 * sxy, sxx - syy)


def _edges(a, g):
    """Per column: the top (towards the core) and bottom edges of the lane at half its peak, and
    the 25-75 % rise of each edge, px."""
    a = gaussian_filter(a, [1, g.k(0.017)])
    n = a.shape[0]
    peak = a.max(axis=0)
    out = {}
    for name, rows in (("top", np.arange(n)[::-1]), ("bottom", np.arange(n))):
        s = a[rows]
        pos = {}
        for f in (0.25, 0.5, 0.75):
            k = np.argmax(s >= f * peak, axis=0)
            prev = s[np.maximum(k - 1, 0), np.arange(s.shape[1])]
            cur = s[k, np.arange(s.shape[1])]
            pos[f] = k - 1 + np.clip((f * peak - prev) / np.maximum(cur - prev, 1e-9), 0, 1)
        out[name] = (pos[0.5], pos[0.75] - pos[0.25])
    return out


def _filaments(A, g):
    """Dark ridges of A: at each pixel the scale (1, 2 or 4 px) where the scale-normalised ridge
    strength s^1.5 max(-k2, 0) is largest (Lindeberg's gamma 3/4, which picks a ridge's width), kept where it is line-like (|k1| under a third of |k2|)
    and among the strongest fifth. Returns: share of the strongest fifth that is line-like, share of
    ridge pixels at each scale (their thickness), median and 90th percentile length (log10 pc),
    median thickness (pc), mean |angle| and spread (deg), share of ridge area in parts longer than
    150 pc (a web rather than flecks)."""
    best, scale, line, ang = None, None, None, None
    for i, s in enumerate((1, 2, 4)):
        k1, k2, an = _eig(*_hessian(gaussian_filter(A, s)))
        r = s ** 1.5 * np.maximum(-k2, 0)
        lk = np.abs(k1) < np.abs(k2) / 3
        if best is None:
            best, scale, line, ang = r, np.zeros(r.shape, int), lk, an
        else:
            up = r > best
            best, scale = np.where(up, r, best), np.where(up, i, scale)
            line, ang = np.where(up, lk, line), np.where(up, an, ang)
    best, scale, line, ang = best[g.core], scale[g.core], line[g.core], ang[g.core]
    strong = best > np.quantile(best, 0.8)
    ridge = strong & line
    out = [float(ridge.sum() / max(strong.sum(), 1))]
    out += [float((scale[ridge] == i).sum() / max(ridge.sum(), 1)) for i in range(3)]
    comp = _components(ridge)
    if comp is None:
        return out + [np.nan] * 6
    cnt, l1, l2, _ = comp
    length = np.sqrt(12 * l1) * g.px * 1000
    keep = cnt >= 3
    m_ang, spread = _circ(ang[ridge] + np.pi / 2, best[ridge])      # along the ridge
    out += [float(np.log10(np.median(length[keep]))), float(np.log10(np.percentile(length[keep], 90))),
            float(np.median((cnt / np.maximum(np.sqrt(12 * l1), 1))[keep]) * g.px * 1000), m_ang, spread,
            float(cnt[length > 150].sum() / cnt.sum())]
    return out


def window_figures(A, g, Ac=None):
    """The figures of one window (rows of the band, a stretch of columns). Each is a list."""
    core = g.core
    hp_px = g.k(HP_KPC)
    a = gaussian_filter(A, PSF)
    hp = a - gaussian_filter(a, hp_px)
    f = {}
    f["spectrum along"] = _spectrum(a[core], 1, g)
    prof = a.mean(axis=1, keepdims=True)
    f["spectrum across"] = _spectrum(a - prof, 0, g)
    f["histogram"] = [float(x) for x in np.percentile(a[core], QUANT)]
    bands = [gaussian_filter(A, s) - gaussian_filter(A, 2 * s) for s in SCALES]
    # fourth and third moments of the speckle at 100 pc, of two bands and of their slope across:
    # their Gaussian values (0) hold for any Gaussian-phase field, whatever its spectrum
    mom = [_mom(hp[core])] + [_mom(b[core]) for b in bands[1:3]]
    f["phase"] = [m[1] for m in mom] + [_mom(np.gradient(b, axis=0)[core])[1] for b in bands[1:3]]
    f["skewness"] = [m[0] for m in mom] + [_mom(bands[0][core])[0]]
    it = []
    for s, b in zip(SCALES[:3], bands[:3]):
        e = b * b
        for L in (4, 8):
            E = gaussian_filter(e, L * s)[core]
            it.append(math.log10(E.std() / (E.mean() + 1e-12) + 1e-9))
    f["intermittency"] = it
    sh = []
    for s in (1, 2, 4):
        si, cv = _shape_index(gaussian_filter(A, s))
        si, w = si[core], cv[core] / (cv[core].sum() + 1e-12)
        sh += [float(w[si < -5 / 8].sum()), float(w[(np.abs(si) > 3 / 8) & (np.abs(si) < 5 / 8)].sum()),
               float(w[si > 5 / 8].sum())]
    f["shape"] = sh
    f["filaments"] = _filaments(A, g)
    ms = []
    for b1, b2 in zip(bands[:-1], bands[1:]):
        ms.append(float(np.corrcoef(np.abs(b1[core]).ravel(), np.abs(b2[core]).ravel())[0, 1]))
    for b1, b2 in zip(bands[:-1], bands[1:]):
        ms.append(float(np.corrcoef(b1[core].ravel(), np.abs(b2[core]).ravel())[0, 1]))
    f["multiscale"] = ms
    h = hp[core]
    qs = np.quantile(h, LEVELS)
    area = h.size * g.px ** 2
    f["minkowski"] = ([_perimeter(h > t) * g.px / area for t in qs] + [_euler(h > t) / area / 100 for t in qs])
    comp = _components(h > qs[-1])                     # dark blobs: the top tenth of the speckle
    if comp is not None:
        cnt, l1, l2, ang = comp
        big = cnt >= 3
        el = np.sqrt(l1 / l2)[big]
        ar = cnt[big] * (g.px * 1000) ** 2
        m_ang, spread = _circ(ang[big], cnt[big])
        f["blobs"] = [math.log10(big.sum() / area + 1e-3), float(np.log10(np.median(ar))),
                      float(np.log10(np.percentile(ar, 90))), float(np.median(el)), float(np.percentile(el, 90)),
                      m_ang, spread]
    else:
        f["blobs"] = [np.nan] * 7
    an = []
    for s in (1, 2, 4):
        coh, ang, tr = _orient(hp[core], s)
        m_ang, spread = _circ(ang, tr * coh)
        an += [float(np.average(coh, weights=tr)), m_ang, spread]
    an += [math.log10(_acf_len(hp[core], 1) * g.px * 1000),
           math.log10(_acf_len(hp - hp.mean(1, keepdims=True), 0) * g.px * 1000)]
    f["anisotropy"] = an
    # strata: peaks of 0.06 nats or more in the across profile of 0.47 kpc stretches; how much of
    # the residual holds along 0.1 and 0.3 kpc; autocorrelation across at 17 to 140 pc
    res = a - prof
    counts = []
    reach = max(int(round(g.k(0.1))), 2)
    for part in np.array_split(np.arange(A.shape[1]), 2):
        p = gaussian_filter(a[:, part].mean(axis=1), g.k(0.013))
        k = 0
        for i in range(2, len(p) - 2):
            if p[i] == p[max(i - 2, 0):i + 3].max():
                lo = max(p[max(i - reach, 0):i].min(), p[i + 1:i + reach + 1].min())
                k += p[i] - lo >= 0.06
        counts.append(k)
    st = [float(np.mean(counts))]
    tot = res.var() + 1e-12
    for s_kpc in (0.1, 0.3):
        st.append(float(gaussian_filter(res, [0, g.k(s_kpc)]).var() / tot))
    rr = res - res.mean(axis=0, keepdims=True)
    for lag_pc in (17, 35, 70, 140):
        lag = max(int(round(g.k(lag_pc / 1000))), 1)
        x, y = rr[:-lag], rr[lag:]
        st.append(float((x * y).sum() / np.sqrt((x * x).sum() * (y * y).sum() + 1e-12)))
    f["strata"] = st
    e = _edges(a, g)
    ed = []
    for name in ("top", "bottom"):
        pos, width = e[name]
        r = pos - gaussian_filter(pos, g.k(0.3), mode="nearest")
        ac = np.correlate(r - r.mean(), r - r.mean(), "full")[len(r) - 1:]
        ac = ac / (ac[0] + 1e-12)
        below = np.nonzero(ac < 1 / math.e)[0]
        ed += [float(np.median(width) * g.px * 1000), float(r.std() * g.px * 1000),
               float((below[0] if len(below) else len(r)) * g.px * 1000)]
    ed += [float(np.median(e["top"][0]) * g.px * 1000), float(np.median(e["bottom"][0]) * g.px * 1000)]
    f["edges"] = ed
    f["profile"] = [float(x) for x in np.interp(np.linspace(g.v_lo, g.v_hi, 13), g.v, a.mean(axis=1))]
    if Ac is not None:
        c = gaussian_filter(Ac, [PSF, PSF, 0])[core]
        depth = a[core]
        col = []
        for k in (1, 2):
            ex = c[..., k] - c[..., 0]
            for lo, hi in zip(DEPTHS[:-1], DEPTHS[1:]):
                sel = (depth >= lo) & (depth < hi)
                col.append(float(np.median(ex[sel])) if sel.sum() > 20 else np.nan)
        f["colour"] = col
    return f


def _speckle(A, g):
    """The core rows' speckle with what every column shares (the lane's profile) taken out: the
    high pass minus its own running mean along the lane over 1 kpc."""
    a = gaussian_filter(A, PSF)
    hp = a - gaussian_filter(a, g.k(HP_KPC))
    hp = hp - gaussian_filter(hp, [0, g.k(1.0)], mode="nearest")
    return hp[g.core]


def _stationarity(rows, left):
    """Window statistics -> their spread along the lane and the left-right difference."""
    spread = list(rows.std(axis=0))
    lr = list(np.abs(rows[left].mean(axis=0) - rows[~left].mean(axis=0)))
    return [float(x) for x in spread + lr]


def lane_figures(A, g):
    """Whole-lane figures: how window statistics move along the lane and left against right
    (mean opacity of the core, contrast at 35 and 70 pc, width at half depth), and whether one
    part repeats another (mirror correlation, highest along-correlation at lags of 1 to 7 kpc)."""
    a = gaussian_filter(A, PSF)
    b2 = gaussian_filter(A, 2) - gaussian_filter(A, 4)
    b4 = gaussian_filter(A, 4) - gaussian_filter(A, 8)
    rows = []
    for w in g.win:
        p = a[:, w].mean(axis=1)
        rows.append([a[g.core][:, w].mean(), math.log10(b2[g.core][:, w].std() + 1e-9),
                     math.log10(b4[g.core][:, w].std() + 1e-9), (p >= p.max() / 2).sum() * g.px * 1000])
    rows = np.array(rows)
    s = _speckle(A, g)
    n = s.shape[1]
    mid = n // 2
    left, right = s[:, :mid], s[:, n - mid:][:, ::-1]
    mirror = float((left * right).sum() / np.sqrt((left ** 2).sum() * (right ** 2).sum()))
    f = np.fft.rfft(s - s.mean(axis=1, keepdims=True), n=2 * n, axis=1)
    ac = np.fft.irfft(np.abs(f) ** 2, axis=1).sum(axis=0)[:n] / np.arange(n, 0, -1)
    ac = ac / ac[0]
    lags = np.arange(n) * g.px
    sel = (lags >= 1.0) & (lags <= 7.0)
    return {"stationarity": _stationarity(rows, g.left), "symmetry": [mirror, float(ac[sel].max())],
            "_windows": rows.tolist(), "_acf_sd": float(ac[sel].std())}


WINDOW_FIGS = ["spectrum along", "spectrum across", "histogram", "phase", "skewness", "intermittency", "shape",
               "filaments", "multiscale", "minkowski", "blobs", "anisotropy", "strata", "edges", "profile", "colour"]
LANE_FIGS = ["stationarity", "symmetry"]
POWER = 8           # the summary is the power mean of the figures' distances, close to the worst
UNSUMMED = ["colour"]   # set by the bench's colour model and Hubble's colour processing: shown, not summed


def figures(lane, Ac=None, g=None):
    """All figures of a Lane (or of a map A with grid g): per window, pooled per region, whole lane."""
    if isinstance(lane, Lane):
        A, Ac, g = lane.A, lane.Ac, lane.g
    else:
        A = lane
    per = [window_figures(A[:, w], g, None if Ac is None else Ac[:, w]) for w in g.win]
    names = [k for k in WINDOW_FIGS if k in per[0]]
    win = {k: np.array([p[k] for p in per], float) for k in names}
    out = {"windows": {k: v.tolist() for k, v in win.items()}, "regions": {}}
    for r, idx in g.regions.items():
        out["regions"][r] = {k: [float(x) for x in np.nanmean(v[idx], axis=0)] for k, v in win.items()}
    out["lane"] = lane_figures(A, g)
    return out


# ---------------------------------------------------------------- reference and distances

def _jackknife(rows, left):
    rows = np.array(rows)
    n = len(rows)
    reps = np.array([_stationarity(np.delete(rows, i, 0), np.delete(left, i)) for i in range(n)])
    return np.sqrt((n - 1) / n * ((reps - reps.mean(axis=0)) ** 2).sum(axis=0))


def _mirror_null(A, g):
    """Spread of the left-right speckle correlation when the halves are not mirror images: the
    right half mirrored and slid by 0.5 to 3 kpc against the left."""
    s = _speckle(A, g)
    n = s.shape[1]
    mid = n // 2
    left, right = s[:, :mid], s[:, n - mid:][:, ::-1]
    cs = []
    for k in range(int(g.k(0.5)), int(g.k(3.0)), max(int(g.k(0.06)), 1)):
        lft, rgt = left[:, k:], right[:, :mid - k]
        cs.append((lft * rgt).sum() / np.sqrt((lft ** 2).sum() * (rgt ** 2).sum()))
    return float(np.std(cs))


def build_reference(lane):
    """Hubble's figures and spreads on one grid, as stored in texture-ref.json."""
    g = lane.g
    fig = figures(lane)
    win = {k: np.array(v, float) for k, v in fig["windows"].items()}
    sigma, halves = {}, {"left/right": {}, "odd/even": {}}
    for r, idx in g.regions.items():
        n = len(idx)
        sigma[r] = {}
        for k, v in win.items():
            sd = np.nanstd(v[idx], axis=0, ddof=1) * math.sqrt(2 / n)   # an independent region of n windows
            floor = np.maximum(0.05 * np.abs(np.nanmean(v[idx], axis=0)), 1e-3)
            sigma[r][k] = [float(x) for x in np.maximum(sd, floor)]
        lr = g.left[idx]
        odd = np.arange(n) % 2 == 1
        for name, sel in (("left/right", lr), ("odd/even", odd)):
            halves[name][r] = {k: [np.nanmean(v[idx][sel], axis=0).tolist(), np.nanmean(v[idx][~sel], axis=0).tolist()]
                               for k, v in win.items()}
    st = np.array(fig["lane"]["stationarity"])
    jk = _jackknife(fig["lane"]["_windows"], g.left)
    lane_sigma = {"stationarity": [float(x) for x in np.maximum(jk * math.sqrt(2), np.maximum(0.05 * np.abs(st), 1e-3))],
                  "symmetry": [_mirror_null(lane.A, g), fig["lane"]["_acf_sd"]]}
    return {"grid_px": g.w, "grid_pc": g.px * 1000, "regions": fig["regions"],
            "lane": {k: fig["lane"][k] for k in LANE_FIGS}, "sigma": sigma, "lane_sigma": lane_sigma,
            "halves": halves, "windows": fig["lane"]["_windows"]}


def grain_ratio(lane):
    """Per band G(s) - G(2s), s = 1, 2, 4, 8, 16 px: the rms of log light in the lane's core rows
    over its rms in the reference rows (bulge and grain alone). About 1 or less: the lane holds no
    structure above the grain at that scale."""
    g = lane.g
    lg = np.log(np.maximum(lane.strip @ LUMA, 1e-6))
    vs = g.vs
    core = g.band & (np.abs(vs) <= SIDES[g.side][2])
    ref = ((vs >= g.ref_lo[0]) & (vs < g.ref_lo[1])) | ((vs >= g.ref_hi[0]) & (vs < g.ref_hi[1]))
    out = {}
    for s in (1, 2, 4, 8, 16):
        b = gaussian_filter(lg, s) - gaussian_filter(lg, 2 * s)
        out[f"{s} px"] = float(b[core].std() / (b[ref].std() + 1e-12))
    return out


def far_reference(far):
    """The far lane's reference. Its texture figures count only at scales where the lane holds
    more than the grain (grain_ratio 1.5 or more); its depth, width and offset only if they stand
    clear of the light fit's own error near the core, which texture_proofs.py measures on the
    dust-free bench light. On Hubble neither holds (see sombrero-dust-sheet.md), so no far figure
    is scored: `measurable` is empty and score() reports the far lane's map and profile only."""
    ref = build_reference(far)
    ref["grain_ratio"] = grain_ratio(far)
    texture_ok = [k for k, v in ref["grain_ratio"].items() if v >= 1.5]
    ref["measurable"] = [] if not texture_ok else ["spectrum along", "phase", "shape", "filaments"]
    ref["profile"] = ref["regions"]["far"]["profile"]
    return ref


_REF = {}


def reference(path=REF_PATH):
    if path not in _REF:
        _REF[path] = json.load(open(path))
    return _REF[path]


def distances(regions, lane=None, ref=None, figs=None):
    """Per figure the rms over its components and regions of (value - Hubble) / spread, with the
    signed z of every component; the summary is their power mean over the summed figures."""
    out, z, per_region = {}, {}, {r: {} for r in ref["regions"]}
    for k in (figs or WINDOW_FIGS):
        zs = []
        for r in ref["regions"]:
            if k not in regions.get(r, {}) or k not in ref["regions"][r]:
                continue
            h = np.array(ref["regions"][r][k], float)
            d = (np.array(regions[r][k], float) - h) / np.array(ref["sigma"][r][k], float)
            d = np.where(np.isfinite(h), np.where(np.isfinite(d), d, 10.0), np.nan)
            d = d[np.isfinite(d)]
            per_region[r][k] = float(np.sqrt(np.mean(d ** 2))) if len(d) else float("nan")
            zs += list(d)
        if zs:
            z[k] = [float(x) for x in zs]
            out[k] = float(np.sqrt(np.mean(np.square(zs))))
    if lane:
        for k in LANE_FIGS:
            d = (np.array(lane[k], float) - np.array(ref["lane"][k], float)) / np.array(ref["lane_sigma"][k])
            z[k] = [float(x) for x in d]
            out[k] = float(np.sqrt(np.mean(d ** 2)))
    summed = [v for k, v in out.items() if k not in UNSUMMED]
    out["summary"] = float(np.mean(np.array(summed) ** POWER) ** (1 / POWER))
    return out, z, per_region


def score_lane(lane, g=None, ref=None):
    """Scores a Lane, or a map A in lane coordinates of grid g (Ac then absent: no colour)."""
    g = lane.g if isinstance(lane, Lane) else g
    ref = ref or reference()["grids"][str(g.w)]
    fig = figures(lane, g=g)
    d, z, per = distances(fig["regions"], fig["lane"], ref)
    return {"distance": d, "regions": per, "z": z, "figures": fig["regions"],
            "lane": {k: fig["lane"][k] for k in LANE_FIGS}, "grid": g.w,
            "_lane": lane if isinstance(lane, Lane) else None, "_A": lane.A if isinstance(lane, Lane) else lane}


def score_far(far, ref):
    """The far lane, apart from the near lane: scored on its measurable figures, or, when Hubble's
    far lane holds none (the case today), only described: profile, mean depth, grain ratio."""
    fig = figures(far)
    out = {"measurable": ref["measurable"], "profile": fig["regions"]["far"]["profile"],
           "mean": float(far.A[far.g.core].mean()), "grain_ratio": grain_ratio(far), "_A": far.A}
    if ref["measurable"]:
        out["distance"], out["z"], _ = distances(fig["regions"], None, ref, ref["measurable"])
    else:
        out["distance"] = None
        out["note"] = ("not scored: on Hubble the far lane holds no structure above the grain and its depth is "
                       "below the light fit's error near the core")
    return out


def score(image, grid_w=None, ref_path=REF_PATH):
    """Image (PIL or path) -> dict: distance per figure and summary, per region, every
    component's z, the figures. Takes about a second at 3072 and three at 6144."""
    t = time.time()
    if isinstance(image, str):
        image = Image.open(image)
    width = image.size[0]
    w = grid_w or pick_grid(width)
    ref = reference(ref_path)["grids"][str(w)]
    lin = grid(w).to_grid(image)
    out = score_lane(opacity(image, w, lin=lin), ref=ref)
    far = opacity(image, w, "far", lin=lin)
    out["far"] = score_far(far, ref["far"])
    out["width"] = width
    out["warning"] = (f"frame {width} px wide, scored on the {w} grid: its finest scales are missing"
                      if width < w else None)
    out["seconds"] = round(time.time() - t, 2)
    return out


def build(path=None, ref_path=REF_PATH, cache=None):
    """Measures Hubble on every grid and writes texture-ref.json; returns ({w: cleaned frame}, ref)."""
    frames, n = clean_hubble(path)
    ref = {"version": 2, "source": "heic2506a", "points_removed": n, "centre": CENTRE, "u_max": U_MAX,
           "band": [V_LO, V_HI], "ref_rows": [REF_LO, REF_HI], "windows": N_WIN, "tips": TIPS,
           "psf_px": PSF, "hp_kpc": HP_KPC, "power": POWER, "unsummed": UNSUMMED, "grids": {}}
    for w, im in frames.items():
        ref["grids"][str(w)] = build_reference(opacity(im, w))
        ref["grids"][str(w)]["far"] = far_reference(opacity(im, w, "far"))
        if cache:
            im.save(os.path.join(cache, f"hubble-{w}-clean.png"))
    json.dump(ref, open(ref_path, "w"), separators=(",", ":"))
    _REF.pop(ref_path, None)
    return frames, ref


# ---------------------------------------------------------------- panel and command line

def font(size):
    for f in ("/System/Library/Fonts/Supplemental/Arial.ttf", "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
              "/usr/share/fonts/dejavu/DejaVuSans.ttf"):
        if os.path.exists(f):
            return ImageFont.truetype(f, size)
    return ImageFont.load_default(size)


def opacity_image(A, width, a_max=2.5, rows=2):
    """The lane's apparent opacity, white (none) to black (a_max nats), the core's side up, cut into
    `rows` stretches stacked, scaled to `width` with the aspect kept."""
    out = []
    for part in np.array_split(np.arange(A.shape[1]), rows):
        t = np.clip(1 - A[::-1, part] / a_max, 0, 1) ** 0.8
        im = Image.fromarray((t * 255).astype(np.uint8))
        out.append(im.resize((width, round(width * im.height / im.width)), Image.LANCZOS))
    sheet = Image.new("L", (width, sum(o.height for o in out) + 6 * (rows - 1)), 0)
    y = 0
    for o in out:
        sheet.paste(o, (0, y))
        y += o.height + 6
    return sheet.convert("RGB")


SHORT = {"spectrum along": "spectre le long", "spectrum across": "spectre en travers", "histogram": "histogramme",
         "phase": "phase (kurtosis)", "skewness": "asymétrie sombre/clair", "intermittency": "intermittence",
         "shape": "forme des taches", "filaments": "filaments", "multiscale": "entre échelles",
         "minkowski": "Minkowski", "blobs": "taches sombres", "anisotropy": "anisotropie", "strata": "strates",
         "edges": "bords", "profile": "profil", "colour": "couleur / profondeur", "stationarity": "stationnarité",
         "symmetry": "symétrie, répétition"}


def bars(dist, width, scale=8.0):
    """Per-figure distances as bars: green to 1.5 (Hubble's own spread), amber to 3, red beyond.
    A figure marked * is shown, not summed."""
    names = [k for k in dist if k != "summary"]
    f = font(24)
    row = 32
    im = Image.new("RGB", (width, row * len(names) + 8), (16, 16, 16))
    d = ImageDraw.Draw(im)
    x0 = 300
    span = width - x0 - 90
    for i, k in enumerate(names):
        v = dist[k]
        y = 4 + i * row
        colour = (90, 180, 90) if v <= 1.5 else (220, 170, 60) if v <= 3 else (210, 70, 60)
        d.text((8, y + 2), SHORT.get(k, k) + (" *" if k in UNSUMMED else ""), font=f, fill=(220, 220, 220))
        w = int(min(v, scale) / scale * span)
        d.rectangle((x0, y + 6, x0 + w, y + row - 6), fill=colour)
        for t in (1, 2, 3, 4, 6):
            xt = x0 + int(t / scale * span)
            d.line((xt, y + 2, xt, y + row - 2), fill=(70, 70, 70))
        d.text((x0 + w + 8, y + 2), f"{v:.1f}" + ("+" if v > scale else ""), font=f, fill=(230, 230, 230))
    return im


def panel(result, label="", width=2400):
    """A sheet panel: label and summary, the lane's apparent opacity, the per-figure distances."""
    d = result["distance"]
    head = Image.new("RGB", (width, 44), "black")
    ImageDraw.Draw(head).text((10, 6), f"{label}   distance à Hubble {d['summary']:.2f}   (grille {result['grid']})",
                              font=font(30), fill="white")
    parts = [head]
    if result.get("_A") is not None:
        parts.append(opacity_image(result["_A"], width))
    parts.append(bars(d, width))
    out = Image.new("RGB", (width, sum(p.height for p in parts)), "black")
    y = 0
    for p in parts:
        out.paste(p, (0, y))
        y += p.height
    return out


def public(result):
    """The result without its arrays, ready for JSON."""
    out = {k: v for k, v in result.items() if not k.startswith("_")}
    if "far" in out:
        out["far"] = {k: v for k, v in out["far"].items() if not k.startswith("_")}
    return out


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("frames", nargs="*")
    p.add_argument("--json", help="write the result (one object, or a list for several frames)")
    p.add_argument("--panel", help="JPG: a panel per frame, stacked")
    p.add_argument("--grid", type=int, choices=GRIDS, help="analysis grid (default: the finest the frame fills)")
    p.add_argument("--ref", default=REF_PATH, help="reference figures (texture-ref.json)")
    p.add_argument("--build-ref", action="store_true", help="measure Hubble and write --ref")
    p.add_argument("--hubble", help="Hubble's frame for --build-ref (else hubble_ref.py's search)")
    p.add_argument("--z", action="store_true", help="print every component's z")
    g = p.parse_args()
    if g.build_ref:
        _, ref = build(g.hubble, g.ref)
        print("reference", g.ref, f"({ref['points_removed']} point sources removed)")
    results, panels = [], []
    for path in g.frames:
        r = score(path, g.grid, g.ref)
        d = r["distance"]
        print(f"{os.path.basename(path)}  summary {d['summary']:.2f}  (grid {r['grid']}, {r['seconds']} s)"
              + (f"  WARNING {r['warning']}" if r["warning"] else ""))
        print("   " + "  ".join(f"{k} {v:.1f}" for k, v in d.items() if k != "summary"))
        fr = r["far"]
        if fr["distance"]:
            print(f"   far lane (apart) {fr['distance']['summary']:.2f}: "
                  + "  ".join(f"{k} {v:.1f}" for k, v in fr["distance"].items() if k != "summary"))
        else:
            print(f"   far lane (apart): mean A {fr['mean']:.3f}, {fr['note']}")
        if g.z:
            for k, zs in r["z"].items():
                print(f"   {k:16} " + " ".join(f"{x:+5.1f}" for x in zs))
        if g.panel:
            panels.append(panel(r, os.path.basename(path)))
        results.append(dict(public(r), frame=path))
    if g.json:
        json.dump(results[0] if len(results) == 1 else results, open(g.json, "w"), indent=1)
    if g.panel and panels:
        out = Image.new("RGB", (panels[0].width, sum(q.height for q in panels)), "black")
        y = 0
        for q in panels:
            out.paste(q, (0, y))
            y += q.height
        out.save(g.panel, quality=90)


if __name__ == "__main__":
    main()
