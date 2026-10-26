#!/usr/bin/env python3
"""Telescope colours: what Hubble and Webb pictures of galaxies are made of, in OKLab.

    telescope-colours.py fetch
        downloads the reference images listed in references/telescope/marks.json
        into out/telescope-images/ (not committed)
    telescope-colours.py measure [--overlays]
        splits every image into regions from its marks and writes
        references/telescope/<set>.json; --overlays also draws the regions
        into out/telescope-overlays/ to check them by eye

The marks give each galaxy a nucleus, a core radius and one or more ellipses for its body.
Everything else is found from brightness at two scales; docs/notes/telescope-colour.md has
the method and what the numbers say.
"""

import json
import math
import os
import sys
import urllib.request

import numpy as np
from PIL import Image, ImageDraw

Image.MAX_IMAGE_PIXELS = None

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REFS = os.path.join(ROOT, "references", "telescope")
MARKS = os.path.join(REFS, "marks.json")
IMAGES = os.path.join(ROOT, "out", "telescope-images")
OVERLAYS = os.path.join(ROOT, "out", "telescope-overlays")

WIDTH = 1600
REGIONS = ["core", "disk", "knots", "dust", "tails", "sky"]
# Blur radii in pixels at WIDTH: a knot is a few pixels, a dust lane tens.
KNOT_SCALES = (1.0, 8.0)
DUST_SCALES = (3.0, 24.0)
# Faint light must be extended at this scale, so a small background galaxy is not a tail.
LIGHT_SCALE = 40.0
KNOT_PERCENTILE = 95
# Dust that absorbs is darker than the broad light and yellower than the galaxy; dust that
# emits is brighter than its surroundings.
DUST_PERCENTILE = {"absorbs": 75, "emits": 80}
BROAD_SCALE = 60.0
# OKLab L above the sky level: below SKY_MARGIN is sky, above LIGHT_MARGIN is faint galaxy light.
SKY_MARGIN = 0.03
LIGHT_MARGIN = 0.05
SAMPLES = 20000
VIVID_PERCENTILE = 84
# OKLab hue in degrees: pink sits near 350, orange near 60, blue near 260.
WARM_HUES = (330, 110)


def srgb_to_oklab(rgb):
    c = np.where(rgb <= 0.04045, rgb / 12.92, ((rgb + 0.055) / 1.055) ** 2.4)
    lms = c @ np.array(
        [
            [0.4122214708, 0.2119034982, 0.0883024619],
            [0.5363325363, 0.6806995451, 0.2817188376],
            [0.0514459929, 0.1073969566, 0.6299787005],
        ]
    )
    lms = np.cbrt(lms)
    return lms @ np.array(
        [
            [0.2104542553, 1.9779984951, 0.0259040371],
            [0.7936177850, -2.4285922050, 0.7827717662],
            [-0.0040720468, 0.4505937099, -0.8086757660],
        ]
    )


def oklab_to_hex(lab):
    lms = np.array(lab) @ np.array(
        [
            [1.0, 1.0, 1.0],
            [0.3963377774, -0.1055613458, -0.0894841775],
            [0.2158037573, -0.0638541728, -1.2914855480],
        ]
    )
    lms = lms**3
    c = lms @ np.array(
        [
            [4.0767416621, -1.2684380046, -0.0041960863],
            [-3.3077115913, 2.6097574011, -0.7034186147],
            [0.2309699292, -0.3413193965, 1.7076147010],
        ]
    )
    c = np.clip(c, 0, 1)
    s = np.where(c <= 0.0031308, 12.92 * c, 1.055 * c ** (1 / 2.4) - 0.055)
    return "#" + "".join(f"{round(v * 255):02x}" for v in s)


def box(a, radius, axis):
    pad = [(0, 0), (0, 0)]
    pad[axis] = (radius + 1, radius)
    c = np.cumsum(np.pad(a, pad, mode="reflect"), axis=axis)
    n = a.shape[axis]
    hi = np.take(c, range(2 * radius + 1, 2 * radius + 1 + n), axis=axis)
    lo = np.take(c, range(0, n), axis=axis)
    return (hi - lo) / (2 * radius + 1)


def blur(a, sigma):
    # Three box passes approximate a Gaussian of this sigma.
    radius = max(1, round((math.sqrt(4 * sigma * sigma + 1) - 1) / 2))
    for axis in (0, 1):
        for _ in range(3):
            a = box(a, radius, axis)
    return a


def load(image_id):
    path = os.path.join(IMAGES, image_id + ".jpg")
    im = Image.open(path)
    im.draft("RGB", (WIDTH, WIDTH))
    im = im.convert("RGB")
    height = round(im.height * WIDTH / im.width)
    im = im.resize((WIDTH, height), Image.LANCZOS)
    return np.asarray(im, dtype=np.float64) / 255.0


def ellipse_mask(shape, ellipse):
    h, w = shape
    y, x = np.mgrid[0:h, 0:w] / w
    cx, cy = ellipse["centre"]
    a, b = ellipse["axes"]
    t = math.radians(ellipse["angle"])
    u = (x - cx) * math.cos(t) + (y - cy) * math.sin(t)
    v = -(x - cx) * math.sin(t) + (y - cy) * math.cos(t)
    return (u / a) ** 2 + (v / b) ** 2 <= 1


def segment(lab, entry):
    shape = lab.shape[:2]
    h, w = shape
    L = lab[..., 0]
    y, x = np.mgrid[0:h, 0:w] / w

    core = np.zeros(shape, bool)
    body = np.zeros(shape, bool)
    for galaxy in entry["galaxies"]:
        if "nucleus" in galaxy:
            nx, ny = galaxy["nucleus"]
            core |= (x - nx) ** 2 + (y - ny) ** 2 <= galaxy["core"] ** 2
        for ellipse in galaxy["body"]:
            body |= ellipse_mask(shape, ellipse)
    body |= core

    knot_detail = blur(L, KNOT_SCALES[0]) - blur(L, KNOT_SCALES[1])
    dust_detail = blur(L, DUST_SCALES[0]) - blur(L, DUST_SCALES[1])
    light = blur(L, LIGHT_SCALE)
    local = blur(L, DUST_SCALES[0])
    inner = body & ~core

    knots = inner & (knot_detail > max(0.02, np.percentile(knot_detail[inner], KNOT_PERCENTILE)))
    if entry["dust"] == "absorbs":
        near_knot = blur(knots.astype(np.float64), 4.0) > 0.05
        yellow = blur(lab[..., 2], DUST_SCALES[0])
        excess = yellow - blur(lab[..., 2], BROAD_SCALE)
        yellower = (yellow > np.percentile(yellow[inner], DUST_PERCENTILE["absorbs"])) | (
            excess > np.percentile(excess[inner], DUST_PERCENTILE["absorbs"])
        )
        shadow = blur(L, DUST_SCALES[0]) < blur(L, BROAD_SCALE) - 0.02
        dust = inner & ~near_knot & shadow & yellower
    else:
        cut = np.percentile(dust_detail[inner], DUST_PERCENTILE["emits"])
        dust = inner & ~knots & (dust_detail > max(0.01, cut))
    disk = inner & ~knots & ~dust

    regions = {"core": core, "disk": disk, "knots": knots, "dust": dust}
    outside = ~body
    if outside.mean() > 0.02:
        sky_level = np.percentile(light[outside], 20)
        compact = knot_detail > np.percentile(knot_detail[outside], KNOT_PERCENTILE)
        regions["tails"] = outside & ~compact & (light > sky_level + LIGHT_MARGIN) & (local > sky_level + LIGHT_MARGIN)
        regions["sky"] = outside & ~compact & (light < sky_level + SKY_MARGIN) & (local < sky_level + SKY_MARGIN)
    else:
        regions["tails"] = np.zeros(shape, bool)
        regions["sky"] = np.zeros(shape, bool)
    return regions


def summary(pixels):
    median = np.median(pixels, axis=0)
    return {
        "median": [round(v, 4) for v in median],
        "chroma": round(float(np.median(np.hypot(pixels[:, 1], pixels[:, 2]))), 4),
        "hue": round(math.degrees(math.atan2(median[2], median[1])) % 360, 1),
        "srgb": oklab_to_hex(median),
    }


def describe(pixels):
    # Medians are nearly grey; the colour a picture is remembered by lives in its most
    # saturated pixels, split warm (pink, red, gold) against cool (blue, cyan, violet).
    chroma = np.hypot(pixels[:, 1], pixels[:, 2])
    vivid = pixels[chroma >= np.percentile(chroma, VIVID_PERCENTILE)]
    hue = np.degrees(np.arctan2(vivid[:, 2], vivid[:, 1])) % 360
    warm = (hue >= WARM_HUES[0]) | (hue < WARM_HUES[1])
    accents = {}
    for name, part in (("warm", vivid[warm]), ("cool", vivid[~warm])):
        if len(part) >= 20:
            accents[name] = {"share": round(len(part) / len(vivid), 3), **summary(part)}
    s = summary(pixels)
    return {
        "median": s["median"],
        "p16": [round(v, 4) for v in np.percentile(pixels, 16, axis=0)],
        "p84": [round(v, 4) for v in np.percentile(pixels, 84, axis=0)],
        "chroma": s["chroma"],
        "hue": s["hue"],
        "srgb": s["srgb"],
        "vivid": accents,
    }


def draw_overlay(rgb, regions, entry):
    tints = {
        "core": (255, 230, 0),
        "knots": (0, 255, 255),
        "dust": (255, 0, 255),
        "tails": (255, 140, 0),
        "sky": (40, 80, 255),
    }
    out = (rgb * 255).astype(np.float64)
    for name, colour in tints.items():
        m = regions[name]
        out[m] = 0.45 * out[m] + 0.55 * np.array(colour)
    im = Image.fromarray(out.astype(np.uint8))
    d = ImageDraw.Draw(im)
    w = rgb.shape[1]
    for galaxy in entry["galaxies"]:
        for e in galaxy["body"]:
            pts = []
            t = math.radians(e["angle"])
            for k in range(73):
                p = 2 * math.pi * k / 72
                u, v = e["axes"][0] * math.cos(p), e["axes"][1] * math.sin(p)
                pts.append(
                    (
                        (e["centre"][0] + u * math.cos(t) - v * math.sin(t)) * w,
                        (e["centre"][1] + u * math.sin(t) + v * math.cos(t)) * w,
                    )
                )
            d.line(pts, fill=(0, 255, 0), width=2)
    im.thumbnail((900, 900))
    os.makedirs(OVERLAYS, exist_ok=True)
    im.save(os.path.join(OVERLAYS, entry["id"] + ".jpg"), quality=85)


def fetch(marks):
    os.makedirs(IMAGES, exist_ok=True)
    for entry in marks["images"]:
        path = os.path.join(IMAGES, entry["id"] + ".jpg")
        if os.path.exists(path):
            continue
        print("fetching", entry["url"])
        urllib.request.urlretrieve(entry["url"], path)


def measure(marks, overlays):
    rng = np.random.default_rng(125)
    pooled = {}
    per_image = {}
    for entry in marks["images"]:
        rgb = load(entry["id"])
        lab = srgb_to_oklab(rgb)
        regions = segment(lab, entry)
        if overlays:
            draw_overlay(rgb, regions, entry)
        stats = {}
        for name in REGIONS:
            pixels = lab[regions[name]]
            if len(pixels) < 200:
                continue
            stats[name] = {"share": round(float(regions[name].mean()), 4), **describe(pixels)}
            pick = rng.choice(len(pixels), min(SAMPLES, len(pixels)), replace=False)
            pooled.setdefault(entry["set"], {}).setdefault(name, []).append(pixels[pick])
        per_image[entry["id"]] = stats
        summary = "  ".join(f"{n} {s['share']:.3f} {s['srgb']}" for n, s in stats.items())
        print(f"{entry['id']:10} {entry['set']:17} {summary}")

    for name, description in marks["sets"].items():
        entries = [e for e in marks["images"] if e["set"] == name]
        if not entries:
            continue
        regions = {}
        for region in REGIONS:
            samples = pooled.get(name, {}).get(region, [])
            if samples:
                regions[region] = {"images": len(samples), **describe(np.concatenate(samples))}
        out = {
            "set": name,
            "description": description,
            "space": "OKLab, from the published sRGB JPEG",
            "regions": regions,
            "images": {
                e["id"]: {"subject": e["subject"], "page": e["page"], "credit": e["credit"], "regions": per_image[e["id"]]}
                for e in entries
            },
        }
        with open(os.path.join(REFS, name + ".json"), "w") as handle:
            json.dump(out, handle, indent=2)
            handle.write("\n")


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in ("fetch", "measure"):
        sys.exit(__doc__)
    with open(MARKS) as handle:
        marks = json.load(handle)
    if sys.argv[1] == "fetch":
        fetch(marks)
    else:
        measure(marks, "--overlays" in sys.argv[2:])


if __name__ == "__main__":
    main()
