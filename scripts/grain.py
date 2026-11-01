#!/usr/bin/env python3
"""Measures how grainy a render is, and lays renders side by side to look at.

    grain.py score <image.png>...                 one line per image, tab separated
    grain.py sheet <out.jpg> [--crop X,Y,W,H | --crop auto] [--label-from name] <image>...

The score works on display luminance, which is what the eye judges. Over the body of the
galaxies (where the blurred luminance is above a floor, and short of white):

  grain       rms of what is finer than two pixels, relative to the local level
  structure   rms of what lies between four and sixteen pixels, relative to the local level
  points      share of body pixels standing more than 25 % above their surroundings

A render that is smooth but still detailed lowers `grain` and keeps `structure`.
Needs numpy and Pillow, as the other scripts here do.
"""

import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

BODY_FLOOR = 0.05
BODY_CEILING = 0.92


def luminance(path):
    image = Image.open(path).convert("RGB")
    rgb = np.asarray(image, dtype=np.float32) / 255.0
    return 0.2126 * rgb[..., 0] + 0.7152 * rgb[..., 1] + 0.0722 * rgb[..., 2]


def blur(field, radius):
    return np.asarray(Image.fromarray(field, mode="F").filter(ImageFilter.GaussianBlur(radius)))


def body_mask(y):
    broad = blur(y, 6)
    return (broad > BODY_FLOOR) & (broad < BODY_CEILING)


def score(path):
    y = luminance(path)
    mask = body_mask(y)
    if mask.sum() < 1000:
        return None
    fine = blur(y, 1.5)
    mid = blur(y, 4)
    wide = blur(y, 16)
    level = np.maximum(mid, 1e-3)
    grain = np.sqrt(np.mean(((y - fine)[mask] / level[mask]) ** 2))
    structure = np.sqrt(np.mean(((mid - wide)[mask] / np.maximum(wide, 1e-3)[mask]) ** 2))
    points = np.mean((y[mask] - mid[mask]) / level[mask] > 0.25)
    return {
        "grain": grain,
        "structure": structure,
        "points": points,
        "body": mask.mean(),
        "mean": float(y[mask].mean()),
    }


def auto_crop(y, width, height):
    """The window whose pixels are most often disk body, neither sky nor core."""
    broad = blur(y, 6)
    body = ((broad > 0.08) & (broad < 0.6)).astype(np.float32)
    step = 32
    best, best_at = -1.0, (0, 0)
    rows, cols = y.shape
    for top in range(0, max(rows - height, 0) + 1, step):
        for left in range(0, max(cols - width, 0) + 1, step):
            value = body[top:top + height, left:left + width].mean()
            if value > best:
                best, best_at = value, (left, top)
    return best_at


def sheet(out, paths, crop, label_from):
    full_width = 720
    crop_w, crop_h = 640, 420
    rows = []
    for path in paths:
        y = luminance(path)
        if crop == "auto":
            left, top = auto_crop(y, crop_w, crop_h)
            box = (left, top, crop_w, crop_h)
            crop = box
        elif crop is None:
            rows_, cols_ = y.shape
            crop = (cols_ // 2 - crop_w // 2, rows_ // 2 - crop_h // 2, crop_w, crop_h)
        rows.append((path, crop, score(path)))

    pad, label_h = 12, 26
    first = Image.open(rows[0][0])
    full_height = round(full_width * first.height / first.width)
    row_h = max(full_height, rows[0][1][3]) + label_h + pad
    canvas = Image.new("RGB", (pad * 3 + full_width + rows[0][1][2], pad + row_h * len(rows)), (18, 18, 18))
    draw = ImageDraw.Draw(canvas)
    for index, (path, (left, top, w, h), metrics) in enumerate(rows):
        image = Image.open(path).convert("RGB")
        y0 = pad + index * row_h
        name = os.path.basename(path)
        if label_from:
            name = name.replace(label_from, "")
        text = name
        if metrics:
            text += "   grain %.3f  structure %.3f  points %.1f %%" % (
                metrics["grain"], metrics["structure"], 100 * metrics["points"])
        draw.text((pad, y0), text, fill=(230, 230, 230))
        small = image.resize((full_width, full_height), Image.LANCZOS)
        canvas.paste(small, (pad, y0 + label_h))
        sx = full_width / image.width
        draw.rectangle(
            (pad + left * sx, y0 + label_h + top * sx, pad + (left + w) * sx, y0 + label_h + (top + h) * sx),
            outline=(255, 200, 80))
        canvas.paste(image.crop((left, top, left + w, top + h)), (pad * 2 + full_width, y0 + label_h))
    canvas.save(out, quality=90)
    print(out)


def main(argv):
    if len(argv) < 2 or argv[1] not in ("score", "sheet"):
        print(__doc__)
        return 2
    if argv[1] == "score":
        print("image\tgrain\tstructure\tpoints\tbody\tmean")
        for path in argv[2:]:
            metrics = score(path)
            if metrics is None:
                print("%s\tno body" % os.path.basename(path))
                continue
            print("%s\t%.4f\t%.4f\t%.4f\t%.3f\t%.3f" % (
                os.path.basename(path), metrics["grain"], metrics["structure"], metrics["points"],
                metrics["body"], metrics["mean"]))
        return 0
    out = argv[2]
    rest = argv[3:]
    crop, label_from = None, None
    paths = []
    i = 0
    while i < len(rest):
        if rest[i] == "--crop":
            value = rest[i + 1]
            crop = "auto" if value == "auto" else tuple(int(v) for v in value.split(","))
            i += 2
        elif rest[i] == "--label-from":
            label_from = rest[i + 1]
            i += 2
        else:
            paths.append(rest[i])
            i += 1
    sheet(out, paths, crop, label_from)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
