#!/usr/bin/env python3
"""film_rc.py OUT_DIR [END_MYR]: the Sombrero film's flight, release candidate (#509), one key a frame.

Writes OUT_DIR/film.flight.json (#510's inside stars) and OUT_DIR/film-animatic.flight.json (the
same, one render a frame), prints the camera once a second and the angle between the line of
sight and the velocity. Axes are galaxy 0's (disk in xy, spin +z; Hubble looks from -y, 6 degrees
up). END_MYR: the take's moment at the cut (170 by default). Env: INSIDE, the flight whose inside
block the film takes ($SOMBRERO/out/511/flights/final02.flight.json, SOMBRERO being
~/claude-workspace/sombrero by default), and DEPTH, the dust screen's depth (0.412 for the film's
20 M take).

Shots (seconds): far, seen 63 degrees from face on with the ring rolled across the frame and off
centre, turning, then unrolling onto Hubble's axis 0-16 (time running to 48 Myr), freeze for the
split screen 16-25, in along Hubble's line of sight 25-31.7, banked swoop onto the near ring
31.7-36.2, low flight along it 36.2-43.7, descent to a stop in the layer 43.7-51.2, the head
turned 100 degrees right and back 51.2-64.7, off out over the ring and round onto the core to a
hover 450 pc above the plane inside the ring 64.7-79.2, held 79.2-80.7, the galaxy turning round
the fixed camera 80.7-88.2, pull-out with time running 88.2-102.2, time speeding up over half a
turn 101.2-107.7, cut.

The camera flies as a pilot: it looks along its own path a little ahead (a lead into turns),
banks with the turn of its course (2.5 rad per rad/s, 0.35 rad at most, eased) and never slips
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
# #511's inside block (dust thresholds; #510's stars), the dust's column 1.2 times the original
# (#511 had 1.15), and #510's star shares scaled by 92/255: they are shares of the look's kernel
# ceiling, which #512's look raised from 92 to 255 px, so the same particles turn to stars
SOM = os.environ.get("SOMBRERO", os.path.expanduser("~/claude-workspace/sombrero"))  # the working folder
INSIDE = os.environ.get("INSIDE", f"{SOM}/out/511/flights/final02.flight.json")
DEPTH = float(os.environ.get("DEPTH", 0.39 * 1.2))  # the 20 M take wants 0.412: its lane is 11 % deeper at one depth
STARS = {"starFrom": round(0.05 * 92 / 255, 6), "starFull": round(0.2 * 92 / 255, 6)}
HUBBLE = np.array([0.0, -795.618, 83.623])  # the freeze: 800 kpc, 6 degrees up
FOV_H, ROLL_H = 0.018632, 0.1
FAR = 2200.0  # first frame: the ring a quarter of the frame's width
AZ0, EL0, ROLL0 = -50.0, 27.0, -0.55  # 63 degrees from face on, 40 degrees round, the ring's line rolled 31 degrees
OFF0 = np.array([0.08, 0.06])  # the centre off the frame's, shares of its width and height
T_F, T_H = 16.0, 25.0  # freeze, end of the hold (the split screen)
T_A = T_H + 6.7  # end of the straight approach
T_RING, T_LOW, T_STOP, T_GO, T_CORE = (T_A + x for x in (4.5, 12.0, 19.5, 33.0, 47.5))
T_ROT, T_PULL, T_PEND, T_ACC, END = (T_A + x for x in (49.0, 56.5, 70.5, 69.5, 76.0))
T_SLOW = 8.0  # the opening's time runs evenly to here, then slows to the freeze
MYR_F = 48.0  # the freeze: a third of a turn of the ring in the opening
HALF = float(sys.argv[2]) if len(sys.argv) > 2 else 65.0  # Myr the ending adds: about half a turn of the ring
R_ROT, R_PULL = 1.0, 2.5  # Myr/s while the camera holds near the core, at the end of the pull-out
EASE_ROT = 5.0  # seconds time takes to start again at the hover
RAMP = 4.5  # seconds the ending's acceleration of time takes
# off again from the stop: a right bend out over the ring (55 degrees, radius 2.5 kpc), then a
# banked left turn back round onto the core (168 degrees, radius 1.6 kpc) climbing to 450 pc, to a
# hover 7.1 kpc from the centre, the eyes on it, the ring's inner dust in front
STOP, HEAD_STOP, Z_HOVER = np.array([5.982, -2.940, 0.016]), 73.8, 0.45
BENDS = [(2.5, -55.0), (1.6, 168.0)]


def bends(n_out=12):
    p, h, xy = STOP[:2].copy(), math.radians(HEAD_STOP), [STOP[:2].copy()]
    for r, a in BENDS:
        for _ in range(400):
            dh = math.radians(a) / 400
            h += dh / 2
            p = p + r * abs(dh) * np.array([math.cos(h), math.sin(h)])
            h += dh / 2
            xy.append(p.copy())
    xy = np.array(xy)
    s = np.concatenate([[0], np.cumsum(np.linalg.norm(np.diff(xy, axis=0), axis=1))])
    pick = np.linspace(0, s[-1], n_out + 1)[1:]
    x = np.clip(pick / (0.85 * s[-1]), 0, 1)
    z = STOP[2] + (Z_HOVER - STOP[2]) * x * x * (3 - 2 * x)
    pts = np.stack([np.interp(pick, s, xy[:, 0]), np.interp(pick, s, xy[:, 1]), z], -1)
    return pts, np.array([math.cos(h), math.sin(h), 0.0])


HOVER_PTS, END_DIR = bends()
C_STOP = HOVER_PTS[-1]
AZ_END = 33.0  # the pull-out's azimuth at 100 kpc
K_BANK, BANK_MAX = 2.5, 0.35

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

# 1-2. from far, at an odd angle and off centre, unrolling onto Hubble's axis; then the hold
op = t <= T_F + 1e-9
ud = smooth5((t - 0.5) / (T_F - 0.5))
ue = smooth5((t - 1.0) / (T_F - 1.0))
rho_op = np.exp(math.log(FAR) + (math.log(800.0) - math.log(FAR)) * ud)
eye[op] = sph(rho_op[op], (AZ0 + (-90.0 - AZ0) * ue)[op], (EL0 + (6.0 - EL0) * ue)[op])
hold = (t >= T_F - 1e-9) & (t <= T_H + 1e-9)
eye[hold] = HUBBLE
fov[op | hold] = FOV_H
roll[op] = (ROLL0 + (ROLL_H - ROLL0) * ue)[op]
roll[hold] = ROLL_H
# the aim moved off the centre so that the galaxy sits OFF0 of the frame away, back to it with the move
f_op = unit(-eye[op])
r_op = unit(np.cross(f_op, [0.0, 0.0, 1.0]))
u_op = np.cross(r_op, f_op)
h_op = 2 * rho_op[op] * math.tan(FOV_H / 2)
off = np.zeros((n, 3))
off[op] = -(1 - ue[op])[:, None] * (OFF0[0] * h_op[:, None] * 16 / 9 * r_op + OFF0[1] * h_op[:, None] * u_op)

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
    [5.598, -4.279, 0.075],    # turning in as it slows, 3.65 kpc round
    [5.855, -3.628, 0.03],
    STOP,                      # 9: the stop in the layer, looking 20 degrees in from the ring
    *HOVER_PTS,                # the S out over the ring and round onto the core, to the hover
])
I_RING, I_LOW, I_STOP, I_CORE = 3, 6, 9, len(P) - 1
chord = np.concatenate([[0], np.cumsum(np.linalg.norm(np.diff(P, axis=0), axis=1))])
end_dir = END_DIR / np.linalg.norm(END_DIR)
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
       (T_GO, I_STOP, 0.0), (T_GO + 6.0, I_STOP + 4, 0.75), (T_CORE, I_CORE, 0.0)]  # +4: end of the right bend
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
LOOK = [(0.0, 0, 0), (1.0, 0, 0), (7.0, -100, 0), (8.5, -100, 0), (13.5, 0, 0)]  # 100 degrees right and back
lk = (t > T_STOP) & (t < T_GO)
yaw_off = np.zeros(n)
pit_off = np.zeros(n)
for (a, ya, pa), (b, yb, pb) in zip(LOOK, LOOK[1:]):
    m = (t - T_STOP >= a) & (t - T_STOP <= b) & lk
    x = smooth5((t[m] - T_STOP - a) / (b - a))
    yaw_off[m] = ya + (yb - ya) * x
    pit_off[m] = pa + (pb - pa) * x
# coming to a hover near the core, the eyes go down to it over the last 2.5 s (under 0.4 kpc/s)
wg = smooth((t - (T_CORE - 2.5)) / 2.5)[:, None]
fwd = unit((1 - wg) * fwd + wg * unit(-eye))
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
aim = eye + d * reach[:, None] + off

# banking from the turn of the course (left positive, as roll)
dchi = np.gradient(np.unwrap(np.arctan2(np.gradient(pts[:, 1]), np.gradient(pts[:, 0]))), arc)
turn = np.interp(s_t, arc, dchi) * v_t * ins
bank = gaussian_filter1d(BANK_MAX * np.tanh(K_BANK * turn / BANK_MAX), 0.6 * FPS, mode="nearest")
# eased in at the swoop and out at the hover: cut at the ends of `ins`, it snapped 10 and 1.4 degrees
env = smooth5((t - T_A) / 1.3) * (1 - smooth5((t - (T_CORE - 0.8)) / 0.8))
roll[ins] += (bank * env)[ins]
fi = CubicHermiteSpline([T_A, T_A + 6.0, T_A + 16.0, T_GO, T_CORE], [fov_appr(RHO_A), 1.0, 1.1, 1.1, 1.1],
                        [-V_A * (fov_appr(RHO_A * 1.001) - fov_appr(RHO_A)) / (RHO_A * 0.001), 0.006, 0, 0, 0])
fov[ins] = fi(t[ins])
fov[core] = 1.1

# 7-8. pull-out: log distance from the centre, a little orbit and rise, aim at the centre
rho0 = float(np.linalg.norm(C_STOP))
az0 = math.degrees(math.atan2(C_STOP[1], C_STOP[0]))
el0 = math.degrees(math.asin(C_STOP[2] / rho0))
pull = t > T_PULL + 1e-9
u = smooth5((t - T_PULL) / (T_PEND - T_PULL))
rho_p = np.exp(math.log(rho0) + (math.log(100.0) - math.log(rho0)) * u)
eye[pull] = sph(rho_p[pull], az0 + (AZ_END - az0) * u[pull], el0 + (25.0 - el0) * u[pull])
aim[core] = 0.0
V0 = 2 * rho0 * math.tan(0.55)
beta = math.log(2 * 100.0 * math.tan(0.1095) / V0) / math.log(100.0 / rho0)
fov[pull] = 2 * np.arctan(V0 * (rho_p[pull] / rho0) ** beta / (2 * rho_p[pull]))

# time: running from the first frame, slowing to the freeze, held, then the galaxy turns round the
# held camera, starting again gently, faster on the way out, speeding up over half a turn at the end
fine = np.linspace(0, END, 200001)
r = np.zeros_like(fine)
mo = fine <= T_F
r[mo] = 1 - smooth((fine[mo] - T_SLOW) / (T_F - T_SLOW))
r[mo] *= (MYR_F - 0.5) / np.trapezoid(r[mo], fine[mo])
mr = (fine > T_ROT) & (fine <= T_PULL)
r[mr] = R_ROT * smooth5((fine[mr] - T_ROT) / EASE_ROT)
mp = (fine > T_PULL) & (fine <= T_ACC)
r[mp] = R_ROT + (R_PULL - R_ROT) * smooth((fine[mp] - T_PULL) / (T_ACC - T_PULL))
ma = fine > T_ACC
myr_fine = 0.5 + np.concatenate([[0], np.cumsum((r[1:] + r[:-1]) / 2 * np.diff(fine))])
ramp = smooth5((fine[ma] - T_ACC) / RAMP)
r_top = R_PULL + (HALF - R_PULL * (END - T_ACC)) / np.trapezoid(ramp, fine[ma])
r[ma] = R_PULL + (r_top - R_PULL) * ramp
myr_fine = 0.5 + np.concatenate([[0], np.cumsum((r[1:] + r[:-1]) / 2 * np.diff(fine))])
myr = np.interp(t, fine, myr_fine)
myr[(t >= T_F - 1e-9) & (t <= T_ROT + 1e-9)] = MYR_F
print(f"time: {myr[0]:.1f} to {MYR_F} Myr in the opening at {r[1]:.2f} Myr/s, {myr[round(T_PULL * FPS)]:.1f} at {T_PULL:.1f} s, "
      f"{myr[round(T_ACC * FPS)]:.1f} at {T_ACC:.1f} s, {myr[-1]:.1f} at the cut; up to {r_top:.1f} Myr/s", file=sys.stderr)


def key(i):
    return {"at": round(i / FPS, 6), "myr": round(float(myr[i]), 6),
            "eye": {"galaxy": 0, "offset": [round(float(x), 6) for x in eye[i]]},
            "aim": {"galaxy": 0, "offset": [round(float(x), 6) for x in aim[i]]},
            "fov": round(float(fov[i]), 7), "roll": round(float(roll[i]), 6)}


inside = {**json.load(open(INSIDE))["inside"], **STARS}
inside["dustScreen"] = {**inside["dustScreen"], "depth": round(DEPTH, 6)}
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
          f"course turns up to {course[m].max():.1f} deg/s, bank up to {np.abs(roll[m]).max():.2f} rad; "
          f"over 0.4 kpc/s max {ang[m & (spd > 0.4)].max():.1f} deg", file=sys.stderr)
np.save(os.path.join(out, "film-sight.npy"), np.stack([t, ang, spd, roll, myr], 1))
for s in range(0, math.floor(END) + 1):
    i = min(s * FPS, n - 1)
    e = eye[i]
    print(f"{t[i]:5.1f}s {myr[i]:6.1f} Myr | R {math.hypot(e[0], e[1]):8.3f} z {e[2]:8.3f} | v {spd[i]:7.3f} "
          f"| head {math.degrees(math.atan2(sight[i, 1], sight[i, 0])):6.1f} pitch "
          f"{math.degrees(math.asin(sight[i, 2])):6.1f} | fov {fov[i]:.4f} roll {roll[i]:+.3f} off {ang[i]:5.1f}",
          file=sys.stderr)
