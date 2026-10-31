#!/usr/bin/env python3
"""Reads calm-disk probe runs (#169) side by side.

    probe-report.py table <run dir>...        one line per run from its probe.json
    probe-report.py compare <a dir> <b dir>   two runs frame by frame, against the tolerances below
    probe-report.py curve <run dir>... --column a2_mid [--every 50]
                                               a column of probe.csv sampled along the run

A run dir holds probe.csv and probe.json as `sillage-render probe-disk` writes them. The
tolerances are the chaotic spread two runs of one disk show (docs/notes/calm-disk-probe.md).
"""

import csv
import json
import math
import os
import sys

TOLERANCES = {
    "r50_kpc": ("relative", 0.01),
    "r90_kpc": ("relative", 0.02),
    "sigma_r_vc_mid": ("absolute", 0.02),
    "a2_mid": ("absolute", 0.03),
    "a1_mid": ("absolute", 0.03),
    "lump_stars": ("absolute", 0.03),
    "coh_pattern": ("absolute", 0.1),
    "coh_material": ("absolute", 0.1),
}

COLUMNS = [
    ("run", "{:<22}"), ("n", "{:>8}"), ("exc%", "{:>5}"), ("breath%", "{:>7}"), ("settle", "{:>6}"),
    ("s/vc0", "{:>6}"), ("s/vc300", "{:>7}"), ("s/vcE", "{:>6}"), ("a2max", "{:>6}"), ("@", "{:>4}"),
    ("a2late", "{:>6}"), ("a1late", "{:>6}"), ("lump0", "{:>6}"), ("lumpL", "{:>6}"), ("polar", "{:>6}"),
    ("cohP", "{:>5}"), ("cohM", "{:>5}"), ("cohS", "{:>5}"), ("w_p/w", "{:>6}"), ("spread", "{:>6}"),
    ("tilt", "{:>5}"), ("jit", "{:>5}"), ("sjit", "{:>5}"), ("off", "{:>5}"), ("outer", "{:>5}"),
    ("knots300", "{:>8}"), ("knots/100", "{:>9}"), ("ms/st", "{:>6}"), ("min", "{:>5}"),
]


def load(run):
    with open(os.path.join(run, "probe.json")) as handle:
        report = json.load(handle)
    return report


def rows(run):
    with open(os.path.join(run, "probe.csv"), newline="") as handle:
        return list(csv.DictReader(handle))


def number(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return math.nan


def fmt(value, digits=3):
    if value is None:
        return "-"
    if isinstance(value, str):
        value = number(value)
    if value is None or (isinstance(value, float) and math.isnan(value)):
        return "nan"
    return f"{value:.{digits}f}"


def table(runs):
    print(" ".join(f.format(name) for name, f in COLUMNS))
    for run in runs:
        try:
            report = load(run)
        except FileNotFoundError:
            print(f"{os.path.basename(run.rstrip('/')):<22} (no probe.json)")
            continue
        s = report["summary"]
        reference = number(s.get("referenceRate"))
        pattern = number(s.get("patternSpeedLate"))
        values = [
            os.path.basename(run.rstrip("/"))[:22], f"{report['galaxyParticles'] // 1000}k",
            fmt(100 * s["firstExcursion"], 1), fmt(100 * s.get("breathing", math.nan), 1),
            fmt(s["settledMyr"], 0), fmt(s["sigmaRatioStart"]), fmt(s["sigmaRatio300"]),
            fmt(s["sigmaRatioEnd"]), fmt(s["amplitude2Peak"]), fmt(s["amplitude2PeakMyr"], 0),
            fmt(s["amplitude2Late"]), fmt(s["amplitude1Late"]), fmt(s["lumpinessStart"]),
            fmt(s["lumpinessLate"]), fmt(s.get("polarLumpinessLate", math.nan)),
            fmt(s["coherencePatternLate"], 2), fmt(s["coherenceMaterialLate"], 2),
            fmt(s["coherenceStaticLate"], 2),
            fmt(pattern / reference if reference else math.nan, 2),
            fmt(s.get("patternSpreadLate", math.nan), 4), fmt(s["axisTiltMaxDeg"], 2),
            fmt(s["nucleusJitterKpc"]), fmt(s["solverCentreJitterKpc"]), fmt(s["centreOffsetLateKpc"], 2),
            fmt(s["outerOffsetLate"], 2), str(s.get("formedFirst300", "-")),
            fmt(s.get("formedLatePer100Myr", math.nan), 0), fmt(report["millisecondsPerStep"], 1),
            fmt(report["seconds"] / 60, 1),
        ]
        print(" ".join(f.format(v) for (_, f), v in zip(COLUMNS, values)))


def compare(a, b):
    ra, rb = rows(a), rows(b)
    frames = min(len(ra), len(rb))
    print(f"{frames} frames in common ({len(ra)} and {len(rb)})")
    worst = {}
    for column, (kind, tolerance) in TOLERANCES.items():
        gaps = []
        for i in range(frames):
            x, y = number(ra[i][column]), number(rb[i][column])
            if math.isnan(x) or math.isnan(y):
                continue
            gap = abs(x - y) / max(abs(x), 1e-9) if kind == "relative" else abs(x - y)
            gaps.append((gap, number(ra[i]["time_myr"])))
        if not gaps:
            continue
        gaps.sort(reverse=True)
        over = sum(1 for g, _ in gaps if g > tolerance)
        worst[column] = (gaps[0][0], gaps[0][1], over, len(gaps))
        unit = "%" if kind == "relative" else ""
        scale = 100 if kind == "relative" else 1
        print(
            f"{column:<16} worst {gaps[0][0] * scale:6.3f}{unit} at {gaps[0][1]:6.0f} Myr, "
            f"{over}/{len(gaps)} frames over {tolerance * scale:g}{unit}")
    return worst


def curve(runs, column, every):
    for run in runs:
        data = rows(run)
        picked = [r for r in data if int(round(number(r["time_myr"]))) % every == 0 or r is data[-1]]
        line = " ".join(f"{number(r['time_myr']):.0f}:{fmt(r[column], 3)}" for r in picked)
        print(f"{os.path.basename(run.rstrip('/'))}: {line}")


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    command, rest = argv[1], argv[2:]
    if command == "table":
        table(rest)
    elif command == "compare" and len(rest) >= 2:
        compare(rest[0], rest[1])
    elif command == "curve":
        column = rest[rest.index("--column") + 1] if "--column" in rest else "a2_mid"
        every = int(rest[rest.index("--every") + 1]) if "--every" in rest else 100
        dirs = [r for r in rest if not r.startswith("--") and r not in (column, str(every))]
        curve(dirs, column, every)
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
