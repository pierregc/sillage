"""ring_ripple.py <take.sillage> <myr> [...]: the stellar disk's concentric rings face on: the azimuthally averaged light
of disk stars and bulge in rings 0.1 kpc wide from 2 to 6 kpc, against a smooth fit (a quadratic in log light over
radius); the rms of the ratio, and its shot-noise floor."""
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
    r = np.hypot(d[:, 0], d[:, 1])
    edges = np.arange(2.0, 6.0001, 0.1); mid = (edges[1:] + edges[:-1]) / 2
    h, _ = np.histogram(r, bins=edges, weights=L); k, _ = np.histogram(r, bins=edges)
    sb = h / (np.pi * (edges[1:] ** 2 - edges[:-1] ** 2))
    fit = np.exp(np.polyval(np.polyfit(mid, np.log(sb), 2), mid))
    ripple = np.std(sb / fit - 1); noise = np.median(np.sqrt(np.mean(L ** 2) / np.mean(L) ** 2 / k))
    print(f"{fr[i,0]*4.714:6.1f} Myr  ripple {ripple:.4f}  (shot noise {noise:.4f})")
