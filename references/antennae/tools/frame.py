#!/usr/bin/env python3
"""Hubble's frame on the wide ground picture: the rectangle, and a check that it is right.

usage: frame.py <wide.jpg> <hubble.tif> <out dir>

Both pictures are tangent-plane images. The wide one is north up, east left, centred on
CENTRE at SCALE arcsec per pixel. Hubble's (heic0615a) centre, field and roll are the archive's:
north is 30.6 degrees right of vertical. The check warps Hubble onto the wide picture's grid and
slides it over the wide luminance: the best shift should be a few pixels.
"""
import json, math, os, sys
import numpy as np
from PIL import Image, ImageDraw

Image.MAX_IMAGE_PIXELS = None
WIDE_CENTRE = (180.452, -18.885)
WIDE_SCALE = 0.40
HUB_CENTRE = (180.470327069, -18.8804907083)
HUB_FIELD = (3.27 * 60, 3.25 * 60)  # arcsec, width x height
ROLL = 30.6  # north is this many degrees clockwise from Hubble's up


def sky_offset(centre, ra, dec):
    return ((ra - centre[0]) * math.cos(math.radians(centre[1])) * 3600, (dec - centre[1]) * 3600)


def main():
    wide_path, hub_path, out = sys.argv[1:4]
    os.makedirs(out, exist_ok=True)
    wide = Image.open(wide_path).convert("RGB")
    hub = Image.open(hub_path).convert("RGB")
    W, H = wide.size
    e, n = sky_offset(WIDE_CENTRE, *HUB_CENTRE)
    cx, cy = W / 2 - e / WIDE_SCALE, H / 2 - n / WIDE_SCALE  # east is left
    t = math.radians(ROLL)
    # Hubble's right and up unit vectors, as (east, north)
    right = (-math.cos(t), math.sin(t))
    up = (math.sin(t), math.cos(t))
    # (right, up) = (N sin t - E cos t, N cos t + E sin t) -> inverse above
    hw, hh = HUB_FIELD[0] / 2, HUB_FIELD[1] / 2
    corners = []
    for sx, sy in ((-1, 1), (1, 1), (1, -1), (-1, -1)):  # top-left, top-right, ...
        E = sx * hw * right[0] + sy * hh * up[0]
        N = sx * hw * right[1] + sy * hh * up[1]
        corners.append((cx - E / WIDE_SCALE, cy - N / WIDE_SCALE))

    # warp Hubble onto the wide grid
    hw_px, hh_px = hub.size
    hs = HUB_FIELD[0] / hw_px  # arcsec per Hubble pixel
    k = WIDE_SCALE / hs
    # wide pixel (x, y) -> (E, N) = (-(x-cx)*s, -(y-cy)*s) -> Hubble (r, u) arcsec -> pixel
    # r = N sin t - E cos t ; u = N cos t + E sin t
    a = np.array([[0.0, 0.0, 0.0], [0.0, 0.0, 0.0]])
    # px_h = hw_px/2 + r/hs ; py_h = hh_px/2 - u/hs ; with E = -(x-cx)S, N = -(y-cy)S
    S = WIDE_SCALE
    # r/hs = (-(y-cy) sin t + (x-cx) cos t) * S/hs
    # u/hs = (-(y-cy) cos t - (x-cx) sin t) * S/hs
    ct, st = math.cos(t), math.sin(t)
    A = k * ct; B = -k * st
    C = hw_px / 2 - (A * cx + B * cy)
    D = k * st; Ee = k * ct
    F = hh_px / 2 - (D * cx + Ee * cy)
    x0, y0 = int(min(c[0] for c in corners)) - 10, int(min(c[1] for c in corners)) - 10
    x1, y1 = int(max(c[0] for c in corners)) + 10, int(max(c[1] for c in corners)) + 10
    # PIL affine maps output (x,y) -> input; do it on the crop
    cw, ch = x1 - x0, y1 - y0
    coeffs = (A, B, C + A * x0 + B * y0, D, Ee, F + D * x0 + Ee * y0)
    warped = hub.transform((cw, ch), Image.AFFINE, coeffs, resample=Image.BILINEAR)
    ref = wide.crop((x0, y0, x1, y1))

    def lum(im, s=4):
        a = np.asarray(im.convert("L"), float)
        a = a[: a.shape[0] // s * s, : a.shape[1] // s * s]
        a = a.reshape(a.shape[0] // s, s, a.shape[1] // s, s).mean((1, 3))
        a = np.log1p(a) ; return a
    ma = np.asarray(Image.new("L", hub.size, 255).transform((cw, ch), Image.AFFINE, coeffs), float) > 128
    wl, hl = lum(ref, 2), lum(warped, 2)
    # blur both, then slide
    def blur(a):
        from numpy.fft import rfft2, irfft2
        return a
    best = None
    m2 = ma[: ma.shape[0] // 2 * 2, : ma.shape[1] // 2 * 2].reshape(ma.shape[0] // 2, 2, ma.shape[1] // 2, 2).all((1, 3))
    for dy in range(-12, 13):
        for dx in range(-12, 13):
            w2 = np.roll(np.roll(wl, dy, 0), dx, 1)
            sel = m2 & np.roll(np.roll(m2, dy, 0), dx, 1)
            a_, b_ = w2[sel], hl[sel]
            c = np.corrcoef(a_, b_)[0, 1]
            if best is None or c > best[0]:
                best = (c, dx * 2, dy * 2)
    c0 = np.corrcoef(wl[m2], hl[m2])[0, 1]
    res = {"centre_px": [cx, cy], "corners_px": corners, "wide_px": [W, H], "wide_scale_arcsec_px": WIDE_SCALE,
           "hubble_scale_arcsec_px": hs, "corr_at_wcs": float(c0),
           "best_shift_px_wide_grid": {"dx": best[1], "dy": best[2], "corr": float(best[0])}}
    json.dump(res, open(os.path.join(out, "hubble-frame.json"), "w"), indent=1)
    print(json.dumps(res, indent=1))
    ov = wide.copy(); d = ImageDraw.Draw(ov)
    d.polygon(corners, outline=(255, 220, 0), width=6)
    d.line([corners[0], corners[1]], fill=(255, 60, 60), width=10)  # top edge
    ov.save(os.path.join(out, "wide-with-hubble-frame.jpg"), quality=92)
    Image.blend(ref, warped, 0.5).save(os.path.join(out, "check-blend.jpg"), quality=92)

main()
