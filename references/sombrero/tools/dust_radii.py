"""dust_radii.py <take.sillage> [myr ...]: the dust grains' radius in the disk plane (percentiles 16, 50,
84) and their rms height, about the bulge's median centre, read straight from a version 7 take."""
import json, struct, sys
import numpy as np
path = sys.argv[1]
f = open(path, "rb"); magic = f.read(8); version = struct.unpack("<Q", f.read(8))[0]
hlen = struct.unpack("<Q", f.read(8))[0]; head = json.loads(f.read(hlen)); base = f.tell()
n, g, frames = head["particleCount"], head["galaxyCount"], head["frameCount"]
assert version == 7, version
off = base + 5 * 4 * n  # population, luminosity, formation, kernelScale, birthRadius
comp = np.fromfile(path, np.uint32, n, offset=off); off += 2 * 4 * n
fr = np.fromfile(path, np.float32, frames * 8, offset=off).reshape(frames, 8); off += frames * 8 * 4
off += frames * g * 4 * 4
pos = np.memmap(path, np.uint64, "r", offset=off, shape=(frames, n))
last = float((1 << 21) - 1)
dust, bulge = comp == 2, comp == 4
for m in [float(x) for x in sys.argv[2:]] or [fr[0, 0] * 4.714, fr[-1, 0] * 4.714]:
    i = int(np.argmin(abs(fr[:, 0] * 4.714 - m)))
    w = np.asarray(pos[i]); o, ext = fr[i, 1:4], fr[i, 4]
    xyz = np.stack([(w >> s) & 0x1FFFFF for s in (0, 21, 42)], 1).astype(np.float64) * (ext / last) + o
    c = np.median(xyz[bulge], 0); d = xyz[dust] - c
    r = np.hypot(d[:, 0], d[:, 1]); z = d[:, 2]
    p16, p50, p84 = np.percentile(r, [16, 50, 84])
    ring = abs(r - p50) < (p84 - p16) / 2
    s = xyz[comp == 0] - c; rs = np.hypot(s[:, 0], s[:, 1])
    zs = np.sqrt((s[(rs > 2) & (rs < 8), 2] ** 2).mean())
    print(f"{fr[i,0] * 4.714:6.1f} Myr  stars rms z 2-8 kpc {zs:.3f}  dust {dust.sum()}  r16 {p16:.2f}  r50 {p50:.2f}  r84 {p84:.2f}  r98 {np.percentile(r,98):.2f} kpc"
          f"  rms z: on the ring {np.sqrt((z[ring]**2).mean()):.3f}, inside {np.sqrt((z[r < p16 - 1]**2).mean()) if (r < p16 - 1).any() else float('nan'):.3f} kpc")
