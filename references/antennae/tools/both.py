"""both.py <work dir> <scene folder>: one scene scored on both pictures at the same moment and from the same
direction (#525, Pierre 2026-11-28: the right candidate matches both). The wide panel's window match is already
there; Hubble's (heic0615a, 20.9 kpc across) is searched over the same window; the moment kept is the one where
the mean of the two curves peaks. There both are matched again: the wide one freely, Hubble's within 15 degrees of
the wide view's direction (the two pictures look from the same place; Hubble's frame turns 30.6 degrees on the
sky, which the roll takes freely). Prints one CSV row: name, moment, wide score, Hubble score held to that
direction, their mean, the roll difference. Needs $SR."""
import json, os, subprocess, sys

def match(sr, s, mapfile, *args):
    subprocess.run([sr, "match", s, mapfile, "--fresh", *args], check=True, capture_output=True)
    name = os.path.basename(mapfile).replace(".map.json", "")
    return json.load(open(f"{s}/match/{name}.json")), json.load(open(f"{s}/match/{name}.sheet.json"))

def main(work, s):
    sr = os.environ["SR"]; s = os.path.abspath(s); ref = f"{os.path.abspath(work)}/ref"
    wide_sheet = json.load(open(f"{s}/match/antennae.sheet.json"))
    w = {round(t, 1): v for t, v in wide_sheet["curves"]["time"]}
    lo, hi = min(w), max(w)
    _, hs = match(sr, s, f"{ref}/heic-window.map.json", "--kpc-across", "20.9", "--at", f"{(lo + hi) / 2:.1f}", "--within", f"{(hi - lo) / 2 + 1:.1f}")
    h = {round(t, 1): v for t, v in hs["curves"]["time"]}
    common = [t for t in w if t in h] or list(w)
    t = max(common, key=lambda x: (w[x] + h.get(x, 0)) / 2)
    wm, _ = match(sr, s, f"{ref}/wide-at.map.json", "--kpc-across", "102.5", "--at", f"{t}", "--within", "2")
    v = wm["view"]
    hm, _ = match(sr, s, f"{ref}/heic-at.map.json", "--kpc-across", "20.9", "--at", f"{wm['megayears']:.2f}", "--within", "1",
                  "--view", f"{v['elevation']:.2f},{v['azimuth']:.2f},{v['roll']:.2f}", "--span", "15")
    d = (hm["view"]["roll"] - v["roll"] + 180) % 360 - 180
    print(f"{os.path.basename(s)},{wm['megayears']:.1f},{wm['score']:.4f},{hm['score']:.4f},{(wm['score'] + hm['score']) / 2:.4f},{d:.0f},"
          f"{v['elevation']:.1f},{v['azimuth']:.1f},{v['roll']:.1f}", flush=True)

if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
