#!/usr/bin/env python3
"""dust_prototypes.py OUTDIR [p1.json ...]: draws each prototype's sheet and face-on view, then the overview.

Writes pN-planche.jpg, pN-face.jpg, faces-6-prototypes.jpg and apercu-6-prototypes.jpg in OUTDIR.
"""
import glob
import json
import os
import sys
from concurrent.futures import ProcessPoolExecutor

from PIL import Image, ImageDraw

import dust_bench as d

HERE = os.path.dirname(os.path.abspath(__file__))


def main():
    out = sys.argv[1]
    files = sys.argv[2:] or sorted(glob.glob(os.path.join(HERE, "..", "dust-prototypes", "p*.json")))
    os.makedirs(out, exist_ok=True)
    light, _ = d.load_light(None, d.BASE_W)
    light = d.clean_light(light)
    pool = ProcessPoolExecutor(4)
    hub = Image.open(d.measure.HUBBLE)
    hub_fig = d.figures(hub)
    bands, faces = [], []
    for f in files:
        par = dict(d.DEFAULTS)
        data = json.load(open(f))
        label = data.pop("label")
        par.update(data)
        name = os.path.splitext(os.path.basename(f))[0]
        im = d.render(par, light, None, d.BASE_W, pool)
        fig = d.figures(im)
        print(label, "|", d.figures_line(fig), flush=True)
        d.make_sheet(os.path.join(out, name + "-planche.jpg"), [(label, im, fig)], hub_fig, 2400, True)
        face = d.face_image(im.face, label)
        face.save(os.path.join(out, name + "-face.jpg"), quality=92)
        bands.append((label, d.row(label, im, fig, 2400, wide=False)))
        faces.append(face)
    rows = [d.row("Hubble", hub, hub_fig, 2400, wide=False)] + [b for _, b in bands]
    sheet = Image.new("RGB", (2400, sum(r.height for r in rows)), "black")
    y = 0
    for r in rows:
        sheet.paste(r, (0, y))
        y += r.height
    sheet.save(os.path.join(out, "apercu-6-prototypes.jpg"), quality=90)
    cols = 3
    s = 700
    grid = Image.new("RGB", (cols * s, ((len(faces) + cols - 1) // cols) * s), "white")
    for i, fc in enumerate(faces):
        grid.paste(fc.resize((s, s), Image.LANCZOS), ((i % cols) * s, (i // cols) * s))
    grid.save(os.path.join(out, "faces-6-prototypes.jpg"), quality=90)


if __name__ == "__main__":
    main()
