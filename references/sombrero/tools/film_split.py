#!/usr/bin/env python3
"""film_split.py: the film's freeze frame beside Hubble, at the film's size (#506).

  film_split.py split FRAME_4K OUTDIR          01-freeze-cut.jpg and 01-freeze-pair.jpg
  film_split.py framing FRAME OUT.png          a core-centred frame (26.5 kpc across its width) cut to
                                               Hubble's framing (core at 504,312 of 1024), for
                                               texture.py and closeup.py; missing edges mirrored
  film_split.py sheet OUT.jpg TILE_W label=png ...   a contact sheet, three tiles a row

A film frame is 26.5 kpc across, the nucleus at its centre (the flight aims at the galaxy's centre).
Hubble is resampled from its full frame (hubble_ref.py) to the same scale, centred on its nucleus,
which sits 12 px right of hubble_ref.CORE at 3840 px (45 px at full resolution).
"""
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hubble_ref  # noqa: E402

Image.MAX_IMAGE_PIXELS = None
NUCLEUS = (hubble_ref.CORE[0] + 12 / 3840, hubble_ref.CORE[1] + 2 / 3840)  # shares of the width
FONT = "/System/Library/Fonts/Avenir Next.ttc"


def crop(a, x0, y0, w, h):
    """a[y0:y0+h, x0:x0+w], mirrored where the box leaves the array."""
    pad = max(0, -x0, -y0, x0 + w - a.shape[1], y0 + h - a.shape[0])
    if pad:
        a = np.pad(a, ((pad, pad), (pad, pad), (0, 0)), mode="reflect")
    return a[y0 + pad:y0 + pad + h, x0 + pad:x0 + pad + w]


def hubble(width, height, kpc=hubble_ref.KPC):
    """Hubble at `kpc` across `width` px, its nucleus at the centre."""
    im = Image.open(os.environ.get("SOMBRERO_HUBBLE") or hubble_ref.DEFAULT_PATH)
    s = width * hubble_ref.KPC / kpc / im.width
    size = (round(im.width * s), round(im.height * s))
    im.draft("RGB", size)
    a = np.asarray(im.convert("RGB").resize(size, Image.LANCZOS))
    cx, cy = NUCLEUS[0] * size[0], NUCLEUS[1] * size[0]
    return Image.fromarray(crop(a, round(cx - width / 2), round(cy - height / 2), width, height))


def label(im, xy, text, anchor, size=34):
    ImageDraw.Draw(im).text(xy, text, font=ImageFont.truetype(FONT, size, index=5), fill=(200, 200, 200),
                            anchor=anchor)


def split(frame, out):
    sim = Image.open(frame).convert("RGB")
    W, H = sim.size
    cut = sim.copy()
    cut.paste(hubble(W, H).crop((W // 2, 0, W, H)), (W // 2, 0))
    label(cut, (60, H - 50), "Simulation  ·  Sillage", "ls")
    label(cut, (W - 60, H - 50), "Hubble  ·  ESA/Hubble & NASA, K. Noll (heic2506a)", "rs")
    cut.save(os.path.join(out, "01-freeze-cut.jpg"), quality=92)
    kpc, pw = 22.0, W // 2  # whole galaxies, each at half width: 22 kpc across, the frame's height in kpc
    ph = round(pw * hubble_ref.KPC * H / W / kpc)
    k = pw * hubble_ref.KPC / (kpc * W)
    s = sim.resize((round(W * k), round(H * k)), Image.LANCZOS)
    s = s.crop(((s.width - pw) // 2, (s.height - ph) // 2, (s.width - pw) // 2 + pw, (s.height - ph) // 2 + ph))
    pair, y = Image.new("RGB", (W, H)), (H - ph) // 2
    pair.paste(s, (0, y))
    pair.paste(hubble(pw, ph, kpc), (pw, y))
    label(pair, (pw // 2, y + ph + 70), "Simulation  ·  Sillage", "ms")
    label(pair, (pw + pw // 2, y + ph + 70), "Hubble  ·  ESA/Hubble & NASA, K. Noll", "ms")
    pair.save(os.path.join(out, "01-freeze-pair.jpg"), quality=92)


def framing(frame, out):
    a = np.asarray(Image.open(frame).convert("RGB"))
    h, w = a.shape[:2]
    x0, y0 = w // 2 - round(hubble_ref.CORE[0] * w), h // 2 - round(hubble_ref.CORE[1] * w)
    Image.fromarray(crop(a, x0, y0, w, round(w * 606 / 1024))).save(out)


def sheet(out, tw, items):
    items = [a.split("=", 1) for a in items]
    ims = [Image.open(p).convert("RGB") for _, p in items]
    th, lab, cols = round(tw * ims[0].height / ims[0].width), max(40, tw // 20), 3
    rows = (len(ims) + cols - 1) // cols
    sh = Image.new("RGB", (cols * tw + (cols + 1) * 8, rows * (th + lab) + 8), (18, 18, 18))
    for i, ((name, _), im) in enumerate(zip(items, ims)):
        x, y = 8 + (i % cols) * (tw + 8), 8 + (i // cols) * (th + lab)
        sh.paste(im.resize((tw, th), Image.LANCZOS), (x, y))
        label(sh, (x + 6, y + th + lab // 2), name, "lm", max(18, tw // 40))
    sh.save(out, quality=92)


if __name__ == "__main__":
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd == "split":
        split(*args)
    elif cmd == "framing":
        framing(*args)
    elif cmd == "sheet":
        sheet(args[0], int(args[1]), args[2:])
    else:
        raise SystemExit(__doc__)
