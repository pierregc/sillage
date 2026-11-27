#!/usr/bin/env python3
"""closeup.py OUT.jpg [frame ...] [--scale N|native] [--labels a,b] [--hubble PATH] [--quality 92] [--far FAR.jpg]
closeup.py --reference OUT.jpg [--hubble PATH]

Close-ups of the lane's left tip, centre and right tip, and of the far half over the core, laid flat
about the core (rolled 5.63 degrees), each frame beside Hubble's at the same scale. A frame is
Hubble's framing (26.5 kpc across); the scale is the px the whole frame would measure across (default
6144, twice the bench's 3072). Hubble is cut from its full frame (14319 px across, see hubble_ref.py),
so it is never enlarged below that scale; a bench narrower than the scale is enlarged, labelled as such.
With no frame, or `--scale native`, Hubble stands alone at its own resolution (1.85 pc a pixel).

A second sheet (FAR.jpg, default OUT-far.jpg) holds the far half: left, centre and right of the core,
each frame plain and with its smooth light divided out (`enhance`), since the far lane is faint.
`--reference` draws Hubble alone at its own scale, near and far halves round the core, plain and
enhanced, with the near lane, the far lane and the inner dust marked apart (#495).

A bench render can be made wider with dust_bench.py --width (the light stays the 3072 px one).
"""
import argparse
import os

import numpy as np
from PIL import Image, ImageDraw
from scipy.ndimage import gaussian_filter, grey_closing, zoom

import dust_bench as d
import hubble_ref
import measure

W = 0.16  # share of the frame's width, per close-up
BOXES = [(x, y, x + W, y + 0.08) for x, y in ((0.125, 0.28), (hubble_ref.CORE[0] - W / 2, 0.29), (0.71, 0.285))]
NAMES = ["left tip", "centre", "right tip", "far half, over the core"]
K = 1 / hubble_ref.KPC  # a kpc as a share of the width


def kpc_box(x0, x1, top, bottom):
    """A box from kpc along the disk (x0..x1) and over the core's row (top..bottom, up positive)."""
    cx, cy = hubble_ref.CORE
    return (cx + x0 * K, cy - top * K, cx + x1 * K, cy - bottom * K)


BOXES.append(kpc_box(-2.12, 2.12, 1.55, -0.57))   # the far half over the core, as wide as the others
FAR = [("far half, left", kpc_box(-6.0, -2.0, 1.2, -0.3)), ("far half, centre", kpc_box(-2.0, 2.0, 1.2, -0.3)),
       ("far half, right", kpc_box(2.0, 6.0, 1.2, -0.3))]
REF = [("left", kpc_box(-6.6, -2.4, 1.3, -1.3)), ("centre, round the core", kpc_box(-2.1, 2.1, 1.3, -1.3)),
       ("right", kpc_box(2.4, 6.6, 1.3, -1.3))]


def enhance(im, scale, size=0.3, lo=0.72, hi=1.04):
    """The picture divided by its own smooth light, shown from `lo` (black) to `hi` (white). The smooth
    light is the display luminance with every dark feature narrower than `size` kpc filled in (a grey
    closing with a disk `size` across, at a quarter of the resolution) and smoothed over half that; dust
    lanes and filaments thinner than `size` stand out, the bulge's gradient goes. Each channel is divided
    by that light times the panel's median colour, so a warm light stays grey and a reddened filament
    shows. Same treatment for any frame at the same `scale` (px across the whole frame)."""
    rgb = np.asarray(im).astype(np.float32) / 255
    lum = rgb @ measure.LUMA.astype(np.float32)
    ppk = scale / hubble_ref.KPC
    q = 4
    small = lum[::q, ::q]
    n = max(3, int(size * ppk / q) | 1)
    yy, xx = np.mgrid[-(n // 2):n // 2 + 1, -(n // 2):n // 2 + 1]
    smooth = grey_closing(small, footprint=xx ** 2 + yy ** 2 <= (n // 2) ** 2, mode="nearest")
    smooth = gaussian_filter(smooth, 0.5 * size * ppk / q, mode="nearest")
    smooth = zoom(smooth, (lum.shape[0] / small.shape[0], lum.shape[1] / small.shape[1]), order=1)
    smooth = smooth[:lum.shape[0], :lum.shape[1]]
    # each channel over the smooth light times the panel's median colour, so a warm light is not shown
    # orange and the dust's reddening is left
    tint = np.median(rgb.reshape(-1, 3) / np.maximum(lum.reshape(-1, 1), 1e-3), axis=0)
    ratio = rgb / np.maximum(smooth[..., None] * tint, 1e-3)
    return Image.fromarray((np.clip((ratio - lo) / (hi - lo), 0, 1) * 255 + 0.5).astype(np.uint8))


def flat(src, box, scale):
    """`box` laid flat at `scale`, with a margin of the smooth light's size round it for `enhance`."""
    m = 0.35 * K
    big = (box[0] - m, box[1] - m, box[2] + m, box[3] + m)
    im = hubble_ref.flat_region(src, big, scale)
    e = enhance(im, scale)
    px = round(m * scale)
    crop = (px, px, im.width - px, im.height - px)
    return im.crop(crop), e.crop(crop)


def ticks(im, box, scale, colour=(255, 255, 255)):
    """Ticks on the left edge at the core's row and every 0.5 kpc over and under it."""
    dr = ImageDraw.Draw(im)
    row0 = (hubble_ref.CORE[1] - box[1]) * scale
    ppk = scale * K
    for h in np.arange(-1.5, 1.51, 0.5):
        y = row0 - h * ppk
        if 0 <= y < im.height:
            L = 18 if h == 0 else 10
            dr.line((0, y, L, y), fill=colour, width=2)
            dr.text((L + 3, y - 9), f"{h:+.1f}" if h else "0", font=d.font(14), fill=colour)
    return im


def sources_of(g, hub, scale):
    labels = g.labels.split(",") if g.labels else []
    out = [("Hubble, %.2f pc a pixel" % (hubble_ref.KPC * 1000 / scale), hub)]
    for n, f in enumerate(g.frames):
        im = Image.open(f).convert("RGB")
        note = "" if im.width >= scale else f", enlarged {scale / im.width:.1f}x"
        lab = labels[n] if n < len(labels) else os.path.basename(f)
        out.append((f"{lab} ({im.width} px{note})", hubble_ref.Source(im)))
    return out


def column(title, panels, names, gap=30, head=44):
    pw = max(p.width for p in panels)
    col = Image.new("RGB", (pw, head + sum(p.height + gap for p in panels)), "black")
    draw = ImageDraw.Draw(col)
    draw.text((8, 6), title, font=d.font(28), fill="white")
    y = head
    for name, im in zip(names, panels):
        draw.text((8, y + 2), name, font=d.font(22), fill=(190, 190, 190))
        col.paste(im, (0, y + gap - 2))
        y += im.height + gap
    return col


def side_by_side(cols, path, quality):
    sheet = Image.new("RGB", (sum(c.width + 6 for c in cols) - 6, max(c.height for c in cols)), "black")
    x = 0
    for c in cols:
        sheet.paste(c, (x, 0))
        x += c.width + 6
    sheet.save(path, quality=quality)
    print(path, sheet.size)


def main_sheet(sources, scale, path, quality):
    cols = []
    for title, src in sources:
        panels = [ticks(hubble_ref.flat_region(src, box, scale), box, scale) if k == 3
                  else hubble_ref.flat_region(src, box, scale) for k, box in enumerate(BOXES)]
        cols.append(column(title, panels, NAMES))
    side_by_side(cols, path, quality)


def far_sheet(sources, scale, path, quality):
    """Per frame two columns, plain and enhanced, rows the far half's left, centre and right."""
    cols = []
    for title, src in sources:
        pairs = [flat(src, box, scale) for _, box in FAR]
        names = [n for n, _ in FAR]
        cols.append(column(title, [ticks(p, box, scale) for p, (_, box) in zip([a for a, _ in pairs], FAR)], names))
        cols.append(column("  smooth light divided out", [ticks(e, box, scale) for e, (_, box) in
                                                           zip([b for _, b in pairs], FAR)], names))
    side_by_side(cols, path, quality)


# The reference's zones over the core's centre column, kpc under (-) and over (+) the core's row, measured
# on the full frame (measure.py --halves --width 0) and read off the enhanced close-up
ZONES = [("near half: dense dark band", -0.70, -0.51, (90, 150, 255)),
         ("near half: orange filaments", -1.00, -0.70, (255, 160, 60)),
         ("inner dust, inside the ring", -0.35, 0.35, (210, 120, 255)),
         ("far half: its inner rim, over the core", 0.40, 0.56, (90, 230, 120))]


def far_line(hub, box, scale, width):
    """Rows of the far lane across a reference panel: its darkest row measured column by column on the
    full frame (measure.halves), over |x| 0.75 to 4.5 kpc where it stands clear, a running median of three."""
    rows = [r for r in measure.halves(hub, scale) if 0.75 <= abs(r["x"]) <= 4.5]
    xs = np.array([r["x"] for r in rows])
    h = np.array([r["far"]["offset"] for r in rows])
    h = np.array([np.median(h[max(i - 1, 0):i + 2]) for i in range(len(h))])
    ppk = scale * K
    xcol = (box[0] - hubble_ref.CORE[0]) / K + np.arange(width) / ppk
    row0 = (hubble_ref.CORE[1] - box[1]) * scale
    ok = (np.abs(xcol) >= 0.75) & (np.abs(xcol) <= 4.5)
    hh = np.where(xcol < 0, np.interp(xcol, xs[xs < 0], h[xs < 0]), np.interp(xcol, xs[xs > 0], h[xs > 0]))
    return row0 - hh * ppk, ok


def reference_sheet(hub, path, quality):
    """Hubble alone at its own scale: rows left, centre, right; plain and enhanced; the zones marked in a
    margin beside the centre row and the far line dotted on the enhanced panels."""
    scale = hub.width
    margin = 360
    rows = []
    for name, box in REF:
        plain, enh = flat(hub, box, scale)
        rows_, ok = far_line(hub, box, scale, enh.width)
        dr = ImageDraw.Draw(enh)
        for x in range(0, enh.width, 30):
            if ok[x]:
                y = rows_[x] - 26   # just over the line, so the filaments stay visible
                dr.line((x, y, x + 14, y), fill=ZONES[3][3], width=4)
        ticks(plain, box, scale)
        ticks(enh, box, scale)
        row = Image.new("RGB", (margin + plain.width + 12 + enh.width, plain.height + 50), "black")
        dr = ImageDraw.Draw(row)
        dr.text((margin + 8, 6), f"{name}: plain", font=d.font(34), fill="white")
        dr.text((margin + plain.width + 20, 6), f"{name}: smooth light divided out (green dashes: just over "
                f"the far lane's darkest row, measured)", font=d.font(34), fill="white")
        row.paste(plain, (margin, 50))
        row.paste(enh, (margin + plain.width + 12, 50))
        row0 = 50 + (hubble_ref.CORE[1] - box[1]) * scale
        ppk = scale * K
        if name.startswith("centre"):
            for k, (label, lo, hi, colour) in enumerate(ZONES):
                y0, y1 = row0 - hi * ppk, row0 - lo * ppk
                x = margin - 30 - 22 * (k % 2)
                dr.line((x, y0, x, y1), fill=colour, width=8)
                dr.line((x, y0, margin - 4, y0), fill=colour, width=3)
                dr.line((x, y1, margin - 4, y1), fill=colour, width=3)
                words = label.split(": ")
                ty = (y0 + y1) / 2 - 22 * len(words)
                for w_ in words:
                    dr.text((8, ty), w_, font=d.font(26), fill=colour)
                    ty += 30
        else:
            dr.text((8, row0 - 20), "core's row", font=d.font(26), fill=(200, 200, 200))
        rows.append(row)
    head = Image.new("RGB", (rows[0].width, 120), "black")
    dr = ImageDraw.Draw(head)
    dr.text((10, 8), "Hubble (heic2506a) at its own resolution, 1.85 pc a pixel: the near half of the ring under "
            "the core, the far half over it, the inner dust round it", font=d.font(40), fill="white")
    dr.text((10, 62), "Laid flat about the core (5.63 degrees). Ticks every 0.5 kpc from the core's row. Smooth light: "
            "Hubble's own luminance with every dark feature under 0.3 kpc filled in, smoothed over 0.15 kpc.",
            font=d.font(28), fill=(200, 200, 200))
    sheet = Image.new("RGB", (rows[0].width, head.height + sum(r.height + 16 for r in rows)), "black")
    sheet.paste(head, (0, 0))
    y = head.height
    for r in rows:
        sheet.paste(r, (0, y))
        y += r.height + 16
    sheet.save(path, quality=quality)
    print(path, sheet.size)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("out")
    p.add_argument("frames", nargs="*")
    p.add_argument("--scale", default="6144", help="px across the whole frame, or native")
    p.add_argument("--labels", default="")
    p.add_argument("--hubble", help="Hubble's full frame (default $SOMBRERO_HUBBLE, the local copy, "
                                    "then the lane strip of assets/478-sombrero)")
    p.add_argument("--quality", type=int, default=92)
    p.add_argument("--far", help="the far half's sheet (default OUT-far.jpg)")
    p.add_argument("--reference", action="store_true", help="Hubble alone, near and far halves, zones marked")
    g = p.parse_args()

    hub = hubble_ref.load(g.hubble)
    if g.reference:
        reference_sheet(hub, g.out, g.quality)
        return
    scale = hub.width if g.scale == "native" else int(g.scale)
    if scale > hub.width:
        raise SystemExit(f"Hubble's frame is {hub.width} px across: no sharper than --scale {hub.width}")
    sources = sources_of(g, hub, scale)
    main_sheet(sources, scale, g.out, g.quality)
    far_sheet(sources, scale, g.far or os.path.splitext(g.out)[0] + "-far.jpg", g.quality)


if __name__ == "__main__":
    main()
