#!/usr/bin/env python3
"""Throwaway tooling for #339 (after library/315/tool.py).

    tool.py looks <tag> <look.json> [key=value ...]   looks/<tag>-<moment>.look.json
    tool.py render <build> <tag>...                   4K stills under the GPU lock, 960 px copies
    tool.py measure <build> <tag>...                  ruler numbers into numbers.json
    tool.py same <tag> <buildA> <buildB>              compares the two builds' stills pixel for pixel
"""

import json
import os
import subprocess
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
SCRATCH = os.environ["SCRATCH"]
BUILDS = {"main": os.path.join(SCRATCH, "main-build"), "branch": os.path.join(SCRATCH, "branch-build")}
LOOKS = os.path.join(HERE, "looks")
SCENE = os.path.join(HERE, "scene-0067")
RULER = os.path.join(REPO, "scripts", "photo-ruler.py")
GPU = os.path.join(HERE, "gpu.sh")
ELEVATION, AZIMUTH = 1.1, 0.467
MOMENTS = {
    "calm": {"frame": 48, "center": [18.53, 8.32, -8.84], "radius": 16.5},
    "passage": {"frame": 232, "center": [0.25, -1.15, 0.30], "radius": 19.0},
    "tails": {"frame": 420, "center": [2.85, -0.22, -1.27], "radius": 26.0},
}


def stills(build):
    return os.path.join(HERE, "stills", build)


def parse(value):
    try:
        return json.loads(value)
    except json.JSONDecodeError:
        return value


def looks(tag, source, overrides):
    with open(source) as f:
        base = json.load(f)
    for item in overrides:
        key, value = item.split("=", 1)
        target = base
        parts = key.split(".")
        for part in parts[:-1]:
            target = target.setdefault(part, {})
        target[parts[-1]] = parse(value)
    os.makedirs(LOOKS, exist_ok=True)
    for moment, m in MOMENTS.items():
        look = json.loads(json.dumps(base))
        look["name"] = f"{tag}-{moment}"
        look["camera"] = {
            "mode": "fixed", "elevation": ELEVATION, "azimuth": AZIMUTH,
            "center": m["center"], "radius": m["radius"],
        }
        with open(os.path.join(LOOKS, f"{tag}-{moment}.look.json"), "w") as f:
            json.dump(look, f, indent=2)


def render(build, tags, width=3840):
    out = stills(build)
    small = out + "-960"
    os.makedirs(out, exist_ok=True)
    os.makedirs(small, exist_ok=True)
    binary = BUILDS[build]
    for moment, m in MOMENTS.items():
        files = [os.path.join(LOOKS, f"{tag}-{moment}.look.json") for tag in tags]
        command = [
            GPU, "env", f"DYLD_LIBRARY_PATH={binary}", os.path.join(binary, "sillage-render"),
            "look", SCENE, "--grid", "--stills", out, "--width", str(width),
            "--frames", str(m["frame"]), "--no-variants", "--no-catalogue", "--base", files[0], *files[1:],
        ]
        done = subprocess.run(command, capture_output=True, text=True)
        if done.returncode != 0:
            sys.exit(done.stdout + done.stderr)
        for tag in tags:
            big = os.path.join(out, f"{tag}-{moment}-{m['frame']}.png")
            Image.open(big).convert("RGB").resize((960, 540), Image.LANCZOS).save(
                os.path.join(small, f"{tag}-{moment}.png"))
    print("rendered", build, " ".join(tags))


def measure(build, tags):
    path = os.path.join(HERE, "numbers.json")
    numbers = json.load(open(path)) if os.path.exists(path) else {}
    for tag in tags:
        for moment in MOMENTS:
            image = os.path.join(stills(build) + "-960", f"{tag}-{moment}.png")
            done = subprocess.run([sys.executable, RULER, "--json", image], capture_output=True, text=True)
            if done.returncode != 0:
                sys.exit(done.stdout + done.stderr)
            numbers[f"{build}/{tag}/{moment}"] = list(json.loads(done.stdout).values())[0]
    json.dump(numbers, open(path, "w"), indent=1, sort_keys=True)
    for tag in tags:
        row = [numbers[f"{build}/{tag}/{m}"] for m in MOMENTS]
        print(f"{build}/{tag}: " + "  ".join(
            f"{k} " + " / ".join(f"{r[k]:.3f}" for r in row) for k in ("saturated", "L50", "L99", "grain")))


def same(tag, a, b):
    for moment, m in MOMENTS.items():
        name = f"{tag}-{moment}-{m['frame']}.png"
        x = np.asarray(Image.open(os.path.join(stills(a), name)))
        y = np.asarray(Image.open(os.path.join(stills(b), name)))
        diff = np.abs(x.astype(int) - y.astype(int))
        print(f"{tag} {moment}: {'identical' if not diff.any() else f'{(diff > 0).any(axis=-1).sum()} pixels differ, largest {diff.max()}'}")


if __name__ == "__main__":
    command, rest = sys.argv[1], sys.argv[2:]
    if command == "looks":
        looks(rest[0], rest[1], rest[2:])
    elif command == "render":
        render(rest[0], rest[1:])
    elif command == "measure":
        measure(rest[0], rest[1:])
    elif command == "same":
        same(rest[0], rest[1], rest[2])
    else:
        sys.exit(__doc__)
