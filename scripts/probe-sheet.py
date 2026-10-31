#!/usr/bin/env python3
"""Contact sheets of calm-disk probe stills (#169), one row per run, one column per instant.

    probe-sheet.py <out.jpg> <run dir>... [--myr 0,100,300,500,1000] [--pane own|app|both]
                   [--width 900] [--label]

Each run dir holds still-<Myr>.png as `sillage-render probe-disk` writes them, two panes side
by side: the disk's own frame on the left, the app's framing on the right. A 900 px sheet is
small enough to judge a look without reading every pixel (docs/notes/calm-disk-probe.md).
"""

import os
import sys

from PIL import Image, ImageDraw


def nearest_still(run, myr):
    stills = {}
    for name in os.listdir(run):
        if name.startswith("still-") and name.endswith(".png"):
            stills[int(name[6:-4])] = os.path.join(run, name)
    if not stills:
        return None
    best = min(stills, key=lambda t: abs(t - myr))
    return stills[best] if abs(best - myr) <= 10 else None


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    out = argv[1]
    rest = argv[2:]
    def option(name, default):
        return rest[rest.index(name) + 1] if name in rest else default
    instants = [int(v) for v in option("--myr", "0,100,300,500,1000").split(",")]
    pane = option("--pane", "own")
    width = int(option("--width", "900"))
    label = "--label" in rest
    runs = [r for i, r in enumerate(rest) if not r.startswith("--") and (i == 0 or not rest[i - 1].startswith("--"))]
    columns = len(instants)
    cell = max(width // columns, 80)
    rows = []
    for run in runs:
        tiles = []
        for myr in instants:
            path = nearest_still(run, myr)
            if path is None:
                tiles.append(Image.new("RGB", (cell, cell), (20, 20, 20)))
                continue
            image = Image.open(path).convert("RGB")
            w, h = image.size
            half = w // 2
            if pane == "own":
                image = image.crop((0, 0, half, h))
            elif pane == "app":
                image = image.crop((half, 0, w, h))
            image = image.resize((cell if pane != "both" else cell * 2, cell), Image.LANCZOS)
            tiles.append(image)
        rows.append((os.path.basename(run.rstrip("/")), tiles))
    tile_w = cell if pane != "both" else cell * 2
    sheet = Image.new("RGB", (tile_w * columns, cell * len(rows)), (0, 0, 0))
    draw = ImageDraw.Draw(sheet)
    for r, (name, tiles) in enumerate(rows):
        for c, tile in enumerate(tiles):
            sheet.paste(tile, (c * tile_w, r * cell))
            if label:
                text = f"{name} {instants[c]} Myr" if c == 0 else f"{instants[c]} Myr"
                draw.text((c * tile_w + 4, r * cell + 4), text, fill=(255, 255, 255))
    sheet.save(out, quality=82)
    print(f"{out}: {len(rows)} runs x {columns} instants, {sheet.size[0]}x{sheet.size[1]}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
