#!/usr/bin/env python3
"""texture_proofs.py OUTDIR [--frames DIR] [--grid 3072|6144] [--light PNG] [--hubble-clean PNG]:
the proofs of texture.py (#487).

Scores against Hubble's cached figures (texture-ref.json), on one grid:
  floor        Hubble's left half against its right half, odd windows against even ones
  frames       every PNG of --frames (p1-p6 and fbm.png rendered by dust_bench.py at the grid's width)
  adversaries  (a) Gaussian-phase fields with Hubble's spectrum and histogram (IAAFT), keeping
               Hubble's mean profile (a1) or everything coherent over 1 kpc along (a2);
               (b) Hubble's left half mirrored onto the right; (c) fbm.png in --frames;
               should pass: (d) Hubble cut in 1.5 kpc blocks and shuffled, (e) Hubble slid by 3.7 kpc
  round trip   Hubble's apparent-opacity map laid on the bench light with the bench's compositing
Each adversary is scored as a map (the figures alone) and laid on the bench light as a frame (what
the explorers' frames go through). Writes OUTDIR/proofs-<grid>.json and, with --sheets, the three
sheets for Pierre: hubble-lane.jpg, aller-retour.jpg, p6-adversaires.jpg.
"""
import argparse
import glob
import json
import os
import sys

import numpy as np
from PIL import Image, ImageDraw
from scipy.ndimage import gaussian_filter, map_coordinates

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import texture as T  # noqa: E402
import dust_bench as D  # noqa: E402
import hubble_ref  # noqa: E402


def iaaft(x, rng, iters=60):
    """Surrogate with x's 2D power spectrum and x's histogram, phases random (Schreiber and
    Schmitz 1996). x is reflected to a periodic field first so its edges leak nothing."""
    p = np.concatenate([x, x[::-1]], 0)
    p = np.concatenate([p, p[:, ::-1]], 1)
    amp = np.abs(np.fft.rfft2(p))
    ranks = np.sort(p.ravel())
    y = rng.permutation(p.ravel()).reshape(p.shape)
    for _ in range(iters):
        y = np.fft.irfft2(amp * np.exp(1j * np.angle(np.fft.rfft2(y))), s=p.shape)
        y.ravel()[np.argsort(y.ravel())] = ranks
    return y[:x.shape[0], :x.shape[1]]


def adversaries(A, g, rng):
    """Maps in lane coordinates made from Hubble's own map A."""
    out = {}
    prof = A.mean(axis=1, keepdims=True)
    out["a1 gaussien, profil de Hubble"] = prof + iaaft(A - prof, rng)
    slow = gaussian_filter(A, [0, g.k(1.0)], mode="nearest")
    out["a2 gaussien, strates de Hubble"] = slow + iaaft(A - slow, rng)
    n = A.shape[1]
    mirrored = A.copy()
    mirrored[:, n - n // 2:] = A[:, :n // 2][:, ::-1]
    out["b miroir gauche-droite"] = mirrored
    block = int(round(g.k(1.5)))
    starts = list(range(0, n, block))
    order = rng.permutation(len(starts))
    out["d Hubble en blocs mélangés"] = np.concatenate([A[:, starts[i]:starts[i] + block] for i in order], 1)[:, :n]
    out["e Hubble glissé de 3,7 kpc"] = np.roll(A, int(round(g.k(3.7))), axis=1)
    return out


def lay(A, light, g, par=None, blur=True):
    """Lays a lane map (apparent opacity on luminance, lane coordinates of grid g) on the bench
    light (at g's width) as the bench lays near dust: transmission (1-b) + b exp(-k a_c N), N solved
    so the green channel, which carries most of the luminance, dims by exp(-A) (inverted on a table,
    so `grey` is honoured). The blur is the bench's, given in 3072 px pixels."""
    par = dict(D.DEFAULTS, **(par or {}))
    b, k = par["behind"], par["k"]
    tau = np.linspace(0, 30, 6001)
    a_g = 1 + par["redden"] / (1 + par["grey"] * tau) * D.CHANNELS[1]
    t_g = (1 - b) + b * np.exp(-tau * a_g)                        # falls with tau
    t = np.clip(np.exp(-A), t_g[-1], 1)
    N = np.interp(-t, -t_g, tau) / k
    full = np.zeros((len(g.vs), len(g.us)), np.float32)
    full[g.band] = N
    vi, ui = g.frame_coords()
    col = map_coordinates(full, [vi, ui], order=1, mode="constant", cval=0.0).astype(np.float32)
    if blur:
        col = gaussian_filter(col, par["blur"] * g.w / D.BASE_W)
    return Image.fromarray(D.attenuate(light, col, np.zeros_like(col), par))


def label_bar(text, width, size=30):
    im = Image.new("RGB", (width, size + 14), "black")
    ImageDraw.Draw(im).text((10, 5), text, font=T.font(size), fill="white")
    return im


def stack(parts):
    w = max(p.width for p in parts)
    out = Image.new("RGB", (w, sum(p.height for p in parts)), "black")
    y = 0
    for p in parts:
        out.paste(p, (0, y))
        y += p.height
    return out


def strip_rows(lin, width, rows=4):
    """The unwrapped lane in colour (display values), the core's side up, in `rows` stretches."""
    s = np.clip(lin[::-1], 0, 1) ** (1 / T.GAMMA)
    out = []
    for part in np.array_split(np.arange(s.shape[1]), rows):
        im = Image.fromarray((s[:, part] * 255).astype(np.uint8))
        out.append(im.resize((width, round(width * im.height / im.width)), Image.LANCZOS))
    return out


def map_rows(A, width, rows=4):
    return [T.opacity_image(A[:, part], width, rows=1) for part in np.array_split(np.arange(A.shape[1]), rows)]


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("out")
    p.add_argument("--frames", help="folder of bench frames (*.png at the grid's width)")
    p.add_argument("--grid", type=int, default=3072, choices=T.GRIDS)
    p.add_argument("--light", default=os.path.expanduser(
        "~/claude-workspace/sombrero/assets-wt/bench-light-12myr-26.5.png"))
    p.add_argument("--hubble-clean", help="cleaned Hubble frame at the grid's width (texture.build(cache=...))")
    p.add_argument("--sheets", action="store_true")
    p.add_argument("--blur", type=float, help="the bench's blur for the laid maps (3072 px pixels; default the bench's)")
    p.add_argument("--colour-fit", action="store_true", help="fit redden and grey on the round trip's colour")
    a = p.parse_args()
    bpar = {} if a.blur is None else {"blur": a.blur}
    blur_txt = f"{bpar.get('blur', D.DEFAULTS['blur']):g}".replace(".", ",")
    tag = "" if a.blur is None else f"-blur{a.blur:g}"
    os.makedirs(a.out, exist_ok=True)
    rng = np.random.default_rng(487)
    g = T.grid(a.grid)
    ref = T.reference()["grids"][str(g.w)]
    hub = Image.open(a.hubble_clean) if a.hubble_clean else T.clean_hubble(widths=(g.w,))[0][g.w]
    hlane = T.opacity(hub, g.w)
    light, _ = D.load_light(a.light, g.w)
    light = D.clean_light(light)
    res = {}

    def line(name, r):
        d = r["distance"]
        print(f"{name:40} {d['summary']:5.2f} | " + " ".join(f"{k[:6]} {v:4.1f}" for k, v in d.items() if k != "summary"),
              flush=True)
        res[name] = {"distance": d, "regions": r.get("regions"), "z": r["z"]}

    for name, hv in ref["halves"].items():
        a_ = {rg: {k: v[0] for k, v in fig.items()} for rg, fig in hv.items()}
        b_ = {rg: {k: v[1] for k, v in fig.items()} for rg, fig in hv.items()}
        d, z, per = T.distances(b_, None, dict(ref, regions=a_))
        line(f"plancher {name}", {"distance": d, "z": z, "regions": per})
    line("Hubble brut (points gardés)", T.score(hubble_raw(g.w), g.w))

    rt = lay(hlane.A, light, g, bpar)
    rt.save(os.path.join(a.out, f"aller-retour-{g.w}.png"))
    r_rt = T.score(rt, g.w)
    line(f"aller-retour (banc, flou {blur_txt})", r_rt)
    r_rt0 = T.score(lay(hlane.A, light, g, blur=False), g.w)
    line("aller-retour sans flou", r_rt0)
    if g.w == 6144:
        line("aller-retour rendu à 3072, grille 6144", T.score(rt.resize((3072, 1818), Image.LANCZOS), g.w))
    else:
        line("aller-retour rendu à 1536, grille 3072", T.score(rt.resize((1536, 909), Image.LANCZOS), g.w))
    line("aller-retour, behind 0,8", T.score(lay(hlane.A, light, g, dict(bpar, behind=0.8)), g.w))
    line("aller-retour, redden 1", T.score(lay(hlane.A, light, g, dict(bpar, redden=1.0)), g.w))
    if a.colour_fit:
        fits = []
        for redden in (1, 2, 3, 5, 7, 9, 12):
            for grey in (0, 0.25, 0.5, 1, 2, 4):
                r = T.score(lay(hlane.A, light, g, dict(bpar, redden=redden, grey=grey)), g.w)
                fits.append((r["distance"]["colour"], redden, grey, r))
        fits.sort(key=lambda f: f[0])
        best = fits[0]
        print("colour fit: best colour distance %.2f at redden %g grey %g; next %s" % (
            best[0], best[1], best[2], ", ".join(f"{f[0]:.2f} ({f[1]:g}, {f[2]:g})" for f in fits[1:4])))
        print("  z (centre: A_g-A_r in 4 depth bins, A_b-A_r in 4; then tips):",
              " ".join(f"{x:+.1f}" for x in best[3]["z"]["colour"]))
        print("  Hubble centre:", " ".join(f"{x:.2f}" for x in ref["regions"]["centre"]["colour"]))
        print("  best centre:  ", " ".join(f"{x:.2f}" for x in best[3]["figures"]["centre"]["colour"]))
        line(f"aller-retour, couleur ajustée (redden {best[1]:g}, grey {best[2]:g})", best[3])
    r_light = T.score(Image.fromarray(light), g.w)
    line("lumière du banc seule", r_light)

    # the far lane: Hubble's profile and grain ratio against what the estimator reads on dust-free light
    gf = T.grid(g.w, "far")
    hfar = T.opacity(hub, g.w, "far")
    far = {"hubble profile": T.figures(hfar)["regions"]["far"]["profile"],
           "hubble grain ratio": T.grain_ratio(hfar),
           "light-alone profile": r_light["far"]["profile"],
           "light-alone grain ratio": r_light["far"]["grain_ratio"]}
    print("far lane, profile across (v from away to towards the core), nats:")
    print("  Hubble      " + " ".join(f"{x:+.3f}" for x in far["hubble profile"]))
    print("  light alone " + " ".join(f"{x:+.3f}" for x in far["light-alone profile"]))
    print("  grain ratio Hubble " + " ".join(f"{k} {v:.2f}" for k, v in far["hubble grain ratio"].items()))

    adv = adversaries(hlane.A, g, rng)
    adv_frames = {}
    for name, A in adv.items():
        line(name + " (carte)", T.score_lane(A, g, ref))
        r = T.score(lay(A, light, g, bpar), g.w)
        adv_frames[name] = r
        line(name + " (banc)", r)

    frames = {}
    if a.frames:
        for f in sorted(glob.glob(os.path.join(a.frames, "*.png"))):
            name = os.path.splitext(os.path.basename(f))[0]
            frames[name] = T.score(f, g.w)
            line(name, frames[name])
            far[name + " far mean A"] = frames[name]["far"]["mean"]
        print("far lane mean A: Hubble %.3f, light alone %.3f, " % (float(hfar.A[gf.core].mean()), r_light["far"]["mean"])
              + ", ".join(f"{n} {frames[n]['far']['mean']:.3f}" for n in frames))
    res["far lane"] = far
    json.dump(res, open(os.path.join(a.out, f"proofs-{g.w}{tag}.json"), "w"), indent=1)
    if not a.sheets:
        return

    W = 2400
    hlin = g.to_grid(hub)
    strips = strip_rows(g.unwrap(hlin)[g.band], W)
    maps = map_rows(hlane.A, W)
    parts = [label_bar(f"Hubble, bande de poussière proche déroulée ({g.px * 1000:.1f} pc/pixel, côté du bulbe en "
                       "haut), puis son opacité apparente A = ln(I0/I), blanc 0, noir 2,5", W, 26)]
    for i, (s, m) in enumerate(zip(strips, maps)):
        u0, u1 = -T.U_MAX + i * 2 * T.U_MAX / 4, -T.U_MAX + (i + 1) * 2 * T.U_MAX / 4
        parts += [label_bar(f"de {u0:+.2f} à {u1:+.2f} kpc le long de la bande", W, 24), s, m]
    fstrips = strip_rows(gf.unwrap(hlin)[gf.band], W)
    fmaps = [T.opacity_image(hfar.A[:, part], W, a_max=0.25, rows=1)
             for part in np.array_split(np.arange(hfar.A.shape[1]), 4)]
    parts += [label_bar("Bande lointaine (moitié arrière de l'anneau, au-dessus du bulbe), déroulée de même, "
                        "côté du bulbe en haut ; opacité apparente dix fois plus contrastée (noir 0,25)", W, 26)]
    for i, (s, m) in enumerate(zip(fstrips, fmaps)):
        u0, u1 = -T.U_MAX + i * 2 * T.U_MAX / 4, -T.U_MAX + (i + 1) * 2 * T.U_MAX / 4
        parts += [label_bar(f"lointaine, de {u0:+.2f} à {u1:+.2f} kpc", W, 24), s, m]
    stack(parts).save(os.path.join(a.out, "hubble-lane.jpg"), quality=90)

    hb, hl, hc = crops(hub)
    rb, rl, rc = crops(rt)
    tw = W // 2

    def pair(x, y):
        th = round(x.height * tw / x.width)
        im = Image.new("RGB", (W, th), "black")
        im.paste(x.resize((tw, th), Image.LANCZOS), (0, 0))
        im.paste(y.resize((tw, th), Image.LANCZOS), (tw, 0))
        return im

    def band(x):
        return x.resize((W, round(x.height * W / x.width)), Image.LANCZOS)

    rt_strip = strip_rows(g.unwrap(g.to_grid(rt))[g.band], W)
    parts = [label_bar("Hubble (réduit à 3072 px, étoiles ponctuelles retirées)", W), band(hb),
             label_bar("Aller-retour : la carte d'opacité de Hubble posée sur la lumière du banc, composition du "
                       f"banc (behind 0,95, redden 3, flou {blur_txt})   distance {r_rt['distance']['summary']:.2f}, "
                       f"sans le flou {r_rt0['distance']['summary']:.2f}", W, 26),
             band(rb),
             label_bar("Bout gauche et sous le bulbe : Hubble à gauche, aller-retour à droite", W, 26),
             pair(hl, rl), pair(hc, rc),
             label_bar(f"Bande déroulée de -7,5 à -3,75 kpc ({g.px * 1000:.1f} pc/pixel) : Hubble, puis aller-retour", W, 26),
             strips[0], rt_strip[0],
             label_bar("Opacité apparente mesurée : Hubble, puis aller-retour", W, 26),
             maps[0], map_rows(r_rt["_A"], W)[0], T.panel(r_rt, "aller-retour", W)]
    stack(parts).save(os.path.join(a.out, "aller-retour.jpg"), quality=90)

    rows = [label_bar("Hubble, opacité apparente, de -7,5 à 0 kpc", W), map_rows(hlane.A, W, 2)[0]]
    items = []
    if "p6" in frames:
        items.append(("Prototype 6 (banc)", frames["p6"]))
    if "fbm" in frames:
        items.append(("c fBm réglé sur les anciens chiffres (banc)", frames["fbm"]))
    for name, r in adv_frames.items():
        items.append((name + " (banc)", r))
    items.append(("Aller-retour de Hubble (banc)", r_rt))
    for lbl, r in items:
        rows += [label_bar(f"{lbl}   distance {r['distance']['summary']:.2f}", W),
                 map_rows(r["_A"], W, 2)[0], T.bars(r["distance"], W)]
    stack(rows).save(os.path.join(a.out, f"p6-adversaires{tag}.jpg"), quality=88)


def crops(im):
    """The bench sheet's crops (band, left end, under the core), laid flat, at 3072 px scale."""
    src = hubble_ref.Source(im)
    return [hubble_ref.flat_region(src, b, D.BASE_W) for b in D.BOXES]


def hubble_raw(w):
    """Hubble at the grid's width, its point sources kept."""
    return hubble_ref.load().frame(w)


if __name__ == "__main__":
    main()
