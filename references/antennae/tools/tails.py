"""tails.py <scene folder> [match name] [myr] [map]: the two tails at the matched moment (or at myr), from the
matched view, measured the same way on the take and on the wide picture's map. The take's particles are
binned on the map's grid at the match's scale and placement; on both, the bins brighter than 1.6 decades
under the peak and joined to a nucleus are kept, and a tail's tip is the mean of the farthest 1 % of them
from the nuclei's middle, north and south of it: projected kpc and position angle, north through east
(north up and east left, as on the picture). Each galaxy's own farthest 1 % of particles give the 3D
lengths. A version 7 take holds each particle's galaxy after its component."""
import json, math, struct, sys
import numpy as np

def tips(light, nuclei, kpc_across, floor=1.6):
    h, w = light.shape
    lit = np.nan_to_num(light, nan=-9) > 10 ** -floor * np.nanpercentile(light, 99.5)  # not the peak: the picture saturates its cores
    seen = np.zeros_like(lit); todo = [(int(y * w), int(x * w)) for x, y in nuclei]
    while todo:  # the lit bins joined to a nucleus, so the sky's specks do not count
        y, x = todo.pop()
        if 0 <= y < h and 0 <= x < w and lit[y, x] and not seen[y, x]:
            seen[y, x] = True; todo += [(y + 1, x), (y - 1, x), (y, x + 1), (y, x - 1)]
    ys, xs = np.nonzero(seen); mid = np.mean(nuclei, 0) * w
    dx, dy = xs + 0.5 - mid[0], ys + 0.5 - mid[1]
    out = {}
    for name, side in (("north", dy < 0), ("south", dy >= 0)):
        if not side.any():
            out[name] = (0.0, float("nan")); continue
        r = np.hypot(dx[side], dy[side]); i = np.argsort(r)[-max(3, side.sum() // 100):]
        tx, ty = dx[side][i].mean(), dy[side][i].mean()
        out[name] = (math.hypot(tx, ty) * kpc_across / w, math.degrees(math.atan2(-tx, -ty)) % 360)
    return out

def read_frame(folder, myr):
    path = f"{folder}/take.sillage"
    f = open(path, "rb"); f.read(8); version = struct.unpack("<Q", f.read(8))[0]
    head = json.loads(f.read(struct.unpack("<Q", f.read(8))[0])); base = f.tell()
    assert version == 7, version
    n, g, frames = head["particleCount"], head["galaxyCount"], head["frameCount"]
    comp = np.fromfile(path, np.uint32, n, offset=base + 5 * 4 * n)
    galaxy = np.fromfile(path, np.uint32, n, offset=base + 6 * 4 * n)
    off = base + 7 * 4 * n
    fr = np.fromfile(path, np.float32, frames * 8, offset=off).reshape(frames, 8)
    off += frames * 8 * 4 + frames * 3 * 4 + frames * g * 4 * 4  # three floats a frame, then each galaxy's spin
    pos = np.memmap(path, np.uint64, "r", offset=off, shape=(frames, n))
    i = int(np.argmin(abs(fr[:, 0] * 4.714 - myr)))
    w = np.asarray(pos[i]); o, ext = fr[i, 1:4], fr[i, 4]
    xyz = np.stack([(w >> np.uint64(s)) & np.uint64(0x1FFFFF) for s in (0, 21, 42)], 1).astype(np.float64)
    return fr[i, 0] * 4.714, xyz * (ext / float((1 << 21) - 1)) + o, comp, galaxy

def place(xyz, view):
    e, a, r = (math.radians(view[k]) for k in ("elevation", "azimuth", "roll"))
    sx = np.array([math.cos(a), math.sin(a), 0]); sy = np.array([math.sin(a) * math.sin(e), -math.cos(a) * math.sin(e), -math.cos(e)])
    px, py = xyz @ sx, xyz @ sy
    k = 1 / view["kpcPerWidth"]
    return (view["origin"][0] + k * (math.cos(r) * px - math.sin(r) * py),
            view["origin"][1] + k * (math.sin(r) * px + math.cos(r) * py))

def measure(folder, match, myr, mapfile):
    m = json.load(open(mapfile)); w, h = m["width"], m["height"]
    t, xyz, comp, galaxy = read_frame(folder, myr)
    stars = comp != 2  # the dust grains are not light
    u, v = place(xyz[stars], match["view"])
    grid, _, _ = np.histogram2d(v * w, u * w, bins=(h, w), range=((0, h), (0, w)))
    cores = [place(xyz[stars & (galaxy == k) & (comp == 4)].mean(0, keepdims=True), match["view"]) for k in range(2)]
    nuclei = [(float(a[0]), float(b[0])) for a, b in cores]
    model = tips(grid, nuclei, match["view"]["kpcPerWidth"])
    mid = np.median(xyz[stars], 0); lengths = []
    for k in range(2):
        d = np.linalg.norm(xyz[stars & (galaxy == k)] - mid, axis=1); lengths.append(float(np.percentile(d, 99)))
    light = np.array([np.nan if x is None else x for x in m["light"]], float).reshape(h, w)
    return t, model, lengths, tips(light, m["nuclei"], match["view"]["kpcPerWidth"])

if __name__ == "__main__":
    s = sys.argv[1]; name = sys.argv[2] if len(sys.argv) > 2 else "antennae"
    match = json.load(open(f"{s}/match/{name}.json"))
    myr = float(sys.argv[3]) if len(sys.argv) > 3 and sys.argv[3] else match["megayears"]
    mapfile = sys.argv[4] if len(sys.argv) > 4 else f"{s}/../../ref/antennae.map.json"
    t, model, lengths, pic = measure(s, match, myr, mapfile)
    f = lambda d: "  ".join(f"{k} {p:.0f} kpc at PA {pa:.0f}" for k, (p, pa) in d.items())
    print(f"{t:.1f} Myr: {f(model)}  (3D 99 %: {lengths[0]:.0f} and {lengths[1]:.0f} kpc)  |  picture: {f(pic)}")
