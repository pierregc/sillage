#!/usr/bin/env python3
"""Lays stills out in a labelled grid, for the dust web spike (#173).

    dust-web-sheet.py <out.jpg> --columns N [--tile W] [--crop X,Y,W,H] [--labels a,b,...]
                      [--rows a,b,...] <image>...

Images go in row by row. `--crop` takes fractions of the image (left, top, width, height),
so the same region of every still is shown; `--tile` is the width each cell is drawn at.
"""

import argparse

from PIL import Image, ImageDraw


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("out")
    parser.add_argument("images", nargs="+")
    parser.add_argument("--columns", type=int, required=True)
    parser.add_argument("--tile", type=int, default=300)
    parser.add_argument("--crop")
    parser.add_argument("--labels", default="")
    parser.add_argument("--rows", default="")
    args = parser.parse_args()

    columns = [c for c in args.labels.split(",") if c] if args.labels else []
    rows = [r for r in args.rows.split(",") if r] if args.rows else []
    tiles = []
    for path in args.images:
        image = Image.open(path).convert("RGB")
        if args.crop:
            x, y, w, h = (float(v) for v in args.crop.split(","))
            box = (round(x * image.width), round(y * image.height),
                   round((x + w) * image.width), round((y + h) * image.height))
            image = image.crop(box)
        height = round(args.tile * image.height / image.width)
        tiles.append(image.resize((args.tile, height), Image.LANCZOS))

    count = len(tiles)
    n_rows = (count + args.columns - 1) // args.columns
    label_w = 96 if rows else 0
    label_h = 18 if columns else 0
    gap = 4
    tile_h = tiles[0].height
    sheet = Image.new(
        "RGB",
        (label_w + args.columns * (args.tile + gap), label_h + n_rows * (tile_h + gap)),
        (14, 14, 14))
    draw = ImageDraw.Draw(sheet)
    for index, label in enumerate(columns[: args.columns]):
        draw.text((label_w + index * (args.tile + gap) + 4, 3), label, fill=(225, 225, 225))
    for index, label in enumerate(rows[:n_rows]):
        draw.text((4, label_h + index * (tile_h + gap) + tile_h // 2 - 6), label, fill=(225, 225, 225))
    for index, tile in enumerate(tiles):
        row, column = divmod(index, args.columns)
        sheet.paste(tile, (label_w + column * (args.tile + gap), label_h + row * (tile_h + gap)))
    sheet.save(args.out, quality=88)
    print(args.out, sheet.size)


if __name__ == "__main__":
    main()
