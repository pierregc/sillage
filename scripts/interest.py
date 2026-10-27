#!/usr/bin/env python3
"""Interest score: which scenes of a batch to look at first, from their curves alone.

    interest.py <scene folder>       features and score into <scene>/interest.json
    interest.py <batch folder>       every scene, then score and rank columns in index.csv
    interest.py --fit <library>      weights fitted to the ratings, against the hand ones

A guide for where to start looking, never a filter: every scene keeps its place in the library.
"""

import csv
import json
import math
import os
import statistics
import sys

# The one place the hand weights live. Each feature is brought to 0..1 by `normalised`.
WEIGHTS = {
    "tidal": 0.35,
    "in_clip": 0.20,
    "closeness": 0.15,
    "burst": 0.15,
    "disruption": 0.15,
}
# A pericentre this close counts half; tails this large and a burst this strong count in full.
CLOSE_KPC = 8.0
FULL_TIDAL = 0.30
FULL_BURST = 5.0
# A minimum in the first or last few percent of the clip is the clip's edge, not a passage.
EDGE = 0.03
SMOOTHING_FRAMES = 15
MINIMUM_RATED = 12
# A story still going when explore reached its cap (#123) counts this share of its score, so
# night picks prefer the scenes they can show whole.
UNFINISHED = 0.5


def number(value, default=0.0):
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def features(curves_path):
    with open(curves_path, newline="") as handle:
        rows = list(csv.DictReader(handle))
    if not rows:
        return None
    times = [number(row["time_myr"]) for row in rows]
    # Curves from before #45 have only the first pair's separation.
    closest = [number(row.get("closest_kpc", row.get("separation_kpc"))) for row in rows]
    tidal = [number(row.get("tidal_fraction")) for row in rows]
    formed = [number(row.get("formed")) for row in rows]
    disks = [key for key in rows[0] if key.startswith("disruption_")]

    paired = [i for i, value in enumerate(closest) if value > 0]
    first = paired[0] if paired else 0
    nearest = min(paired, key=lambda i: closest[i]) if paired else None
    span = max(times[-1] - times[0], 1e-9)
    when = (times[nearest] - times[0]) / span if nearest is not None else None

    # Per frame counts are noisy enough that a single frame would pass for a burst.
    half = SMOOTHING_FRAMES // 2
    smooth = [statistics.fmean(formed[max(i - half, 0):i + half + 1]) for i in range(len(formed))]
    median = statistics.median(smooth)
    peak = max(smooth)
    burst = peak / median if median > 0 else (1.0 + peak if peak > 0 else 1.0)

    return {
        "min_separation_kpc": round(closest[nearest], 3) if nearest is not None else None,
        "min_separation_myr": round(times[nearest], 1) if nearest is not None else None,
        "min_separation_at": round(when, 3) if when is not None else None,
        # Closer than it started, and turning back before the clip ends.
        "in_clip": bool(nearest is not None and EDGE < when < 1 - EDGE
                        and closest[nearest] < closest[first]),
        "peak_tidal": round(max(tidal), 4),
        "burst_ratio": round(burst, 3),
        "final_disruption": round(max((number(rows[-1][key]) for key in disks), default=0.0), 3),
    }


def normalised(found):
    separation = found["min_separation_kpc"]
    return {
        "tidal": min(found["peak_tidal"] / FULL_TIDAL, 1.0),
        "in_clip": 1.0 if found["in_clip"] else 0.0,
        "closeness": 0.0 if separation is None else 1 / (1 + (separation / CLOSE_KPC) ** 2),
        "burst": min(max(math.log(max(found["burst_ratio"], 1.0)) / math.log(FULL_BURST), 0.0), 1.0),
        "disruption": found["final_disruption"],
    }


def score(found, weights=WEIGHTS):
    terms = normalised(found)
    return sum(weights[name] * terms[name] for name in weights)


def story_complete(folder):
    """What explore recorded in clip.json, or None for a scene explored before #123."""
    try:
        with open(os.path.join(folder, "clip.json")) as handle:
            story = json.load(handle).get("story")
    except (OSError, ValueError):
        return None
    return None if story is None else bool(story.get("complete"))


def score_scene(folder):
    curves = os.path.join(folder, "curves.csv")
    if not os.path.exists(curves):
        return None
    found = features(curves)
    if found is None:
        return None
    found["story_complete"] = story_complete(folder)
    value = score(found) * (UNFINISHED if found["story_complete"] is False else 1.0)
    result = {"version": 1, "score": round(value, 4), "features": found}
    with open(os.path.join(folder, "interest.json"), "w") as handle:
        json.dump(result, handle, indent=2, sort_keys=True)
        handle.write("\n")
    return result


def score_batch(batch):
    scores = {}
    for name in sorted(os.listdir(batch)):
        folder = os.path.join(batch, name)
        if not name.startswith(".") and os.path.isdir(folder):
            result = score_scene(folder)
            if result:
                scores[name] = result["score"]
    ranks = {name: rank for rank, name in
             enumerate(sorted(scores, key=lambda n: (-scores[n], n)), start=1)}
    index = os.path.join(batch, "index.csv")
    if os.path.exists(index):
        with open(index, newline="") as handle:
            reader = csv.DictReader(handle)
            fields = list(reader.fieldnames or [])
            rows = list(reader)
        # Before `status`, which scripts read as the last column.
        for column in ("score", "rank"):
            if column not in fields:
                fields.insert(fields.index("status") if "status" in fields else len(fields), column)
        for row in rows:
            row["score"] = scores.get(row.get("id"), "")
            row["rank"] = ranks.get(row.get("id"), "")
        temporary = index + ".tmp"
        with open(temporary, "w", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=fields, lineterminator="\n")
            writer.writeheader()
            writer.writerows(rows)
        os.replace(temporary, index)
    for name in sorted(ranks, key=ranks.get):
        print("%4d  %.3f  %s" % (ranks[name], scores[name], name))
    return scores


# Fitting: the ratings in each batch's ratings.json against the features in interest.json.

def rated(library):
    samples = []
    batches = [library] + [os.path.join(library, d) for d in sorted(os.listdir(library))]
    for batch in batches:
        path = os.path.join(batch, "ratings.json")
        if not os.path.isfile(path):
            continue
        with open(path) as handle:
            ratings = json.load(handle).get("scenes", {})
        for name, entry in sorted(ratings.items()):
            interest = os.path.join(batch, name, "interest.json")
            if entry.get("rating") is None or not os.path.exists(interest):
                continue
            with open(interest) as handle:
                found = json.load(handle)["features"]
            samples.append((normalised(found), float(entry["rating"])))
    return samples


def solve(matrix, vector):
    """Gaussian elimination with partial pivoting, small enough not to need numpy."""
    size = len(vector)
    rows = [list(matrix[i]) + [vector[i]] for i in range(size)]
    for column in range(size):
        pivot = max(range(column, size), key=lambda r: abs(rows[r][column]))
        rows[column], rows[pivot] = rows[pivot], rows[column]
        lead = rows[column][column]
        if abs(lead) < 1e-12:
            continue
        for r in range(size):
            if r != column:
                factor = rows[r][column] / lead
                rows[r] = [a - factor * b for a, b in zip(rows[r], rows[column])]
    return [rows[i][size] / rows[i][i] if abs(rows[i][i]) > 1e-12 else 0.0 for i in range(size)]


def fit(samples, names, ridge=1e-3):
    """Least squares with an intercept, a touch of ridge so a constant feature does not blow up."""
    columns = len(names) + 1
    gram = [[0.0] * columns for _ in range(columns)]
    moment = [0.0] * columns
    for terms, rating in samples:
        x = [1.0] + [terms[name] for name in names]
        for i in range(columns):
            moment[i] += x[i] * rating
            for j in range(columns):
                gram[i][j] += x[i] * x[j]
    for i in range(1, columns):
        gram[i][i] += ridge * len(samples)
    coefficients = solve(gram, moment)
    return coefficients[0], dict(zip(names, coefficients[1:]))


def ranks_of(values):
    order = sorted(range(len(values)), key=lambda i: values[i])
    ranks = [0.0] * len(values)
    i = 0
    while i < len(order):
        j = i
        while j + 1 < len(order) and values[order[j + 1]] == values[order[i]]:
            j += 1
        for k in range(i, j + 1):
            ranks[order[k]] = (i + j) / 2
        i = j + 1
    return ranks


def spearman(a, b):
    ra, rb = ranks_of(a), ranks_of(b)
    ma, mb = statistics.fmean(ra), statistics.fmean(rb)
    num = sum((x - ma) * (y - mb) for x, y in zip(ra, rb))
    den = math.sqrt(sum((x - ma) ** 2 for x in ra) * sum((y - mb) ** 2 for y in rb))
    return num / den if den > 0 else 0.0


def report_fit(library):
    samples = rated(library)
    if len(samples) < MINIMUM_RATED:
        print("%d rated scenes with an interest.json; %d needed to fit" % (len(samples), MINIMUM_RATED))
        return 1
    names = list(WEIGHTS)
    ratings = [rating for _, rating in samples]
    hand = [sum(WEIGHTS[n] * terms[n] for n in names) for terms, _ in samples]
    # Each scene predicted by weights fitted without it, so the fit is not judged on what it saw.
    held_out = []
    for i in range(len(samples)):
        intercept, weights = fit(samples[:i] + samples[i + 1:], names)
        held_out.append(intercept + sum(weights[n] * samples[i][0][n] for n in names))
    hand_rho, fitted_rho = spearman(hand, ratings), spearman(held_out, ratings)
    _, weights = fit(samples, names)
    print("%d rated scenes" % len(samples))
    print("rank correlation with the ratings: hand %.3f, fitted %.3f (leave one out)"
          % (hand_rho, fitted_rho))
    # Only the ordering matters, so the fitted weights are scaled to sum to one like the hand ones.
    total = sum(abs(w) for w in weights.values()) or 1.0
    scaled = {n: round(w / total, 3) for n, w in weights.items()}
    print("fitted weights: " + json.dumps(scaled))
    if fitted_rho > hand_rho:
        print("the fitted weights predict better: replace WEIGHTS in scripts/interest.py with them")
    else:
        print("the hand weights predict as well or better: keep them")
    return 0


def main(argv):
    if len(argv) == 3 and argv[1] == "--fit":
        return report_fit(argv[2])
    if len(argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    target = argv[1]
    if os.path.exists(os.path.join(target, "curves.csv")):
        result = score_scene(target)
        if not result:
            print("%s: empty curves" % target, file=sys.stderr)
            return 1
        print("%.3f  %s" % (result["score"], json.dumps(result["features"], sort_keys=True)))
        return 0
    score_batch(target)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
