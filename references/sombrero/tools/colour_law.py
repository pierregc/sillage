#!/usr/bin/env python3
"""colour_law.py measure|proof OUTDIR [--clean PNG] [--light PNG]: the Sombrero's reddening law on Hubble (#499).

  measure   apparent opacity in red and blue against green on Hubble's near lane (6144 px grid, point
            sources removed, texture.py's estimator), by depth, in two zones apart (the dense band under the
            lane's upper edge, and the orange zone below it) and in two regions (centre, tips); the
            floor the light model's share of light behind explains and what is left; the three tests of
            what makes the band grey. Writes colour-law.json (beside this file), OUTDIR/colour-law-*.png.
  proof     Hubble's own opacity map laid back on the bench light with the old law and with law=hubble,
            scored with texture.py (the `colour` bar and the others). Writes OUTDIR/proof-*.png and .json.

The zones: d is the distance, in kpc along the lane's across axis, below the lane's upper edge (the
highest row of each column whose smoothed A_g passes 0.6); the band is d < 0.10 (the thin skirt over the
edge included), the orange zone 0.15 < d < 0.45. Colours are A_c = ln(I0_c / I_c) from texture.opacity, smoothed 1.5 px.
"""
import argparse
import json
import math
import os
import sys

import numpy as np
from PIL import Image, ImageDraw
from scipy.ndimage import gaussian_filter, map_coordinates
from scipy.optimize import least_squares

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import dust_bench as D  # noqa: E402
import hubble_ref  # noqa: E402
import light_model as LM  # noqa: E402
import texture as T  # noqa: E402

Image.MAX_IMAGE_PIXELS = None
OUT_JSON = os.path.join(HERE, "colour-law.json")
W = 6144
SMOOTH = 1.5                  # px: the maps are smoothed before they are binned
EDGE_A = 0.6                  # A_g that marks the lane's upper edge
ZONES = {"band": (-0.5, 0.10), "orange": (0.15, 0.45)}
BINS = [0.15, 0.3, 0.45, 0.6, 0.8, 1.0, 1.2, 1.4, 1.6, 1.8, 2.0, 2.25, 2.5]   # A_g
MIN_PX = 300                  # pixels a bin needs
REGIONS = ("centre", "tips")


# ---------------------------------------------------------------- data

class Data:
    """Hubble's near lane at 6144 px: per-channel apparent opacity, the lane's upper edge, the light share."""

    def __init__(self, clean, raw=True, w=W):
        """`clean`: a PNG path or an image (Hubble with its points removed, or a bench frame) on grid w."""
        self.g = g = T.grid(w)
        lanes = {"clean": T.opacity(Image.open(clean) if isinstance(clean, str) else clean, w)}
        if raw:
            lanes["raw"] = T.opacity(hubble_ref.load().frame(w), w)
        self.lanes = lanes
        self.S = {k: gaussian_filter(l.Ac, [SMOOTH, SMOOTH, 0]) for k, l in lanes.items()}
        self.v, self.us = g.v, g.us
        edge = gaussian_filter(lanes["clean"].Ac[..., 1], [2, 2]) > EDGE_A
        nv = edge.shape[0]
        self.top = np.where(edge.any(0), self.v[nv - 1 - np.argmax(edge[::-1], 0)], np.nan)
        self.d = (self.top[None, :] - self.v[:, None]).astype(np.float32)   # kpc below the upper edge
        self.b = share_map(g)
        win = np.array_split(np.arange(len(self.us)), T.N_WIN)
        self.windows = {"centre": win[T.TIPS:T.N_WIN - T.TIPS], "tips": win[:T.TIPS] + win[T.N_WIN - T.TIPS:]}

    def pixels(self, region, zone, key="clean", cols=None):
        """The (r, g, b) apparent opacities and the light model's floor 1 - b of a zone's pixels."""
        cols = np.concatenate(self.windows[region]) if cols is None else cols
        z0, z1 = ZONES[zone]
        m = (self.d[:, cols] >= z0) & (self.d[:, cols] < z1)
        return self.S[key][:, cols][m], 1 - self.b[:, cols][m]


def share_map(g):
    """The light model's share of light behind the dust, on the lane's rows and columns (dust in the
    ring's plane, `centre=nucleus`)."""
    U, V = np.meshgrid(g.us, g.v)
    sy = T.centre(U) + V
    x, y = U - D.NUCLEUS[0], (sy - D.NUCLEUS[1]) / math.sin(LM.INC)
    return LM.share(LM.load(), x.ravel(), y.ravel(), np.zeros(x.size)).reshape(x.shape).astype(np.float32)


def curve(pix, floor, windows=None, S_cols=None):
    """Per bin of A_g: n, median (A_r, A_g, A_b), the ratios, the pixel-to-pixel IQR of the ratios and the
    model floor."""
    rows = []
    for lo, hi in zip(BINS[:-1], BINS[1:]):
        k = (pix[:, 1] >= lo) & (pix[:, 1] < hi)
        if k.sum() < MIN_PX:
            continue
        s = pix[k]
        m = np.median(s, 0)
        iqr = lambda x: float(np.subtract(*np.percentile(x, [75, 25])))
        rows.append(dict(lo=lo, hi=hi, n=int(k.sum()), A=[float(x) for x in m], r_g=float(m[0] / m[1]),
                         b_g=float(m[2] / m[1]), iqr_r_g=iqr(s[:, 0] / s[:, 1]), iqr_b_g=iqr(s[:, 2] / s[:, 1]),
                         floor=float(floor[k].mean())))
    return rows


def window_scatter(data, region, zone, rows, key="clean"):
    """Spread over the region's windows of each bin's ratio (the windows' own medians)."""
    out = []
    for r in rows:
        rg, bg = [], []
        for w in data.windows[region]:
            pix, _ = data.pixels(region, zone, key, w)
            k = (pix[:, 1] >= r["lo"]) & (pix[:, 1] < r["hi"])
            if k.sum() >= 60:
                m = np.median(pix[k], 0)
                rg.append(m[0] / m[1])
                bg.append(m[2] / m[1])
        out.append(dict(win_r_g=float(np.std(rg)) if len(rg) > 2 else None,
                        win_b_g=float(np.std(bg)) if len(bg) > 2 else None, windows=len(rg)))
    return out


# ---------------------------------------------------------------- the law and its fits

def law_curves(a_r, a_b, Ag, floor, t0=None):
    """A_r, A_b of a law that dims green by A_g behind a floor (the light in front, 1 - b): the optical
    depths in red and blue are a_r and a_b times green's in thin dust and tend to green's as the dust
    thickens, ratio = 1 + (a - 1) / (1 + tau / t0) (t0 None: they stay a_r and a_b)."""
    floor = np.asarray(floor, float)
    tau = -np.log(np.clip((np.exp(-Ag) - floor) / (1 - floor), 1e-6, 1))   # green's optical depth
    return [-np.log(floor + (1 - floor) * np.exp(-tau * (a if t0 is None else 1 + (a - 1) / (1 + tau / t0))))
            for a in (a_r, a_b)]


def fit_law(curves, mode):
    """Fits (a_r, a_b) [and t0, or a free floor per region] to {region: rows} by least squares on A_r, A_b.
    mode: "floor" (the light model's floor), "grey" (model floor, t0), "free" (free floor per region),
    "grey free" (both)."""
    regs = list(curves)
    n0 = 3 if mode.startswith("grey") else 2

    def res(q):
        out = []
        for i, r in enumerate(regs):
            c = curves[r]
            Ag = np.array([x["A"][1] for x in c])
            fl = np.array([x["floor"] for x in c])
            if mode.endswith("free"):
                fl = np.full(len(c), q[n0 + i])
            ar, ab = law_curves(q[0], q[1], Ag, fl, q[2] if n0 == 3 else None)
            out += [ar - np.array([x["A"][0] for x in c]), ab - np.array([x["A"][2] for x in c])]
        return np.concatenate(out)

    q0 = [0.5, 1.5] + ([1.0] if n0 == 3 else []) + ([0.05] * len(regs) if mode.endswith("free") else [])
    lo = [0, 0] + ([0.05] if n0 == 3 else []) + [0] * (len(q0) - n0)
    hi = [3, 5] + ([60.0] if n0 == 3 else []) + [0.5] * (len(q0) - n0)
    r = least_squares(res, q0, bounds=(lo, hi))
    return dict(a_r=float(r.x[0]), a_b=float(r.x[1]), t0=float(r.x[2]) if n0 == 3 else None,
                floors=[float(x) for x in r.x[n0:]], rms=float(np.sqrt(np.mean(r.fun ** 2))))


def thin_law(rows, a_max=0.7):
    """The law read off the thin dust only (A_g under a_max), where no floor matters: A_r/A_g, A_b/A_g."""
    thin = [r for r in rows if r["A"][1] < a_max]
    n = np.array([r["n"] for r in thin], float)
    return [float(np.average([r[k] for r in thin], weights=n)) for k in ("r_g", "b_g")]


# ---------------------------------------------------------------- plotting (PIL only)

COL = {"band": (40, 90, 200), "orange": (220, 110, 20), "old": (110, 110, 110), "new": (20, 150, 70),
       "raw": (200, 40, 160)}


class Plot:
    def __init__(self, w, h, xr, yr, title="", xlabel="", ylabel="", xticks=True):
        self.im = Image.new("RGB", (w, h), "white")
        self.d = ImageDraw.Draw(self.im)
        self.w, self.h, self.xr, self.yr = w, h, xr, yr
        self.l, self.r, self.t, self.b = 70, 14, 34, 50
        self.f = D.font(18)
        self.d.text((self.l, 6), title, font=self.f, fill="black")
        self.d.text((self.l + 280, h - 24), xlabel, font=self.f, fill="black")
        self.d.text((6, 6 + 0), ylabel, font=D.font(14), fill=(80, 80, 80))
        self.d.rectangle((self.l, self.t, w - self.r, h - self.b), outline=(120, 120, 120))
        for x in (np.arange(math.ceil(xr[0] * 4) / 4, xr[1] + 1e-9, 0.5 if xr[1] > 1.5 else 0.25) if xticks else []):
            X = self.px(x, yr[0])[0]
            self.d.line((X, self.t, X, h - self.b), fill=(228, 228, 228))
            self.d.text((X - 10, h - self.b + 4), f"{x:g}", font=D.font(14), fill="black")
        for y in np.arange(math.ceil(yr[0] * 4) / 4, yr[1] + 1e-9, 0.25):
            Y = self.px(xr[0], y)[1]
            self.d.line((self.l, Y, w - self.r, Y), fill=(228, 228, 228))
            self.d.text((self.l - 38, Y - 8), f"{y:.2f}".rstrip("0").rstrip("."), font=D.font(14), fill="black")

    def px(self, x, y):
        return (self.l + (x - self.xr[0]) / (self.xr[1] - self.xr[0]) * (self.w - self.l - self.r),
                self.h - self.b - (y - self.yr[0]) / (self.yr[1] - self.yr[0]) * (self.h - self.t - self.b))

    def line(self, xs, ys, colour, width=3, dashed=False, dots=False):
        pts = [self.px(x, y) for x, y in zip(xs, ys) if y is not None and np.isfinite(y)]
        if dashed:   # eight sub-segments a step, three drawn, three left
            pts = [(p0[0] + (p1[0] - p0[0]) * f / 8, p0[1] + (p1[1] - p0[1]) * f / 8)
                   for p0, p1 in zip(pts[:-1], pts[1:]) for f in range(8)]
        for i in range(len(pts) - 1):
            if not dashed or i % 6 < 3:
                self.d.line((*pts[i], *pts[i + 1]), fill=colour, width=width)
        if dots:
            for X, Y in pts:
                self.d.ellipse((X - 4, Y - 4, X + 4, Y + 4), fill=colour)

    def band(self, xs, lo, hi, colour):
        ov = Image.new("RGBA", self.im.size, (0, 0, 0, 0))
        od = ImageDraw.Draw(ov)
        up = [self.px(x, y) for x, y in zip(xs, hi)]
        dn = [self.px(x, y) for x, y in zip(xs[::-1], lo[::-1])]
        od.polygon(up + dn, fill=(*colour, 60))
        self.im.paste(Image.alpha_composite(self.im.convert("RGBA"), ov).convert("RGB"))
        self.d = ImageDraw.Draw(self.im)

    def legend(self, items, x=None, y=None):
        x = x or self.l + 10
        y = y or self.t + 8
        for text, colour in items:
            self.d.line((x, y + 9, x + 26, y + 9), fill=colour, width=4)
            self.d.text((x + 32, y), text, font=D.font(15), fill="black")
            y += 21


def sheet(parts, cols, path):
    w, h = parts[0].size
    rows = -(-len(parts) // cols)
    im = Image.new("RGB", (w * cols, h * rows), "white")
    for i, p in enumerate(parts):
        im.paste(p, ((i % cols) * w, (i // cols) * h))
    im.save(path)


# ---------------------------------------------------------------- measure

OLD = np.array([1.0, 1 + 3 * D.CHANNELS[1], 1 + 3 * D.CHANNELS[2]])   # the bench's old law at redden 3: 1, 1.66, 2.56


def measure(a):
    data = Data(a.clean)
    res = {"grid": W, "zones_kpc_below_upper_edge": ZONES, "smooth_px": SMOOTH, "bins_A_g": BINS, "curves": {}, "fits": {}}
    plots = []
    for zone in ZONES:
        res["curves"][zone] = {}
        for region in REGIONS:
            pix, floor = data.pixels(region, zone)
            rows = curve(pix, floor)
            for r, s in zip(rows, window_scatter(data, region, zone, rows)):
                r.update(s)
            res["curves"][zone][region] = rows
    # the fits: one law a zone on both regions, the light model's floor, then a leak, then free floors
    for zone in ZONES:
        cv = res["curves"][zone]
        res["fits"][zone] = {m: fit_law(cv, m) for m in ("floor", "grey", "free", "grey free")}
        res["fits"][zone]["thin"] = {r: thin_law(cv[r]) for r in REGIONS}
        res["fits"][zone]["model_floor"] = {r: float(np.mean([x["floor"] for x in cv[r]])) for r in REGIONS}
        # without any floor, the thin dust's law kept: how much of the flattening is left
        for r in REGIONS:
            rows = cv[r]
            ar, ab = thin_law(rows)
            Ag = np.array([x["A"][1] for x in rows])
            for name, fl in (("no floor", np.zeros(len(rows))), ("model floor", np.array([x["floor"] for x in rows]))):
                pr, pb = law_curves(ar, ab, Ag, fl)
                err = np.r_[pr - [x["A"][0] for x in rows], pb - [x["A"][2] for x in rows]]
                res["fits"][zone].setdefault("thin_law_rms", {}).setdefault(r, {})[name] = float(np.sqrt(np.mean(err ** 2)))
    # the zone's profile across the lane's upper edge at a given column (the band is not a depth)
    prof = []
    for z0 in np.arange(-0.05, 0.50, 0.025):
        for region in REGIONS:
            cols = np.concatenate(data.windows[region])
            m = (data.d[:, cols] >= z0) & (data.d[:, cols] < z0 + 0.025)
            s = data.S["clean"][:, cols][m]
            k = (s[:, 1] >= 1.3) & (s[:, 1] < 2.0)
            if k.sum() > 300:
                q = np.median(s[k], 0)
                prof.append(dict(d=float(z0 + 0.0125), region=region, n=int(k.sum()), A_g=float(q[1]), r_g=float(q[0] / q[1]),
                                 b_g=float(q[2] / q[1])))
    res["same_column_profile"] = prof
    # floor colours: the share of light each channel lets through in the deepest pixels
    floors = {}
    for zone in ZONES:
        pix, _ = data.pixels("centre", zone)
        k = pix[:, 1] >= 2.0
        t = np.exp(-np.median(pix[k], 0))
        floors[zone] = dict(T=[float(x) for x in t], n=int(k.sum()), T_r_g=float(t[0] / t[1]), T_b_g=float(t[2] / t[1]))
    res["deepest_pixels"] = floors
    # points: raw against cleaned
    raw = {}
    for zone in ZONES:
        raw[zone] = {k: curve(data.pixels("centre", zone, k)[0], data.pixels("centre", zone, k)[1]) for k in ("clean", "raw")}
    res["raw_vs_clean"] = {z: {k: [dict(lo=r["lo"], r_g=r["r_g"], b_g=r["b_g"]) for r in rows] for k, rows in v.items()}
                           for z, v in raw.items()}
    json.dump(res, open(OUT_JSON, "w"), indent=1)
    report(res)
    os.makedirs(a.out, exist_ok=True)
    plot_curves(res, os.path.join(a.out, "colour-law-curves.png"))
    plot_tests(res, data, os.path.join(a.out, "colour-law-tests.png"))
    ratio_map(data, os.path.join(a.out, "colour-law-ratio-map.png"))
    return res


def report(res):
    for zone in ZONES:
        for region in REGIONS:
            print(f"{zone} {region}  (A_g bin: r/g  b/g  [pixel IQR] (windows' sd)  floor)")
            for r in res["curves"][zone][region]:
                print(f"  {r['lo']:.2f}-{r['hi']:.2f} n={r['n']:6d}  {r['r_g']:.2f} {r['b_g']:.2f}  [{r['iqr_r_g']:.2f} {r['iqr_b_g']:.2f}]"
                      f" ({r['win_r_g'] or 0:.2f} {r['win_b_g'] or 0:.2f})  {r['floor']:.3f}")
        f = res["fits"][zone]
        print(zone, "thin law (r/g, b/g) centre", np.round(f["thin"]["centre"], 2), "tips", np.round(f["thin"]["tips"], 2))
        print("   model floor", {k: round(v, 3) for k, v in f["model_floor"].items()}, " thin law rms", f["thin_law_rms"])
        for m in ("floor", "grey", "free", "grey free"):
            print(f"   fit {m}: a_r {f[m]['a_r']:.2f} a_b {f[m]['a_b']:.2f} t0 {f[m]['t0']} floors {np.round(f[m]['floors'], 3)} rms {f[m]['rms']:.3f}")
    print("deepest pixels (A_g >= 2), centre:", res["deepest_pixels"])


def plot_curves(res, path):
    parts = []
    for ch, (name, key) in enumerate((("A_r / A_g", "r_g"), ("A_b / A_g", "b_g"))):
        for region in REGIONS:
            yr = (0.2, 1.0) if key == "r_g" else (0.8, 2.0)
            p = Plot(620, 400, (0, 2.5), yr, f"{name}, {region}", "apparent opacity in green A_g", "")
            for zone in ZONES:
                rows = res["curves"][zone][region]
                xs = [r["A"][1] for r in rows]
                ys = [r[key] for r in rows]
                sd = [r["win_" + key] or 0 for r in rows]
                p.band(xs, [y - s for y, s in zip(ys, sd)], [y + s for y, s in zip(ys, sd)], COL[zone])
                p.line(xs, ys, COL[zone], 3, dots=True)
                fl = np.array([r["floor"] for r in rows])
                f = res["fits"][zone]["grey"]
                pr, pb = law_curves(f["a_r"], f["a_b"], np.array(xs), fl, f["t0"])
                fit = (pr if key == "r_g" else pb) / np.array(xs)
                p.line(xs, fit, COL[zone], 2, dashed=True)
                # the old law (redden 3) behind the same floors
                pr, pb = law_curves(OLD[0] / OLD[1], OLD[2] / OLD[1], np.array(xs), np.full(len(xs), 0.05))
                if zone == "orange":
                    p.line(xs, (pr if key == "r_g" else pb) / np.array(xs), COL["old"], 2)
            p.legend([("dense band (d < 0.10 kpc)", COL["band"]), ("orange zone (0.15-0.45)", COL["orange"]),
                      ("dashed: law fitted behind the light model's floor", (90, 90, 90)),
                      ("grey: old law, redden 3, behind 0.95", COL["old"])], 330, 38 if key == "b_g" else 250)
            parts.append(p.im)
    sheet(parts, 2, path)


def plot_tests(res, data, path):
    parts = []
    # 1. the same column, the other colour: b/g and A_g against the distance below the upper edge
    prof = [p for p in res["same_column_profile"] if p["region"] == "centre"]
    p = Plot(620, 400, (-0.05, 0.5), (0.6, 2.0), "centre, pixels with A_g 1.3-2.0, by depth below the upper edge",
             "d, kpc below the lane's upper edge", "")
    p.line([x["d"] for x in prof], [x["b_g"] for x in prof], (40, 90, 200), 3, dots=True)
    p.line([x["d"] for x in prof], [x["r_g"] + 0.0 for x in prof], (200, 40, 40), 3, dots=True)
    p.line([x["d"] for x in prof], [x["A_g"] for x in prof], (90, 90, 90), 2, dashed=True)
    p.legend([("A_b / A_g", (40, 90, 200)), ("A_r / A_g", (200, 40, 40)), ("A_g (dashed): the column is the same", (90, 90, 90))], 300, 250)
    parts.append(p.im)
    # 2. the floor's colour in the deepest pixels, against what scattered or young blue light would give
    p = Plot(620, 400, (-0.3, 3.3), (0.0, 2.0), "light let through, T_c / T_g, in the deepest pixels (A_g >= 2): r, g, b",
             "", "", xticks=False)
    for i, (zone, off) in enumerate((("band", 0), ("orange", 1.1))):
        t = res["deepest_pixels"][zone]["T"]
        for j, v in enumerate(t):
            x = off + 0.3 * j
            p.d.rectangle((*p.px(x, v / t[1]), *p.px(x + 0.22, 0.0)), fill=COL[zone])
    # a floor of unreddened light is flat; blue light added (young stars, scattering) is bluer than the light
    for j, v in enumerate((0.7, 1.0, 1.5)):
        x = 2.2 + 0.3 * j
        p.d.rectangle((*p.px(x, v), *p.px(x + 0.22, 0.0)), fill=(150, 170, 235))
    for x, text, c in ((0.0, "dense band", COL["band"]), (1.1, "orange zone", COL["orange"]),
                       (2.1, "a blue floor (young", (90, 110, 200))):
        p.d.text((*p.px(x, 1.9),), text, font=D.font(16), fill=c)
    p.d.text((*p.px(2.1, 1.78),), "stars, scattering): not seen", font=D.font(16), fill=(90, 110, 200))
    parts.append(p.im)
    # 3. the point sources: the band's b/g with and without them
    p = Plot(620, 400, (0, 2.5), (0.8, 1.4), "dense band, centre: A_b / A_g with the point sources removed and kept", "A_g", "")
    for k, c, wd in (("clean", COL["band"], 4), ("raw", COL["raw"], 2)):
        rows = res["raw_vs_clean"]["band"][k]
        p.line([(r["lo"]) for r in rows], [r["b_g"] for r in rows], c, wd, dots=True)
    p.legend([("4816 point sources removed", COL["band"]), ("kept", COL["raw"])], 300, 250)
    parts.append(p.im)
    sheet(parts, 3, path)


def ratio_map(data, path, u0=-1.2, u1=1.2):
    """Hubble's near lane, the core's side up, and under it A_b / A_g where A_g > 0.4: grey-blue to orange."""
    g = data.g
    i0, i1 = np.searchsorted(g.us, u0), np.searchsorted(g.us, u1)
    strip = g.unwrap(g.to_grid(Image.open(_CLEAN_PATH[0])))[:, i0:i1]
    rgb = (np.clip(strip[::-1], 0, 1) ** (1 / T.GAMMA) * 255).astype(np.uint8)
    S = data.S["clean"][:, i0:i1]
    full = np.full(strip.shape[:2], np.nan, np.float32)
    ratio = S[..., 2] / np.maximum(S[..., 1], 1e-3)
    ratio[S[..., 1] < 0.4] = np.nan
    full[g.band] = ratio
    full = full[::-1]
    t = np.clip((full - 1.0) / 0.8, 0, 1)
    cold, warm = np.array([40, 70, 200.0]), np.array([240, 130, 20.0])
    col = (cold + (warm - cold) * t[..., None])
    col[np.isnan(full)] = 255
    top = Image.fromarray(rgb)
    bot = Image.fromarray(col.astype(np.uint8))
    s = 3
    top, bot = (x.resize((x.width * s, x.height * s), Image.LANCZOS) for x in (top, bot))
    im = Image.new("RGB", (top.width, top.height * 2 + 4), "white")
    im.paste(top, (0, 0))
    im.paste(bot, (0, top.height + 4))
    d = ImageDraw.Draw(im)
    d.text((8, 6), "Hubble, near lane, core's side up (6144 px grid, 4.3 pc a pixel, 3x), u -1.2 to 1.2 kpc", font=D.font(20), fill="black")
    d.text((8, top.height + 10), "A_b / A_g where A_g > 0.4: blue = 1.0 (grey dust), orange = 1.8 (reddening dust)", font=D.font(20), fill="black")
    im.save(path)


_CLEAN_PATH = [None]


# ---------------------------------------------------------------- proof

def zone_weight(d):
    """The inner rim's share of a pixel's column from its depth below the lane's upper edge (kpc)."""
    t = np.clip((d - 0.08) / 0.08, 0, 1)
    return np.where(np.isnan(d), 0.0, 1 - t * t * (3 - 2 * t)).astype(np.float32)


def lay(data, light, par, depth_share, blur=0.0):
    """Hubble's near lane map A laid on the bench light: N solved so that the luminance dims by exp(-A)
    through green (as texture_proofs.lay), the law and floors of `par`. depth_share: each pixel's b from the
    light model (else `behind`)."""
    g = data.g
    A = data.lanes["clean"].A
    b = data.b if depth_share else np.full(A.shape, par["behind"], np.float32)
    leak = par["leak"]
    t = np.clip(np.exp(-A), 1e-4, 1)
    e = np.clip((t - (1 - b)) / b, 1e-3, 1)
    e = np.clip((e - leak) / (1 - leak), 1e-3, 1)
    green = 1 + par["redden"] * D.CHANNELS[1]
    N = -np.log(e) / (par["k"] * green)
    q = zone_weight(data.d) if par["law"] == "hubble" else np.zeros_like(A)
    full = {}
    for name, m in (("N", N), ("rim", N * q), ("b", b)):
        f = np.zeros((len(g.vs), len(g.us)), np.float32)
        f[g.band] = m
        full[name] = f
    vi, ui = g.frame_coords()
    fr = {k: map_coordinates(v, [vi, ui], order=1, mode="constant", cval=0.0).astype(np.float32) for k, v in full.items()}
    if blur:
        fr["N"], fr["rim"] = (gaussian_filter(fr[k], blur * g.w / D.BASE_W) for k in ("N", "rim"))
    shares = (fr["b"], np.zeros_like(fr["b"])) if depth_share else None
    rims = (fr["rim"], np.zeros_like(fr["rim"])) if par["law"] == "hubble" else None
    return Image.fromarray(D.attenuate(light, fr["N"], np.zeros_like(fr["N"]), par, shares, rims))


def proof(a):
    data = Data(a.clean, raw=False)
    g = data.g
    light, _ = D.load_light(a.light, g.w)
    light = D.clean_light(light)
    os.makedirs(a.out, exist_ok=True)
    cases = [("old law, behind 0.95 (as #498)", dict(law="old"), False),
             ("old law, light model's share", dict(law="old"), True),
             ("law=hubble, behind 0.95", dict(law="hubble"), False),
             ("law=hubble, light model's share", dict(law="hubble"), True)]
    out = {}
    for blur in (0.0, 0.15):
        for name, p, depth in cases:
            par = dict(D.DEFAULTS, **p)
            im = lay(data, light, par, depth, blur)
            r = T.score(im, g.w)
            tag = f"{name} | blur {blur:g}"
            d = r["distance"]
            print(f"{tag:52s} {d['summary']:5.2f} | colour {d['colour']:.2f} | " +
                  " ".join(f"{k[:7]} {v:.1f}" for k, v in d.items() if k not in ("summary", "colour")), flush=True)
            out[tag] = {"distance": d, "colour_z": r["z"]["colour"], "colour_figures": r["figures"]["centre"]["colour"]}
            if blur == 0.0:
                im.save(os.path.join(a.out, "roundtrip-" + "".join(c if c.isalnum() else "-" for c in name) + ".png"))
    ref = T.reference()["grids"][str(g.w)]["regions"]["centre"]["colour"]
    print("Hubble colour (centre): ", " ".join(f"{x:.2f}" for x in ref))
    out["hubble_colour_centre"] = ref
    json.dump(out, open(os.path.join(a.out, "proof.json"), "w"), indent=1)


PARAMS = ["dif_r", "dif_b", "dif_t", "rim_r", "rim_b", "rim_t"]


def calibrate(a):
    """Refines the law's six numbers on the round trip itself: least squares on the 16 z of the `colour`
    bar (centre and tips), from the values fitted to the curves, behind the light model's floors."""
    data = Data(a.clean, raw=False)
    g = data.g
    light = D.clean_light(D.load_light(a.light, g.w)[0])
    q0 = [D.DEFAULTS[k] for k in PARAMS]
    print("start", dict(zip(PARAMS, np.round(q0, 3))), flush=True)

    def z(q):
        par = dict(D.DEFAULTS, law="hubble", **dict(zip(PARAMS, q)))
        r = T.score(lay(data, light, par, True), g.w)
        v = np.array(r["z"]["colour"])
        print("  ", np.round(q, 3), "colour %.2f" % r["distance"]["colour"], flush=True)
        return v

    lo = [0.0, 0.5, 0.2, 0.0, 0.5, 0.1]
    hi = [1.0, 3.0, 30.0, 1.0, 2.0, 30.0]
    r = least_squares(z, q0, bounds=(lo, hi), diff_step=0.03, max_nfev=a.nfev, x_scale=[0.3, 0.5, 1.0, 0.3, 0.3, 0.3])
    print("best", {k: round(float(v), 3) for k, v in zip(PARAMS, r.x)}, "colour %.2f" % np.sqrt(np.mean(r.fun ** 2)))


def frames(a):
    """The colour of the band and of the orange zone in bench frames, by depth, beside Hubble's (centre)."""
    hub = json.load(open(OUT_JSON))["curves"]
    rows = [("Hubble", None)] + [(os.path.basename(f), f) for f in a.frames]
    bins = ((0.6, 1.0), (1.0, 1.4), (1.4, 2.0), (2.0, 2.5))
    print(f"{'':34}" + "".join(f"  A_g {lo:g}-{hi:g}: r/g b/g " for lo, hi in bins))
    for zone in ZONES:
        print(zone)
        for name, f in rows:
            if f is None:
                pix = None
                cv = hub[zone]["centre"]
                out = []
                for lo, hi in bins:
                    sel = [r for r in cv if lo <= r["A"][1] < hi]
                    out.append((np.mean([r["r_g"] for r in sel]), np.mean([r["b_g"] for r in sel])) if sel else None)
            else:
                data = Data(f, raw=False, w=a.grid)
                pix, _ = data.pixels("centre", zone)
                out = []
                for lo, hi in bins:
                    k = (pix[:, 1] >= lo) & (pix[:, 1] < hi)
                    q = np.median(pix[k], 0) if k.sum() > 200 else None
                    out.append((q[0] / q[1], q[2] / q[1]) if q is not None else None)
            print(f"  {name:32}" + "".join(f"  {'':8}{o[0]:.2f} {o[1]:.2f}  " if o else f"  {'-':>18}  " for o in out))


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("mode", choices=["measure", "proof", "calibrate", "frames"])
    p.add_argument("paths", nargs="*", help="the output folder; for frames, the bench frames (PNG) to read")
    p.add_argument("--grid", type=int, default=3072, help="frames: the grid they are read on")
    p.add_argument("--nfev", type=int, default=25)
    p.add_argument("--clean", default=os.path.expanduser("~/claude-workspace/sombrero/banc/487/cache/hubble-6144-clean.png"),
                   help="Hubble at 6144 px, point sources removed (texture.build(cache=...))")
    p.add_argument("--light", default=os.path.expanduser("~/claude-workspace/sombrero/assets-wt/bench-light-12myr-26.5.png"))
    a = p.parse_args()
    a.out, a.frames = (a.paths[0] if a.paths else "."), a.paths
    _CLEAN_PATH[0] = a.clean
    {"measure": measure, "proof": proof, "calibrate": calibrate, "frames": frames}[a.mode](a)


if __name__ == "__main__":
    main()
