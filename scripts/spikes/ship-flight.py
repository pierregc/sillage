#!/usr/bin/env python3
"""Spike #474: a camera that flies like a ship. See docs/notes/ship-flights.md.

  ship-flight.py measure <flight.json> --galaxy 0 [--from s --to s] [--level]
  ship-flight.py fly <plan.json> [--out flight.json] [--samples file.npz]
  ship-flight.py animatic <flight.json> <plan.json> out.mp4 --galaxy 0 --from s --to s

Everything is worked out in one galaxy's disk axes with time frozen, where a flight's anchors are
fixed points: no take is read. `measure` ports Flight.swift's path (eye and aim on a Hermite
curve with centripetal tangents) and approximates `"pace": "nearness"` on a model disk.
"""
import argparse, json, math, subprocess, sys
import numpy as np

RATE = 60
DISK_RADIUS, FLOOR = 20.0, 0.15


def unit(v):
    n = np.linalg.norm(v, axis=-1, keepdims=True)
    return v / np.maximum(n, 1e-12)


def nearness(p):
    r = np.hypot(p[..., 0], p[..., 1])
    return np.maximum(np.hypot(np.maximum(r - DISK_RADIUS, 0), p[..., 2]), FLOOR)


def angle(a, b):
    return np.degrees(np.arccos(np.clip(np.sum(unit(a) * unit(b), axis=-1), -1, 1)))


# ---- today's flight, ported

def place(point, galaxy, level):
    if isinstance(point, list):
        raise SystemExit("a world point cannot be placed without the take: narrow --from/--to")
    if point["galaxy"] != galaxy and "offset" in point:
        raise SystemExit(f"a point on galaxy {point['galaxy']}: narrow --from/--to")
    if point["galaxy"] != galaxy:
        raise SystemExit("an aim on the other galaxy: narrow --from/--to")
    if not point.get("disk") and "offset" in point and not level:
        raise SystemExit("an offset in the world's axes: pass --level if the disk is level")
    return np.array(point.get("offset", [0, 0, 0]), float)


def resolved(flight, galaxy, start, end, level):
    keys, eye, aim = [], None, None
    for k in flight["keys"]:
        eye, aim = k.get("eye", eye), k.get("aim", aim)
        if "eye" not in k and "aim" not in k:
            continue
        if start <= k["at"] <= end:
            keys.append({"at": k["at"], "eye": place(eye, galaxy, level), "aim": place(aim, galaxy, level),
                         "pace": k.get("pace") == "nearness"})
    return keys


def tangent(keys, which, k):
    if k == 0 or k + 1 == len(keys):
        return np.zeros(3)
    p0, p1, p2 = (keys[i][which] for i in (k - 1, k, k + 1))
    d0, d1 = np.linalg.norm(p1 - p0), np.linalg.norm(p2 - p1)
    if d0 < 1e-9 or d1 < 1e-9:
        return np.zeros(3)
    h0, h1 = keys[k]["at"] - keys[k - 1]["at"], keys[k + 1]["at"] - keys[k]["at"]
    t0, t1 = math.sqrt(d0), math.sqrt(d1)
    along = (p1 - p0) / t0 - (p2 - p0) / (t0 + t1) + (p2 - p1) / t1
    r0, r1 = t0 / h0, t1 / h1
    velocity = along * (2 * r0 * r1 / (r0 + r1))
    most, speed = min(3 * d0 / h0, 3 * d1 / h1), np.linalg.norm(velocity)
    return velocity * most / speed if speed > most else velocity


def path(keys, which, seconds):
    ats = np.array([k["at"] for k in keys])
    i = np.clip(np.searchsorted(ats, seconds, side="right") - 1, 0, len(keys) - 2)
    h = ats[i + 1] - ats[i]
    u = np.clip((seconds - ats[i]) / h, 0, 1)[:, None]
    pts = np.array([k[which] for k in keys])
    tans = np.array([tangent(keys, which, k) for k in range(len(keys))])
    a, b, h = pts[i], pts[i + 1], h[:, None]
    return (a + (b - a) * (-2 * u**3 + 3 * u**2) + tans[i] * (u**3 - 2 * u**2 + u) * h
            + tans[i + 1] * (u**3 - u**2) * h)


def path_seconds(keys, video):
    """Video seconds to path seconds: a paced run keeps its seconds, its eye at a share of the nearness."""
    out = video.copy()
    k = 0
    while k < len(keys) - 1:
        if not keys[k]["pace"]:
            k += 1
            continue
        last = k
        while last < len(keys) - 1 and keys[last]["pace"]:
            last += 1
        a, b = keys[k]["at"], keys[last]["at"]
        s = np.linspace(a, b, 4096)
        eye = path(keys, "eye", s)
        step = np.linalg.norm(np.diff(eye, axis=0), axis=1)
        near = nearness((eye[1:] + eye[:-1]) / 2)
        t = np.concatenate([[0], np.cumsum(step / near)])
        t = a + (b - a) * t / t[-1]
        inside = (video >= a) & (video <= b)
        out[inside] = np.interp(video[inside], t, s)
        k = last
    return out


def carried_ups(forward, dt, world_z):
    """Flight.carriedUps: the world's z as the horizon, carried near the vertical, righted at pi a second."""
    def rejected(v, f):
        w = v - f * np.dot(v, f)
        n = np.linalg.norm(w)
        return w / n if n > 1e-9 else None
    ups, up = [], None
    for n, f in enumerate(forward):
        level = rejected(world_z, f)
        z = abs(np.dot(f, world_z))
        s = min(max((z - 0.95) / (0.995 - 0.95), 0), 1)
        weight = s * s * (3 - 2 * s)
        if up is None:
            up = level if level is not None else rejected(np.array([0, 1.0, 0]), f)
        else:
            up = rejected(turned(up, forward[n - 1], f), f)
            if up is None:
                up = level
            if level is not None:
                a = math.atan2(np.dot(np.cross(up, level), f), np.dot(up, level))
                most = math.pi * (1 - weight) * dt
                up = level if abs(a) <= most else about(up, f, math.copysign(most, a))
        ups.append(up)
    return np.array(ups)


def turned(v, a, b):
    axis = np.cross(a, b)
    s, c = np.linalg.norm(axis), np.dot(a, b)
    return v if s < 1e-12 else about(v, axis / s, math.atan2(s, c))


def about(v, k, a):
    return v * math.cos(a) + np.cross(k, v) * math.sin(a) + k * np.dot(k, v) * (1 - math.cos(a))


def keyed(flight, galaxy, start, end, level, world_z):
    keys = resolved(flight, galaxy, start, end, level)
    t = np.arange(keys[0]["at"], keys[-1]["at"] + 1e-9, 1 / RATE)
    s = path_seconds(keys, t)
    eye, aim = path(keys, "eye", s), path(keys, "aim", s)
    forward = unit(aim - eye)
    return {"t": t - t[0], "eye": eye, "forward": forward, "up": carried_ups(forward, 1 / RATE, world_z)}


# ---- what a ship would feel

def smooth(x, seconds):
    n = max(int(seconds * RATE) | 1, 3)
    w = np.hanning(n + 2)[1:-1]
    w /= w.sum()
    pad = np.pad(x, [(n // 2, n // 2)] + [(0, 0)] * (x.ndim - 1), mode="edge")
    return np.apply_along_axis(lambda c: np.convolve(c, w, mode="valid"), 0, pad)


def roll_rate(forward, up, dt):
    out = np.zeros(len(forward))
    for n in range(1, len(forward)):
        carried = turned(up[n - 1], forward[n - 1], forward[n])
        out[n] = math.degrees(math.atan2(np.dot(np.cross(carried, up[n]), forward[n]), np.dot(carried, up[n]))) / dt
    return out


def measures(run):
    dt = 1 / RATE
    eye, f = run["eye"], run["forward"]
    v = np.gradient(eye, dt, axis=0)
    speed = np.linalg.norm(v, axis=1)
    turn = np.concatenate([[0], angle(f[1:], f[:-1]) / dt])
    moving = speed > 0.02 * np.median(speed)
    slip = np.where(moving, angle(v, f), 0)
    swing = np.abs(np.gradient(smooth(slip, 0.25), dt))
    accel = np.abs(np.gradient(smooth(turn, 0.25), dt))
    roll = np.abs(roll_rate(f, run["up"], dt))
    seconds = len(f) * dt
    return {
        "seconds": seconds,
        "turn": turn,
        "view turn, peak (deg/s)": turn.max(),
        "view turn, 95th percentile (deg/s)": np.percentile(turn, 95),
        "seconds turning faster than 10 deg/s": (turn > 10).sum() * dt,
        "view turned in all (deg)": turn.sum() * dt,
        "turn pick-up, peak (deg/s2)": accel.max(),
        "looking over 30 deg off its course (share of time)": (slip > 30).mean(),
        "looking over 90 deg off its course (share of time)": (slip > 90).mean(),
        "seconds the view swings over 10 deg/s against its course": (swing > 10).sum() * dt,
        "roll about the line of sight, peak (deg/s)": roll.max(),
        "seconds with under a tenth of the frame lit": (lit(run, MODEL[0]) < 0.1).sum() / 2,
    }


def lit(run, points, fov=0.6, aspect=16 / 9):
    """The share of the frame that holds some of the model disk, on 32 by 18 cells, twice a second."""
    out = []
    half = math.tan(fov / 2)
    for n in range(0, len(run["t"]), RATE // 2):
        f, up = run["forward"][n], run["up"][n]
        rel = points - run["eye"][n]
        depth = rel @ f
        ok = depth > 0.02
        x, y = (rel[ok] @ np.cross(f, up)) / depth[ok] / (half * aspect), (rel[ok] @ up) / depth[ok] / half
        seen = (np.abs(x) < 1) & (np.abs(y) < 1)
        cells = np.bincount(((y[seen] + 1) * 9).astype(int) * 32 + ((x[seen] + 1) * 16).astype(int), minlength=576)
        out.append((cells >= 3).mean())
    return np.array(out)


def table(columns):
    names = [n for n in next(iter(columns.values())) if n != "turn"]
    lines = ["| | " + " | ".join(columns) + " |", "|---|" + "---|" * len(columns)]
    for n in names:
        cells = []
        for m in columns.values():
            x = m[n]
            cells.append(f"{100 * x:.0f} %" if "share" in n else f"{x:.2f}" if x < 2 else f"{x:.0f}")
        lines.append(f"| {n} | " + " | ".join(cells) + " |")
    return "\n".join(lines)


# ---- the ship

SHIP = {"turn": 8.0, "share": 0.35, "thrust": 0.5, "level": 4.0, "bank": 0.35, "wing": 34.0, "slowest": 0.1,
        "floor": 1.0}


def bspline(points, per=400):
    """Uniform cubic B-spline: position, first and second derivatives, and each sample's segment."""
    u = np.linspace(0, 1, per, endpoint=False)[:, None]
    basis = np.hstack([(1 - u) ** 3, 3 * u**3 - 6 * u**2 + 4, -3 * u**3 + 3 * u**2 + 3 * u + 1, u**3]) / 6
    d1 = np.hstack([-(1 - u) ** 2, 3 * u**2 - 4 * u, -3 * u**2 + 2 * u + 1, u**2]) / 2
    d2 = np.hstack([1 - u, 3 * u - 2, -3 * u + 1, u])
    p, t, c, seg = [], [], [], []
    for i in range(len(points) - 3):
        q = points[i:i + 4]
        p.append(basis @ q), t.append(d1 @ q), c.append(d2 @ q), seg.append(np.full(per, i))
    return np.vstack(p), np.vstack(t), np.vstack(c), np.concatenate(seg)


def expand(plan):
    """A pilot's manoeuvres as waypoints, in a disk's axes: dive, climb, skim, bank left or right."""
    p = np.array(plan["start"]["at"], float)
    h = unit((np.array(plan["start"]["toward"], float) - p) * [1, 1, 0])
    route = [{"at": p.tolist()}]

    def add(point, m):
        route.append({"at": [round(float(x), 2) for x in point], "tempo": m.get("tempo", 1.0),
                      "look": m.get("look"), "most": m.get("most", 35.0)})

    for m in plan["manoeuvres"]:
        if "dive" in m or "climb" in m:
            p = p + h * m["over"]
            p[2] = m.get("dive", m.get("climb"))
            add(p, m)
        elif "skim" in m:
            parts = max(int(m["skim"] // 12), 1)
            for _ in range(parts):
                p = p + h * m["skim"] / parts
                p[2] = m.get("height", p[2])
                add(p, m)
        else:
            side = 1.0 if m["bank"] == "left" else -1.0
            left = np.array([-h[1], h[0], 0.0])
            centre, spoke = p + side * left * m["radius"], -side * left
            steps = max(math.ceil(m["turn"] / 40), 1)
            low, high = p[2], m.get("height", p[2])
            for n in range(1, steps + 1):
                a = side * math.radians(m["turn"]) * n / steps
                out = np.array([spoke[0] * math.cos(a) - spoke[1] * math.sin(a),
                                spoke[0] * math.sin(a) + spoke[1] * math.cos(a), 0.0])
                p = centre + out * m["radius"] * (1.0 if n == steps else 1.1)
                p[2] = low + (high - low) * n / steps
                add(p, m)
            h = np.array([h[0] * math.cos(a) - h[1] * math.sin(a), h[0] * math.sin(a) + h[1] * math.cos(a), 0.0])
    route[0].update({k: route[1][k] for k in ("tempo", "look", "most")})
    return route


def control(route):
    """The control polygon: a plain waypoint is passed near, an exact one through, on its heading."""
    points, owner = [], []
    for n, w in enumerate(route):
        p = np.array(w["at"], float)
        if n in (0, len(route) - 1) or "heading" in w:
            if "heading" in w:
                h = unit(np.array(w["heading"], float)) * w.get("lead", 0.3 * np.linalg.norm(p))
            else:
                other = np.array(route[1 if n == 0 else -2]["at"], float)
                h = (other - p) * (1 if n == 0 else -1)
            trio = [p - h, p, p + h]
            if n == 0:
                trio = trio if "heading" in w else [2 * p - other, p]
            if n == len(route) - 1:
                trio = trio if "heading" in w else [p, 2 * p - other]
            points += trio
            owner += [n] * len(trio)
        else:
            points.append(p), owner.append(n)
    return np.array(points), owner


def head(ahead, eye, looks, ship):
    """The gaze as a head: it turns to a place, or back ahead, at a bounded rate it picks up and lets go."""
    most, pick = math.radians(ship["head"]), math.radians(ship.get("pick", 1.2 * ship["head"]))
    out, gaze, spin = [], None, np.zeros(3)
    for n in range(len(ahead)):
        target, limit = looks[n]
        want = ahead[n]
        if target is not None:
            to = unit(target - eye[n])
            off = math.degrees(math.acos(np.clip(np.dot(to, ahead[n]), -1, 1)))
            want = to if off <= limit else about(ahead[n], unit(np.cross(ahead[n], to)), math.radians(limit))
        if gaze is None:
            gaze = want
        axis = np.cross(gaze, want)
        sine = np.linalg.norm(axis)
        off = math.atan2(sine, np.dot(gaze, want))
        rate = min(most, 0.8 * math.sqrt(2 * pick * off), off / 0.6)
        change = (axis / sine * rate if sine > 1e-9 else np.zeros(3)) - spin
        size = np.linalg.norm(change)
        spin = spin + (change * min(1, pick / RATE / size) if size > 0 else 0)
        gaze = unit(gaze + np.cross(spin, gaze) / RATE)
        out.append(gaze)
    return np.array(out)


def fly(plan):
    ship = dict(SHIP, **plan.get("ship", {}))
    route = plan["route"] if "route" in plan else expand(plan)
    points, owner = control(route)
    p, d1, d2, seg = bspline(points)
    keep = slice(0, None)
    if "heading" in route[0]:
        keep = slice(400, None)
    p, d1, d2, seg = p[keep], d1[keep], d2[keep], seg[keep]
    if "heading" in route[-1]:
        p, d1, d2, seg = p[:-400], d1[:-400], d2[:-400], seg[:-400]
    step = np.linalg.norm(np.diff(p, axis=0), axis=1)
    s = np.concatenate([[0], np.cumsum(step)])
    grid = np.linspace(0, s[-1], 40000)
    pos = np.column_stack([np.interp(grid, s, p[:, i]) for i in range(3)])
    tan = unit(np.column_stack([np.interp(grid, s, d1[:, i]) for i in range(3)]))
    kappa = np.interp(grid, s, np.linalg.norm(np.cross(d1, d2), axis=1) / np.linalg.norm(d1, axis=1) ** 3)
    leg = np.interp(grid, s, seg + 1.5).astype(int).clip(0, len(owner) - 1)
    way = np.array(owner)[leg]
    tempo = np.array([w.get("tempo", 1.0) for w in route])[way]
    ds = grid[1] - grid[0]
    looks, look, most = {}, None, 0.0
    for n, w in enumerate(route):
        if "look" in w:
            look, most = (None, 0.0) if w["look"] is None else (np.array(w["look"], float), w.get("most", 25.0))
        looks[n] = (look, most)

    def profile(scale, turn):
        want = np.minimum(scale * ship["share"] * np.maximum(nearness(pos), ship["floor"]) * tempo,
                          ship.get("fastest", np.inf))
        v = np.minimum(want, turn / np.maximum(kappa, 1e-9))
        short = v < ship["slowest"] * want
        for n in range(1, len(v)):
            v[n] = min(v[n], v[n - 1] + ship["thrust"] * ds)
        for n in range(len(v) - 2, -1, -1):
            v[n] = min(v[n], v[n + 1] + ship["thrust"] * ds)
        return v, np.concatenate([[0], np.cumsum(ds / ((v[1:] + v[:-1]) / 2))]), short

    def timed(turn):
        scale = 1.0
        if "seconds" in plan:
            low, high = 0.02, 50.0
            for _ in range(50):
                scale = math.sqrt(low * high)
                low, high = (scale, high) if profile(scale, turn)[1][-1] > plan["seconds"] else (low, scale)
        v, clock, short = profile(scale, turn)
        t = np.arange(0, clock[-1], 1 / RATE)
        at = np.interp(t, clock, grid)
        eye = np.column_stack([np.interp(at, grid, pos[:, i]) for i in range(3)])
        ahead = unit(np.column_stack([np.interp(at, grid, tan[:, i]) for i in range(3)]))
        index = np.clip(np.searchsorted(grid, at), 0, len(grid) - 1)
        # the gaze: ahead, leaning towards a place by a bounded angle, the lean smoothed
        lean = np.zeros_like(ahead)
        for n in range(len(t)):
            target, limit = looks[way[index[n]]]
            if target is None:
                continue
            to = unit(target - eye[n])
            off = math.degrees(math.acos(np.clip(np.dot(to, ahead[n]), -1, 1)))
            lean[n] = (to if off <= limit else about(ahead[n], unit(np.cross(ahead[n], to)), math.radians(limit))) - ahead[n]
        lean = smooth(lean, plan.get("gaze", 8.0))
        return scale, clock, short, t, at, eye, ahead, lean, index

    full = math.radians(ship["turn"])
    turn = np.full(len(grid), full)
    if "head" in ship:
        scale, clock, short, t, at, eye, ahead, lean, index = timed(turn)
        forward = head(ahead, eye, [looks[way[i]] for i in index], ship)
    else:
        # the turn a ship allows is shared between its course and its gaze
        for _ in range(3):
            scale, clock, short, t, at, eye, ahead, lean, index = timed(turn)
            leaning = np.linalg.norm(np.gradient(lean, 1 / RATE, axis=0), axis=1)
            turn = np.maximum(full - np.interp(grid, at, smooth(leaning, 1.0)), 0.25 * full)
        forward = unit(ahead + lean)

    # up: carried, levelled slowly on the disk's spin, banked into the turn
    z = np.array([0, 0, 1.0])
    ups, up = [], None
    for n, f in enumerate(forward):
        w = z - f * np.dot(z, f)
        level = w / np.linalg.norm(w) if np.linalg.norm(w) > 0.3 else None
        if up is None:
            up = level if level is not None else unit(np.cross(np.cross(f, [0, 1.0, 0]), f))
        else:
            up = unit(turned(up, forward[n - 1], f))
            up = unit(up - f * np.dot(up, f))
            if level is not None:
                a = math.atan2(np.dot(np.cross(up, level), f), np.dot(up, level))
                most = math.radians(ship["level"]) / RATE * min(1, (np.linalg.norm(w) - 0.3) / 0.3)
                up = about(up, f, math.copysign(min(abs(a) / (2 * RATE), most), a))
        ups.append(up)
    ups = np.array(ups)
    yaw = np.einsum("ij,ij->i", np.cross(ahead, np.gradient(ahead, 1 / RATE, axis=0)), ups)
    wing = math.radians(ship["wing"])
    bank = smooth(np.clip(ship["bank"] * yaw, -wing, wing), ship.get("roll", 2.0))
    ups = np.array([about(u, f, -b) for u, f, b in zip(ups, forward, bank)])

    crawl = short[index]
    report = {"seconds": round(float(clock[-1]), 2), "kiloparsecs": round(float(grid[-1]), 1),
              "tempo": round(scale, 3),
              "seconds a turn holds it under a tenth of its pace": round(float(crawl.sum() / RATE), 2)}
    return {"t": t, "eye": eye, "forward": forward, "up": ups}, report


def as_flight(run, galaxy, myr, every=0.5):
    """The ship's flight as today's keys: an eye and an aim on the galaxy's disk, every half second."""
    keys = []
    last = run["t"][-1]
    for at in list(np.arange(0, last, every)) + [last]:
        n = min(int(round(at * RATE)), len(run["t"]) - 1)
        eye = run["eye"][n]
        aim = eye + run["forward"][n] * max(np.linalg.norm(eye), 5.0)
        key = {"at": round(float(at), 3),
               "eye": {"galaxy": galaxy, "offset": [round(float(x), 4) for x in eye], "disk": True},
               "aim": {"galaxy": galaxy, "offset": [round(float(x), 4) for x in aim], "disk": True}}
        keys.append(key)
    keys[0]["myr"] = keys[-1]["myr"] = myr
    keys[0]["fov"] = 0.6
    return {"version": 1, "keys": keys}


# ---- the animatic: a model disk drawn as dots, the two flights side by side

def model_disk(count=140000, seed=7):
    rng = np.random.default_rng(seed)
    r = np.minimum(rng.exponential(5.0, count), DISK_RADIUS * rng.uniform(0.9, 1.0, count))
    arm = rng.integers(0, 2, count) * math.pi
    theta = np.where(rng.uniform(size=count) < 0.7, arm + np.log(np.maximum(r, 0.5) / 2.0) / math.tan(0.5)
                     + rng.normal(0, 0.22, count), rng.uniform(0, 2 * math.pi, count))
    disk = np.column_stack([r * np.cos(theta), r * np.sin(theta), rng.normal(0, 0.18, count)])
    bulge = rng.normal(0, 0.7, (count // 8, 3)) * [1, 1, 0.7]
    return np.vstack([disk, bulge]), np.concatenate([np.full(count, 1.0), np.full(count // 8, 1.6)])


MODEL = model_disk()


def frame(points, light, eye, forward, up, width, height, fov=0.6):
    right = np.cross(forward, up)
    rel = points - eye
    depth = rel @ forward
    ok = depth > 0.02
    scale = height / 2 / math.tan(fov / 2)
    x = (width / 2 + scale * (rel[ok] @ right) / depth[ok]).astype(int)
    y = (height / 2 - scale * (rel[ok] @ up) / depth[ok]).astype(int)
    inside = (x >= 0) & (x < width) & (y >= 0) & (y < height)
    gain = np.minimum(1.0 / depth[ok][inside] ** 2, 4.0) * light[ok][inside]
    image = np.bincount(y[inside] * width + x[inside], weights=gain, minlength=width * height)
    image = image.reshape(height, width)
    soft = image + 0.5 * (np.roll(image, 1, 0) + np.roll(image, -1, 0) + np.roll(image, 1, 1) + np.roll(image, -1, 1))
    white = max(np.percentile(soft, 99.7), 1e-4)
    return np.clip(np.log1p(30 * soft / white) / math.log(31), 0, 1)


def animatic(keyed_run, ship_run, out, labels):
    from PIL import Image, ImageDraw, ImageFont
    points, light = MODEL
    w, h, strip = 960, 540, 200
    font = ImageFont.load_default(22)
    small = ImageFont.load_default(16)
    runs = [keyed_run, ship_run]
    turns = [measures(r)["turn"] for r in runs]
    longest = max(len(r["t"]) for r in runs)
    most = 60.0

    def plot(n):
        img = Image.new("RGB", (w, strip), (10, 10, 14))
        d = ImageDraw.Draw(img)
        yy = lambda rate: strip - 24 - (strip - 50) * min(rate, most) / most
        for rate in (8, 30, 60):
            d.line([(0, yy(rate)), (w, yy(rate))], fill=(70, 70, 80))
            d.text((4, yy(rate) - 18), f"{rate} deg/s", fill=(130, 130, 140), font=small)
        xs = np.arange(len(turns[n])) * (w - 1) / (longest - 1)
        d.line(list(zip(xs.tolist(), [yy(x) for x in smooth(turns[n], 0.2)])), fill=(255, 200, 90), width=2)
        d.text((w - 330, 4), "how fast the view turns", fill=(200, 200, 210), font=small)
        return img

    plots = [plot(0), plot(1)]
    encoder = subprocess.Popen(
        ["ffmpeg", "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{2 * w}x{h + strip}",
         "-r", "30", "-i", "-", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "20", out], stdin=subprocess.PIPE)
    for n in range(0, longest, RATE // 30):
        canvas = Image.new("RGB", (2 * w, h + strip))
        for side, run in enumerate(runs):
            k = min(n, len(run["t"]) - 1)
            grey = frame(points, light, run["eye"][k], run["forward"][k], run["up"][k], w, h)
            rgb = np.stack([grey * 255, grey * 235, grey * 215], axis=-1).astype(np.uint8)
            canvas.paste(Image.fromarray(rgb), (side * w, 0))
            panel = plots[side].copy()
            x = k * (w - 1) / (longest - 1)
            ImageDraw.Draw(panel).line([(x, 0), (x, strip)], fill=(255, 255, 255))
            canvas.paste(panel, (side * w, h))
            d = ImageDraw.Draw(canvas)
            d.text((side * w + 16, 12), labels[side], fill=(255, 255, 255), font=font)
            d.text((side * w + 16, 42), f"{run['t'][k]:.1f} s" + ("  (ended)" if n >= len(run["t"]) else ""),
                   fill=(200, 200, 210), font=small)
        ImageDraw.Draw(canvas).line([(w, 0), (w, h + strip)], fill=(60, 60, 70))
        encoder.stdin.write(canvas.tobytes())
    encoder.stdin.close()
    encoder.wait()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["measure", "fly", "animatic"])
    parser.add_argument("files", nargs="+")
    parser.add_argument("--galaxy", type=int, default=0)
    parser.add_argument("--from", dest="start", type=float, default=0)
    parser.add_argument("--to", dest="end", type=float, default=1e9)
    parser.add_argument("--level", action="store_true", help="the disk's axes stand for the world's")
    parser.add_argument("--tilt", type=float, default=0, help="the world's z from the disk's spin, radians")
    parser.add_argument("--out")
    parser.add_argument("--myr", type=float, default=0)
    args = parser.parse_args()
    world_z = np.array([0, math.sin(args.tilt), math.cos(args.tilt)])
    if args.command == "measure":
        run = keyed(json.load(open(args.files[0])), args.galaxy, args.start, args.end, args.level, world_z)
        print(table({"keys": measures(run)}))
    elif args.command == "fly":
        run, report = fly(json.load(open(args.files[0])))
        print(json.dumps(report))
        print(table({"ship": measures(run)}))
        if args.out:
            flight = as_flight(run, args.galaxy, args.myr)
            json.dump(flight, open(args.out, "w"), indent=1)
            again = keyed(flight, args.galaxy, 0, 1e9, False, np.array([0, 0, 1.0]))
            n = min(len(again["t"]), len(run["t"]))
            print(json.dumps({"keys": len(flight["keys"]),
                              "eye off by at most (kpc)": round(float(np.linalg.norm(again["eye"][:n] - run["eye"][:n], axis=1).max()), 4),
                              "view off by at most (deg)": round(float(angle(again["forward"][:n], run["forward"][:n]).max()), 3),
                              "view turn through the keys, peak (deg/s)": round(float(measures(again)["view turn, peak (deg/s)"]), 2)}))
    else:
        runs, names = [], []
        for path in args.files[:2]:
            file = json.load(open(path))
            if "route" in file or "manoeuvres" in file:
                run, report = fly(file)
                print(json.dumps(report))
                names.append(file.get("name", "Flown by the ship"))
            else:
                run = keyed(file, args.galaxy, args.start, args.end, args.level, world_z)
                names.append("The keys, as written today")
            runs.append(run)
        print(table({names[0]: measures(runs[0]), names[1]: measures(runs[1])}))
        animatic(runs[0], runs[1], args.files[2], names)

if __name__ == "__main__":
    main()
