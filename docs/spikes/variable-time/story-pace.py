#!/usr/bin/env python3
"""Where a story's simulated time goes, and how long its video would play at an automatic pace.

    story-pace.py <curves.csv> [...]

Reads only the curves a run writes. Without the scene file it cannot place the reach `Story`
judges collisions with, so a pair counts as engaged below LIMIT_KPC, and as merged once its
centres stay within MERGE_KPC to the end. Research prototype for docs/notes/variable-time.md.
"""

import csv
import math
import os
import statistics
import sys

LIMIT_KPC = 45.0      # stands in for 1.5 times the two disks' reach
MERGE_KPC = 10.0
LEAD_MYR = 150.0      # Story.Settings.lead
# Story's thresholds over its 150 Myr window: tails share, extent relative, disruption.
TAILS, EXTENT, DISRUPTION = 0.02, 0.15, 0.05
HALF_MYR = 75.0       # each side of a frame, so the window is Story's 150 Myr
PACE = 4.0            # an activity of PACE thresholds plays at 1x, a quarter of it at 4x
TOP = 8.0
DOUBLING_SECONDS = 3.0  # the speed doubles or halves over at least this much video
FPS = 30
BURST = 2.0           # star formation this many times its level before the story plays at 1x


def load(path):
    rows = list(csv.DictReader(open(path)))
    galaxies = 0
    while f"x_{galaxies}" in rows[0]:
        galaxies += 1
    t = [float(r["time_myr"]) for r in rows]
    centres = [[tuple(float(r[f"{a}_{i}"]) for a in "xyz") for i in range(galaxies)] for r in rows]
    return t, centres, galaxies, rows


def pair(t, d):
    """Passes below LIMIT_KPC, whether the pair ends merged, and when its engagement ends."""
    merged = None
    for k in range(len(d) - 1, -1, -1):
        if d[k] >= MERGE_KPC:
            break
        merged = k
    if merged is not None and t[-1] - t[merged] < 50:
        merged = None
    passes, low = [], None
    for k in range(1, len(d)):
        if merged is not None and k >= merged:
            break
        if low is None:
            if d[k] < d[k - 1]:
                low = k
            continue
        if d[k] < d[low]:
            low = k
        elif d[k] > max(d[low] * 1.5, d[low] + 5.0):
            if d[low] < LIMIT_KPC:
                passes.append(low)
            low = None
    if merged is not None:
        return passes, t[merged]
    if not passes:
        return passes, None
    k = passes[-1]
    while k < len(d) and d[k] < LIMIT_KPC:
        k += 1
    return passes, t[min(k, len(d) - 1)]


def change(t, v, k):
    lo = hi = k
    while lo > 0 and t[k] - t[lo - 1] <= HALF_MYR:
        lo -= 1
    while hi < len(t) - 1 and t[hi + 1] - t[k] <= HALF_MYR:
        hi += 1
    part = v[lo:hi + 1]
    return max(part) - min(part)


def ramped(speeds):
    """No faster change than a doubling per DOUBLING_SECONDS of video, forwards then back."""
    def sweep(values):
        out = [values[0]]
        for s in values[1:]:
            factor = 2 ** ((1 / out[-1]) / (DOUBLING_SECONDS * FPS))
            out.append(min(max(s, out[-1] / factor), out[-1] * factor))
        return out
    return sweep(sweep(speeds)[::-1])[::-1]


def story(path):
    t, centres, galaxies, rows = load(path)
    first = engaged = None
    for i in range(galaxies):
        for j in range(i + 1, galaxies):
            passes, end = pair(t, [math.dist(c[i], c[j]) for c in centres])
            if passes:
                first = t[passes[0]] if first is None else min(first, t[passes[0]])
            if end is not None:
                engaged = end if engaged is None else max(engaged, end)
    if first is None:
        return None
    start = max(t[0], first - LEAD_MYR)
    k0 = next(k for k in range(len(t)) if t[k] >= start)
    tails = [float(r["tidal_fraction"]) for r in rows]
    extent = [float(r["extent_kpc"]) for r in rows]
    formed = [float(r["formed"]) for r in rows]
    disruption = [[float(r.get(f"disruption_{i}") or 0) for r in rows] for i in range(galaxies)]
    step = [t[k] - t[k - 1] if k else t[1] - t[0] for k in range(len(t))]
    rate = [formed[k] / step[k] for k in range(len(t))]
    quiet_rate = statistics.median(rate[:max(k0, 20)]) or 1.0
    speeds = []
    for k in range(k0, len(t)):
        activity = max(
            change(t, tails, k) / TAILS,
            change(t, extent, k) / max(extent[k], 1e-6) / EXTENT,
            max(change(t, d, k) for d in disruption) / DISRUPTION)
        lo = hi = k
        while lo > 0 and t[k] - t[lo - 1] <= 25:
            lo -= 1
        while hi < len(t) - 1 and t[hi + 1] - t[k] <= 25:
            hi += 1
        if statistics.mean(rate[lo:hi + 1]) / quiet_rate > BURST or t[k] <= engaged:
            activity = max(activity, PACE)
        speeds.append(min(max(PACE / max(activity, 1e-6), 1.0), TOP))
    speeds = ramped(speeds)
    return dict(
        start=start, first=first, engaged=engaged, end=t[-1],
        plain=(len(t) - k0) / FPS, paced=sum(1 / s for s in speeds) / FPS,
        fast=sum(1 for s in speeds if s >= 4) / len(speeds), top=max(speeds))


def main(paths):
    found = []
    for path in paths:
        name = path.split(os.sep)[-2]
        result = story(path)
        if result is None:
            print(f"{name:12s} no collision")
            continue
        found.append(result)
        r = result
        print(
            f"{name:12s} story {r['start']:5.0f} to {r['end']:5.0f} Myr, first pass {r['first']:5.0f},"
            f" engaged to {r['engaged']:5.0f} | before {r['start'] / r['end']:4.0%}"
            f" engaged {(r['engaged'] - r['start']) / r['end']:4.0%}"
            f" after {(r['end'] - r['engaged']) / r['end']:4.0%}"
            f" | video {r['plain']:5.1f} s at 1x, {r['paced']:5.1f} s paced ({r['paced'] / r['plain']:4.0%}),"
            f" top {r['top']:.1f}x, {r['fast']:4.0%} of its frames at 4x or more")
    total = sum(r["end"] for r in found)
    told = sum(r["end"] - r["start"] for r in found)
    print(
        f"\n{len(found)} stories, {total:.0f} Myr simulated: before the story"
        f" {sum(r['start'] for r in found) / total:.0%},"
        f" engaged {sum(r['engaged'] - r['start'] for r in found) / total:.0%},"
        f" after {sum(r['end'] - r['engaged'] for r in found) / total:.0%};"
        f" of the story's own frames engaged {sum(r['engaged'] - r['start'] for r in found) / told:.0%}")
    ratios = [r["paced"] / r["plain"] for r in found]
    print(f"paced video against 1x: mean {statistics.mean(ratios):.0%}, from {min(ratios):.0%} to {max(ratios):.0%}")


if __name__ == "__main__":
    main(sys.argv[1:])
