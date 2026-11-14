#!/usr/bin/env python3
"""Throwaway tooling for #315: per-moment looks, 4K stills, ruler numbers, contact sheets.

    tool.py looks <tag> <look.json> [key=value ...]   writes looks/<tag>-<moment>.look.json
    tool.py render <tag>...                           4K stills + 960 px copies, under the GPU lock
    tool.py measure <tag>...                          ruler numbers into numbers.json
    tool.py sheet <out.jpg> <title> <col>...          rows are the moments; col is ref or a tag
"""

import json
import os
import subprocess
import sys

from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
SET = os.environ.get("SET", "mice")
LOOKS = os.path.join(HERE, "looks")
STILLS = os.path.join(HERE, "stills", SET)
SMALL = os.path.join(HERE, "stills", SET + "-960")
NUMBERS = os.path.join(HERE, "numbers.json")
GROUND = os.path.join(REPO, "out", "ground-images")
RULER = os.path.join(REPO, "scripts", "photo-ruler.py")

# Each set: its scene, the camera angles of its film, and three moments framed so the
# galaxies fill the frame.
SETS = {
    "mice": {
        "scene": "scene-0067",
        "angles": (1.1, 0.467),
        "moments": {
            "calm": {"frame": 48, "center": [18.53, 8.32, -8.84], "radius": 16.5},
            "passage": {"frame": 232, "center": [0.25, -1.15, 0.30], "radius": 19.0},
            "tails": {"frame": 420, "center": [2.85, -0.22, -1.27], "radius": 26.0},
        },
        "references": {
            "calm": ("ngc1232-ls.jpg", (0, 125, 2400, 1475), "NGC 1232"),
            "passage": ("antennae-bodies-ls.jpg", None, "Antennae"),
            "tails": ("mice-ls.jpg", (840, 220, 1460, 1300), "Mice"),
        },
    },
    "explore": {
        "scene": "explore-0067",
        "angles": (1.1, 0.467),
        "moments": {
            "calm": {"frame": 235, "center": [18.81, 8.03, -8.78], "radius": 16.5},
            "passage": {"frame": 419, "center": [0.36, -1.55, 0.49], "radius": 19.0},
            "tails": {"frame": 607, "center": [2.93, -0.75, -0.91], "radius": 26.0},
        },
        "references": {
            "calm": ("ngc1232-ls.jpg", (0, 125, 2400, 1475), "NGC 1232"),
            "passage": ("antennae-bodies-ls.jpg", None, "Antennae"),
            "tails": ("mice-ls.jpg", (840, 220, 1460, 1300), "Mice"),
        },
    },
    "antennae": {
        "scene": "scene-0099",
        "angles": (1.396, -0.288),
        "moments": {
            "calm": {"frame": 60, "center": [-5.15, 17.12, 11.44], "radius": 15.0},
            "passage": {"frame": 200, "center": [1.01, -0.85, -1.31], "radius": 17.0},
            "tails": {"frame": 344, "center": [-0.55, 0.37, -1.45], "radius": 40.0},
        },
        "references": {
            "calm": ("ngc1232-ls.jpg", (0, 125, 2400, 1475), "NGC 1232"),
            "passage": ("antennae-bodies-ls.jpg", None, "Antennae"),
            "tails": ("antennae-ls.jpg", (560, 220, 1840, 1940), "Antennae"),
        },
    },
}
CREDIT = "Legacy Surveys / D. Lang (Perimeter Institute) · CC BY 4.0"
SCENE = os.environ.get("SCENE", os.path.join(HERE, SETS[SET]["scene"]))
ELEVATION, AZIMUTH = SETS[SET]["angles"]
MOMENTS = SETS[SET]["moments"]
REFERENCES = {k: (f, c, f"{name} · {CREDIT}") for k, (f, c, name) in SETS[SET]["references"].items()}


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
            "mode": "fixed",
            "elevation": ELEVATION,
            "azimuth": AZIMUTH,
            "center": m["center"],
            "radius": m["radius"],
        }
        with open(os.path.join(LOOKS, f"{SET}-{tag}-{moment}.look.json"), "w") as f:
            json.dump(look, f, indent=2)


def render(tags, width=3840):
    os.makedirs(STILLS, exist_ok=True)
    os.makedirs(SMALL, exist_ok=True)
    for moment, m in MOMENTS.items():
        files = [os.path.join(LOOKS, f"{SET}-{tag}-{moment}.look.json") for tag in tags]
        command = [
            os.path.join(HERE, "gpu.sh"), "env", f"DYLD_LIBRARY_PATH={REPO}/.build/dev",
            os.path.join(REPO, ".build/dev/sillage-render"), "look", SCENE, "--grid",
            "--stills", STILLS, "--width", str(width), "--frames", str(m["frame"]),
            "--no-variants", "--no-catalogue", "--base", files[0], *files[1:],
        ]
        out = subprocess.run(command, capture_output=True, text=True)
        if out.returncode != 0:
            sys.exit(out.stdout + out.stderr)
        for tag in tags:
            big = os.path.join(STILLS, f"{tag}-{moment}-{m['frame']}.png")
            small = os.path.join(SMALL, f"{tag}-{moment}.png")
            Image.open(big).convert("RGB").resize((960, 540), Image.LANCZOS).save(small)
    print("rendered", " ".join(tags))


def reference(moment):
    name, crop, label = REFERENCES[moment]
    path = os.path.join(GROUND, name)
    out = os.path.join(HERE, "refs", f"{name[:-4]}-{crop[0] if crop else 0}.png")
    if not os.path.exists(out):
        os.makedirs(os.path.dirname(out), exist_ok=True)
        im = Image.open(path).convert("RGB")
        if crop:
            im = im.crop(crop)
        im.save(out)
    return out, label


def measure(tags):
    numbers = json.load(open(NUMBERS)) if os.path.exists(NUMBERS) else {}
    paths = {}
    for tag in tags:
        for moment in MOMENTS:
            key = f"{SET}/{tag}/{moment}" if tag != "ref" else f"ref/{SET}/{moment}"
            paths[key] = reference(moment)[0] if tag == "ref" else os.path.join(SMALL, f"{tag}-{moment}.png")
    out = subprocess.run([sys.executable, RULER, "--json", *paths.values()], capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit(out.stderr)
    rows = json.loads(out.stdout)
    for key, path in paths.items():
        numbers[key] = rows[path]
    with open(NUMBERS, "w") as f:
        json.dump(numbers, f, indent=1, sort_keys=True)
    for key in paths:
        print(key, "  ".join(f"{k} {v}" for k, v in numbers[key].items()))


def font(size):
    for path in ("/System/Library/Fonts/Menlo.ttc", "/System/Library/Fonts/Supplemental/Arial.ttf"):
        if os.path.exists(path):
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()


def fit(im, w, h):
    im = im.convert("RGB")
    scale = min(w / im.width, h / im.height)
    small = im.resize((max(1, round(im.width * scale)), max(1, round(im.height * scale))), Image.LANCZOS)
    cell = Image.new("RGB", (w, h), (8, 8, 10))
    cell.paste(small, ((w - small.width) // 2, (h - small.height) // 2))
    return cell


def sheet(out, title, columns, cell_w=640):
    numbers = json.load(open(NUMBERS))
    cell_h = cell_w * 9 // 16
    label_h, text_h, title_h = 22, 40, 34
    rows = list(MOMENTS)
    W = cell_w * len(columns)
    H = title_h + len(rows) * (label_h + cell_h + text_h)
    board = Image.new("RGB", (W, H), (18, 18, 20))
    d = ImageDraw.Draw(board)
    d.text((8, 7), title, font=font(18), fill=(235, 235, 235))
    small, big = font(13), font(14)
    for r, moment in enumerate(rows):
        y = title_h + r * (label_h + cell_h + text_h)
        for c, column in enumerate(columns):
            col, _, title_text = column.partition(":")
            x = c * cell_w
            if col == "ref":
                path, label = reference(moment)
                key = f"ref/{SET}/{moment}"
            else:
                path = os.path.join(SMALL, f"{col}-{moment}.png")
                label = f"{title_text or col} · {moment} · frame {MOMENTS[moment]['frame']}"
                key = f"{SET}/{col}/{moment}"
            d.text((x + 6, y + 3), label, font=big, fill=(220, 220, 220))
            board.paste(fit(Image.open(path), cell_w, cell_h), (x, y + label_h))
            n = numbers.get(key, {})
            line1 = f"lit {n.get('lit', 0):.0%}  L50 {n.get('L50', 0):.2f}  L99 {n.get('L99', 0):.2f}"
            line2 = f"saturated {n.get('saturated', 0):.0%}  grain {n.get('grain', 0):.2f}  shadow {n.get('shadow', 0):.0%}"
            d.text((x + 6, y + label_h + cell_h + 3), line1, font=small, fill=(200, 200, 200))
            d.text((x + 6, y + label_h + cell_h + 20), line2, font=small, fill=(200, 200, 200))
    board.save(out, quality=88)
    print(out, board.size)


def main():
    command, args = sys.argv[1], sys.argv[2:]
    if command == "looks":
        looks(args[0], args[1], args[2:])
    elif command == "render":
        render(args)
    elif command == "measure":
        measure(args)
    elif command == "sheet":
        sheet(args[0], args[1], args[2:])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
