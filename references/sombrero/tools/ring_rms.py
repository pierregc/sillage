"""ring_rms.py <take.sillage> <myr> [...]: the stellar disk's lumpiness face on. In rings 0.25 kpc wide from 2 to 6 kpc,
the rms over 36 sectors of 10 degrees of the stars' light (disk stars and bulge, luminosity weighted, no dust) over its
mean; printed per kpc band and as the median over rings, with the shot-noise floor for that many particles."""
import json, struct, sys
import numpy as np
path = sys.argv[1]
f = open(path, "rb"); f.read(16); hlen = struct.unpack("<Q", f.read(8))[0]; head = json.loads(f.read(hlen)); base = f.tell()
n, g, frames = head["particleCount"], head["galaxyCount"], head["frameCount"]
lum = np.fromfile(path, np.float32, n, offset=base + 4 * n)
comp = np.fromfile(path, np.uint32, n, offset=base + 5 * 4 * n)
off = base + 7 * 4 * n
fr = np.fromfile(path, np.float32, frames * 8, offset=off).reshape(frames, 8); off += frames * 8 * 4 + frames * g * 16
emit = (comp == 0) | (comp == 4) | (comp == 5)
for m in [float(x) for x in sys.argv[2:]]:
    i = int(np.argmin(abs(fr[:, 0] * 4.714 - m)))
    w = np.asarray(np.memmap(path, np.uint64, "r", offset=off + i * n * 8, shape=(n,)))
    xyz = np.stack([(w >> s) & 0x1FFFFF for s in (0, 21, 42)], 1).astype(np.float64) * (fr[i, 4] / ((1 << 21) - 1)) + fr[i, 1:4]
    c = np.median(xyz[comp == 4], 0); d = xyz[emit] - c; L = lum[emit]
    r = np.hypot(d[:, 0], d[:, 1]); phi = np.arctan2(d[:, 1], d[:, 0])
    rows = []
    for r0 in np.arange(2.0, 6.0, 0.25):
        s = (r >= r0) & (r < r0 + 0.25)
        h, _ = np.histogram(phi[s], bins=36, range=(-np.pi, np.pi), weights=L[s])
        k, _ = np.histogram(phi[s], bins=36, range=(-np.pi, np.pi))
        noise = np.sqrt(np.mean((L[s] ** 2)) / np.mean(L[s]) ** 2 / max(k.mean(), 1))
        rows.append((r0, h.std() / h.mean(), noise))
    rows = np.array(rows)
    bands = " ".join(f"{a:.0f}-{a+1:.0f}kpc {rows[(rows[:,0]>=a)&(rows[:,0]<a+1),1].mean():.3f}" for a in (2, 3, 4, 5))
    print(f"{fr[i,0]*4.714:6.1f} Myr  median {np.median(rows[:,1]):.3f} (shot noise {np.median(rows[:,2]):.3f})  {bands}")
