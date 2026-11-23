"""One continuous flight for the NGC 2207 film, after the Cartwheel's film3: <scene>/flights/film.flight.json.
The approach and the grazing passage, time easing into a freeze on the picture's view, a dive into
IC 2163's eye, across to NGC 2207 through its disk, down its axis, along its plane through the arms,
a turn over them, then a pull back framing both while time runs to the end of the take.
usage: flights.py <scene folder>"""
import csv, json, math, os, subprocess, sys
scene = sys.argv[1]
here = os.path.dirname(os.path.abspath(__file__))
photo = json.loads(subprocess.check_output(["python3", f"{here}/view2key.py", f"{scene}/match/ngc2207.json"]))
M = photo["myr"]
rows = list(csv.DictReader(open(f"{scene}/curves-hires.csv")))
t = [float(r["time_myr"]) for r in rows]; d = [float(r["separation_kpc"]) for r in rows]
peri = next(i for i in range(1, len(d) - 1) if d[i] <= d[i - 1] and d[i] <= d[i + 1])
P = t[peri]
START = max(t[0] + 0.5, P - 110)
END = json.load(open(f"{scene}/clip.json"))["story"]["endMyr"] - 0.5
at_m = min(range(len(t)), key=lambda i: abs(t[i] - M))
c0 = [float(rows[at_m][f"{a}_0"]) for a in "xyz"]; c1 = [float(rows[at_m][f"{a}_1"]) for a in "xyz"]

K = {k: photo[k] for k in ("eye", "aim", "fov", "roll")}
look = [K["eye"][i] - K["aim"][i] for i in range(3)]
dist = math.sqrt(sum(x * x for x in look)); u = [x / dist for x in look]   # from the aim towards the eye

def turned(v, yaw, pitch):
    """v turned about z by yaw and tilted towards z by pitch, radians."""
    x, y, z = v
    x, y = x * math.cos(yaw) - y * math.sin(yaw), x * math.sin(yaw) + y * math.cos(yaw)
    h = math.hypot(x, y); e = math.atan2(z, h) + pitch
    r = math.sqrt(x * x + y * y + z * z); a = math.atan2(y, x)
    return [r * math.cos(e) * math.cos(a), r * math.cos(e) * math.sin(a), r * math.sin(e)]

def scaled(v, k):
    return [x * k for x in v]

def g(i, off, disk=False):
    o = {"galaxy": i, "offset": [round(x, 3) for x in off]}
    if disk: o["disk"] = True
    return o

N, I = {"galaxy": 0}, {"galaxy": 1}
mid = [(c0[i] + c1[i]) / 2 - c0[i] for i in range(3)]          # the pair's middle, from NGC 2207
side = turned(u, 1.1, -0.35)                                     # the approach seen from the side, lower
near = [K["aim"][i] + 0.45 * (K["eye"][i] - K["aim"][i]) for i in range(3)]
hold = 30.0
keys = [
    # the approach and the passage, seen wide from the side, the camera closing and climbing
    {"at": 0, "myr": START, "eye": g(0, [mid[i] + 150 * side[i] for i in range(3)]), "aim": g(0, mid), "fov": 0.6},
    {"at": 9, "myr": P - 25, "eye": g(0, [mid[i] + 120 * turned(u, 0.75, -0.25)[i] for i in range(3)]), "aim": g(0, mid)},
    {"at": 16, "myr": P + 0.5 * (M - P), "eye": g(0, [mid[i] + 85 * turned(u, 0.35, -0.1)[i] for i in range(3)]),
     "aim": g(0, mid), "roll": 0.4 * K["roll"]},
    {"at": 24, "myr": M - 8, "eye": near, "aim": K["aim"], "fov": 0.3, "roll": 0.8 * K["roll"]},
    dict({"at": hold, "myr": M}, **K),
    dict({"at": hold + 9}, **{k: K[k] for k in ("eye", "aim")}),
    # over to IC 2163, face on from its spin, and down into its eye
    {"at": 50, "eye": g(1, [6, -5, 46], True), "aim": I, "fov": 0.6, "roll": 0},
    {"at": 53, "eye": g(1, [4, -3, 26], True), "aim": g(1, [1, -0.6, 0], True), "pace": "nearness"},
    {"at": 63, "eye": g(1, [1.2, -0.8, 2.2], True), "aim": g(1, [1.2, -0.8, -30], True)},
    # inside it, turning slowly towards NGC 2207, rising out on the near side
    {"at": 70, "eye": g(1, [1.0, -0.6, 1.4], True), "aim": N},
    {"at": 77, "eye": g(1, [1.5, -1.0, 4.0], True), "aim": N},
    # the long cruise across, time frozen, through NGC 2207's outer disk on the way
    {"at": 97, "eye": g(0, [-12, -8, 26], True), "aim": N},
    # down its axis through the centre, then out under the disk
    {"at": 106, "eye": g(0, [-3, -2, 6], True), "aim": g(0, [3, 2, -8], True), "pace": "nearness"},
    {"at": 112, "eye": g(0, [1.5, 1.0, -3], True), "aim": g(0, [12, 7, -0.5], True)},
    {"at": 119, "eye": g(0, [13, 7, -15], True), "aim": g(0, [6, 3, 0], True)},
    # round under the disk to its edge, then along it just above the plane, through the arms
    {"at": 129, "eye": g(0, [-16, -12, -16], True), "aim": N},
    {"at": 139, "eye": g(0, [-48, -6, 2.2], True), "aim": g(0, [0, -4, 0], True)},
    {"at": 145, "eye": g(0, [-26, -5, 1.8], True), "aim": g(0, [10, -4, -1], True), "pace": "nearness"},
    {"at": 153, "eye": g(0, [-4, -4, 1.5], True), "aim": g(0, [30, -4, -1.5], True), "pace": "nearness"},
    {"at": 158, "eye": g(0, [13, -6, 3.0], True), "aim": N},
    # a turn low over the arms
    {"at": 165, "eye": g(0, [24, -11, 4.5], True), "aim": N},
    {"at": 172, "eye": g(0, [11, 23, 5.5], True), "aim": N},
    {"at": 179, "myr": M, "eye": g(0, [-18, 19, 8], True), "aim": N},
    # back out to frame both, and time runs again to the end of the take
    {"at": 188, "myr": M + 10, "eye": g(0, [mid[i] + 110 * turned(u, -0.5, 0.15)[i] for i in range(3)]), "aim": g(0, mid), "fov": 0.6},
    {"at": 206, "myr": END, "eye": g(0, [mid[i] + 150 * turned(u, -0.8, 0.2)[i] for i in range(3)]), "aim": g(0, mid)},
]
# lighter than the Cartwheel's: these wide disks put most of the 8 M in the near field, 128 M point
# stars a render and up to 8 renders a frame took 17 s an image
inside = {"field": [6, 14], "glowHaze": 5, "glowFade": 0.5, "stars": 24, "subframes": 2}
os.makedirs(f"{scene}/flights", exist_ok=True)
json.dump({"version": 1, "inside": inside, "keys": keys}, open(f"{scene}/flights/film.flight.json", "w"), indent=1)
print("start", round(START, 1), "pericentre", P, "photo", M, "end", END, "seconds", keys[-1]["at"])
