#!/usr/bin/env python3
"""Fidelity: does a scene picked at the exploration size still look the same at millions?

    fidelity.py run <scene> --per-galaxy N[,N...] [--dt-scale X]
        replays the scene at each size into <scene>/.fidelity/<label>/, through `hires`,
        with its curves and its density maps; the take is dropped
    fidelity.py report <scene or batch>... [--markdown FILE]
        compares every replay of each scene with the largest one at the scene's own step,
        into <scene>/.fidelity/fidelity.json, and prints a table

The dynamics are chaotic, so the question is the large scale: where the centres go, when and
how close they pass, how much ends in tails, and where the stars are at a few instants.
"""

import csv
import json
import math
import os
import shutil
import subprocess
import sys

import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.path.join(ROOT, ".build", "dev", "sillage-render")
# Instants with density maps. Their grid is the same for every replay of a scene, so maps
# compare cell by cell: its half side is this many times the widest the preview's stars spread.
DENSITY_FRAMES = 8
DENSITY_REACH = 1.5
# Cells summed into one before comparing maps, 256 / 2 a side: coarse enough that shot noise
# at 50 000 stars a galaxy does not read as a difference.
BLOCK = 2
# Minima of the closest pair this far from the clip's ends are passages, not its edges.
EDGE = 0.03
SMOOTHING_FRAMES = 5


def scene_galaxies(scene):
    with open(os.path.join(scene, "scene.json")) as handle:
        return len(json.load(handle)["galaxies"])


def label(per_galaxy, dt_scale):
    name = f"{per_galaxy // 1000}k"
    return name + (f"-dt{dt_scale:g}" if dt_scale is not None else "")


def run(scene, sizes, dt_scale):
    galaxies = scene_galaxies(scene)
    extent = DENSITY_REACH * float(np.max(curves(os.path.join(scene, "curves.csv"))["extent_kpc"]))
    for per_galaxy in sizes:
        folder = os.path.join(scene, ".fidelity", label(per_galaxy, dt_scale))
        if os.path.exists(os.path.join(folder, "hires.json")):
            print(f"fidelity   {folder}: done already")
            continue
        os.makedirs(folder, exist_ok=True)
        for name in ("scene.json", "look.json", "clip.json"):
            if os.path.exists(os.path.join(scene, name)):
                shutil.copy(os.path.join(scene, name), folder)
        command = [BIN, "hires", folder, "--particles", str(per_galaxy * galaxies),
                   "--density", os.path.join(folder, "density.npy"),
                   "--density-frames", str(DENSITY_FRAMES),
                   "--density-extent", f"{extent:.3f}"]
        if dt_scale is not None:
            command += ["--dt-scale", str(dt_scale)]
        print("fidelity   " + " ".join(command), flush=True)
        with open(os.path.join(folder, "run.log"), "w") as log:
            subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
        # Only the curves and the maps are compared; a take at millions is gigabytes.
        for name in ("take.sillage", "hires.mov"):
            if os.path.exists(os.path.join(folder, name)):
                os.remove(os.path.join(folder, name))


def curves(path):
    with open(path, newline="") as handle:
        rows = list(csv.DictReader(handle))
    columns = {key: np.array([float(row[key]) for row in rows]) for key in rows[0]}
    galaxies = sum(1 for key in rows[0] if key.startswith("x_"))
    columns["centres"] = np.stack(
        [np.stack([columns[f"{axis}_{i}"] for axis in "xyz"], axis=1) for i in range(galaxies)],
        axis=1) if galaxies else None
    return columns


def passages(closest, times):
    """The minima of the closest pair, smoothed a little, away from the clip's ends."""
    kernel = np.ones(SMOOTHING_FRAMES) / SMOOTHING_FRAMES
    smooth = np.convolve(np.pad(closest, SMOOTHING_FRAMES // 2, mode="edge"), kernel, "valid")
    span = max(times[-1] - times[0], 1e-9)
    found = []
    for i in range(1, len(smooth) - 1):
        at = (times[i] - times[0]) / span
        if smooth[i] < smooth[i - 1] and smooth[i] <= smooth[i + 1] and EDGE < at < 1 - EDGE:
            # The raw minimum near the smoothed one.
            low, high = max(i - SMOOTHING_FRAMES, 0), min(i + SMOOTHING_FRAMES + 1, len(closest))
            j = low + int(np.argmin(closest[low:high]))
            if not found or found[-1][0] != j:
                found.append((j, float(times[j]), float(closest[j])))
    return found


def pericentre(c):
    found = passages(c["closest_kpc"], c["time_myr"])
    if not found:
        return None
    j, time, distance = min(found, key=lambda p: p[2])
    return {"frame": j, "myr": round(time, 2), "kpc": round(distance, 3),
            "first_myr": round(found[0][1], 2), "first_kpc": round(found[0][2], 3),
            "count": len(found)}


def coarse(maps):
    count, size, _ = maps.shape
    cells = size // BLOCK
    return maps[:, :cells * BLOCK, :cells * BLOCK].reshape(count, cells, BLOCK, cells, BLOCK).sum(
        axis=(2, 4))


def compare_density(reference, other):
    a, b = coarse(reference), coarse(other)
    shared, correlation = [], []
    for x, y in zip(a, b):
        # The fraction of stars on the grid that both maps put in the same cells.
        total = max(x.sum(), y.sum(), 1e-12)
        shared.append(float(np.minimum(x, y).sum() / total))
        # On the square root, so the disks do not drown the tails.
        sx, sy = np.sqrt(x).ravel(), np.sqrt(y).ravel()
        correlation.append(float(np.corrcoef(sx, sy)[0, 1]))
    return {"shared": [round(v, 3) for v in shared], "correlation": [round(v, 3) for v in correlation]}


def compare(reference, other):
    """`other` against `reference`, both curves of the same scene over the same frames."""
    frames = min(len(reference["frame"]), len(other["frame"]))
    result = {"frames": frames,
              "time_offset_myr": round(float(np.max(np.abs(
                  reference["time_myr"][:frames] - other["time_myr"][:frames]))), 3)}
    ref_c, oth_c = reference["centres"], other["centres"]
    if ref_c is not None and oth_c is not None:
        gap = np.linalg.norm(ref_c[:frames] - oth_c[:frames], axis=2)
        # Against how far apart the centres are, so a wide flyby and a tight merger compare.
        scale = max(float(np.median(reference["closest_kpc"][:frames])), 1.0)
        result["centre_rms_kpc"] = round(float(np.sqrt(np.mean(gap ** 2))), 3)
        result["centre_max_kpc"] = round(float(gap.max()), 3)
        result["centre_final_kpc"] = round(float(gap[-1].max()), 3)
        result["centre_rms_relative"] = round(float(np.sqrt(np.mean(gap ** 2))) / scale, 4)
    p, q = pericentre(reference), pericentre(other)
    result["pericentre"] = q
    if p and q:
        result["pericentre_dt_myr"] = round(q["myr"] - p["myr"], 2)
        result["pericentre_dd_kpc"] = round(q["kpc"] - p["kpc"], 3)
        result["passages_match"] = p["count"] == q["count"]
    tidal_a, tidal_b = reference["tidal_fraction"][:frames], other["tidal_fraction"][:frames]
    result["tidal_rms"] = round(float(np.sqrt(np.mean((tidal_a - tidal_b) ** 2))), 4)
    result["tidal_final"] = round(float(tidal_b[-1]), 4)
    result["tidal_final_reference"] = round(float(tidal_a[-1]), 4)
    return result


def particles(folder):
    with open(os.path.join(folder, "hires.json")) as handle:
        return json.load(handle)


def report_scene(scene):
    root = os.path.join(scene, ".fidelity")
    if not os.path.isdir(root):
        return None
    runs = {}
    for name in sorted(os.listdir(root)):
        folder = os.path.join(root, name)
        if os.path.exists(os.path.join(folder, "hires.json")):
            runs[name] = {"record": particles(folder),
                          "curves": curves(os.path.join(folder, "curves-hires.csv")),
                          "density": np.load(os.path.join(folder, "density.npy"))
                          if os.path.exists(os.path.join(folder, "density.npy")) else None}
    if not runs:
        return None
    with open(os.path.join(scene, "scene.json")) as handle:
        default_scale = json.load(handle).get("timeStepScale")
    plain = [n for n in runs if abs(runs[n]["record"]["timeStepScale"] - default_scale) < 1e-6]
    reference = max(plain or runs, key=lambda n: runs[n]["record"]["particles"])
    ref = runs[reference]
    result = {"scene": os.path.basename(os.path.normpath(scene)),
              "galaxies": scene_galaxies(scene), "reference": reference,
              "reference_particles": ref["record"]["particles"],
              "reference_pericentre": pericentre(ref["curves"]), "runs": {}}
    # The preview itself, explored once, against the replay at its own size: how much two
    # runs that should be the same drift apart, the floor every other difference sits on.
    explored = os.path.join(scene, "curves.csv")
    compared = {name: run for name, run in runs.items() if name != reference}
    for name, run in compared.items():
        entry = compare(ref["curves"], run["curves"])
        entry["particles"] = run["record"]["particles"]
        entry["dt_scale"] = run["record"]["timeStepScale"]
        if ref["density"] is not None and run["density"] is not None:
            entry["density"] = compare_density(ref["density"], run["density"])
        result["runs"][name] = entry
    if os.path.exists(explored):
        same = [n for n, r in runs.items() if r["record"]["particles"]
                == r["record"]["previewParticles"] and n in plain]
        if same:
            result["rerun_floor"] = compare(runs[same[0]]["curves"], curves(explored))
            result["rerun_floor"]["against"] = same[0]
    with open(os.path.join(root, "fidelity.json"), "w") as handle:
        json.dump(result, handle, indent=2, sort_keys=True)
        handle.write("\n")
    return result


def scenes_in(path):
    if os.path.exists(os.path.join(path, "scene.json")):
        return [path]
    return [os.path.join(path, n) for n in sorted(os.listdir(path))
            if not n.startswith(".") and os.path.exists(os.path.join(path, n, "scene.json"))]


def table(results):
    lines = ["| scene | gal | reference | run | centres rms | rel | pericentre dt | dd | "
             "tails rms | density shared, first to last | correlation |",
             "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |"]
    for result in results:
        rows = sorted(result["runs"].items(), key=lambda kv: (kv[1]["dt_scale"] != 3.5,
                                                             kv[1]["particles"]))
        if "rerun_floor" in result:
            rows.append(("explored", result["rerun_floor"] | {"particles": 0, "dt_scale": 0}))
        for name, entry in rows:
            run_name = (f"{name} vs {result['rerun_floor']['against']}" if name == "explored"
                        else name)
            density = entry.get("density")
            fmt = lambda v, f="{:.2f}": "" if v is None else f.format(v)
            lines.append("| " + " | ".join([
                result["scene"], str(result["galaxies"]), result["reference"], run_name,
                fmt(entry.get("centre_rms_kpc")), fmt(entry.get("centre_rms_relative"), "{:.1%}"),
                fmt(entry.get("pericentre_dt_myr"), "{:+.1f}"),
                fmt(entry.get("pericentre_dd_kpc"), "{:+.2f}"),
                fmt(entry.get("tidal_rms"), "{:.3f}"),
                # The first instant is the same disks drawn twice: the shot noise floor.
                f"{density['shared'][0]:.2f} to {density['shared'][-1]:.2f}" if density else "",
                f"{density['correlation'][0]:.2f} to {density['correlation'][-1]:.2f}"
                if density else ""]) + " |")
    return "\n".join(lines)


def main(arguments):
    if len(arguments) >= 2 and arguments[0] == "run":
        scene, rest = arguments[1], arguments[2:]
        sizes, dt_scale = [], None
        while rest:
            if rest[0] == "--per-galaxy":
                sizes = [int(float(v)) for v in rest[1].split(",")]
            elif rest[0] == "--dt-scale":
                dt_scale = float(rest[1])
            else:
                sys.exit(__doc__)
            rest = rest[2:]
        if not sizes:
            sys.exit(__doc__)
        run(scene, sizes, dt_scale)
        return
    if len(arguments) >= 2 and arguments[0] == "report":
        markdown = None
        paths = arguments[1:]
        if "--markdown" in paths:
            index = paths.index("--markdown")
            markdown = paths[index + 1]
            paths = paths[:index] + paths[index + 2:]
        results = [r for path in paths for scene in scenes_in(path)
                   if (r := report_scene(scene))]
        text = table(results)
        print(text)
        if markdown:
            with open(markdown, "w") as handle:
                handle.write(text + "\n")
        return
    sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
