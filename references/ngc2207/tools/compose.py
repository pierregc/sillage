"""The film from one continuous shot: over its hold the frame shrinks into the left half, the picture slides
in on the right, the title fades in and out; encoded x265 10 bit.
usage: compose.py <master.mov> <out.mp4> [hold start s] [hold length s]"""
import os, subprocess, sys
from PIL import Image
shot, out = sys.argv[1], sys.argv[2]
h0 = float(sys.argv[3]) if len(sys.argv) > 3 else 30.0
hl = float(sys.argv[4]) if len(sys.argv) > 4 else 9.0
C = os.path.expanduser("~/claude-workspace/ngc2207")
W, H, FPS = 3840, 2160, 30
ts, te, push = h0 + 0.4, h0 + hl - 0.3, 1.3
still = os.path.splitext(shot)[0] + "-hold.png"
subprocess.run(["ffmpeg", "-v", "error", "-y", "-ss", str(h0 + hl / 2), "-i", shot, "-frames:v", "1", still], check=True)
sim = Image.open(still).convert("RGB")
title = Image.open(f"{C}/out/title.png").convert("RGBA")
ph = round(W / 2 * 2983 / 6353)
pic = Image.open(f"{C}/ref/heic2414a-large.jpg").convert("RGB").resize((W // 2, ph), Image.LANCZOS)

def smooth(x):
    x = min(max(x, 0.0), 1.0); return x * x * (3 - 2 * x)

seg = f"{C}/out/split.mov"
enc = subprocess.Popen(["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}",
                        "-r", str(FPS), "-i", "-", "-c:v", "prores_ks", "-profile:v", "3", "-pix_fmt", "yuv422p10le", seg],
                       stdin=subprocess.PIPE)
n = round((te - ts) * FPS)
for i in range(n):
    t = ts + i / FPS
    p = smooth((t - ts) / push) * smooth((te - t) / push)
    s = 1 - 0.5 * p
    frame = Image.new("RGB", (W, H))
    sw, sh = round(W * s), round(H * s)
    frame.paste(sim.resize((sw, sh), Image.BILINEAR), (round(W / 2 - 960 * p - sw / 2), round(H / 2 - sh / 2)))
    if p > 0:
        x0, y0 = round(W / 2 - 960 * p - sw / 2), round(H / 2 - sh / 2)
        gap = round((sh - sh * 1803 / H) / 2)
        cover = Image.new("L", (sw, gap), round(255 * p))
        frame.paste((0, 0, 0), (x0, y0, x0 + sw, y0 + gap), cover)
        frame.paste((0, 0, 0), (x0, y0 + sh - gap, x0 + sw, y0 + sh), cover)
    frame.paste(pic, (round(W - (W / 2) * p), (H - ph) // 2))
    a = smooth((t - ts - push - 0.3) / 0.8) * smooth((te - push - t) / 0.6)
    if a > 0:
        tl = title.copy(); tl.putalpha(tl.getchannel("A").point(lambda v: int(v * a)))
        frame = Image.alpha_composite(frame.convert("RGBA"), tl).convert("RGB")
    enc.stdin.write(frame.tobytes())
enc.stdin.close(); enc.wait()
graph = (f"[0:v]trim=0:{ts},setpts=PTS-STARTPTS[a];[1:v]setpts=PTS-STARTPTS[b];"
         f"[0:v]trim=start={ts + n / FPS},setpts=PTS-STARTPTS[c];[a][b][c]concat=n=3:v=1,format=yuv420p10le[v]")
subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", shot, "-i", seg, "-filter_complex", graph, "-map", "[v]",
                "-c:v", "libx265", "-preset", os.environ.get("X265_PRESET", "medium"), "-crf", "14",
                "-pix_fmt", "yuv420p10le", "-tag:v", "hvc1", "-movflags", "+faststart", out], check=True)
