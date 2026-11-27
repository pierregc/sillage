"""Writes the Sombrero fixture's synthetic dust screen tile (#513): 64 azimuths by 16 radii of
standard normal scores and a lut of 16 columns from -3 to 3 that turns them into a ring's column.
Run from this folder: python3 make_tile.py. Small and seeded, so it writes the same bytes."""
import json
import math
import struct

WIDTH, HEIGHT, LUT = 64, 16, 16
RADII = [0.5, 8.0]

state = 12345


def unit():
    global state
    state = (state * 1664525 + 1013904223) % 2**32
    return (state >> 8) / 16777216.0


def normal():
    return math.sqrt(-2.0 * math.log(1.0 - unit())) * math.cos(2.0 * math.pi * unit())


scores = [normal() for _ in range(WIDTH * HEIGHT)]
lut = []
for row in range(HEIGHT):
    radius = RADII[0] + (RADII[1] - RADII[0]) * (row + 0.5) / HEIGHT
    ring = math.exp(-0.5 * ((radius - 5.0) / 1.5) ** 2)
    for column in range(LUT):
        score = -3.0 + 6.0 * column / (LUT - 1)
        lut.append(ring * math.exp(0.6 * score))

with open("tile.f32", "wb") as f:
    f.write(struct.pack("<%df" % len(scores), *scores))
with open("lut.f32", "wb") as f:
    f.write(struct.pack("<%df" % len(lut), *lut))
with open("tile.json", "w") as f:
    json.dump({"width": WIDTH, "height": HEIGHT, "radii": RADII, "data": "tile.f32",
               "lut": {"data": "lut.f32", "width": LUT, "range": [-3.0, 3.0]}}, f, indent=2)
    f.write("\n")
