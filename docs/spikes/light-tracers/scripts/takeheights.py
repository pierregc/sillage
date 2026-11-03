"""Thickness of each disk in a take, tracers against massive particles, and two random halves of
the tracers against each other."""
import json, struct, sys
import numpy as np

path, tracers = sys.argv[1], int(sys.argv[2])
raw = np.memmap(path, dtype=np.uint8, mode="r")
hl = struct.unpack("<Q", bytes(raw[16:24]))[0]
header = json.loads(bytes(raw[24:24 + hl]))
count, frames, galaxies = header["particleCount"], header["frameCount"], header["galaxyCount"]
off = 24 + hl
arrays = {}
for name in ["population", "luminosity", "formation", "kernelScale", "birthRadius"]:
    off += count * 4
component = np.frombuffer(raw, dtype="<u4", count=count, offset=off); off += count * 4
galaxy = np.frombuffer(raw, dtype="<u4", count=count, offset=off); off += count * 4
fields = np.frombuffer(raw, dtype="<f4", count=frames * 8, offset=off).reshape(frames, 8); off += frames * 32
rest = np.frombuffer(raw, dtype="<f4", count=frames * (galaxies - 1) * 3, offset=off).reshape(frames, galaxies - 1, 3); off += frames * (galaxies - 1) * 12
disks = np.frombuffer(raw, dtype="<f4", count=frames * galaxies * 4, offset=off).reshape(frames, galaxies, 4); off += frames * galaxies * 16
pos = np.frombuffer(raw, dtype="<u2", count=frames * count * 3, offset=off).reshape(frames, count, 3)
scene = header["scene"]
reach = [g["diskScaleLength"] * g["diskTruncation"] for g in scene["galaxies"]]
rng = np.random.default_rng(2)
order = rng.permutation(tracers)
massive = np.arange(tracers, count)
half_a, half_b = np.sort(order[: len(massive)]), np.sort(order[len(massive): 2 * len(massive)])
sets = {"light": np.arange(tracers), "massive": massive, "half a": half_a, "half b": half_b}
print("frame  " + "  ".join(f"g{g} light/massive (halves)" for g in range(galaxies)))
for f in range(0, frames, max(frames // 12, 1)):
    t, ox, oy, oz, ext = fields[f][:5]
    centres = [fields[f][5:8]] + [rest[f][g] for g in range(galaxies - 1)]
    out = []
    for g in range(galaxies):
        axis = disks[f][g][:3]
        vals = {}
        for name, idx in sets.items():
            sel = idx[(galaxy[idx] == g) & (component[idx] < 3)]
            p = pos[f, sel].astype(np.float64) * (ext / 65535.0) + np.array([ox, oy, oz]) - centres[g]
            h = p @ axis
            inplane = np.linalg.norm(p - np.outer(h, axis), axis=1)
            keep = inplane < reach[g]
            vals[name] = np.sqrt((h[keep] ** 2).mean())
        out.append(f"{vals['light']:.3f}/{vals['massive']:.3f} ({(vals['light']/vals['massive']-1)*100:+.2f} %, halves {(vals['half a']/vals['half b']-1)*100:+.2f} %)")
    print(f"{f:5d}  " + "  ".join(out))
