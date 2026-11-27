#!/usr/bin/env python3
"""crown.py <wide frame> [--kpc 65] [--centre x,y]

The shape of the Sombrero's crown on a wide frame: at levels between the sky and the core, the
isophote's half width along the disk, its height over the core and their ratio. A frame is taken
to be --kpc across and the disk to lie flat; --centre gives the core in pixels of a 964 pixel
wide copy when the brightest point of the middle third is a star.

On the SDSS picture of NGC 4594 (23.39 arcminutes, 65 kpc across, the core at 486,294) the
ratio goes 3.8, 3.4, 2.8, 2.1, 1.6, 1.5, 1.3 from level 0.90 down to 0.12: wide and low near the
core, where the stellar disk tapers under the bulge, round far out.
"""
import argparse

import numpy as np
from PIL import Image, ImageFilter

LUMA = np.array([0.2126, 0.7152, 0.0722])
WIDTH = 964
LEVELS = (0.90, 0.75, 0.60, 0.45, 0.30, 0.20, 0.12)
SDSS = (3.8, 3.4, 2.8, 2.1, 1.6, 1.5, 1.3)


def run(row, threshold):
    below = row < threshold
    return int(np.argmax(below)) if below.any() else len(row)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[1])
    parser.add_argument("frame")
    parser.add_argument("--kpc", type=float, default=65.0)
    parser.add_argument("--centre")
    args = parser.parse_args()

    image = Image.open(args.frame).convert("RGB")
    image = image.resize((WIDTH, round(image.height * WIDTH / image.width)), Image.LANCZOS)
    lum = (np.asarray(image.filter(ImageFilter.MedianFilter(5))).astype(float) / 255) @ LUMA
    height, width = lum.shape
    scale = args.kpc / width
    if args.centre:
        cx, cy = (int(v) for v in args.centre.split(","))
    else:
        middle = lum[height // 3 : 2 * height // 3, width // 3 : 2 * width // 3]
        cy, cx = np.unravel_index(np.argmax(middle), middle.shape)
        cy, cx = cy + height // 3, cx + width // 3
    sky, peak = float(np.median(lum[:40, :40])), float(lum[cy, cx])

    print(f"core {cx},{cy}  peak {peak:.2f}  sky {sky:.2f}")
    print("level   half width   height   ratio   SDSS")
    column = np.median(lum[: cy + 1, cx - 2 : cx + 3], axis=1)[::-1]
    for level, reference in zip(LEVELS, SDSS):
        threshold = sky + (peak - sky) * level
        up = run(column, threshold)
        half = 0.0
        for rise in range(int(1.5 / scale) + 1):
            row = lum[cy - rise]
            half = max(half, (run(row[cx:], threshold) + run(row[: cx + 1][::-1], threshold)) / 2)
        print(
            f"{level:.2f}    {half * scale:6.2f} kpc  {up * scale:5.2f} kpc  "
            f"{half / max(up, 1):5.2f}   {reference:.1f}")


if __name__ == "__main__":
    main()
