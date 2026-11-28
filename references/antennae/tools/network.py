"""network.py <scene folder> <match json> <hubble picture> <out prefix> [ages Myr ...]: does the take's young
star formation gather into a network as Hubble's red regions do? At the match's moment and view (Hubble's
framing), the knots (grains turned into stars during the run, younger than each age) are binned on a 128-bin
grid across the frame; Hubble's red regions are the pink pixels, red well above green and blue not below it, binned
the same way. On each, inside the galaxy's footprint (bins lit above 1/30 of the 99.5th percentile of all the
light), the share of the knots (or red light) in the densest tenth of the footprint, and in the densest
hundredth; a uniform spread gives 0.10 and 0.01. Writes <out>-knots.png and <out>-hubble-red.png."""
import json, math, sys, os
import numpy as np
from PIL import Image
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tails import read_frame, place
G = 128

def shares(grid, foot):
    v = np.sort(grid[foot].ravel())[::-1]; tot = v.sum(); k = len(v)
    return v[: max(1, k // 10)].sum() / tot, v[: max(1, k // 100)].sum() / tot, k

def image(grid, path, colour):
    g = grid / max(np.percentile(grid[grid > 0], 99), 1e-9) if (grid > 0).any() else grid
    a = np.clip(g, 0, 1) ** 0.5
    rgb = (np.stack([a * c for c in colour], -1) * 255).astype(np.uint8)
    Image.fromarray(rgb).resize((512, round(512 * grid.shape[0] / grid.shape[1])), Image.NEAREST).save(path)

def main(s, matchfile, picture, out, ages):
    m = json.load(open(matchfile)); v = m["view"]; t = m["megayears"]
    _, xyz, comp, galaxy = read_frame(s, t)
    p = f"{s}/take.sillage"
    import struct
    f = open(p, "rb"); f.read(16); h = json.loads(f.read(struct.unpack("<Q", f.read(8))[0])); base = f.tell(); n = h["particleCount"]
    form = np.fromfile(p, np.float32, n, offset=base + 2 * 4 * n) * 4.714  # internal time units
    pic = Image.open(picture).convert("RGB"); W, H = pic.size; rows = round(G * H / W)
    u, w = place(xyz, v)
    inside = (u >= 0) & (u < 1) & (w >= 0) & (w < rows / G)
    allg, _, _ = np.histogram2d(w[inside] * G, u[inside] * G, bins=(rows, G), range=((0, rows), (0, G)))
    foot = allg > np.percentile(allg, 99.5) / 30
    res = {"moment": round(t, 1), "footprint_bins": int(foot.sum())}
    for a in ages:
        k = inside & (comp == 2) & (form <= t) & (form > t - a)
        kg, _, _ = np.histogram2d(w[k] * G, u[k] * G, bins=(rows, G), range=((0, rows), (0, G)))
        s10, s100, _ = shares(kg, foot)
        res[f"knots_{a}"] = {"count": int(k.sum()), "densest_tenth": round(float(s10), 3), "densest_hundredth": round(float(s100), 3)}
        image(kg, f"{out}-knots-{a}.png", (1.0, 0.35, 0.45))
    a = np.asarray(pic.resize((G * 4, rows * 4), Image.BOX), float) / 255
    r, g, b = a[..., 0], a[..., 1], a[..., 2]
    red = np.clip(np.minimum(r - g - 0.12, b - g + 0.02), 0, None) * (r > 0.35)  # pink, Halpha with blue: red and blue both over green
    rg = red.reshape(rows, 4, G, 4).sum((1, 3))
    lum = a.mean(-1).reshape(rows, 4, G, 4).mean((1, 3))
    hfoot = lum > np.percentile(lum, 99.5) / 30
    s10, s100, _ = shares(rg, hfoot)
    res["hubble_red"] = {"densest_tenth": round(float(s10), 3), "densest_hundredth": round(float(s100), 3), "footprint_bins": int(hfoot.sum())}
    image(rg, f"{out}-hubble-red.png", (1.0, 0.35, 0.45))
    print(json.dumps(res, indent=1))

if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], [float(x) for x in sys.argv[5:]] or [5.0, 25.0])
