"""thread_census.py <take.sillage> <myr>: emitting particles beside the dust threads at 2 to 4 kpc against those away
from them: count by component, local spacing (from the particle count in 30 pc cells), luminosity, kernelScale."""
import json, struct, sys
import numpy as np
path, myr = sys.argv[1], float(sys.argv[2])
f = open(path, "rb"); f.read(8); version = struct.unpack("<Q", f.read(8))[0]
hlen = struct.unpack("<Q", f.read(8))[0]; head = json.loads(f.read(hlen)); base = f.tell()
n, g, frames = head["particleCount"], head["galaxyCount"], head["frameCount"]
off = base
pop = np.fromfile(path, np.float32, n, offset=off); off += 4 * n
lum = np.fromfile(path, np.float32, n, offset=off); off += 4 * n
off += 4 * n  # formation
ks = np.fromfile(path, np.float32, n, offset=off); off += 4 * n
off += 4 * n  # birth radius
comp = np.fromfile(path, np.uint32, n, offset=off); off += 4 * n
off += 4 * n  # galaxy
fr = np.fromfile(path, np.float32, frames * 8, offset=off).reshape(frames, 8); off += frames * 8 * 4
off += frames * g * 16
i = int(np.argmin(abs(fr[:, 0] * 4.714 - myr)))
w = np.asarray(np.memmap(path, np.uint64, "r", offset=off + i * n * 8, shape=(n,)))
xyz = np.stack([(w >> s) & 0x1FFFFF for s in (0, 21, 42)], 1).astype(np.float64) * (fr[i, 4] / ((1 << 21) - 1)) + fr[i, 1:4]
c = np.median(xyz[comp == 4], 0); d = xyz - c
r = np.hypot(d[:, 0], d[:, 1]); band = (r > 2) & (r < 4) & (abs(d[:, 2]) < 0.3)
cell = 0.03
key = np.floor(d[band] / cell).astype(np.int64)
k = (key[:, 0] + 1000) * 4000000 + (key[:, 1] + 1000) * 2000 + (key[:, 2] + 1000)
cb, comps = k, comp[band]
uniq, inv, counts = np.unique(cb, return_inverse=True, return_counts=True)
spacing = (cell ** 3 / counts[inv]) ** (1 / 3)
dustcells = set(uniq[np.isin(np.arange(len(uniq)), np.unique(inv[comps == 2]))].tolist())
# a cell or its 26 neighbours holds dust
offs = [(a * 4000000 + b * 2000 + c2) for a in (-1, 0, 1) for b in (-1, 0, 1) for c2 in (-1, 0, 1)]
near_cell = np.zeros(len(uniq), bool)
dc = np.array(sorted(dustcells))
for o in offs:
    near_cell |= np.isin(uniq + o, dc)
emitting = comps != 2
near = emitting & near_cell[inv]; away = emitting & ~near_cell[inv]
names = {0: "star", 1: "hii", 3: "halo", 4: "bulge", 5: "outskirt"}
print(f"{fr[i,0]*4.714:.1f} Myr, band 2-4 kpc, |z|<0.3 kpc, cells 30 pc")
for label, m in (("near threads", near), ("away", away)):
    sel = np.nonzero(band)[0][m]
    cnt = {names.get(int(v), str(v)): int((comp[sel] == v).sum()) for v in np.unique(comp[sel])}
    kc = {"<0.8": int((ks[sel] < 0.8).sum()), "0.8-1": int(((ks[sel] >= 0.8) & (ks[sel] < 1)).sum()), ">=1": int((ks[sel] >= 1).sum())}
    print(f"{label:13} n {len(sel):7}  {cnt}  spacing median {np.median(spacing[m])*1000:.1f} pc  lum median {np.median(lum[sel]):.3f}  kernelScale {kc}")
