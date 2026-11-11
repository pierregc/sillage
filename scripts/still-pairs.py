#!/usr/bin/env python3
"""The CUDA engine's stills against Metal's, side by side (#277).

    still-pairs.py METAL CUDA --out DIR [--looks hubble,raw] [--scale 32]

METAL is a folder of Metal's stills, `<look>-<frame>.png` (the `stills/` of the render folder of
`assets/cuda-checks`), CUDA the folder `CUDAStillChecks.compareWithMetal` writes
(`SILLAGE_CUDA_STILLS_OUT`): `<look>-<frame>.png` as the CUDA engine draws it, `-half.png` with
the particle passes blending in half floats as Metal's targets do, `-post.png` with Metal's own
light developed by the CUDA post-processing alone.

For each pair one PNG of three panels, Metal's, CUDA's and the difference of the two, the
largest of the three channels' absolute differences on a scale from black through red and
yellow to white at SCALE levels of 255 (32 by default). A table of the PSNR, the mean difference
and the share of the pixels over 8 levels goes to `comparison.md` beside them and to the output.
"""

import argparse
import os
import sys

import numpy as np
from PIL import Image, ImageDraw


def load(path):
    return np.asarray(Image.open(path).convert("RGB")).astype(np.float64)


def measure(a, b):
    difference = a - b
    squares = (difference**2).mean()
    return {
        "psnr": 10 * np.log10(255**2 / squares) if squares > 0 else float("inf"),
        "mean": np.abs(difference).mean(),
        "largest": int(np.abs(difference).max()),
        "over": 100 * (np.abs(difference).max(axis=2) > 8).mean(),
    }


def heat(levels, scale):
    """Black, red, yellow, white for 0 to `scale` levels."""
    t = np.clip(levels / scale, 0, 1)
    red = np.clip(t * 3, 0, 1)
    green = np.clip(t * 3 - 1, 0, 1)
    blue = np.clip(t * 3 - 2, 0, 1)
    return (np.stack([red, green, blue], axis=-1) * 255).astype(np.uint8)


def panel(image, text):
    out = Image.fromarray(image)
    draw = ImageDraw.Draw(out)
    draw.rectangle([0, 0, 8 + 6 * len(text), 14], fill=(0, 0, 0))
    draw.text((4, 2), text, fill=(255, 255, 255))
    return out


def describe(m):
    psnr = "exact" if m["psnr"] == float("inf") else "%.1f dB" % m["psnr"]
    return "%s, mean %.3f, %.2f %% over 8" % (psnr, m["mean"], m["over"])


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    parser.add_argument("metal")
    parser.add_argument("cuda")
    parser.add_argument("--out", required=True)
    parser.add_argument("--looks", help="only these looks, separated by commas")
    parser.add_argument("--scale", type=float, default=32)
    arguments = parser.parse_args()

    wanted = set(arguments.looks.split(",")) if arguments.looks else None
    os.makedirs(arguments.out, exist_ok=True)
    rows = []
    for name in sorted(os.listdir(arguments.cuda)):
        stem, extension = os.path.splitext(name)
        if extension != ".png" or stem.endswith("-half") or stem.endswith("-post"):
            continue
        look = stem.rsplit("-", 1)[0]
        metal_path = os.path.join(arguments.metal, name)
        if (wanted and look not in wanted) or not os.path.exists(metal_path):
            continue
        metal = load(metal_path)
        drawn = load(os.path.join(arguments.cuda, name))
        row = {"name": stem, "drawn": measure(drawn, metal)}
        for variant in ("half", "post"):
            path = os.path.join(arguments.cuda, "%s-%s.png" % (stem, variant))
            if os.path.exists(path):
                row[variant] = measure(load(path), metal)
        rows.append(row)

        difference = np.abs(drawn - metal).max(axis=2)
        panels = [
            panel(metal.astype(np.uint8), "Metal"),
            panel(drawn.astype(np.uint8), "CUDA, " + describe(row["drawn"])),
            panel(heat(difference, arguments.scale), "difference, white at %g levels" % arguments.scale),
        ]
        width, height = panels[0].size
        sheet = Image.new("RGB", (width * 3, height))
        for index, image in enumerate(panels):
            sheet.paste(image, (index * width, 0))
        sheet.save(os.path.join(arguments.out, name), optimize=True)

    lines = [
        "| frame | drawn | half floats in the particle passes | Metal's light developed here |",
        "| --- | --- | --- | --- |",
    ]
    for row in rows:
        lines.append(
            "| %s | %s | %s | %s |"
            % (
                row["name"],
                describe(row["drawn"]),
                describe(row["half"]) if "half" in row else "",
                describe(row["post"]) if "post" in row else "",
            )
        )
    text = "\n".join(lines) + "\n"
    with open(os.path.join(arguments.out, "comparison.md"), "w") as handle:
        handle.write(text)
    sys.stdout.write(text)


if __name__ == "__main__":
    main()
