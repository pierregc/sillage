"""sheet.py <out.jpg> <picture> <model folder>...: for each model a row: the wide picture, its match in the
window from the first pericentre to the merger, its free match over the whole take, then a strip along time
from the paper's view (the approach, both passages, the merger, the settled remnant). Reads the stills
photokey.sh drew into <model>/stills/ (window.png, free.png, t-<myr>.png) and the clock."""
import json, os, sys
from PIL import Image, ImageDraw, ImageFont
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from clock import clock
from tails import measure

W, H = 320, 360
font = ImageFont.truetype("/System/Library/Fonts/Avenir Next.ttc", 15, index=5)
small = ImageFont.truetype("/System/Library/Fonts/Avenir Next.ttc", 13, index=0)

def tile(path, lines):
    im = Image.open(path).convert("RGB").resize((W, H), Image.LANCZOS) if os.path.exists(path) else Image.new("RGB", (W, H))
    d = ImageDraw.Draw(im)
    for k, t in enumerate(lines):
        d.text((8, 6 + 18 * k), t, font=font if k == 0 else small, fill=(255, 255, 255))
    return im

def strip_times(c):
    p = [q["myr"] for q in c["pericentres"]]
    times = [("approach", max(p[0] - 100, c["start_myr"] + 2)), ("1st passage", p[0])]
    if len(p) > 1:
        times.append(("2nd passage", p[1]))
    if c["merger_myr"]:
        times.append(("merger", c["merger_myr"]))
    if c["settled_myr"]:
        times.append(("settled", c["settled_myr"]))
    return times

def row(picture, s):
    n = os.path.basename(s.rstrip("/")); c = clock(s); p1 = c["pericentres"][0]["myr"]
    tiles = [tile(picture, ["wide picture, 102.5 kpc"])]
    mapfile = f"{os.path.dirname(os.path.dirname(os.path.abspath(s)))}/ref/antennae.map.json"
    for kind, name in (("window", "antennae"), ("free", "antennae-free")):
        m = json.load(open(f"{s}/match/{name}.json")); v = m["view"]
        t, model, _, _ = measure(s, m, m["megayears"], mapfile)
        tiles.append(tile(f"{s}/stills/{kind}.png", [
            f"{n}: {kind} match {m['score']:.3f}",
            f"{m['megayears']:.0f} Myr, {m['megayears'] - p1:+.0f} after the 1st passage",
            f"view {v['elevation']:.0f}, {v['azimuth']:.0f}, roll {v['roll']:.0f}",
            f"tails N {model['north'][0]:.0f} kpc PA {model['north'][1]:.0f}, S {model['south'][0]:.0f} kpc PA {model['south'][1]:.0f}"]))
    for label, t in strip_times(c):
        tiles.append(tile(f"{s}/stills/t-{t:.0f}.png", [f"{label}, {t:.0f} Myr", "the paper's view"]))
    return tiles

if __name__ == "__main__":
    out, picture, models = sys.argv[1], sys.argv[2], sys.argv[3:]
    rows = [row(picture, s) for s in models]; cols = max(len(r) for r in rows)
    sheet = Image.new("RGB", (cols * W, len(rows) * H))
    for j, r in enumerate(rows):
        for i, im in enumerate(r):
            sheet.paste(im, (i * W, j * H))
    sheet.save(out, quality=88)
