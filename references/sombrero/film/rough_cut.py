#!/usr/bin/env python3
"""rough_cut.py OUT_DIR: the Sombrero rough cut's flight (#509), one key a frame at 30 fps.

Writes OUT_DIR/rough-cut.flight.json and OUT_DIR/rough-cut-animatic.flight.json (the same path,
one render a frame from inside), and prints the camera once a second.

The flight's own easing (fov and roll smoothstepped key to key) would stall at every key, so the
path is computed here and laid one key per video frame: every frame lands on a key and draws
exactly this camera. Axes are the world's, offsets from galaxy 0's centre (the disk is the xy
plane, spin +z; Hubble looks from -y, 6 degrees up).

Shots (seconds): zenith 0-10, tilt onto Hubble's axis 10-18, hold for the split screen
18-25.3, straight approach along Hubble's line of sight 25.3-32, low flight over the near ring
32-44, descent into the layer 44-54, towards the core 54-64, pull-out with time running 64-78.
Time: 0.5 Myr at 0 s, 8 at 10 s, 12 at 18 s, held to 64 s, 22 at 78 s.
"""
import json
import math
import os
import sys

import numpy as np
from scipy.interpolate import CubicHermiteSpline, CubicSpline, PchipInterpolator
from scipy.ndimage import gaussian_filter1d

FPS = 30
END = 78.0
INSIDE = "/Users/pierregc/claude-workspace/sombrero/out/508/flights/h2-descent.flight.json"
HUBBLE = np.array([0.0, -795.618, 83.623])  # e9/h2 freeze: 800 kpc, 6 degrees up
FOV_H, ROLL_H = 0.018632, 0.1
TIMES = [(0.0, 0.5), (10.0, 8.0), (18.0, 12.0), (64.0, 12.0), (78.0, 22.0)]
HOLD = (18.0, 25.3)
T_A, T_CORE = 32.0, 64.0

t = np.arange(round(END * FPS) + 1) / FPS
n = len(t)


def smooth(x):
    x = np.clip(x, 0.0, 1.0)
    return x * x * (3 - 2 * x)


def lntan(f):
    return np.log(np.tan(np.asarray(f) / 2))


def untan(v):
    return 2 * np.arctan(np.exp(v))


def sph(rho, az, el):
    a, e = np.radians(az), np.radians(el)
    return np.stack([rho * np.cos(e) * np.cos(a), rho * np.cos(e) * np.sin(a), rho * np.sin(e)], -1)


eye = np.zeros((n, 3))
aim_centre = np.zeros((n, 3))
fov = np.zeros(n)
roll = np.zeros(n)

# 1-3. zenith, tilt, hold: on the 800 kpc sphere, aim at the centre
far = t <= HOLD[1] + 1e-9
el = 89.0 + (6.0 - 89.0) * smooth((t - 10.0) / 8.0)
eye[far] = sph(800.0, -90.0, el[far])
eye[np.isclose(t, HOLD[0]) | ((t >= HOLD[0]) & far)] = HUBBLE
fz = PchipInterpolator([0.0, 10.0, 18.0, 30.0], lntan([0.0275, 0.0265, FOV_H, FOV_H]))
fov[far] = untan(fz(t[far]))
roll[far] = ROLL_H * smooth((t[far] - 10.0) / 8.0)

# 4a. straight approach along Hubble's line of sight, the distance eased in log
RHO_A, V_A = 10.05, 1.0
unit = HUBBLE / np.linalg.norm(HUBBLE)
A = unit * RHO_A
appr = (t > HOLD[1]) & (t <= T_A)
dln = math.log(800.0 / RHO_A)
# the rate of closing in log distance: quick while far (nothing changes but the size), slow
# once the perspective opens, V_A / RHO_A at A
RATE = [(HOLD[1], 0.0), (26.1, 1.0), (27.0, 0.85), (28.5, 0.42), (30.0, 0.2), (31.0, 0.13)]
fine = np.linspace(HOLD[1], T_A, 4001)


def closing(k):
    return PchipInterpolator([r[0] for r in RATE] + [T_A], [k * r[1] for r in RATE] + [V_A / RHO_A])(fine)


lo, hi = 0.1, 20.0
for _ in range(60):
    k = (lo + hi) / 2
    lo, hi = (k, hi) if np.trapezoid(closing(k), fine) < dln else (lo, k)
lnr = math.log(800.0) - np.concatenate([[0], np.cumsum((closing(k)[1:] + closing(k)[:-1]) / 2 * np.diff(fine))])
rho_appr = np.exp(np.interp(t, fine, lnr))
eye[appr] = unit * rho_appr[appr, None]
V_H = 2 * 800.0 * math.tan(FOV_H / 2)
alpha = math.log(2 * RHO_A * math.tan(0.475) / V_H) / math.log(RHO_A / 800.0)


def fov_appr(rho):
    return 2 * np.arctan(V_H * (rho / 800.0) ** alpha / (2 * rho))


fov[appr] = fov_appr(rho_appr[appr])
roll[appr] = ROLL_H * (1 - smooth((t[appr] - 26.0) / 5.0))

# 4b-6. the inside path: a spline through points (x, y, z) timed by arc length
P = np.array([
    A,
    [0.25, -8.85, 0.78],
    [0.95, -7.80, 0.52],
    [2.10, -7.05, 0.30],   # 36.5 s: over the near ring, R 7.36
    [3.45, -6.30, 0.21],
    [4.62, -5.70, 0.17],   # weave out
    [5.55, -4.62, 0.14],   # 44 s: the descent begins
    [6.18, -3.78, 0.075],
    [6.56, -3.10, 0.03],
    [6.70, -2.75, 0.016],  # 54 s: slowest, in the layer
    [6.72, -2.30, 0.04],
    [6.25, -1.45, 0.12],
    [5.10, -0.85, 0.22],
    [3.80, -0.45, 0.32],
    [3.00, -0.25, 0.38],   # 64 s: three kpc from the centre, at rest
])
chord = np.concatenate([[0], np.cumsum(np.linalg.norm(np.diff(P, axis=0), axis=1))])
end_dir = (P[-1] - P[-2]) / np.linalg.norm(P[-1] - P[-2])
path = CubicSpline(chord, P, bc_type=((1, -unit), (1, end_dir)))
uu = np.linspace(0, chord[-1], 20001)
ds = np.linalg.norm(np.diff(path(uu), axis=0), axis=1)
arc = np.concatenate([[0], np.cumsum(ds)])
arc_at = lambda i: float(np.interp(chord[i], uu, arc))  # noqa: E731
# (seconds, control point, speed kpc/s)
WAY = [(T_A, 0, V_A), (36.5, 3, 0.50), (44.0, 6, 0.33), (54.0, 9, 0.03), (T_CORE, 14, 0.0)]
st = CubicHermiteSpline([w[0] for w in WAY], [arc_at(w[1]) for w in WAY], [w[2] for w in WAY])
ins = (t > T_A) & (t <= T_CORE)
s_t = st(t[ins])
eye[ins] = path(np.interp(s_t, arc, uu))
for (ta, ia, va), (tb, ib, vb) in zip(WAY, WAY[1:]):
    m = (arc_at(ib) - arc_at(ia)) / (tb - ta)
    sp = st.derivative()(np.linspace(ta, tb, 50))
    print(f"path {ta:5.1f}-{tb:5.1f} s: {arc_at(ib) - arc_at(ia):5.2f} kpc, mean {m:.2f}, "
          f"speed {sp.min():.2f}-{sp.max():.2f} kpc/s", file=sys.stderr)

# 7. pull-out: log distance from the centre, a little orbit and rise, aim at the centre
pull = t > T_CORE
p14 = P[-1]
rho0, az0, el0 = np.linalg.norm(p14), math.degrees(math.atan2(p14[1], p14[0])), math.degrees(
    math.asin(p14[2] / np.linalg.norm(p14)))
u = smooth((t - T_CORE) / (END - T_CORE))
rho_p = np.exp(math.log(rho0) + (math.log(100.0) - math.log(rho0)) * u)
eye[pull] = sph(rho_p[pull], az0 + (20.0 - az0) * u[pull], el0 + (25.0 - el0) * u[pull])
V0 = 2 * rho0 * math.tan(0.5)
beta = math.log(2 * 100.0 * math.tan(0.1095) / V0) / math.log(100.0 / rho0)
fov[pull] = 2 * np.arctan(V0 * (rho_p[pull] / rho0) ** beta / (2 * rho_p[pull]))

# inside fov: from the approach's own slope at A to wider in the layer, 1.0 at the core
f_slope = -V_A * (fov_appr(RHO_A * 1.001) - fov_appr(RHO_A)) / (RHO_A * 0.001)
fi = CubicHermiteSpline([T_A, 44.0, 52.0, T_CORE], [fov_appr(RHO_A), 1.0, 1.1, 1.0], [f_slope, 0.008, 0, 0])
fov[ins] = fi(t[ins])

# aim: the centre, or ahead along the path (yawed in towards the bulge, pitched down)
vel = np.gradient(eye, t, axis=0)
vs = gaussian_filter1d(vel, 0.35 * FPS, axis=0, mode="nearest")
acc = np.gradient(vs, t, axis=0)
head = np.degrees(np.arctan2(vs[:, 1], vs[:, 0]))
yaw = np.interp(t, [33, 36, 44, 48, 52, 64], [0, 38, 38, 22, 10, 10])
pitch = np.interp(t, [32, 36, 44, 52, 64], [-6, -8, -8, -1.5, -1.5])
hd = np.radians(head + yaw)
pr = np.radians(pitch)
d_head = np.stack([np.cos(pr) * np.cos(hd), np.cos(pr) * np.sin(hd), np.sin(pr)], -1)
to_c = aim_centre - eye
dist_c = np.linalg.norm(to_c, axis=1)
d_cen = to_c / dist_c[:, None]
w = smooth((t - T_A) / 3.5) * (1 - smooth((t - 57.0) / 5.0))
cosang = np.clip(np.sum(d_cen * d_head, axis=1), -1, 1)
ang = np.arccos(cosang)
sa = np.where(ang > 1e-6, np.sin(ang), 1.0)
k0 = np.where(ang > 1e-6, np.sin((1 - w) * ang) / sa, 1 - w)
k1 = np.where(ang > 1e-6, np.sin(w * ang) / sa, w)
d = k0[:, None] * d_cen + k1[:, None] * d_head
d /= np.linalg.norm(d, axis=1)[:, None]
reach = (1 - w) * dist_c + w * 2.5
aim = eye + d * reach[:, None]

# banking from the turn's sideways acceleration (left positive, as roll), gated to the inside
speed = np.linalg.norm(vs[:, :2], axis=1)
lat = (vs[:, 0] * acc[:, 1] - vs[:, 1] * acc[:, 0]) / np.maximum(speed, 1e-6)
lat = gaussian_filter1d(lat, 0.5 * FPS, mode="nearest")
gate = smooth((t - 31.5) / 2.0) * (1 - smooth((t - 60.5) / 3.0))
K = 1.6  # rad per kpc/s^2
bank = np.clip(K * lat, -0.32, 0.32) * gate
roll = roll + bank

myr = {round(a * FPS): m for a, m in TIMES}


def key(i):
    k = {"at": round(i / FPS, 6)}
    if i in myr:
        k["myr"] = myr[i]
    k["eye"] = {"galaxy": 0, "offset": [round(float(x), 6) for x in eye[i]]}
    k["aim"] = {"galaxy": 0, "offset": [round(float(x), 6) for x in aim[i]]}
    k["fov"] = round(float(fov[i]), 7)
    k["roll"] = round(float(roll[i]), 6)
    return k


inside = json.load(open(INSIDE))["inside"]
keys = [key(i) for i in range(n)]
out = sys.argv[1]
os.makedirs(out, exist_ok=True)
# rough-cut: the far shots (binary of #508); rough-cut-stars: from 25.3 s on, with #510's inside
# stars (its binary), kernel lengths held at the freeze's moment
STARS = {"starBloom": 0.12, "heldLengths": 12.0}
for name, extra in (("rough-cut", {}), ("rough-cut-stars", STARS), ("rough-cut-animatic", {"subframes": 1})):
    path = os.path.join(out, f"{name}.flight.json")
    with open(path + ".part", "w") as f:
        json.dump({"version": 1, "inside": {**inside, **extra}, "keys": keys}, f, separators=(",", ":"))
    os.replace(path + ".part", path)

spd = np.linalg.norm(vel, axis=1)
for s in range(0, round(END) + 1, 1):
    i = min(s * FPS, n - 1)
    e = eye[i]
    R, th = math.hypot(e[0], e[1]), math.degrees(math.atan2(e[1], e[0]))
    fw = (aim[i] - e) / np.linalg.norm(aim[i] - e)
    print(f"{t[i]:5.1f}s R {R:8.3f} th {th:7.1f} z {e[2]:8.3f} | v {spd[i]:8.3f} kpc/s "
          f"head {math.degrees(math.atan2(fw[1], fw[0])):6.1f} pitch {math.degrees(math.asin(fw[2])):6.1f} "
          f"| fov {fov[i]:.4f} roll {roll[i]:+.3f}", file=sys.stderr)
