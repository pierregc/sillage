#!/usr/bin/env python3
"""closeup.py OUT.jpg [frame ...] [--scale N|native] [--labels a,b] [--hubble PATH] [--quality 92]

Close-ups of the lane's left tip, centre and right tip, laid flat about the core (rolled 5.63 degrees),
each frame beside Hubble's at the same scale. A frame is Hubble's framing (26.5 kpc across); the
scale is the px the whole frame would measure across (default 6144, twice the bench's 3072). Hubble
is cut from its full frame (14319 px across, see hubble_ref.py), so it is never enlarged below that
scale; a bench narrower than the scale is enlarged, labelled as such. With no frame, or `--scale
native`, Hubble stands alone at its own resolution (1.85 pc a pixel).

A bench render can be made wider with dust_bench.py --width (the light stays the 3072 px one).
"""
import argparse
import os

from PIL import Image, ImageDraw

import dust_bench as d
import hubble_ref

W = 0.16  # share of the frame's width, per close-up
BOXES = [(x, y, x + W, y + 0.08) for x, y in ((0.125, 0.28), (hubble_ref.CORE[0] - W / 2, 0.29), (0.71, 0.285))]
NAMES = ["left tip", "centre", "right tip"]


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("out")
    p.add_argument("frames", nargs="*")
    p.add_argument("--scale", default="6144", help="px across the whole frame, or native")
    p.add_argument("--labels", default="")
    p.add_argument("--hubble", help="Hubble's full frame (default $SOMBRERO_HUBBLE, the local copy, "
                                    "then the lane strip of assets/478-sombrero)")
    p.add_argument("--quality", type=int, default=92)
    g = p.parse_args()

    hub = hubble_ref.load(g.hubble)
    scale = hub.width if g.scale == "native" else int(g.scale)
    if scale > hub.width:
        raise SystemExit(f"Hubble's frame is {hub.width} px across: no sharper than --scale {hub.width}")
    labels = g.labels.split(",") if g.labels else []
    sources = [("Hubble, %.2f pc a pixel" % (hubble_ref.KPC * 1000 / scale), hub)]
    for n, f in enumerate(g.frames):
        im = Image.open(f).convert("RGB")
        note = "" if im.width >= scale else f", enlarged {scale / im.width:.1f}x"
        lab = labels[n] if n < len(labels) else os.path.basename(f)
        sources.append((f"{lab} ({im.width} px{note})", hubble_ref.Source(im)))

    head = 44
    cols = []
    for title, src in sources:
        panels = [hubble_ref.flat_region(src, box, scale) for box in BOXES]
        pw, ph = panels[0].size
        col = Image.new("RGB", (pw, head + len(panels) * (ph + 30)), "black")
        draw = ImageDraw.Draw(col)
        draw.text((8, 6), title, font=d.font(28), fill="white")
        for k, im in enumerate(panels):
            draw.text((8, head + k * (ph + 30) + 2), NAMES[k], font=d.font(22), fill=(190, 190, 190))
            col.paste(im, (0, head + k * (ph + 30) + 28))
        cols.append(col)
    sheet = Image.new("RGB", (sum(c.width + 6 for c in cols) - 6, cols[0].height), "black")
    x = 0
    for c in cols:
        sheet.paste(c, (x, 0))
        x += c.width + 6
    sheet.save(g.out, quality=g.quality)
    print(g.out, sheet.size)


if __name__ == "__main__":
    main()
