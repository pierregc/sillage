#!/usr/bin/env python3
"""Two runs of one scene side by side, for choosing a time step (#225).

    step-compare.py hires REFERENCE RUN [RUN...] [--markdown FILE]
        hires runs of the same scene, each a folder with curves-hires.csv, hires.json, the
        density maps of `--density FOLDER/density.npy` and the run's output in run.log
    step-compare.py explore BATCH BATCH [--markdown FILE]
        two explore batches of the same seed: whether interest.py ranks the same scenes on top
    step-compare.py frames REFERENCE.png OTHER.png [OTHER.png...]
        how far apart stills of the same frame are, blurred a little and at full size
    step-compare.py sheet OUT.jpg DIR [DIR...] [--width W] [--crop W]
        the stills of each folder in a column, the same file names in each, and a sheet of
        1:1 crops of their middle beside it

Two runs that differ by a tiny perturbation set the floor: the encounter's own chaotic
divergence, which any other difference has to be read against.
"""

import csv
import json
import math
import os
import re
import sys

import numpy as np

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fidelity import curves, passages  # noqa: E402

PAIR_FLOOR_KPC = 5.0
MERGED_KPC = 2.0
HALF = 0.5
BURST_SMOOTHING = 15


def load_run(folder):
    path = os.path.abspath(folder)
    run = {"name": os.path.join(os.path.basename(os.path.dirname(path)), os.path.basename(path)),
           "folder": folder}
    with open(os.path.join(folder, "hires.json")) as handle:
        run["record"] = json.load(handle)
    run["curves"] = curves(os.path.join(folder, "curves-hires.csv"))
    run["maps"] = {}
    for name, suffix in (("drawn", ""), ("tracers", ".tracers"), ("massive", ".massive")):
        path = os.path.join(folder, f"density{suffix}.npy")
        if os.path.exists(path):
            run["maps"][name] = np.load(path).astype(np.float64)
    run["counts"], run["drift"], run["step_ms"] = {}, [], []
    log = os.path.join(folder, "run.log")
    if os.path.exists(log):
        text = open(log).read()
        found = re.search(r"tracers\s+(\d+) light, (\d+) massive visible", text)
        if found:
            light, heavy = int(found.group(1)), int(found.group(2))
            run["counts"] = {"tracers": light, "massive": heavy, "drawn": light + heavy}
        for line in re.findall(r"^drift .*$", text, re.M):
            numbers = [float(v) for v in re.findall(r"-?\d+\.?\d*", line)]
            heights = re.findall(r"([\d.]+)/([\d.]+)", line)
            run["drift"].append({
                "frame": int(numbers[0]), "myr": numbers[1],
                "tails_light": numbers[2], "tails_massive": numbers[3],
                "extent_light": numbers[4], "extent_massive": numbers[5],
                "height_light": [float(a) for a, _ in heights],
                "height_massive": [float(b) for _, b in heights]})
        run["step_ms"] = [float(v) for v in re.findall(r"\(([\d.]+) ms/step\)", text)]
    return run


def specific_momentum(c):
    """|r x dr/dt| of the first pair's relative orbit, kpc^2 per Myr."""
    centres = c["centres"]
    if centres is None or centres.shape[1] < 2:
        return None
    r = centres[:, 1] - centres[:, 0]
    v = np.gradient(r, c["time_myr"], axis=0)
    return np.linalg.norm(np.cross(r, v), axis=1)


def crossing(values, times, level):
    above = np.nonzero(values >= level)[0]
    return float(times[above[0]]) if len(above) else None


def merged_at(c):
    closest = c["closest_kpc"]
    below = closest < MERGED_KPC
    for i in range(len(below)):
        if below[i:].all():
            return float(c["time_myr"][i])
    return None


def burst_peak(c):
    formed = c["formed"]
    kernel = np.ones(BURST_SMOOTHING) / BURST_SMOOTHING
    smooth = np.convolve(np.pad(formed, BURST_SMOOTHING // 2, mode="edge"), kernel, "valid")
    i = int(np.argmax(smooth))
    return float(c["time_myr"][i]), float(smooth[i])


def chi2(a, b, floor=20):
    """Chi-square a cell of two count maps against the Poisson noise of two samples alike."""
    total = a + b
    keep = total >= floor
    terms = (a - b) ** 2 / np.maximum(total, 1e-12)
    return float(terms[keep].sum() / max(keep.sum(), 1)), int(keep.sum())


def binned(m, factor=4):
    size = m.shape[0] // factor
    return m[: size * factor, : size * factor].reshape(size, factor, size, factor).sum(axis=(1, 3))


def elsewhere(a, b):
    """Half the summed absolute difference of two count maps, and what Poisson noise alone moves."""
    na, nb = max(a.sum(), 1e-12), max(b.sum(), 1e-12)
    shift = 0.5 * np.abs(a / na - b / nb).sum()
    mean = 0.5 * (a / na + b / nb)
    sigma = np.sqrt(mean / na + mean / nb)
    return float(shift), float(0.5 * math.sqrt(2 / math.pi) * sigma.sum())


def compare_maps(reference, other, name):
    count = reference["counts"].get(name) or reference["record"].get("particles")
    a_maps, b_maps = reference["maps"].get(name), other["maps"].get(name)
    if a_maps is None or b_maps is None or not count:
        return None
    times = [d["myr"] for d in reference["drift"]]
    rows = []
    for index in range(min(len(a_maps), len(b_maps))):
        a, b = a_maps[index] * count, b_maps[index] * count
        c1, _ = chi2(a, b)
        c4, _ = chi2(binned(a), binned(b))
        shift, noise = elsewhere(binned(a), binned(b))
        rows.append({"instant": index, "myr": times[index] if index < len(times) else None,
                     "chi2": round(c1, 3), "chi2_4x4": round(c4, 3),
                     "elsewhere": round(shift, 5), "noise": round(noise, 5)})
    return rows


def compare_curves(a, b):
    ca, cb = a["curves"], b["curves"]
    frames = min(len(ca["frame"]), len(cb["frame"]))
    cut = lambda c, key: c[key][:frames]
    out = {"frames": frames}
    gap = np.linalg.norm(cut(ca, "centres") - cut(cb, "centres"), axis=2)
    out["centre_rms_kpc"] = float(np.sqrt(np.mean(gap ** 2)))
    out["centre_max_kpc"] = float(gap.max())
    out["closest_rms_kpc"] = float(np.sqrt(np.mean((cut(ca, "closest_kpc") - cut(cb, "closest_kpc")) ** 2)))
    pa, pb = passages(cut(ca, "closest_kpc"), cut(ca, "time_myr")), passages(cut(cb, "closest_kpc"), cut(cb, "time_myr"))
    out["passages"] = [len(pa), len(pb)]
    out["passages_ref"] = [(round(t, 1), round(d, 2)) for _, t, d in pa]
    out["passages_run"] = [(round(t, 1), round(d, 2)) for _, t, d in pb]
    ha, hb = specific_momentum(ca), specific_momentum(cb)
    if ha is not None and hb is not None:
        apart = cut(ca, "closest_kpc") > PAIR_FLOOR_KPC
        ratio = np.abs(hb[:frames] - ha[:frames]) / np.maximum(ha[:frames], 1e-9)
        out["momentum_median_rel"] = float(np.median(ratio[apart])) if apart.any() else None
        out["momentum_start"] = [float(ha[0]), float(hb[0])]
        out["momentum_last_apart"] = [float(ha[apart][-1]), float(hb[apart][-1])] if apart.any() else None
    out["merged_myr"] = [merged_at(ca), merged_at(cb)]
    out["tidal_rms"] = float(np.sqrt(np.mean((cut(ca, "tidal_fraction") - cut(cb, "tidal_fraction")) ** 2)))
    out["tidal_final"] = [float(ca["tidal_fraction"][frames - 1]), float(cb["tidal_fraction"][frames - 1])]
    ea, eb = cut(ca, "extent_kpc"), cut(cb, "extent_kpc")
    out["extent_rms_rel"] = float(np.sqrt(np.mean(((eb - ea) / np.maximum(ea, 1e-9)) ** 2)))
    fa, fb = ca["formed"][:frames].sum(), cb["formed"][:frames].sum()
    out["formed"] = [float(fa), float(fb)]
    out["burst"] = [burst_peak(ca), burst_peak(cb)]
    disks = []
    for key in sorted(k for k in ca if k.startswith("disruption_")):
        index = key.split("_")[1]
        torn = f"torn_{index}"
        disks.append({
            "galaxy": int(index),
            "disruption_final": [float(ca[key][frames - 1]), float(cb[key][frames - 1])],
            "disruption_half_myr": [crossing(ca[key][:frames], ca["time_myr"], HALF),
                                    crossing(cb[key][:frames], cb["time_myr"], HALF)],
            "torn_final": [float(ca[torn][frames - 1]), float(cb[torn][frames - 1])]
            if torn in ca else None,
            "torn_half_myr": [crossing(ca[torn][:frames], ca["time_myr"], HALF),
                              crossing(cb[torn][:frames], cb["time_myr"], HALF)]
            if torn in ca else None})
    out["disks"] = disks
    return out


def compare_drift(a, b):
    rows = []
    for x, y in zip(a["drift"], b["drift"]):
        rows.append({
            "myr": x["myr"],
            "tails": [x["tails_light"], y["tails_light"]],
            "extent_rel": (y["extent_light"] - x["extent_light"]) / max(x["extent_light"], 1e-9),
            "height_rel": [(q - p) / max(p, 1e-9) for p, q in zip(x["height_light"], y["height_light"])]})
    return rows


def timing(run):
    record = run["record"]
    steps = record["settle"] + record["steps"]
    massive = record.get("massive") or record["particles"]
    out = {"seconds": record.get("seconds"), "steps": steps, "step_myr": record["timeStepMyr"],
           "peak_gb": (record.get("peakMemoryBytes") or 0) / 1e9}
    if record.get("seconds"):
        out["ns_per_massive_step"] = record["seconds"] / (massive * steps) * 1e9
    if run["step_ms"]:
        out["median_ms_per_step"] = float(np.median(run["step_ms"]))
    return out


def hires_report(folders, markdown):
    runs = [load_run(f) for f in folders]
    reference = runs[0]
    lines = [f"# Runs against {reference['name']}", ""]
    lines += ["| run | step Myr | steps | wall | ms a step | peak GB |", "| --- | ---: | ---: | ---: | ---: | ---: |"]
    for run in runs:
        t = timing(run)
        wall = f"{t['seconds'] / 60:.1f} min" if t["seconds"] else ""
        lines.append(f"| {run['name']} | {t['step_myr']:.4f} | {t['steps']} | {wall} | "
                     f"{t.get('median_ms_per_step', float('nan')):.1f} | {t['peak_gb']:.1f} |")
    results = {"reference": reference["name"], "runs": {}}
    for run in runs[1:]:
        entry = {"curves": compare_curves(reference, run), "drift": compare_drift(reference, run),
                 "maps": {name: compare_maps(reference, run, name) for name in ("drawn", "massive", "tracers")},
                 "timing": timing(run)}
        results["runs"][run["name"]] = entry
        c = entry["curves"]
        lines += ["", f"## {run['name']} against {reference['name']}", ""]
        lines.append(f"- centres: rms {c['centre_rms_kpc']:.2f} kpc, max {c['centre_max_kpc']:.2f}; "
                     f"closest pair rms {c['closest_rms_kpc']:.2f} kpc")
        lines.append(f"- passages {c['passages_ref']} against {c['passages_run']}")
        if c.get("momentum_median_rel") is not None:
            lines.append(f"- orbit's angular momentum while apart: median {c['momentum_median_rel']:.2%} off; "
                         f"last apart {c['momentum_last_apart'][0]:.2f} against {c['momentum_last_apart'][1]:.2f}")
        lines.append(f"- merged (closest under {MERGED_KPC:g} kpc for good): {c['merged_myr'][0]} against {c['merged_myr'][1]} Myr")
        lines.append(f"- tails: rms {c['tidal_rms']:.4f}, final {c['tidal_final'][0]:.4f} against {c['tidal_final'][1]:.4f}")
        lines.append(f"- extent rms {c['extent_rms_rel']:.2%}; formed {c['formed'][0]:.0f} against {c['formed'][1]:.0f} "
                     f"({(c['formed'][1] - c['formed'][0]) / max(c['formed'][0], 1):+.2%}); burst at "
                     f"{c['burst'][0][0]:.0f} against {c['burst'][1][0]:.0f} Myr")
        for d in c["disks"]:
            lines.append(f"- galaxy {d['galaxy']}: disruption {d['disruption_final'][0]:.3f} against "
                         f"{d['disruption_final'][1]:.3f} (half at {d['disruption_half_myr'][0]} and "
                         f"{d['disruption_half_myr'][1]} Myr), torn {d['torn_final']} (half at {d['torn_half_myr']})")
        for name in ("drawn", "massive"):
            rows = entry["maps"].get(name)
            if not rows:
                continue
            lines += ["", f"Density, {name}:", "",
                      "| Myr | chi2 a cell | binned 4x4 | light elsewhere | noise alone |",
                      "| ---: | ---: | ---: | ---: | ---: |"]
            for r in rows:
                myr = f"{r['myr']:.0f}" if r["myr"] is not None else str(r["instant"])
                lines.append(f"| {myr} | {r['chi2']:.2f} | {r['chi2_4x4']:.2f} | "
                             f"{r['elsewhere'] * 100:.2f} % | {r['noise'] * 100:.2f} % |")
        if entry["drift"]:
            lines += ["", "Drift lines (tracers):", "", "| Myr | tails | extent | disk heights |",
                      "| ---: | --- | ---: | --- |"]
            for r in entry["drift"]:
                heights = ", ".join(f"{h:+.1%}" for h in r["height_rel"])
                lines.append(f"| {r['myr']:.0f} | {r['tails'][0]:.2f} % / {r['tails'][1]:.2f} % | "
                             f"{r['extent_rel']:+.2%} | {heights} |")
    text = "\n".join(lines)
    print(text)
    if markdown:
        with open(markdown, "w") as handle:
            handle.write(text + "\n")
        with open(os.path.splitext(markdown)[0] + ".json", "w") as handle:
            json.dump(results, handle, indent=2, default=float)
            handle.write("\n")


def batch_rows(batch):
    with open(os.path.join(batch, "index.csv"), newline="") as handle:
        rows = {r["id"]: r for r in csv.DictReader(handle) if r.get("status") == "ok"}
    for name, row in rows.items():
        path = os.path.join(batch, name, "interest.json")
        row["interest"] = json.load(open(path)).get("features", {}) if os.path.exists(path) else {}
        path = os.path.join(batch, name, "scene.json")
        if os.path.exists(path):
            row["generator"] = (json.load(open(path)).get("draw") or {}).get("generator", "")
        path = os.path.join(batch, name, "curves.csv")
        if os.path.exists(path):
            with open(path, newline="") as handle:
                row["formed_total"] = sum(float(r.get("formed") or 0) for r in csv.DictReader(handle))
    return rows


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
    return float(np.corrcoef(ra, rb)[0, 1]) if len(a) > 2 else float("nan")


def slot_ns(rows, jobs=4):
    work = sum(float(r["particles"]) * (float(r["settle"]) + float(r["steps"])) for r in rows.values())
    wall = sum(float(r["wall_seconds"]) for r in rows.values())
    return wall / jobs / work * 1e9 if work else float("nan"), wall / max(len(rows), 1)


def explore_report(first, second, markdown):
    a, b = batch_rows(first), batch_rows(second)
    common = sorted(set(a) & set(b))
    score = lambda rows, n: float(rows[n].get("score") or 0)
    sa, sb = [score(a, n) for n in common], [score(b, n) for n in common]
    top = lambda s: [n for _, n in sorted(zip(s, common), key=lambda p: -p[0])]
    ta, tb = top(sa), top(sb)
    lines = [f"# {os.path.basename(os.path.normpath(second))} against {os.path.basename(os.path.normpath(first))}", ""]
    lines.append(f"- scenes done in both: {len(common)} (only first {sorted(set(a) - set(b))}, only second {sorted(set(b) - set(a))})")
    lines.append(f"- score rank correlation (Spearman): {spearman(sa, sb):.3f}")
    for k in (1, 4, 10):
        lines.append(f"- top {k}: {len(set(ta[:k]) & set(tb[:k]))} in common")
    lines.append(f"- score: mean |difference| {np.mean(np.abs(np.array(sa) - np.array(sb))):.3f}, "
                 f"mean {np.mean(sa):.3f} against {np.mean(sb):.3f}")
    ratios = [b[n]["formed_total"] / a[n]["formed_total"] for n in common
              if a[n].get("formed_total") and b[n].get("formed_total") is not None]
    if ratios:
        q = np.percentile(ratios, [10, 50, 90])
        lines.append(f"- stars formed, second over first: median {q[1]:.3f} (10 to 90 % {q[0]:.3f} to {q[2]:.3f})")
    na, wa = slot_ns({n: a[n] for n in common})
    nb, wb = slot_ns({n: b[n] for n in common})
    lines.append(f"- wall per scene {wa:.0f} s against {wb:.0f} s ({wa / max(wb, 1e-9):.2f}x); "
                 f"{na:.0f} against {nb:.0f} ns per particle step and slot")
    lines += ["", "| scene | drawn | gal | score | rank | closest kpc | at Myr | tails | burst | disruption | formed |",
              "| --- | --- | ---: | --- | --- | --- | --- | --- | --- | --- | ---: |"]
    for n in ta:
        ia, ib = a[n]["interest"], b[n]["interest"]
        pair = lambda key, f="{:.2f}": " / ".join(
            "" if x.get(key) is None else f.format(x[key]) for x in (ia, ib))
        formed = (f"{b[n]['formed_total'] / a[n]['formed_total']:.3f}"
                  if a[n].get("formed_total") and b[n].get("formed_total") is not None else "")
        lines.append(f"| {n} | {a[n].get('generator', '')} | {a[n]['galaxies']} | {score(a, n):.3f} / {score(b, n):.3f} | "
                     f"{ta.index(n) + 1} / {tb.index(n) + 1} | {pair('min_separation_kpc')} | "
                     f"{pair('min_separation_myr', '{:.0f}')} | {pair('peak_tidal', '{:.3f}')} | "
                     f"{pair('burst_ratio')} | {pair('final_disruption')} | {formed} |")
    text = "\n".join(lines)
    print(text)
    if markdown:
        with open(markdown, "w") as handle:
            handle.write(text + "\n")


def luminance(path):
    from PIL import Image

    image = np.asarray(Image.open(path).convert("RGB"), dtype=np.float64) / 255
    return image @ np.array([0.2126, 0.7152, 0.0722])


def blur(image, radius):
    if radius <= 0:
        return image
    x = np.arange(-3 * radius, 3 * radius + 1)
    kernel = np.exp(-0.5 * (x / radius) ** 2)
    kernel /= kernel.sum()
    image = np.apply_along_axis(lambda r: np.convolve(r, kernel, "same"), 1, image)
    return np.apply_along_axis(lambda c: np.convolve(c, kernel, "same"), 0, image)


def frames_report(paths):
    reference = luminance(paths[0])
    print("other  radius px  mean |difference| / mean light  pixels lit in one only")
    for path in paths[1:]:
        other = luminance(path)
        for radius in (0, 2, 8):
            a, b = blur(reference, radius), blur(other, radius)
            relative = np.abs(a - b).mean() / max(a.mean(), 1e-9)
            lit = ((a > 0.05) != (b > 0.05)).mean()
            label = os.path.join(os.path.basename(os.path.dirname(os.path.abspath(path))), os.path.basename(path))
            print(f"{label}  {radius:9d}  {relative:30.3%}  {lit:22.3%}")


def sheet(out, folders, width, crop):
    from PIL import Image

    frame = lambda n: int(re.findall(r"\d+", n)[-1]) if re.findall(r"\d+", n) else 0
    names = sorted((n for n in os.listdir(folders[0]) if n.endswith(".png")
                    and all(os.path.exists(os.path.join(f, n)) for f in folders)), key=lambda n: (frame(n), n))
    scaled, crops = [], []
    for name in names:
        row, crop_row = [], []
        for folder in folders:
            image = Image.open(os.path.join(folder, name)).convert("RGB")
            w, h = image.size
            row.append(image.resize((width, width * h // w), Image.LANCZOS))
            cw, ch = crop, crop * 9 // 16
            crop_row.append(image.crop(((w - cw) // 2, (h - ch) // 2, (w + cw) // 2, (h + ch) // 2)))
        scaled.append(row)
        crops.append(crop_row)
    for rows, path in ((scaled, out), (crops, os.path.splitext(out)[0] + "-crops.jpg")):
        cw, ch = rows[0][0].size
        canvas = Image.new("RGB", (cw * len(folders), ch * len(rows)))
        for r, row in enumerate(rows):
            for c, image in enumerate(row):
                canvas.paste(image, (c * cw, r * ch))
        canvas.save(path, quality=90)
        print(f"sheet    {path} ({', '.join(os.path.basename(os.path.normpath(f)) for f in folders)}; rows {', '.join(names)})")


def option(arguments, name, default=None):
    if name in arguments:
        index = arguments.index(name)
        value = arguments[index + 1]
        del arguments[index:index + 2]
        return value
    return default


def main(arguments):
    if not arguments:
        sys.exit(__doc__)
    command, rest = arguments[0], arguments[1:]
    markdown = option(rest, "--markdown")
    if command == "hires" and len(rest) >= 2:
        hires_report(rest, markdown)
    elif command == "explore" and len(rest) == 2:
        explore_report(rest[0], rest[1], markdown)
    elif command == "frames" and len(rest) >= 2:
        frames_report(rest)
    elif command == "sheet" and len(rest) >= 2:
        width = int(option(rest, "--width", 1280))
        crop = int(option(rest, "--crop", 960))
        sheet(rest[0], rest[1:], width, crop)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
