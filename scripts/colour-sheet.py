#!/usr/bin/env python3
"""Spike #118: key frames of every variant in one sheet, the clips in one animated grid, and the
colourfulness of each variant.

usage: colour-sheet.py <variant dir> <title> [variant ...]
"""
import glob
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont, ImageSequence

CELL = (480, 270)
LABEL = 150


def font(size):
    for path in ["/System/Library/Fonts/SFNS.ttf", "/System/Library/Fonts/Helvetica.ttc"]:
        if os.path.exists(path):
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()


def colourfulness(image):
    """Hasler and Süsstrunk (2003) over the lit pixels, and the share of clipped ones."""
    rgb = np.asarray(image.convert("RGB"), dtype=np.float64)
    lit = rgb.max(axis=2) > 24
    r, g, b = (rgb[..., i][lit] for i in range(3))
    rg = r - g
    yb = 0.5 * (r + g) - b
    m = np.hypot(rg.std(), yb.std()) + 0.3 * np.hypot(rg.mean(), yb.mean())
    clipped = (rgb.max(axis=2) >= 254).sum() / max(lit.sum(), 1)
    return m, clipped


def main():
    folder, title = sys.argv[1], sys.argv[2]
    variants = sys.argv[3:] or ["baseline", "fixed", "radius", "component", "population", "mix"]
    frames = sorted(
        {int(p.rsplit("-f", 1)[1][:3]) for p in glob.glob(os.path.join(folder, "baseline-f*.png"))}
    )
    rows = [v for v in variants if os.path.exists(os.path.join(folder, f"{v}-f{frames[0]:03d}.png"))]
    sheet = Image.new("RGB", (LABEL + len(frames) * (CELL[0] + 4), 40 + len(rows) * (CELL[1] + 4)), (20, 20, 20))
    draw = ImageDraw.Draw(sheet)
    draw.text((10, 10), title, fill=(230, 230, 230), font=font(18))
    scores = []
    for row, variant in enumerate(rows):
        y = 40 + row * (CELL[1] + 4)
        draw.text((10, y + CELL[1] // 2 - 10), variant, fill=(230, 230, 230), font=font(18))
        values = []
        for column, frame in enumerate(frames):
            image = Image.open(os.path.join(folder, f"{variant}-f{frame:03d}.png"))
            values.append(colourfulness(image))
            sheet.paste(image.convert("RGB").resize(CELL, Image.LANCZOS), (LABEL + column * (CELL[0] + 4), y))
        m = np.mean([v[0] for v in values])
        clipped = np.mean([v[1] for v in values])
        draw.text((10, y + CELL[1] // 2 + 14), f"M {m:.0f}", fill=(160, 160, 160), font=font(14))
        scores.append((variant, m, clipped))
    for column, frame in enumerate(frames):
        draw.text((LABEL + column * (CELL[0] + 4) + 6, 14), f"frame {frame}", fill=(160, 160, 160), font=font(14))
    sheet.save(os.path.join(folder, "sheet.jpg"), quality=88)
    for variant, m, clipped in scores:
        print(f"{variant:12s} colourfulness {m:5.1f}  clipped {100 * clipped:4.2f} %")

    clips = [v for v in rows if os.path.exists(os.path.join(folder, f"{v}.webp"))]
    if not clips:
        return
    readers = {v: [f.convert("RGB").resize(CELL, Image.LANCZOS) for f in ImageSequence.Iterator(Image.open(os.path.join(folder, f"{v}.webp")))] for v in clips}
    count = min(len(f) for f in readers.values())
    columns = 3
    grid_rows = (len(clips) + columns - 1) // columns
    out = []
    for index in range(count):
        frame = Image.new("RGB", (columns * CELL[0], grid_rows * CELL[1]), (0, 0, 0))
        d = ImageDraw.Draw(frame)
        for slot, variant in enumerate(clips):
            x, y = (slot % columns) * CELL[0], (slot // columns) * CELL[1]
            frame.paste(readers[variant][index], (x, y))
            d.text((x + 8, y + 6), variant, fill=(235, 235, 235), font=font(16))
        out.append(frame)
    out[0].save(
        os.path.join(folder, "grid.webp"), save_all=True, append_images=out[1:], duration=62, loop=0,
        quality=70, method=4)


if __name__ == "__main__":
    main()
