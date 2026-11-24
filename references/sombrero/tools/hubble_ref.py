"""hubble_ref.py: Hubble's Sombrero (heic2506a) at full resolution, for the dust tools.

The frame is 14319 x 8477 px (26.5 kpc across, 1.85 pc a pixel). It is found, in this order:
  1. the path given (--hubble), else $SOMBRERO_HUBBLE, else the local copy DEFAULT_PATH;
  2. the lane strip of branch assets/478-sombrero (rows 2640 to 6160 at full width, lossless crop of
     the same file) with a 3072 px copy of the whole frame for what lies outside it.

Everything is placed as shares of the frame's width: a box is (x0, y0, x1, y1) with both axes in
units of the width. `region` gives a box at native resolution, `frame` the whole frame at a width,
`flat_region` a box laid flat about the core at any scale (a source is never enlarged by the
tools, as Hubble is only ever shown at its own scale or finer).
"""
import json
import math
import os
import subprocess

import numpy as np
from PIL import Image

Image.MAX_IMAGE_PIXELS = None

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_PATH = "/Users/pierregc/claude-workspace/sombrero/reference/heic2506a-large.jpg"
KPC = 26.5
CORE = (0.4921875, 0.3046875)  # Hubble's core, shares of the width (x, y)
ROLL = 5.63  # degrees the disk's major axis is tilted
STRIP, LOWRES, STRIP_META = "heic2506a-lane-strip.jpg", "heic2506a-3072.jpg", "heic2506a-lane-strip.json"


def fetch_asset(name):
    """A file of branch assets/478-sombrero, cached in /tmp/dust_bench_assets (None if absent)."""
    cache = os.path.join("/tmp", "dust_bench_assets")
    os.makedirs(cache, exist_ok=True)
    dest = os.path.join(cache, name)
    if not os.path.exists(dest):
        root = os.path.join(HERE, "..", "..", "..")
        subprocess.run(["git", "-C", root, "fetch", "origin", "assets/478-sombrero"], check=False,
                       capture_output=True)
        blob = subprocess.run(["git", "-C", root, "show", f"origin/assets/478-sombrero:{name}"],
                              capture_output=True)
        if blob.returncode:
            return None
        open(dest, "wb").write(blob.stdout)
    return dest


def _resize(im, width):
    height = round(im.height * width / im.width)
    im.draft("RGB", (width, height))
    return im.convert("RGB").resize((width, height), Image.LANCZOS)


class Source:
    """A picture in Hubble's framing: `width`, `height` in pixels, `region(box)` and `frame(width)`."""

    def __init__(self, im):
        self.im = im.convert("RGB")
        self.width, self.height = self.im.size
        self.name = "image"

    def region(self, box):
        x0, y0, x1, y1 = (round(v * self.width) for v in box)
        return self.im.crop((x0, y0, x1, y1))

    def frame(self, width):
        return self.im if width == self.width else self.im.resize(
            (width, round(self.height * width / self.width)), Image.LANCZOS)


class Hubble(Source):
    def __init__(self, path=None, strip=None):
        self.path, self.strip = path, strip
        if path:
            self.file = Image.open(path)
            self.width, self.height = self.file.size
            self.name = f"Hubble {self.width} px ({path})"
        else:
            meta = json.load(open(fetch_asset(STRIP_META)))
            self.file = Image.open(strip)
            self.width, self.height, self.y0 = meta["width"], meta["height"], meta["y0"]
            self.rows = meta["rows"]
            self.name = f"Hubble {self.width} px (lane strip rows {self.y0}-{self.y0 + self.rows})"
            self.low = Image.open(fetch_asset(LOWRES)).convert("RGB")

    def region(self, box):
        x0, y0, x1, y1 = (round(v * self.width) for v in box)
        if self.path:
            return self.file.crop((x0, y0, x1, y1)).convert("RGB")
        if y0 < self.y0 or y1 > self.y0 + self.rows:
            raise ValueError(f"rows {y0}-{y1} lie outside the lane strip ({self.y0}-{self.y0 + self.rows}); "
                             "point --hubble or $SOMBRERO_HUBBLE at the full frame")
        return self.file.crop((x0, y0 - self.y0, x1, y1 - self.y0)).convert("RGB")

    def frame(self, width):
        if self.path:
            return _resize(Image.open(self.path), width)
        # the strip over the 3072 px copy: a frame wider than the copy keeps its sky enlarged, its lane sharp
        height = round(width * self.height / self.width)
        out = self.low.resize((width, height), Image.LANCZOS)
        strip = _resize(self.file, width) if width < self.width else self.file
        out.paste(strip, (0, round(self.y0 * width / self.width)))
        return out


def load(path=None):
    """Hubble's frame; see the module doc for where it comes from."""
    path = path or os.environ.get("SOMBRERO_HUBBLE") or DEFAULT_PATH
    if os.path.exists(path):
        return Hubble(path)
    strip, low = fetch_asset(STRIP), fetch_asset(LOWRES)
    if not (strip and low):
        raise SystemExit(f"no Hubble frame: {path} is missing and branch assets/478-sombrero has no strip")
    return Hubble(None, strip)


def flat_region(src, box, scale, roll=ROLL, core=CORE):
    """`box` of the frame laid flat (rolled `roll` degrees about `core`), drawn with the frame `scale`
    px across: a picture round((x1 - x0) * scale) wide. The source is cut with a margin, brought to
    that scale and rolled, so a close-up of Hubble comes from the full frame, not from a copy."""
    x0, y0, x1, y1 = box
    s = abs(math.sin(math.radians(roll)))  # a point d from the core moves d * s sideways
    px = max(abs(y0 - core[1]), abs(y1 - core[1])) * s + 0.004
    py = max(abs(x0 - core[0]), abs(x1 - core[0])) * s + 0.004
    big = (max(x0 - px, 0), max(y0 - py, 0), min(x1 + px, 1), min(y1 + py, src.height / src.width))
    part = src.region(big)
    w = round((big[2] - big[0]) * scale)
    part = part.resize((w, round(part.height * w / part.width)), Image.LANCZOS) if w != part.width else part
    k = part.width / (big[2] - big[0])  # pixels per share of the width
    centre = ((core[0] - big[0]) * k, (core[1] - big[1]) * k)
    part = part.rotate(roll, resample=Image.BICUBIC, center=centre)
    left, top = round((x0 - big[0]) * k), round((y0 - big[1]) * k)
    return part.crop((left, top, left + round((x1 - x0) * scale), top + round((y1 - y0) * scale)))
