#!/usr/bin/env python3
"""film_rc.py OUT_DIR [END_MYR]: the Sombrero film's flight, release candidate (#509), one key a frame.

Writes OUT_DIR/film.flight.json (#510's inside stars) and OUT_DIR/film-animatic.flight.json (the
same, one render a frame), prints the camera once a second and the angle between the line of
sight and the velocity. Axes are galaxy 0's (disk in xy, spin +z; Hubble looks from -y, 6 degrees
up). END_MYR: the take's moment at the cut (170 by default).

Shots (seconds): far and tilted, advancing onto Hubble's axis 0-16 (time running to 12 Myr),
freeze for the split screen 16-23.3, in along Hubble's line of sight 23.3-30, banked swoop onto the
near ring 30-34.5, low flight along it 34.5-42, descent to a stop in the layer 42-49.5, a look
round 49.5-61, off towards the core 61-70, held 70-71.5, the galaxy turning round the fixed
camera 71.5-78, pull-out with time running 78-92, time racing 90-95.5, cut.

The camera flies as a pilot: it looks along its own path a little ahead (a lead into turns),
banks with the turn of its course (3.5 rad per rad/s, 0.45 rad at most, eased) and never slips
sideways; the look round is a head turned from a stop.
"""
import json
import math
import os
import sys

import numpy as np
from scipy.interpolate import CubicHermiteSpline, CubicSpline, PchipInterpolator
from scipy.ndimage import gaussian_filter1d

FPS = 30
INSIDE = "/Users/pierregc/claude-workspace/sombrero/out/508/flights/h2-descent.flight.json"
STARS = {"starBloom": 0.12, "heldLengths": 12.0}
HUBBLE = np.array([0.0, -795.618, 83.623])  # the freeze: 800 kpc, 6 degrees up
FOV_H, ROLL_H = 0.018632, 0.1
FAR, EL_FAR = 3200.0, 68.0  # first frame: four times Hubble's distance, 22 degrees off the pole
T_F, T_H = 16.0, 23.3  # freeze, end of the hold
T_A = 30.0  # end of the straight approach
T_RING, T_LOW, T_STOP, T_GO, T_CORE = 34.5, 42.0, 49.5, 61.0, 70.0
T_ROT, T_PULL, T_PEND, T_ACC, END = 71.5, 78.0, 92.0, 90.0, 95.5
MYR_F = 12.0
MYR_END = float(sys.argv[2]) if len(sys.argv) > 2 else 170.0
R_ROT, R_PULL = 1.2, 2.5  # Myr/s while the camera holds near the core, at the end of the pull-out
RAMP = 2.5  # seconds the last acceleration of time takes
C_STOP = np.array([3.0, -0.25, 0.38])  # the stop near the core
K_BANK, BANK_MAX = 3.5, 0.45

t = np.arange(round(END * FPS) + 1) / FPS
n = len(t)


def smooth(x):
    x = np.clip(x, 0.0, 1.0)
    return x * x * (3 - 2 * x)


def smooth5(x):
    x = np.clip(x, 0.0, 1.0)
    return x ** 3 * (10 + x * (-15 + 6 * x))


def lntan(f):
    return np.log(np.tan(np.asarray(f) / 2))


def untan(v):
    return 2 * np.arctan(np.exp(v))


def unit(v):
    return v / np.maximum(np.linalg.norm(v, axis=-1, keepdims=True), 1e-12)


def sph(rho, az, el):
    a, e = np.radians(az), np.radians(el)
    return np.stack([rho * np.cos(e) * np.cos(a), rho * np.cos(e) * np.sin(a), rho * np.sin(e)], -1)


eye = np.zeros((n, 3))
fov = np.zeros(n)
roll = np.zeros(n)

# 1-2. from far and tilted onto Hubble's axis, then the hold
op = t <= T_F + 1e-9
ud = smooth5((t - 0.5) / (T_F - 0.5))
ue = smooth5((t - 1.5) / (T_F - 1.5))
rho_op = np.exp(math.log(FAR) + (math.log(800.0) - math.log(FAR)) * ud)
eye[op] = sph(rho_op[op], -90.0, (EL_FAR + (6.0 - EL_FAR) * ue)[op])
hold = (t >= T_F - 1e-9) & (t <= T_H + 1e-9)
eye[hold] = HUBBLE
fov[op | hold] = FOV_H
roll[op] = ROLL_H * ue[op]
roll[hold] = ROLL_H

# 3. straight in along Hubble's line of sight, the distance eased in log; the closing rate starts
# from rest over two seconds
RHO_A, V_A = 10.05, 1.0
uni = HUBBLE / np.linalg.norm(HUBBLE)
A = uni * RHO_A
appr = (t > T_H + 1e-9) & (t <= T_A + 1e-9)
dln = math.log(800.0 / RHO_A)
RATE = [(T_H, 0.0), (T_H + 1.0, 0.4), (T_H + 2.0, 1.0), (T_H + 2.8, 0.85), (T_H + 4.0, 0.42),
        (T_H + 5.3, 0.2), (T_H + 6.1, 0.13)]
fine = np.linspace(T_H, T_A, 4001)


def closing(k):
    return PchipInterpolator([r[0] for r in RATE] + [T_A], [k * r[1] for r in RATE] + [V_A / RHO_A])(fine)


lo, hi = 0.1, 20.0
for _ in range(60):
    k = (lo + hi) / 2
    lo, hi = (k, hi) if np.trapezoid(closing(k), fine) < dln else (lo, k)
lnr = math.log(800.0) - np.concatenate([[0], np.cumsum((closing(k)[1:] + closing(k)[:-1]) / 2 * np.diff(fine))])
rho_appr = np.exp(np.interp(t, fine, lnr))
eye[appr] = uni * rho_appr[appr, None]
V_H = 2 * 800.0 * math.tan(FOV_H / 2)
alpha = math.log(2 * RHO_A * math.tan(0.475) / V_H) / math.log(RHO_A / 800.0)


def fov_appr(rho):
    return 2 * np.arctan(V_H * (rho / 800.0) ** alpha / (2 * rho))


fov[appr] = fov_appr(rho_appr[appr])
roll[appr] = ROLL_H * (1 - smooth((t[appr] - T_H - 0.7) / 5.0))

# 4-6. inside: a spline through points, timed by a speed profile along its length
u_c = C_STOP / np.linalg.norm(C_STOP)


def ring(th, r, z):
    return [r * math.cos(math.radians(th)), r * math.sin(math.radians(th)), z]


# along the near ring a steady left turn, spiralling in by 0.36 kpc, then a left turn onto the core
P = np.array([
    A,
    [0.25, -8.85, 0.78],
    [0.95, -7.80, 0.52],
    ring(-73.4, 7.36, 0.30),   # 3: over the near ring
    ring(-63.0, 7.30, 0.22),
    ring(-53.0, 7.22, 0.18),
    ring(-43.0, 7.14, 0.14),   # 6: the descent begins
    ring(-35.0, 7.08, 0.075),
    [6.008, -3.545, 0.03],     # turning in as it slows
    [6.027, -2.989, 0.016],    # 9: the stop in the layer, looking 30 degrees in from the ring
    [5.777, -1.849, 0.16],     # a climbing left turn onto the core, 2.7 kpc round
    [5.066, -0.922, 0.42],
    C_STOP + 0.9 * u_c,
    C_STOP,                    # 14: near the core, looking at it
])
I_RING, I_LOW, I_STOP, I_CORE = 3, 6, 9, len(P) - 1
chord = np.concatenate([[0], np.cumsum(np.linalg.norm(np.diff(P, axis=0), axis=1))])
end_dir = -u_c
path = CubicSpline(chord, P, bc_type=((1, -uni), (1, end_dir)))
uu = np.linspace(0, chord[-1], 40001)
pts = path(uu)
arc = np.concatenate([[0], np.cumsum(np.linalg.norm(np.diff(pts, axis=0), axis=1))])


def arc_at(i):
    return float(np.interp(chord[i], uu, arc))


def point_at(s):
    s = np.asarray(s, dtype=float)
    p = np.stack([np.interp(np.minimum(s, arc[-1]), arc, pts[:, j]) for j in range(3)], -1)
    return p + np.maximum(s - arc[-1], 0)[..., None] * end_dir


# (seconds, control point, speed kpc/s); within a leg the speed goes from one to the next
# smoothstepped, plus a bump 16 x^2 (1-x)^2 that makes the leg's length: no jolt at any waypoint
WAY = [(T_A, 0, V_A), (T_RING, I_RING, 0.55), (T_LOW, I_LOW, 0.55), (T_STOP, I_STOP, 0.0),
       (T_GO, I_STOP, 0.0), (T_CORE, I_CORE, 0.0)]
ins = (t > T_A + 1e-9) & (t <= T_CORE + 1e-9)
s_t = np.zeros(n)
v_t = np.zeros(n)
for (ta, ia, va), (tb, ib, vb) in zip(WAY, WAY[1:]):
    T, d = tb - ta, arc_at(ib) - arc_at(ia)
    kb = (d / T - (va + vb) / 2) / (16 / 30)
    m = (t > ta + 1e-9) & (t <= tb + 1e-9)
    x = (t[m] - ta) / T
    v_t[m] = va + (vb - va) * smooth(x) + kb * 16 * x * x * (1 - x) ** 2
    s_t[m] = arc_at(ia) + T * (va * x + (vb - va) * (x ** 3 - x ** 4 / 2) + kb * 16 * (x ** 3 / 3 - x ** 4 / 2 + x ** 5 / 5))
    xx = np.linspace(0, 1, 201)
    vv = va + (vb - va) * smooth(xx) + kb * 16 * xx * xx * (1 - xx) ** 2
    print(f"leg {ta:5.1f}-{tb:5.1f} s: {d:5.2f} kpc, speed {vv.min():.2f}-{vv.max():.2f} kpc/s", file=sys.stderr)
eye[ins] = point_at(s_t[ins])
core = t > T_CORE + 1e-9
eye[core & (t <= T_PULL + 1e-9)] = C_STOP

# the line of sight inside: along the path a little ahead (the lead grows with the speed)
lead = 0.15 + 0.4 * v_t
fwd = unit(point_at(s_t + lead) - point_at(s_t))

# a head turned from the stop: (seconds after the stop, yaw left, pitch up in degrees), each move
# minimum-jerk, held still between
LOOK = [(0.0, 0, 0), (0.6, 0, 0), (2.1, 5, 8), (2.5, 5, 8), (4.4, -3, -8), (4.8, -3, -8),
        (6.8, 20, -1), (7.3, 20, -1), (10.3, -20, 1), (10.6, -20, 1), (11.5, 0, 0)]
lk = (t > T_STOP) & (t < T_GO)
yaw_off = np.zeros(n)
pit_off = np.zeros(n)
for (a, ya, pa), (b, yb, pb) in zip(LOOK, LOOK[1:]):
    m = (t - T_STOP >= a) & (t - T_STOP <= b) & lk
    x = smooth5((t[m] - T_STOP - a) / (b - a))
    yaw_off[m] = ya + (yb - ya) * x
    pit_off[m] = pa + (pb - pa) * x
psi = np.arctan2(fwd[:, 1], fwd[:, 0]) + np.radians(yaw_off)
th = np.arcsin(np.clip(fwd[:, 2], -1, 1)) + np.radians(pit_off)
look = np.stack([np.cos(th) * np.cos(psi), np.cos(th) * np.sin(psi), np.sin(th)], -1)

# aim: the centre while far, near the core and on the way out; inside, 2.5 kpc along the look
to_c = -eye
dist_c = np.linalg.norm(to_c, axis=1)
d_cen = to_c / np.maximum(dist_c, 1e-9)[:, None]
w = smooth((t - T_A) / 1.2) * (1 - smooth((t - T_CORE) / 0.5)) * ins
d = unit((1 - w)[:, None] * d_cen + w[:, None] * look)
reach = dist_c + (2.5 - dist_c) * smooth((t - T_A) / 2.5) * (1 - smooth((t - (T_CORE - 3.0)) / 3.0)) * (t <= T_CORE)
aim = eye + d * reach[:, None]

# banking from the turn of the course (left positive, as roll)
dchi = np.gradient(np.unwrap(np.arctan2(np.gradient(pts[:, 1]), np.gradient(pts[:, 0]))), arc)
turn = np.interp(s_t, arc, dchi) * v_t * ins
bank = gaussian_filter1d(BANK_MAX * np.tanh(K_BANK * turn / BANK_MAX), 0.6 * FPS, mode="nearest")
roll[ins] += bank[ins]
fi = CubicHermiteSpline([T_A, 36.0, 46.0, T_GO, T_CORE], [fov_appr(RHO_A), 1.0, 1.1, 1.1, 1.0],
                        [-V_A * (fov_appr(RHO_A * 1.001) - fov_appr(RHO_A)) / (RHO_A * 0.001), 0.006, 0, 0, 0])
fov[ins] = fi(t[ins])
fov[core] = 1.0

# 7-8. pull-out: log distance from the centre, a little orbit and rise, aim at the centre
rho0 = float(np.linalg.norm(C_STOP))
az0 = math.degrees(math.atan2(C_STOP[1], C_STOP[0]))
el0 = math.degrees(math.asin(C_STOP[2] / rho0))
pull = t > T_PULL + 1e-9
u = smooth5((t - T_PULL) / (T_PEND - T_PULL))
rho_p = np.exp(math.log(rho0) + (math.log(100.0) - math.log(rho0)) * u)
eye[pull] = sph(rho_p[pull], az0 + (20.0 - az0) * u[pull], el0 + (25.0 - el0) * u[pull])
aim[core] = 0.0
V0 = 2 * rho0 * math.tan(0.5)
beta = math.log(2 * 100.0 * math.tan(0.1095) / V0) / math.log(100.0 / rho0)
fov[pull] = 2 * np.arctan(V0 * (rho_p[pull] / rho0) ** beta / (2 * rho_p[pull]))

# time: running to the freeze, held, then the galaxy turns round the held camera, faster on the
# way out, racing at the end
fine = np.linspace(0, END, 200001)
r = np.zeros_like(fine)
mo = fine <= T_F
r[mo] = 1 - smooth((fine[mo] - 4.0) / (T_F - 4.0))
r[mo] *= (MYR_F - 0.5) / np.trapezoid(r[mo], fine[mo])
mr = (fine > T_ROT) & (fine <= T_PULL)
r[mr] = R_ROT * smooth((fine[mr] - T_ROT) / 1.5)
mp = (fine > T_PULL) & (fine <= T_ACC)
r[mp] = R_ROT + (R_PULL - R_ROT) * smooth((fine[mp] - T_PULL) / (T_ACC - T_PULL))
ma = fine > T_ACC
myr_fine = 0.5 + np.concatenate([[0], np.cumsum((r[1:] + r[:-1]) / 2 * np.diff(fine))])
need = MYR_END - myr_fine[ma][0]
ramp = smooth((fine[ma] - T_ACC) / RAMP)
r_top = R_PULL + (need - R_PULL * (END - T_ACC)) / np.trapezoid(ramp, fine[ma])
r[ma] = R_PULL + (r_top - R_PULL) * ramp
myr_fine = 0.5 + np.concatenate([[0], np.cumsum((r[1:] + r[:-1]) / 2 * np.diff(fine))])
myr = np.interp(t, fine, myr_fine)
myr[(t >= T_F - 1e-9) & (t <= T_ROT + 1e-9)] = MYR_F
print(f"time: {myr[round(T_PULL * FPS)]:.1f} Myr at {T_PULL} s, {myr[round(T_ACC * FPS)]:.1f} at {T_ACC} s, "
      f"{myr[-1]:.1f} at the cut; racing at {r_top:.1f} Myr/s", file=sys.stderr)


def key(i):
    return {"at": round(i / FPS, 6), "myr": round(float(myr[i]), 6),
            "eye": {"galaxy": 0, "offset": [round(float(x), 6) for x in eye[i]]},
            "aim": {"galaxy": 0, "offset": [round(float(x), 6) for x in aim[i]]},
            "fov": round(float(fov[i]), 7), "roll": round(float(roll[i]), 6)}


inside = {**json.load(open(INSIDE))["inside"], **STARS}
keys = [key(i) for i in range(n)]
out = sys.argv[1]
os.makedirs(out, exist_ok=True)
for name, extra in (("film", {}), ("film-animatic", {"subframes": 1})):
    fp = os.path.join(out, f"{name}.flight.json")
    with open(fp + ".part", "w") as f:
        json.dump({"version": 1, "inside": {**inside, **extra}, "keys": keys}, f, separators=(",", ":"))
    os.replace(fp + ".part", fp)

# the line of sight against the velocity, where the eye moves faster than 20 pc/s
vel = np.gradient(eye, t, axis=0)
spd = np.linalg.norm(vel, axis=1)
sight = unit(aim - eye)
ang = np.degrees(np.arccos(np.clip(np.sum(unit(vel) * sight, axis=1), -1, 1)))
for name, a, b in (("swoop", T_A, T_RING), ("low flight", T_RING, T_LOW), ("descent", T_LOW, T_STOP),
                   ("to the core", T_GO, T_CORE)):
    m = (t > a) & (t < b) & (spd > 0.02)
    course = np.degrees(np.abs(np.gradient(np.unwrap(np.arctan2(vel[:, 1], vel[:, 0])), t)))
    print(f"sight off the velocity, {name}: max {ang[m].max():.1f} deg, mean {ang[m].mean():.1f}; "
          f"course turns up to {course[m].max():.1f} deg/s, bank up to {np.abs(roll[m]).max():.2f} rad", file=sys.stderr)
np.save(os.path.join(out, "film-sight.npy"), np.stack([t, ang, spd, roll, myr], 1))
for s in range(0, math.floor(END) + 1):
    i = min(s * FPS, n - 1)
    e = eye[i]
    print(f"{t[i]:5.1f}s {myr[i]:6.1f} Myr | R {math.hypot(e[0], e[1]):8.3f} z {e[2]:8.3f} | v {spd[i]:7.3f} "
          f"| head {math.degrees(math.atan2(sight[i, 1], sight[i, 0])):6.1f} pitch "
          f"{math.degrees(math.asin(sight[i, 2])):6.1f} | fov {fov[i]:.4f} roll {roll[i]:+.3f} off {ang[i]:5.1f}",
          file=sys.stderr)
