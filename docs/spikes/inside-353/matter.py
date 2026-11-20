#!/usr/bin/env python3
"""matter.py <take> : where galaxy 0's emitting particles are around its centre near 452 Myr."""
import json, mmap, struct, sys
import numpy as np
path = sys.argv[1]
with open(path, "rb") as h:
    data = mmap.mmap(h.fileno(), 0, access=mmap.ACCESS_READ)
version = struct.unpack("<Q", data[8:16])[0]
length = struct.unpack("<Q", data[16:24])[0]
header = json.loads(data[24:24 + length])
count, frames, galaxies = header["particleCount"], header["frameCount"], header["galaxyCount"]
print({k: v for k, v in header.items() if not isinstance(v, (list, dict))})
levels = (1 << 21) - 1
offset = 24 + length
floats = 2 + (version >= 2) + (version >= 4) + (version >= 6)
offset += floats * 4 * count
components = np.frombuffer(data, dtype="<u4", count=count, offset=offset)
owners = np.frombuffer(data, dtype="<u4", count=count, offset=offset + 4 * count)
offset += 2 * 4 * count
table = np.frombuffer(data, dtype="<f4", count=frames * 8, offset=offset).reshape(frames, 8)
offset += frames * 8 * 4
if galaxies > 1: offset += frames * (galaxies - 1) * 3 * 4
if version >= 3: offset += frames * galaxies * 4 * 4
assert offset + frames * count * 8 == len(data)
myr = table[:, 0] * 4.71
print("table rows", table[0], table[frames // 2])
print("components", np.unique(components, return_counts=True), "owners", np.unique(owners, return_counts=True))
def positions(frame):
    words = np.frombuffer(data, dtype="<u8", count=count, offset=offset + frame * count * 8)
    m = np.uint64(0x1FFFFF)
    cells = np.stack([words & m, (words >> np.uint64(21)) & m, (words >> np.uint64(42)) & m], axis=1).astype(np.float64)
    return cells, table[frame]
sel = (owners == 0) & np.isin(components, (0, 1, 2, 4, 5))
for want in [float(a) for a in sys.argv[2:]]:
    f = int(np.argmin(np.abs(myr - want)))
    cells, row = positions(f)
    print(f"frame {f} at {myr[f]:.1f} Myr row {row}")
    np.save(f"out/pos-{int(want)}.npy", cells[sel].astype(np.float32))
    np.save(f"out/row-{int(want)}.npy", row)
np.save("out/sel-comp.npy", components[sel])
