"""The Cartwheel's three flights, written into <scene>/flights/ from the match of the photo.
usage: flights.py <scene folder> [photo myr override]"""
import json, math, os, subprocess, sys
scene = sys.argv[1]
here = os.path.dirname(os.path.abspath(__file__))
photo = json.loads(subprocess.check_output(
    ["python3", f"{here}/../../../scripts/picture-film.py", "key", f"{scene}/match/cartwheel-crop.json",
     "--aspect", "2745x3088", "--fit", "height"]))
M = photo["myr"]
END = json.load(open(f"{scene}/clip.json"))["story"]["endMyr"] - 0.5
P = {k: photo[k] for k in ("eye", "aim", "fov", "roll")}
def g(i, off, disk=False):
    d = {"galaxy": i, "offset": off}
    if disk: d["disk"] = True
    return d
C = {"galaxy": 0}
G = {"galaxy": 1}
mid = [P["aim"][i] + 0.42 * (P["eye"][i] - P["aim"][i]) for i in range(3)]

# 1. the collision, the freeze on the photo, the hold the split screen is laid over, into G3
hold = 30.0
one = [
    {"at": 0, "myr": 160, "eye": g(0, [-130, -230, -70]), "aim": g(0, [-10, 0, -50]), "fov": 0.6},
    {"at": 7, "myr": 268, "eye": g(0, [-48, -80, 6]), "aim": g(0, [0, 0, -8])},
    {"at": 12, "myr": 300, "eye": g(0, [-32, -52, 5]), "aim": C},
    {"at": 17, "myr": 332, "eye": g(0, [-10, -62, 30]), "aim": C, "roll": 0.3 * P["roll"]},
    {"at": 24, "myr": M - 30, "eye": mid, "aim": C, "fov": 0.33, "roll": 0.75 * P["roll"]},
    dict({"at": hold, "myr": M}, **P),
    dict({"at": hold + 9}, **{k: P[k] for k in ("eye", "aim")}),
    {"at": hold + 14, "eye": g(1, [8, -6, 60], True), "aim": G, "fov": 0.6, "roll": 0,
     "pace": "nearness"},
    {"at": hold + 20, "eye": g(1, [1.5, -1.0, 2.5], True), "aim": g(1, [1.5, -1.0, -30], True),
     "pace": "nearness"},
    {"at": hold + 26, "myr": M, "eye": g(1, [5, -4, 14]), "aim": C},
]
# 2. through the big one's centre, along its axis
two = [
    {"at": 0, "myr": M, "eye": g(0, [-14, -7, 30], True), "aim": C, "fov": 0.6, "pace": "nearness"},
    {"at": 6, "eye": g(0, [-3, -1.5, 6], True), "aim": g(0, [3, 1.5, -8], True), "pace": "nearness"},
    {"at": 9, "eye": g(0, [1.5, 0.8, -3], True), "aim": g(0, [22, 11, 0], True)},
    {"at": 13, "myr": M, "eye": g(0, [12, 6, -16], True), "aim": g(0, [6, 3, 0], True)},
]
# 3. across it edge on, just above the plane, through the ring twice
three = [
    {"at": 0, "myr": M, "eye": g(0, [-46, -6, 2.0], True), "aim": g(0, [0, -3, 0], True),
     "fov": 0.6, "pace": "nearness"},
    {"at": 4, "eye": g(0, [-24, -4.5, 1.6], True), "aim": g(0, [10, -3, -1], True),
     "pace": "nearness"},
    {"at": 9, "eye": g(0, [-3, -3, 1.4], True), "aim": g(0, [30, -3, -1.5], True), "pace": "nearness"},
    {"at": 12, "myr": M, "eye": g(0, [9, -3, 1.5], True), "aim": g(0, [30, -3, -2.5], True)},
]
# 4. a turn low over the ring, then back to frame both and time runs again
four = [
    {"at": 0, "myr": M, "eye": g(0, [22, -10, 4], True), "aim": C, "fov": 0.6},
    {"at": 4, "eye": g(0, [10, 21, 5], True), "aim": C},
    {"at": 8, "myr": M, "eye": g(0, [-16, 17, 7], True), "aim": C},
    {"at": 15, "myr": M + 12, "eye": g(0, [-10, -60, -110]), "aim": g(0, [0, 0, 40])},
    {"at": 31, "myr": END, "eye": g(0, [0, -50, -125]), "aim": g(0, [0, 0, 40])},
]
os.makedirs(f"{scene}/flights", exist_ok=True)
for name, keys in (("1-collision", one), ("2-centre", two), ("3-edge", three), ("4-again", four)):
    json.dump({"version": 1, "keys": keys}, open(f"{scene}/flights/{name}.flight.json", "w"), indent=1)
print("photo", M, "end", END)
