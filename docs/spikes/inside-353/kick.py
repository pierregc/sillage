#!/usr/bin/env python3
"""kick.py <take>: how fast galaxy 0's swept particles move, and how near the companion's nucleus they pass."""
import json, mmap, struct, sys
import numpy as np
with open(sys.argv[1], "rb") as h:
    data = mmap.mmap(h.fileno(), 0, access=mmap.ACCESS_READ)
version = struct.unpack("<Q", data[8:16])[0]
length = struct.unpack("<Q", data[16:24])[0]
header = json.loads(data[24:24 + length])
count, frames, galaxies = header["particleCount"], header["frameCount"], header["galaxyCount"]
L = (1 << 21) - 1
offset = 24 + length + (2 + (version >= 2) + (version >= 4) + (version >= 6)) * 4 * count
components = np.frombuffer(data, dtype="<u4", count=count, offset=offset)
owners = np.frombuffer(data, dtype="<u4", count=count, offset=offset + 4 * count)
offset += 8 * count
table = np.frombuffer(data, dtype="<f4", count=frames * 8, offset=offset).reshape(frames, 8)
offset += frames * 32
others = np.frombuffer(data, dtype="<f4", count=frames * (galaxies - 1) * 3, offset=offset).reshape(frames, 3)
offset += frames * (galaxies - 1) * 12 + frames * galaxies * 16
myr = table[:, 0] * 4.71
sel = np.flatnonzero((owners == 0) & np.isin(components, (0, 1, 2)))[::8]
def pos(f):
    words = np.frombuffer(data, dtype="<u8", count=count, offset=offset + f * count * 8)[sel]
    m = np.uint64(0x1FFFFF)
    cells = np.stack([words & m, (words >> np.uint64(21)) & m, (words >> np.uint64(42)) & m], axis=1).astype(np.float64)
    return table[f, 1:4] + cells / L * table[f, 4]
X = np.array([-0.99, 0.15, -0.01]); Y = np.array([-0.13, -0.83, 0.54]); Z = np.array([0.08, 0.53, 0.84])
f0 = int(np.argmin(np.abs(myr - 414)))
p0 = pos(f0); rel = p0 - table[f0, 5:8]
x, y, z = rel @ X, rel @ Y, rel @ Z
R = np.hypot(x, y)
# where the companion's nucleus will pass: its place at 440 Myr in galaxy 0's frame today
f440 = int(np.argmin(np.abs(myr - 440)))
track = others[f440] - table[f440, 5:8]
tx, ty = track @ X, track @ Y
print("companion nucleus at 440 Myr in galaxy 0's disk axes", tx, ty, track @ Z)
near = (np.abs(z) < 1) & (np.hypot(x - tx * 0.75, y - ty * 0.75) < 3)   # a patch 3 kpc wide at R ~ 10 toward it
far = (np.abs(z) < 1) & (np.hypot(x + tx * 0.75, y + ty * 0.75) < 3)    # the same patch on the other side
print("patch sizes", near.sum(), far.sum(), "at R", np.median(R[near]), np.median(R[far]))
prev = None
for f in range(f0, f0 + 14):
    p = pos(f)
    line = f"{myr[f]:6.1f} Myr  sep {np.linalg.norm(others[f]-table[f,5:8]):5.1f} kpc"
    for name, m in (("near", near), ("far", far)):
        d = np.linalg.norm(p[m] - others[f], axis=1)
        line += f" | {name}: to companion nucleus median {np.median(d):5.1f} min5% {np.percentile(d,5):5.1f}"
        if prev is not None:
            dt = (myr[f] - myr[f - 1])
            v = (p[m] - prev[m]) / dt - (table[f, 5:8] - table[f - 1, 5:8]) / dt
            line += f" speed about galaxy 0 median {np.median(np.linalg.norm(v, axis=1)) * 978:4.0f} km/s"
    print(line)
    prev = p
