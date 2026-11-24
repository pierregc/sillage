#!/usr/bin/env python3
"""screen_tile.py b|bz|c SPEC.json OUT [--plain]: a dust screen's tile (#506) from a ring of the bench.

  b  track B's field (dust_track_b.field: the bench's sky column N on the polar grid, 312 radii from
     4.6 to 11 kpc by 21504 azimuths), resampled to 16384 azimuths. --plain keeps its mean by radius.
  bz track B's texture in the ring's own coordinates (carrier "polar", prof "radius", no tips: the same
     statistics at every azimuth) as standard normal scores by radius, with a lut of the column at each
     radius against the score: what a renewing screen blends (inside.dustScreen.renew).
  c  track C's ring drawn at Hubble's angle (24 M grains, near and far halves apart, the bench's sky
     column per pixel at 6144 px), read back onto the polar grid as a thin layer on the mid-plane,
     each half from its own map: at 6 degrees the screen shows what the bench showed, the clouds'
     heights included as the sky shift they make there; from any other angle it is a flat sheet.

Writes OUT.f32 (raw little-endian float32, radius rows by azimuth columns, theta = -pi/2 on the
disk's -v axis, the side facing a camera on Hubble's axis) and OUT.tile.json, as `inside.dustScreen`
reads it. The values are the column across the plane: the sky column times sin 6 degrees.
"""
import json
import math
import os
import sys
from concurrent.futures import ProcessPoolExecutor

import numpy as np
from PIL import Image
from scipy.ndimage import map_coordinates

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
WIDTH = 16384  # Metal's widest texture


def track_b(spec, plain=False):
    import dust_track_b as B
    N = B.field(json.load(open(spec)))["A"].astype(np.float32)
    if plain:
        N = np.repeat(N.mean(1, keepdims=True), N.shape[1], 1)
    pad = 256
    wrapped = np.concatenate([N[:, -pad:], N, N[:, :pad]], 1)
    im = Image.fromarray(wrapped, "F").resize((round(wrapped.shape[1] * WIDTH / N.shape[1]), N.shape[0]),
                                              Image.LANCZOS)
    p = round(pad * WIDTH / N.shape[1])
    return np.asarray(im)[:, p:p + WIDTH], (B.R0, B.R1)


def track_b_scores(spec):
    import dust_bench as D
    import dust_track_b as B
    from scipy.special import ndtr, ndtri
    s = json.load(open(spec))
    if s.get("carrier") != "polar" or s.get("prof") != "radius" or s.get("tips", True):
        raise SystemExit("bz takes a ring texture: carrier polar, prof radius, tips false")
    st = B.stats(s.get("J", 6), s.get("K", 4), s.get("win"), "centre")
    rng = np.random.default_rng(s.get("seed", 1))     # as texture_field draws it
    shape = B.polar_shape(s.get("c", 1.0))
    X = (B.gaussian_field(st, shape, rng) if s["family"] == "gauss" else
         B.synthesise(st, shape, rng, s.get("iters", 6), s["family"], stat_keys=s.get("keys", ("corr", "rel", "mag"))))
    Xp = B.carry(X, "polar", s.get("c", 1.0))
    Z = ndtri((Xp.argsort(1).argsort(1) + 0.5) / Xp.shape[1]).astype(np.float32)
    pad = 256
    wrapped = np.concatenate([Z[:, -pad:], Z, Z[:, :pad]], 1)
    im = Image.fromarray(wrapped, "F").resize((round(wrapped.shape[1] * WIDTH / Z.shape[1]), Z.shape[0]),
                                              Image.LANCZOS)
    p = round(pad * WIDTH / Z.shape[1])
    Z = np.asarray(im)[:, p:p + WIDTH]
    Q = B.quantiles_by_radius()
    xs = np.linspace(-4, 4, 256)
    A = np.stack([np.interp(ndtr(xs), np.linspace(0, 1, Q.shape[1]), Q[i]) for i in range(Q.shape[0])])
    par = dict(D.DEFAULTS, **B.BASE, **s.get("par", {}))
    N = B.a_to_n(np.maximum(A, 0) * s.get("contrast", 1.0), par, 0.97)
    return Z, N.astype(np.float32), (B.R0, B.R1)


def track_c(spec, width=6144):
    import dust_bench as db
    import dust_track_b as B
    import dust_track_c as C
    par = C.load_par([spec])
    t = C.build_table(par)
    bp = C.bench_par(par)
    bp["share"], bp["law"] = "split", "old"
    jobs = [(lo, hi, seed, width, bp) for lo, hi, seed, _, _ in C.jobs_of(t, par, width)]
    maps, total = None, 0.0
    with ProcessPoolExecutor(8, initializer=C._init, initargs=(t, par)) as pool:
        for mp, wt, _, _ in pool.map(C._chunk, jobs):
            maps = mp if maps is None else [a + b for a, b in zip(maps, mp)]
            total += wt
    near, far = [db.to_column(m, total, bp, width) for m in maps[:2]]
    rs, ts = B.axes(312, WIDTH)
    TH, R = np.meshgrid(ts, rs)
    x, y = R * np.cos(TH), R * np.sin(TH)
    dx, dy = db.centre_offset(bp)
    sx, sy = x + dx, y * math.sin(db.INC) + dy
    ux = sx * math.cos(db.ROLL) + sy * math.sin(db.ROLL)
    uy = -sx * math.sin(db.ROLL) + sy * math.cos(db.ROLL)
    kpp = db.FRAME_KPC / width
    fx, fy = db.CORE[0] * width + ux / kpp - 0.5, db.CORE[1] * width - uy / kpp - 0.5
    N = np.where(y < 0, map_coordinates(near, [fy, fx], order=1, mode="constant"),
                 map_coordinates(far, [fy, fx], order=1, mode="constant"))
    return N.astype(np.float32), (B.R0, B.R1)


def main():
    track, spec, out = sys.argv[1], sys.argv[2], sys.argv[3]
    if track == "bz":
        Z, N, radii = track_b_scores(spec)
        Z.astype("<f4").tofile(out + ".f32")
        lut = N * math.sin(math.radians(6))
        lut.astype("<f4").tofile(out + "-lut.f32")
        json.dump({"width": Z.shape[1], "height": Z.shape[0], "radii": list(radii), "data": os.path.basename(out) + ".f32",
                   "lut": {"data": os.path.basename(out) + "-lut.f32", "width": lut.shape[1], "range": [-4.0, 4.0]}},
                  open(out + ".tile.json", "w"))
        print(json.dumps({"tile": out + ".tile.json", "score sd": float(Z.std()), "lut max": float(lut.max())}))
        return
    N, radii = track_b(spec, "--plain" in sys.argv) if track == "b" else track_c(spec)
    tile = np.maximum(N, 0) * math.sin(math.radians(6))
    tile.astype("<f4").tofile(out + ".f32")
    json.dump({"width": tile.shape[1], "height": tile.shape[0], "radii": list(radii),
               "data": os.path.basename(out) + ".f32"}, open(out + ".tile.json", "w"))
    print(json.dumps({"tile": out + ".tile.json", "max": float(tile.max()), "mean": float(tile.mean())}))


if __name__ == "__main__":
    main()
