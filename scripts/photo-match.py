#!/usr/bin/env python3
"""Photo match (#320): the picture's side of a match, and the sheet of one.

    photo-match.py picture <image> [--out <map.json>] [--width 256]
                   [--nuclei x,y,x,y | --marks <id>] [--preview <png>]
        reduces a photograph to a map of its extended light: linear luminance, compact sources
        (foreground stars, background galaxies, spikes and bleed trails) masked, binned to
        --width pixels, sky removed. Nuclei are fractions of the image width, x right and y
        down, as references/telescope/marks.json holds them (--marks <id> reads them there).
    photo-match.py sheet <match-result.json> [--out <sheet.png>]
        the picture, the take from the best view, the two overlaid, and the score along time
        and along each angle, from what `sillage-render match` wrote.

The match itself, the take's side, the search and the score are in Swift (PhotoMatch.swift);
docs/notes/photo-match.md has the method.
"""

import json
import math
import os
import sys

import numpy as np
from PIL import Image, ImageDraw

Image.MAX_IMAGE_PIXELS = None

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MARKS = os.path.join(ROOT, "references", "telescope", "marks.json")

WORK_WIDTH = 1200
# Scales in pixels at WORK_WIDTH: a star is a few pixels, while a tail or a body is smooth at
# MIDDLE; BODY is the scale at which a galaxy's light outweighs any star.
FINE, MIDDLE, BODY = 1.0, 4.0, 30.0
# A compact source stands this many times the detail's own noise above the broad light...
COMPACT_SIGMA = 4.0
# ...and a bright one, whose halo and spikes reach further, this many.
BRIGHT_SIGMA = 60.0
GROW, GROW_BRIGHT = 3, 10
RELATIVE = 0.1
# Broad light above this share of its maximum is a galaxy's body, where nothing is masked.
BODY_SHARE = 0.08
# A bin with more than this share of its pixels masked is masked.
MASKED_SHARE = 0.6


def box(a, radius, axis):
    if radius < 1:
        return a
    pad = [(0, 0)] * a.ndim
    pad[axis] = (radius + 1, radius)
    c = np.cumsum(np.pad(a, pad, mode="edge"), axis=axis)
    n = a.shape[axis]
    hi = np.take(c, np.arange(2 * radius + 1, 2 * radius + 1 + n), axis=axis)
    lo = np.take(c, np.arange(0, n), axis=axis)
    return (hi - lo) / (2 * radius + 1)


def blur(a, sigma):
    # Three box passes per axis approximate a Gaussian.
    radius = max(int(round(math.sqrt(12 * sigma * sigma / 3 + 1) / 2 - 0.5)), 0)
    for axis in (0, 1):
        for _ in range(3):
            a = box(a, radius, axis)
    return a


def grow(mask, radius):
    if radius < 1:
        return mask
    m = mask.astype(np.float32)
    for axis in (0, 1):
        m = box(m, radius, axis)
    return m > 1e-6


def luminance(image):
    rgb = np.asarray(image.convert("RGB"), dtype=np.float32) / 255
    linear = np.where(rgb <= 0.04045, rgb / 12.92, ((rgb + 0.055) / 1.055) ** 2.4)
    return linear @ np.array([0.2126, 0.7152, 0.0722], dtype=np.float32)


def robust(values):
    median = np.median(values)
    return median, 1.4826 * np.median(np.abs(values - median)) + 1e-9


def sky_level(values, rounds=6):
    kept = values
    for _ in range(rounds):
        level, spread = robust(kept)
        kept = values[values < level + 3 * spread]
    return robust(kept)


def compact_mask(y):
    middle = blur(y, MIDDLE)
    detail = blur(y, FINE) - middle
    _, noise = robust(detail)
    broad = blur(y, BODY)
    floor, _ = sky_level(broad.ravel()[:: max(broad.size // 200_000, 1)])
    body = broad - floor > BODY_SHARE * (broad.max() - floor)
    # The grain of a tail grows with its light, so the bar does too.
    bar = noise + RELATIVE * np.maximum(middle - floor, 0)
    compact = (detail > COMPACT_SIGMA * bar) & ~body
    bright = (detail > BRIGHT_SIGMA * bar) & ~body
    return grow(compact, GROW) | grow(bright, GROW_BRIGHT), body


def bin_down(y, mask, width):
    h, w = y.shape
    height = max(int(round(width * h / w)), 1)
    rows = np.linspace(0, h, height + 1).astype(int)
    cols = np.linspace(0, w, width + 1).astype(int)
    light = np.full((height, width), np.nan, dtype=np.float64)
    keep = (~mask).astype(np.float64)
    weighted = y * keep
    for i in range(height):
        band, band_keep = weighted[rows[i] : rows[i + 1]], keep[rows[i] : rows[i + 1]]
        for j in range(width):
            cell = band_keep[:, cols[j] : cols[j + 1]]
            kept = cell.sum()
            if kept > (1 - MASKED_SHARE) * cell.size:
                light[i, j] = band[:, cols[j] : cols[j + 1]].sum() / kept
    return light


def nuclei_from(args):
    if "--nuclei" in args:
        values = [float(v) for v in args[args.index("--nuclei") + 1].split(",")]
        if len(values) % 2:
            sys.exit("--nuclei wants x,y pairs")
        return [values[i : i + 2] for i in range(0, len(values), 2)]
    if "--marks" in args:
        wanted = args[args.index("--marks") + 1]
        with open(MARKS) as f:
            for entry in json.load(f)["images"]:
                if entry["id"] == wanted:
                    return [g["nucleus"] for g in entry["galaxies"]]
        sys.exit(f"no image {wanted} in {MARKS}")
    return None


def option(args, name, default=None):
    return args[args.index(name) + 1] if name in args else default


def picture(args):
    path = args[0]
    width = int(option(args, "--width", 256))
    image = Image.open(path)
    w, h = image.size
    work = image.resize((WORK_WIDTH, max(int(round(WORK_WIDTH * h / w)), 1)), Image.LANCZOS)
    y = luminance(work)
    mask, _ = compact_mask(y)
    light = bin_down(y, mask, width)
    seen = light[np.isfinite(light)]
    sky, noise = sky_level(seen)
    light -= sky
    reference = np.percentile(light[np.isfinite(light)], 99.5)
    depth = float(np.clip(math.log10(max(reference, 1e-9) / (2 * noise)), 1.0, 4.0))
    out = option(args, "--out", os.path.splitext(path)[0] + ".map.json")
    document = {
        "version": 1,
        "source": os.path.basename(path),
        "width": width,
        "height": light.shape[0],
        "depth": round(depth, 3),
        "light": [None if not np.isfinite(v) else round(float(v), 7) for v in light.ravel()],
    }
    nuclei = nuclei_from(args)
    if nuclei:
        document["nuclei"] = nuclei
    with open(out, "w") as f:
        json.dump(document, f, separators=(",", ":"))
    masked = 1 - seen.size / light.size
    print(f"{out}: {width} x {light.shape[0]}, depth {depth:.2f} decades, {masked:.1%} of bins masked")
    preview = option(args, "--preview")
    if preview:
        levels = to_levels(light, depth)
        grey = grey_image(levels, depth)
        rgb = np.stack([grey] * 3, axis=-1)
        rgb[~np.isfinite(light)] = (90, 0, 0)
        Image.fromarray(rgb).resize((width * 3, light.shape[0] * 3), Image.NEAREST).save(preview)


def to_levels(light, depth):
    finite = light[np.isfinite(light)]
    reference = max(np.percentile(finite, 99.5), 1e-12)
    with np.errstate(invalid="ignore", divide="ignore"):
        return np.log10(np.maximum(light / reference, 10.0**-depth))


def grey_image(levels, depth):
    v = np.nan_to_num((levels + depth) / depth, nan=0.0)
    return (np.clip(v, 0, 1) * 255).astype(np.uint8)


def plot(draw, box_, points, best, title, xlabel):
    x0, y0, x1, y1 = box_
    draw.rectangle(box_, outline=(90, 90, 90))
    draw.text((x0 + 6, y0 + 4), title, fill=(220, 220, 220))
    if not points:
        return
    xs = [p[0] for p in points]
    lo, hi = min(xs), max(xs)
    span = hi - lo or 1

    def at(x, s):
        return (x0 + 8 + (x - lo) / span * (x1 - x0 - 16), y1 - 18 - s * (y1 - y0 - 40))

    for level in (0.25, 0.5, 0.75, 1.0):
        _, y = at(lo, level)
        draw.line([(x0 + 8, y), (x1 - 8, y)], fill=(45, 45, 45))
        draw.text((x1 - 34, y - 12), f"{level:.2f}", fill=(110, 110, 110))
    draw.line([at(x, s) for x, s in points], fill=(120, 200, 255), width=2)
    if best is not None:
        bx, _ = at(best, 0)
        draw.line([(bx, y0 + 20), (bx, y1 - 18)], fill=(255, 150, 90))
    draw.text((x0 + 6, y1 - 15), f"{lo:.0f}", fill=(140, 140, 140))
    draw.text((x1 - 60, y1 - 15), f"{hi:.0f} {xlabel}", fill=(140, 140, 140))


def sheet(args):
    path = args[0]
    with open(path) as f:
        result = json.load(f)
    w, h = result["width"], result["height"]
    depth = result["depth"]

    def levels(name):
        return np.array([np.nan if v is None else v for v in result[name]], dtype=np.float64).reshape(h, w)

    shown, taken = levels("pictureLevels"), levels("takeLevels")
    scale = max(1, 512 // w)
    a, b = grey_image(shown, depth), grey_image(taken, depth)
    masked = ~np.isfinite(shown)
    left = np.stack([a] * 3, axis=-1)
    left[masked] = (70, 0, 0)
    middle = np.stack([b] * 3, axis=-1)
    right = np.stack([a, b, a], axis=-1)
    right[masked] = (70, 0, 0)
    panels = [Image.fromarray(p).resize((w * scale, h * scale), Image.BILINEAR) for p in (left, middle, right)]
    pw, ph = w * scale, h * scale
    gap, plot_h = 12, 220
    canvas = Image.new("RGB", (3 * pw + 4 * gap, ph + plot_h * 2 + 5 * gap + 40), (12, 12, 14))
    draw = ImageDraw.Draw(canvas)
    best = result["best"]
    draw.text(
        (gap, 10),
        f"{result.get('source', '')}  score {best['score']:.3f} at {best['megayears']:.0f} Myr"
        f"  elevation {best['elevation']:.1f}  azimuth {best['azimuth']:.1f}  roll {best['roll']:.1f}"
        f"  {best['kpcPerWidth']:.1f} kpc across",
        fill=(235, 235, 235),
    )
    for i, (panel, label) in enumerate(
        zip(panels, ["picture", "take from the best view", "overlaid: picture magenta, take green"])
    ):
        x = gap + i * (pw + gap)
        canvas.paste(panel, (x, 40))
        draw.text((x + 6, 44), label, fill=(255, 210, 120))
    curves = result["curves"]
    top = 40 + ph + gap
    cw = (canvas.width - 3 * gap) // 2
    plot(draw, (gap, top, gap + cw, top + plot_h), curves.get("time"), best["megayears"], "score along time", "Myr")
    plot(draw, (2 * gap + cw, top, 2 * gap + 2 * cw, top + plot_h), curves.get("roll"), best["roll"], "score along the roll", "deg")
    top += plot_h + gap
    plot(draw, (gap, top, gap + cw, top + plot_h), curves.get("elevation"), best["elevation"], "score along the elevation", "deg")
    plot(draw, (2 * gap + cw, top, 2 * gap + 2 * cw, top + plot_h), curves.get("azimuth"), best["azimuth"], "score along the azimuth", "deg")
    out = option(args, "--out", os.path.splitext(path)[0] + ".png")
    canvas.save(out)
    print(out)


def main():
    if len(sys.argv) < 3 or sys.argv[1] not in ("picture", "sheet"):
        sys.exit(__doc__)
    {"picture": picture, "sheet": sheet}[sys.argv[1]](sys.argv[2:])


if __name__ == "__main__":
    main()
