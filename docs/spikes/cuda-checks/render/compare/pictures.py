#!/usr/bin/env python3
"""Pictures of the CUDA renderer against Metal (#276).

Reads the maps `CUDARenderChecks.compare` writes (SILLAGE_CUDA_RENDER_MAPS): for each look and
frame the light Metal left, the light the CUDA renderer left on the CPU target, and their
relative difference a pixel. Writes one PNG a target: Metal's light, CUDA's light, the
difference in fixed point and the difference with half floats, each halved in size.

    pictures.py <maps folder> <output folder>
"""
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image


def tone(light):
    """The sum of RGB on a log scale, as a grey picture: the eye's view of both targets."""
    rgb = np.clip(light[..., :3], 0, None)
    scale = np.percentile(rgb.sum(axis=2), 99.9) or 1.0
    mapped = np.log1p(rgb / scale * 400.0) / np.log1p(400.0)
    return (np.clip(mapped, 0, 1) ** (1 / 2.2) * 255).astype(np.uint8)


def heat(difference):
    """A relative difference from 1e-4 (black) to 1 (white) on a log scale, through red and yellow."""
    level = np.clip((np.log10(np.clip(difference, 1e-4, 1)) + 4) / 4, 0, 1)
    red = np.clip(level * 3, 0, 1)
    green = np.clip(level * 3 - 1, 0, 1)
    blue = np.clip(level * 3 - 2, 0, 1)
    return (np.stack([red, green, blue], axis=2) * 255).astype(np.uint8)


def halved(picture):
    image = Image.fromarray(picture)
    return image.resize((image.width // 2, image.height // 2), Image.BOX)


def main():
    maps, out = Path(sys.argv[1]), Path(sys.argv[2])
    out.mkdir(parents=True, exist_ok=True)
    for entry in json.loads((maps / "maps.json").read_text()):
        width, height, stem = int(entry["width"]), int(entry["height"]), entry["stem"]

        def read(suffix, channels):
            values = np.fromfile(maps / f"{stem}-{suffix}.f32", dtype="<f4")
            return values.reshape(height, width, channels) if channels > 1 else values.reshape(height, width)

        panels = [
            halved(tone(read("metal-light", 4))),
            halved(tone(read("cuda-light", 4))),
            halved(heat(read("light-difference", 1))),
            halved(heat(read("half-light-difference", 1))),
        ]
        sheet = Image.new("RGB", (panels[0].width * 2, panels[0].height * 2))
        for index, panel in enumerate(panels):
            sheet.paste(panel, ((index % 2) * panels[0].width, (index // 2) * panels[0].height))
        sheet = sheet.quantize(colors=128, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE)
        sheet.save(out / f"{stem}.png", optimize=True)
        print(f"{stem}.png")


if __name__ == "__main__":
    main()
