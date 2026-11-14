#!/usr/bin/env python3
"""Photo ruler: how far a frame is from a photograph of galaxies, in six numbers (#315).

    photo-ruler.py <image>... [--json] [--overlays DIR] [--width PX]

Every image is read at 960 px wide, references and renders alike (--width for another size,
where a grain that 960 px averages away shows):

  lit       share of the frame 0.10 in OKLab L above the sky
  L50, L99  OKLab L of the lit pixels at the median and the 99th centile
  saturated share of the lit pixels with an OKLab chroma above 0.05
  grain     rms contrast of the linear light finer than 1.5 px, against the light at 8 px,
            over the galaxies' light (lit pixels inside the light blurred at 16 px)
  shadow    share of the body darker than its surroundings and yellower, as dust makes it

The sky is the 5th centile of L blurred at 4 px, so a frame that is all galaxy has no sky.
--overlays draws the lit, saturated and shadow pixels into DIR to check them by eye.
docs/notes/a-frame-that-passes-for-a-photograph.md has what the numbers say.
"""

import json
import math
import os
import sys

import numpy as np
from PIL import Image

Image.MAX_IMAGE_PIXELS = None

WIDTH = 960
LIT = 0.10
SATURATED = 0.05
SKY_CENTILE = 5
# Shadow: light at 3 px under this share of the light at 24 px, inside the body.
SHADOW_SCALES = (3.0, 24.0)
SHADOW_SHARE = 0.65


def srgb_to_linear(rgb):
    return np.where(rgb <= 0.04045, rgb / 12.92, ((rgb + 0.055) / 1.055) ** 2.4)


def oklab(linear):
    lms = np.cbrt(
        linear
        @ np.array(
            [
                [0.4122214708, 0.2119034982, 0.0883024619],
                [0.5363325363, 0.6806995451, 0.2817188376],
                [0.0514459929, 0.1073969566, 0.6299787005],
            ]
        )
    )
    return lms @ np.array(
        [
            [0.2104542553, 1.9779984951, 0.0259040371],
            [0.7936177850, -2.4285922050, 0.7827717662],
            [-0.0040720468, 0.4505937099, -0.8086757660],
        ]
    )


def box(a, width, axis):
    r = width // 2
    pad = [(0, 0), (0, 0)]
    pad[axis] = (r + 1, r)
    total = np.cumsum(np.pad(a, pad, mode="reflect"), axis=axis)
    n = a.shape[axis]
    return (np.take(total, range(width, width + n), axis=axis) - np.take(total, range(n), axis=axis)) / width


def blur(a, sigma):
    # Three box passes per axis approximate a Gaussian of this sigma.
    ideal = math.sqrt(4 * sigma * sigma + 1)
    lower = int(ideal) - (1 - int(ideal) % 2)
    passes = round((12 * sigma * sigma - 3 * lower * lower - 12 * lower - 9) / (-4 * lower - 4))
    for axis in (0, 1):
        for index in range(3):
            a = box(a, lower if index < passes else lower + 2, axis)
    return a


def load(path, width=WIDTH):
    image = Image.open(path)
    image.draft("RGB", (width, width))
    image = image.convert("RGB")
    if image.width != width:
        image = image.resize((width, round(image.height * width / image.width)), Image.LANCZOS)
    return np.asarray(image, dtype=np.float64) / 255.0


def measure(rgb):
    linear = srgb_to_linear(rgb)
    lab = oklab(linear)
    L = lab[..., 0]
    chroma = np.hypot(lab[..., 1], lab[..., 2])
    Y = linear @ np.array([0.2126, 0.7152, 0.0722])

    sky = np.percentile(blur(L, 4), SKY_CENTILE)
    lit = L > sky + LIT
    # The body's rim always stands under the light around it, so only its inside is searched.
    body = blur((blur(L, 16) > sky + LIT).astype(np.float64), SHADOW_SCALES[1] / 2) > 0.97
    near, broad = (blur(Y, s) for s in SHADOW_SCALES)
    yellower = blur(lab[..., 2], SHADOW_SCALES[0]) > blur(lab[..., 2], SHADOW_SCALES[1])
    shadow = body & (near < SHADOW_SHARE * broad) & yellower
    masks = {"lit": lit, "saturated": lit & (chroma > SATURATED), "shadow": shadow}
    if lit.sum() < 100:
        return {"sky": round(float(sky), 3), "lit": round(float(lit.mean()), 3)}, masks

    fine = (Y - blur(Y, 1.5)) / np.maximum(blur(Y, 8), 1e-4)
    # Over the galaxies' light only: a field star alone outweighs a whole disk's grain.
    galaxy = lit & (blur(L, 16) > sky + LIT)
    numbers = {
        "sky": float(sky),
        "lit": float(lit.mean()),
        "L50": float(np.median(L[lit])),
        "L99": float(np.percentile(L[lit], 99)),
        "saturated": float(masks["saturated"].sum() / lit.sum()),
        "grain": float(np.sqrt(np.mean(fine[galaxy] ** 2))),
        "shadow": float(shadow.sum() / max(body.sum(), 1)),
    }
    return {k: round(v, 3) for k, v in numbers.items()}, masks


def overlay(rgb, masks, path):
    out = rgb * 0.5
    out[masks["lit"]] += np.array([0.0, 0.25, 0.0])
    out[masks["saturated"]] += np.array([0.25, 0.0, 0.25])
    out[masks["shadow"]] = np.array([1.0, 0.85, 0.0])
    Image.fromarray((np.clip(out, 0, 1) * 255).astype(np.uint8)).save(path, quality=85)


def main():
    args = sys.argv[1:]
    as_json = "--json" in args
    overlays = None
    if "--overlays" in args:
        overlays = args[args.index("--overlays") + 1]
        os.makedirs(overlays, exist_ok=True)
    width = int(args[args.index("--width") + 1]) if "--width" in args else WIDTH
    paths = [a for i, a in enumerate(args) if not a.startswith("--") and (i == 0 or args[i - 1] not in ("--overlays", "--width"))]
    if not paths:
        sys.exit(__doc__)
    rows = {}
    for path in paths:
        rgb = load(path, width)
        numbers, masks = measure(rgb)
        rows[path] = numbers
        if overlays:
            name = os.path.splitext(os.path.basename(path))[0]
            overlay(rgb, masks, os.path.join(overlays, name + ".jpg"))
        if not as_json:
            print(os.path.basename(path), "  ".join(f"{k} {v:.3f}" for k, v in numbers.items()))
    if as_json:
        json.dump(rows, sys.stdout, indent=1)
        print()


if __name__ == "__main__":
    main()
