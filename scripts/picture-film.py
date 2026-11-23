#!/usr/bin/env python3
"""A real picture beside the simulation (#463): the key that frames it, the film, the title, sheets.

    picture-film.py key <match.json> (--picture <image> | --aspect <width>x<height>)
                    [--fit width|height] [--fov 0.15] [--at 0]
    picture-film.py flight <match.json> (--picture <image> | --aspect ...) [--fit ...] [--fov ...]
                    --out <flight.json>
    picture-film.py title <out.png> --title <text> [--subtitle <text>] [--left <text>]
                    [--right <text>] [--credit <text>] [--size 3840x2160] [--font <file>]
    picture-film.py film <master video> <out.mp4> --picture <image> --hold <start s>:<length s>
                    [--layout auto|shrink|slide] [--title-image <png> | --title <text> ...]
                    [--crf 14] [--x265-preset medium]
    picture-film.py still <frame image> <out.jpg> --picture <image> [--layout ...] [--left <text>]
                    [--right <text>]
    picture-film.py sheet <out.jpg> <image | video>... [--picture <image>] [--labels a,b,...]
                    [--at <s,...>] [--columns 2] [--tile-width 768]

key prints the flight key that shows the scene as the picture shows it, from the match that
`sillage-render match` wrote: `--fit width` lays the picture's width over the frame's, `--fit
height` its height over the frame's. flight writes a two key flight of one second holding that
view, for `export --flight <file> --flight-keys <dir>`.

film takes one continuous video whose camera holds the picture's view from `--hold`: over the
hold the frame shrinks into the left half, the picture slides in on the right and the title fades
in and out; the rest of the video passes untouched. A picture wider than tall goes with a key
made with `--fit width` and the `shrink` layout; a taller one with `--fit height` and `slide`,
where the frame moves left so that its middle half, which holds the picture's field, fills the
left half. `auto` picks by the picture's shape. `--label-y` places `--left` and `--right`, in
pixels of a 3840 wide frame. still lays one frame and the picture side by
side. sheet tiles images, or the frames of one video at `--at` seconds, with the picture first
when one is given.

Needs Pillow and ffmpeg. Nothing is read or written outside the paths given.
"""

import argparse
import json
import math
import os
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw, ImageFont

FONTS = [
    ("/System/Library/Fonts/Avenir Next.ttc", 7),
    ("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 0),
]


def die(message):
    sys.exit(f"picture-film: {message}")


def font(size, path=None):
    for name, index in ([(path, 0)] if path else FONTS):
        if os.path.exists(name):
            return ImageFont.truetype(name, size, index=index)
    die("no font found, give one with --font")


def smooth(x):
    x = min(max(x, 0.0), 1.0)
    return x * x * (3 - 2 * x)


def picture_aspect(path):
    with Image.open(path) as im:
        return im.height / im.width


def key_from_match(match, aspect, fit, fov, at):
    """The camera that sees the scene as the picture does: `origin` is where the scene's origin
    lands on the picture, in fractions of its width."""
    v = match["view"]
    e, a, r = (math.radians(v[k]) for k in ("elevation", "azimuth", "roll"))
    k = v["kpcPerWidth"]
    towards = (math.sin(a) * math.cos(e), -math.cos(a) * math.cos(e), math.sin(e))
    right = (math.cos(a), math.sin(a), 0.0)
    down = (math.sin(a) * math.sin(e), -math.cos(a) * math.sin(e), -math.cos(e))
    cx, cy = 0.5 - v["origin"][0], 0.5 * aspect - v["origin"][1]
    sx = k * (math.cos(r) * cx + math.sin(r) * cy)
    sy = k * (-math.sin(r) * cx + math.cos(r) * cy)
    aim = [sx * right[i] + sy * down[i] for i in range(3)]
    height = k * 9 / 16 if fit == "width" else k * aspect
    distance = (height / 2) / math.tan(fov / 2)
    eye = [aim[i] + distance * towards[i] for i in range(3)]
    return {
        "at": at,
        "myr": round(match["megayears"], 4),
        "eye": [round(x, 3) for x in eye],
        "aim": [round(x, 3) for x in aim],
        "fov": fov,
        "roll": round(r, 4),
    }


def draw_title(size, args):
    w, h = size
    s = w / 3840
    im = Image.new("RGBA", size, (0, 0, 0, 0))
    d = ImageDraw.Draw(im)

    def centred(text, y, f, fill, x=w / 2, spacing=0.0):
        width = d.textlength(text, font=f) + spacing * (len(text) - 1)
        cx = x - width / 2
        for ch in text:
            d.text((cx, y), ch, font=f, fill=fill)
            cx += d.textlength(ch, font=f) + spacing

    if args.title:
        centred(args.title, h - 470 * s, font(round(118 * s), args.font), (255, 255, 255, 255), spacing=18 * s)
    if args.subtitle:
        centred(args.subtitle, h - 310 * s, font(round(46 * s), args.font), (225, 228, 235, 235))
    small = font(round(40 * s), args.font)
    label_y = args.label_y if args.label_y is not None else (70 if getattr(args, "layout_used", "shrink") == "slide" else 470)
    if args.left:
        centred(args.left, label_y * s, small, (235, 235, 240, 230), x=w / 4)
    if args.right:
        centred(args.right, label_y * s, small, (235, 235, 240, 230), x=3 * w / 4)
    if args.credit:
        f = font(round(32 * s), args.font)
        d.text((w - 60 * s - d.textlength(args.credit, font=f), h - 75 * s), args.credit, font=f,
               fill=(210, 212, 220, 220))
    return im


def probe(video):
    out = subprocess.check_output(
        ["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
         "stream=width,height,r_frame_rate:format=duration", "-of", "json", video])
    info = json.loads(out)
    stream = info["streams"][0]
    num, den = stream["r_frame_rate"].split("/")
    return stream["width"], stream["height"], float(num) / float(den), float(info["format"]["duration"])


def grab(video, second, path):
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-ss", f"{second:.3f}", "-i", video, "-frames:v", "1", path],
                   check=True)


def panel(picture, w, h):
    """The picture fitted into the right half."""
    pic = Image.open(picture).convert("RGB")
    scale = min((w / 2) / pic.width, h / pic.height)
    return pic.resize((round(pic.width * scale), round(pic.height * scale)), Image.LANCZOS)


def layout_of(args):
    if args.layout != "auto":
        return args.layout
    return "slide" if picture_aspect(args.picture) >= 1 else "shrink"


def split_frame(sim, pic, size, p, layout="shrink"):
    """The frame at progress p of the push: 0 the plain frame, 1 the two halves. `shrink` scales
    the whole frame into the left half; `slide` moves it left so its middle half fills it."""
    w, h = size
    frame = Image.new("RGB", size)
    if layout == "slide":
        frame.paste(sim, (round(-(w / 4) * p), 0))
        if p > 0:
            x = round(w - (w / 2) * p)
            frame.paste((0, 0, 0), (x, 0, w, h))
            frame.paste(pic, (x + (w // 2 - pic.width) // 2, (h - pic.height) // 2))
        return frame
    s = 1 - 0.5 * p
    sw, sh = round(w * s), round(h * s)
    x0, y0 = round(w / 2 - (w / 4) * p - sw / 2), round(h / 2 - sh / 2)
    frame.paste(sim if p == 0 else sim.resize((sw, sh), Image.BILINEAR), (x0, y0))
    band = min(1.0, 2 * pic.height / h)
    gap = round(sh * (1 - band) / 2)
    if p > 0 and gap > 0:
        cover = Image.new("L", (sw, gap), round(255 * p))
        frame.paste((0, 0, 0), (x0, y0, x0 + sw, y0 + gap), cover)
        frame.paste((0, 0, 0), (x0, y0 + sh - gap, x0 + sw, y0 + sh), cover)
    if p > 0:
        frame.paste(pic, (round(w - (w / 2) * p + (w / 2 - pic.width) / 2), (h - pic.height) // 2))
    return frame


def title_for(args, size):
    if getattr(args, "title_image", None):
        return Image.open(args.title_image).convert("RGBA").resize(size, Image.LANCZOS)
    if args.title or args.subtitle or args.left or args.right or args.credit:
        return draw_title(size, args)
    return None


def with_title(frame, title, alpha):
    if title is None or alpha <= 0:
        return frame
    layer = title.copy()
    layer.putalpha(layer.getchannel("A").point(lambda v: int(v * alpha)))
    return Image.alpha_composite(frame.convert("RGBA"), layer).convert("RGB")


def film(args):
    try:
        start, length = (float(x) for x in args.hold.split(":"))
    except ValueError:
        die("--hold wants <start s>:<length s>")
    w, h, fps, duration = probe(args.master)
    if start + length > duration:
        die(f"the hold ends at {start + length:.1f} s, the video lasts {duration:.1f} s")
    size = (w, h)
    ts, te, push = start + 0.4, start + length - 0.3, 1.3
    if te - ts < 2 * push:
        die("the hold is too short for the push in and out: 4 s at least")
    pic = panel(args.picture, w, h)
    layout = args.layout_used = layout_of(args)
    title = title_for(args, size)
    count = round((te - ts) * fps)
    with tempfile.TemporaryDirectory() as work:
        still, segment = f"{work}/hold.png", f"{work}/split.mov"
        grab(args.master, start + length / 2, still)
        sim = Image.open(still).convert("RGB")
        encoder = subprocess.Popen(
            ["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{w}x{h}", "-r",
             f"{fps}", "-i", "-", "-c:v", "prores_ks", "-profile:v", "3", "-pix_fmt", "yuv422p10le", segment],
            stdin=subprocess.PIPE)
        for i in range(count):
            t = ts + i / fps
            p = smooth((t - ts) / push) * smooth((te - t) / push)
            frame = split_frame(sim, pic, size, p, layout)
            alpha = smooth((t - ts - push - 0.3) / 0.8) * smooth((te - push - t) / 0.6)
            encoder.stdin.write(with_title(frame, title, alpha).tobytes())
        encoder.stdin.close()
        if encoder.wait() != 0:
            die("ffmpeg could not encode the split screen")
        graph = (f"[0:v]trim=0:{ts},setpts=PTS-STARTPTS[a];[1:v]setpts=PTS-STARTPTS[b];"
                 f"[0:v]trim=start={ts + count / fps},setpts=PTS-STARTPTS[c];"
                 "[a][b][c]concat=n=3:v=1,format=yuv420p10le[v]")
        subprocess.run(
            ["ffmpeg", "-v", "error", "-y", "-i", args.master, "-i", segment, "-filter_complex", graph, "-map",
             "[v]", "-c:v", "libx265", "-preset", args.x265_preset, "-crf", str(args.crf), "-x265-params", "log-level=error", "-pix_fmt",
             "yuv420p10le", "-tag:v", "hvc1", "-movflags", "+faststart", args.out], check=True)
    print(json.dumps({"film": args.out, "width": w, "height": h, "fps": fps,
                      "layout": layout, "split": [round(ts, 3), round(ts + count / fps, 3)]}))


def still(args):
    sim = Image.open(args.frame).convert("RGB")
    size = sim.size
    args.layout_used = layout_of(args)
    frame = split_frame(sim, panel(args.picture, *size), size, 1.0, args.layout_used)
    args.title = args.subtitle = None
    frame = with_title(frame, title_for(args, size), 1.0)
    frame.save(args.out, quality=92)
    print(json.dumps({"still": args.out, "width": size[0], "height": size[1]}))


def sheet(args):
    tw = args.tile_width
    tiles, labels = [], []
    given = args.labels.split(",") if args.labels else []
    with tempfile.TemporaryDirectory() as work:
        sources = []
        for item in args.items:
            if item.lower().endswith((".mp4", ".mov", ".mkv", ".webm")):
                if not args.at:
                    die("a video needs --at <s,...>")
                for second in (float(x) for x in args.at.split(",")):
                    path = f"{work}/{len(sources):04d}.png"
                    grab(item, second, path)
                    sources.append((path, f"{second:g} s"))
            else:
                sources.append((item, os.path.splitext(os.path.basename(item))[0]))
        for i, (path, name) in enumerate(sources):
            tiles.append(Image.open(path).convert("RGB"))
            labels.append(given[i] if i < len(given) else name)
        if not tiles:
            die("nothing to lay out")
        th = round(tw * tiles[0].height / tiles[0].width)
        if args.picture:
            pic = Image.open(args.picture).convert("RGB")
            scale = min(tw / pic.width, th / pic.height)
            fitted = pic.resize((round(pic.width * scale), round(pic.height * scale)), Image.LANCZOS)
            first = Image.new("RGB", (tw, th))
            first.paste(fitted, ((tw - fitted.width) // 2, (th - fitted.height) // 2))
            tiles.insert(0, first)
            labels.insert(0, args.picture_label)
        columns = args.columns
        rows = (len(tiles) + columns - 1) // columns
        out = Image.new("RGB", (columns * tw, rows * th))
        f = font(max(12, round(tw / 45)), args.font)
        for i, (tile, label) in enumerate(zip(tiles, labels)):
            tile = tile if tile.size == (tw, th) else tile.resize((tw, th), Image.LANCZOS)
            ImageDraw.Draw(tile).text((10, 8), label, font=f, fill=(255, 255, 255), stroke_width=2,
                                      stroke_fill=(0, 0, 0))
            out.paste(tile, ((i % columns) * tw, (i // columns) * th))
        out.save(args.out, quality=88)
    print(json.dumps({"sheet": args.out, "tiles": len(tiles), "width": out.width, "height": out.height}))


def words(parser, title=True):
    if title:
        parser.add_argument("--title")
        parser.add_argument("--subtitle")
    parser.add_argument("--left")
    parser.add_argument("--right")
    parser.add_argument("--credit")
    parser.add_argument("--label-y", type=float)
    parser.add_argument("--layout", choices=["auto", "shrink", "slide"], default="auto")
    parser.add_argument("--font")


def view(parser):
    parser.add_argument("match")
    parser.add_argument("--picture")
    parser.add_argument("--aspect")
    parser.add_argument("--fit", choices=["width", "height"], default="width")
    parser.add_argument("--fov", type=float, default=0.15)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("key")
    view(p)
    p.add_argument("--at", type=float, default=0.0)

    p = sub.add_parser("flight")
    view(p)
    p.add_argument("--out", required=True)

    p = sub.add_parser("title")
    p.add_argument("out")
    p.add_argument("--size", default="3840x2160")
    words(p)

    p = sub.add_parser("film")
    p.add_argument("master")
    p.add_argument("out")
    p.add_argument("--picture", required=True)
    p.add_argument("--hold", required=True)
    p.add_argument("--title-image")
    p.add_argument("--crf", type=int, default=14)
    p.add_argument("--x265-preset", default="medium")
    words(p)

    p = sub.add_parser("still")
    p.add_argument("frame")
    p.add_argument("out")
    p.add_argument("--picture", required=True)
    words(p, title=False)

    p = sub.add_parser("sheet")
    p.add_argument("out")
    p.add_argument("items", nargs="+")
    p.add_argument("--picture")
    p.add_argument("--picture-label", default="picture")
    p.add_argument("--labels")
    p.add_argument("--at")
    p.add_argument("--columns", type=int, default=2)
    p.add_argument("--tile-width", type=int, default=768)
    p.add_argument("--font")

    args = parser.parse_args()
    if args.command in ("key", "flight"):
        match = json.load(open(args.match))
        if args.aspect:
            try:
                width, height = (float(x) for x in args.aspect.split("x"))
            except ValueError:
                die("--aspect wants <width>x<height>")
            aspect = height / width
        elif args.picture:
            aspect = picture_aspect(args.picture)
        else:
            die("give --picture <image> or --aspect <width>x<height>")
        key = key_from_match(match, aspect, args.fit, args.fov, getattr(args, "at", 0.0))
        if args.command == "key":
            print(json.dumps(key))
        else:
            json.dump({"version": 1, "keys": [key, dict(key, at=1.0)]}, open(args.out, "w"), indent=1)
            print(json.dumps({"flight": args.out, "myr": key["myr"]}))
    elif args.command == "title":
        try:
            w, h = (int(x) for x in args.size.split("x"))
        except ValueError:
            die("--size wants <width>x<height>")
        draw_title((w, h), args).save(args.out)
        print(json.dumps({"title": args.out, "width": w, "height": h}))
    elif args.command == "film":
        film(args)
    elif args.command == "still":
        still(args)
    else:
        sheet(args)


if __name__ == "__main__":
    main()
