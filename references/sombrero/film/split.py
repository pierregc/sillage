#!/usr/bin/env python3
"""split.py: the Sombrero film's split screen beside Hubble, captioned as the Cartwheel's (#509).

  split.py title OUT.png [WxH]                      the words, divider and bottom shade, transparent
  split.py still WIDE.png OUT.jpg WxH               the open split screen, captioned
  split.py film MASTER.mov WIDE.png OUT.mp4 START:LENGTH [--crf 20]

The layout and type are the Cartwheel montage's (references/cartwheel/tools/title.py of #455,
Avenir Next, drawn on a 3840x2160 layer and scaled): two halves edge to edge with a thin divider,
a label at the top of each half, the title and one line under it at the bottom over a shade, the
credit at the bottom right. Over the hold the film frame shrinks into the left half (WIDE, the same
camera rendered K_WIDE times wider and taller at the same scale, fills round it) and Hubble slides
in on the right at the same kiloparsecs per pixel; the words fade in once both are in place.
Hubble's picture is 26.5 x 15.7 kpc: at the scale where its whole lane fits a half (K_WIDE), it is
shorter than the half, so its top and bottom edges fade into its own sky's tone.
"""
import json
import os
import subprocess
import sys
import tempfile

import numpy as np
from PIL import Image, ImageDraw, ImageFont
from scipy.ndimage import gaussian_filter1d

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tools"))
import film_split  # noqa: E402
import hubble_ref  # noqa: E402

# the words, all in one place
WORDS = {
    "title": "SOMBRERO GALAXY",
    "subtitle": "M104  ·  30 million light-years away  ·  a dust ring seen 6 degrees from edge on",
    "left": "Simulation  ·  Sillage",
    "right": "Hubble Space Telescope",
    "credit": "Image: ESA/Hubble & NASA, K. Noll (CC BY 4.0)",  # references/catalogue/catalogue.json, heic2506a
}
K_WIDE = 1.55  # the wide frame against the film frame; a half then holds 26.5 * 1.55 / 2 = 20.5 kpc
AV = "/System/Library/Fonts/Avenir Next.ttc"
PUSH = 1.3


def smooth(x):
    x = np.clip(x, 0.0, 1.0)
    return x * x * (3 - 2 * x)


def title_layer(size=(3840, 2160)):
    W, H = 3840, 2160
    im = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    band = Image.new("L", (1, 520))
    for y in range(520):
        band.putpixel((0, y), int(200 * (y / 519) ** 1.6))
    im.paste((0, 0, 0, 255), (0, H - 520, W, H), band.resize((W, 520)))
    d = ImageDraw.Draw(im)

    def font(px):
        return ImageFont.truetype(AV, px, index=7)

    def centred(text, y, f, fill, x=W / 2, spacing=0):
        cx = x - (d.textlength(text, font=f) + spacing * (len(text) - 1)) / 2
        for ch in text:
            d.text((cx, y), ch, font=f, fill=fill)
            cx += d.textlength(ch, font=f) + spacing

    centred(WORDS["title"], H - 330, font(118), (255, 255, 255, 255), spacing=18)
    centred(WORDS["subtitle"], H - 170, font(46), (225, 228, 235, 235))
    centred(WORDS["left"], 70, font(40), (235, 235, 240, 230), x=W / 4)
    centred(WORDS["right"], 70, font(40), (235, 235, 240, 230), x=3 * W / 4)
    f = font(32)
    d.text((W - 60 - d.textlength(WORDS["credit"], font=f), H - 75), WORDS["credit"], font=f, fill=(210, 212, 220, 220))
    d.line([(W / 2, 0), (W / 2, H)], fill=(255, 255, 255, 90), width=3)
    return im if size == (W, H) else im.resize(size, Image.LANCZOS)


def hubble_half(w, h):
    """Hubble in a (w/2) x h half at the wide frame's scale, nucleus centred, its top and bottom
    edges faded over a tenth of the half into its edge rows' own tone, darkening outwards."""
    hw = w // 2
    kpc = hubble_ref.KPC * K_WIDE / 2  # across the half
    ph = round(hw * hubble_ref.KPC / kpc * 8477 / 14319)
    a = np.asarray(film_split.hubble(hw, h, kpc)).astype(np.float32)
    top = (h - ph) // 2 + round((0.5 - film_split.NUCLEUS[1] * 14319 / 8477) * ph)
    top, bot = max(top, 0), min(top + ph, h)
    fade = max(4, h // 10)
    rows = max(2, h // 60)
    out = a.copy()
    y = np.arange(h)[:, None, None]
    for edge, inside in ((top, 1), (bot - 1, -1)):
        tone = a[edge:edge + inside * rows:inside].mean(0) if inside > 0 else a[edge - rows + 1:edge + 1].mean(0)
        tone = gaussian_filter1d(tone, hw / 8, axis=0, mode="nearest")
        dist = (edge - y) * inside  # > 0 outside the picture
        sky = tone[None] * (0.55 + 0.45 * np.exp(-np.maximum(dist, 0) / (0.6 * fade)))
        alpha = smooth((dist + fade * 0.5) / fade)  # 0 inside, 1 out past the edge
        out = np.where(dist > -fade, out * (1 - alpha) + sky * alpha, out)
    return Image.fromarray(np.clip(out, 0, 255).astype(np.uint8))


def frame_at(sim, wide, pic, layer, p, alpha):
    """The frame at push progress p: the film frame shrinking into the left half over the wide
    frame, Hubble sliding in on the right, the words at alpha."""
    w, h = sim.size
    s = 1 - (1 - 1 / K_WIDE) * p  # the film frame's scale: 1 to 1/K_WIDE
    cx = w / 2 - (w / 4) * p
    frame = Image.new("RGB", (w, h))
    g = s * K_WIDE * w / wide.width
    ws = wide.resize((round(wide.width * g), round(wide.height * g)), Image.BILINEAR)
    frame.paste(ws, (round(cx - ws.width / 2), round(h / 2 - ws.height / 2)))
    k = 1 - smooth(p / 0.3)
    if k > 0:
        ss = sim.resize((round(w * s), round(h * s)), Image.BILINEAR) if p > 0 else sim
        mask = Image.new("L", ss.size, round(255 * k))
        frame.paste(ss, (round(cx - ss.width / 2), round(h / 2 - ss.height / 2)), mask)
    if p > 0:
        frame.paste(pic, (round(w - (w / 2) * p), 0))
    if alpha > 0:
        lay = layer.copy()
        lay.putalpha(lay.getchannel("A").point(lambda v: int(v * alpha)))
        frame = Image.alpha_composite(frame.convert("RGBA"), lay).convert("RGB")
    return frame


def probe(video):
    out = json.loads(subprocess.check_output(
        ["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
         "stream=width,height,r_frame_rate:format=duration", "-of", "json", video]))
    st = out["streams"][0]
    num, den = st["r_frame_rate"].split("/")
    return st["width"], st["height"], float(num) / float(den), float(out["format"]["duration"])


def film(master, wide_png, out, hold, crf):
    start, length = (float(x) for x in hold.split(":"))
    w, h, fps, _ = probe(master)
    ts, te = start + 0.4, start + length - 0.3
    count = round((te - ts) * fps)
    wide = Image.open(wide_png).convert("RGB")
    pic, layer = hubble_half(w, h), title_layer((w, h))
    with tempfile.TemporaryDirectory() as work:
        still, seg = f"{work}/hold.png", f"{work}/split.mov"
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-ss", f"{start + length / 2:.3f}", "-i", master,
                        "-frames:v", "1", still], check=True)
        sim = Image.open(still).convert("RGB")
        enc = subprocess.Popen(["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{w}x{h}",
                                "-r", f"{fps}", "-i", "-", "-c:v", "prores_ks", "-profile:v", "3", "-pix_fmt",
                                "yuv422p10le", seg], stdin=subprocess.PIPE)
        for i in range(count):
            t = ts + i / fps
            p = float(smooth((t - ts) / PUSH) * smooth((te - t) / PUSH))
            a = float(smooth((t - ts - PUSH - 0.3) / 0.8) * smooth((te - PUSH - t) / 0.6))
            enc.stdin.write(frame_at(sim, wide, pic, layer, p, a).tobytes())
        enc.stdin.close()
        if enc.wait() != 0:
            sys.exit("split: ffmpeg could not encode the split screen")
        graph = (f"[0:v]trim=0:{ts},setpts=PTS-STARTPTS[a];[1:v]setpts=PTS-STARTPTS[b];"
                 f"[0:v]trim=start={ts + count / fps},setpts=PTS-STARTPTS[c];"
                 "[a][b][c]concat=n=3:v=1,format=yuv420p10le[v]")
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", master, "-i", seg, "-filter_complex", graph, "-map", "[v]",
                        "-c:v", "libx265", "-preset", "medium", "-tune", "grain", "-crf", str(crf), "-x265-params", "log-level=error",
                        "-pix_fmt", "yuv420p10le", "-tag:v", "hvc1", "-movflags", "+faststart", out], check=True)
    print(json.dumps({"film": out, "split": [round(ts, 3), round(ts + count / fps, 3)]}))


def main():
    cmd = sys.argv[1]
    if cmd == "title":
        size = tuple(int(x) for x in sys.argv[3].split("x")) if len(sys.argv) > 3 else (3840, 2160)
        title_layer(size).save(sys.argv[2])
    elif cmd == "still":
        wide = Image.open(sys.argv[2]).convert("RGB")
        w, h = (int(x) for x in sys.argv[4].split("x"))
        sim = wide.crop(((wide.width - round(wide.width / K_WIDE)) // 2, (wide.height - round(wide.height / K_WIDE)) // 2,
                         (wide.width + round(wide.width / K_WIDE)) // 2, (wide.height + round(wide.height / K_WIDE)) // 2))
        frame_at(sim.resize((w, h), Image.LANCZOS), wide, hubble_half(w, h), title_layer((w, h)), 1.0, 1.0).save(
            sys.argv[3], quality=92)
    elif cmd == "film":
        crf = sys.argv[sys.argv.index("--crf") + 1] if "--crf" in sys.argv else "20"
        film(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], crf)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
