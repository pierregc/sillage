#!/usr/bin/env python3
"""Whether light tracers stay on the mass (#187).

Reads the density maps a run with `--massive` writes beside `--density`: the tracers alone and
the massive visible particles alone, counted on the same grid at the same instants. Two samples
of one distribution differ cell by cell by Poisson noise only, so each instant is scored by
chi-square per cell against that noise, at the grid's own cells and binned 4x4 (where a slow
drift would add up), and by the share of the light that sits elsewhere (half the summed absolute
difference) against the share noise alone would move.

    tracer-drift.py RUN.log DENSITY.npy [--sheet out.png]
"""

import re
import sys

import numpy as np


def load(path):
    return np.load(path).astype(np.float64)


def counts(log):
    text = open(log).read()
    found = re.search(r"tracers\s+(\d+) light, (\d+) massive visible", text)
    if not found:
        sys.exit(f"{log}: no tracer line")
    times = [float(t) for t in re.findall(r"drift\s+frame \d+ t=([\d.]+) Myr", text)]
    return int(found.group(1)), int(found.group(2)), times


def binned(maps, factor):
    n, size, _ = maps.shape
    return maps.reshape(n, size // factor, factor, size // factor, factor).sum(axis=(2, 4))


def chi2(light, heavy, n_light, n_heavy, floor=20):
    # Counts, so the noise of each map is its own.
    a = light * n_light
    b = heavy * n_heavy
    expected = (a + b) / (n_light + n_heavy)
    keep = (a + b) >= floor
    ea = expected * n_light
    eb = expected * n_heavy
    terms = (a - ea) ** 2 / np.maximum(ea, 1e-12) + (b - eb) ** 2 / np.maximum(eb, 1e-12)
    return terms[keep].sum() / max(keep.sum(), 1), int(keep.sum())


def elsewhere(light, heavy, n_light, n_heavy):
    """Half the summed absolute difference of the two maps, as a share of what each holds, and
    the same quantity for two Poisson draws of their mean."""
    total_light = light.sum()
    total_heavy = heavy.sum()
    shift = 0.5 * np.abs(light / total_light - heavy / total_heavy).sum()
    mean = 0.5 * (light / total_light + heavy / total_heavy)
    sigma = np.sqrt(mean / (n_light * total_light) + mean / (n_heavy * total_heavy))
    return shift, 0.5 * np.sqrt(2 / np.pi) * sigma.sum()


def sheet(light, heavy, n_light, n_heavy, path):
    from PIL import Image

    rows = []
    for index in range(light.shape[0]):
        a = binned(light[index : index + 1], 4)[0]
        b = binned(heavy[index : index + 1], 4)[0]
        noise = np.sqrt(np.maximum(a / n_light + b / n_heavy, 1e-30))
        z = np.where(a + b > 0, (a - b) / noise, 0.0)
        tiles = []
        for image in (light[index], heavy[index]):
            v = np.log10(np.maximum(image, 1e-9))
            v = np.clip((v + 7.5) / 5.0, 0, 1)
            tiles.append((v * 255).astype(np.uint8)[::-1])
        zc = np.clip(z / 4.0, -1, 1)[::-1]
        z_image = np.zeros((zc.shape[0], zc.shape[1], 3), dtype=np.uint8)
        z_image[..., 0] = (np.maximum(zc, 0) * 255).astype(np.uint8)
        z_image[..., 2] = (np.maximum(-zc, 0) * 255).astype(np.uint8)
        z_tile = np.kron(z_image, np.ones((4, 4, 1), dtype=np.uint8))
        grey = [np.repeat(t[..., None], 3, axis=2) for t in tiles]
        rows.append(np.concatenate(grey + [z_tile], axis=1))
    Image.fromarray(np.concatenate(rows, axis=0)).save(path)


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    log, density = sys.argv[1], sys.argv[2]
    n_light, n_heavy, times = counts(log)
    stem = density[: -len(".npy")] if density.endswith(".npy") else density
    light = load(stem + ".tracers.npy")
    heavy = load(stem + ".massive.npy")
    print("instant  Myr     chi2/cell  cells   chi2/cell 4x4  cells   elsewhere  noise alone")
    for index in range(light.shape[0]):
        c1, k1 = chi2(light[index], heavy[index], n_light, n_heavy)
        lb = binned(light[index : index + 1], 4)[0]
        hb = binned(heavy[index : index + 1], 4)[0]
        c4, k4 = chi2(lb, hb, n_light, n_heavy)
        shift, noise = elsewhere(lb, hb, n_light, n_heavy)
        time = times[index] if index < len(times) else float("nan")
        print(
            f"{index:7d}  {time:6.0f}  {c1:9.3f}  {k1:6d}  {c4:13.3f}  {k4:6d}"
            f"  {shift * 100:8.2f} %  {noise * 100:8.2f} %"
        )
    if "--sheet" in sys.argv:
        out = sys.argv[sys.argv.index("--sheet") + 1]
        sheet(light, heavy, n_light, n_heavy, out)
        print(f"sheet    {out} (tracers, massive, residual binned 4x4: red more light, blue less)")


if __name__ == "__main__":
    main()
