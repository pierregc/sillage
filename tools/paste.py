#!/usr/bin/env python3
"""paste.py <tag> [count]: small procedural background galaxies added to the tag's 4K stills where
the frame is sky, as <tag>-bg. For the sheet only (#315 step 6)."""
import glob, os, sys
import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
SET = os.environ.get("SET", "mice")
STILLS = os.path.join(HERE, "stills", SET)
SMALL = os.path.join(HERE, "stills", SET + "-960")
THUMBS = sorted(glob.glob(os.path.expanduser("~/claude-workspace/sillage/library/2026-11-13/scene-*/thumbnail.png")))


def lin(a):
    return np.where(a <= 0.04045, a / 12.92, ((a + 0.055) / 1.055) ** 2.4)


def enc(a):
    a = np.clip(a, 0, 1)
    return np.where(a <= 0.0031308, a * 12.92, 1.055 * a ** (1 / 2.4) - 0.055)


def sprites(rng, n=48):
    """Sersic-like ellipses: warm ellipticals and neutral disks, as a deep field shows them."""
    out = []
    for _ in range(n):
        size = 64
        yy, xx = np.mgrid[0:size, 0:size] - (size - 1) / 2
        elliptical = rng.random() < 0.45
        q = rng.uniform(0.55, 1.0) if elliptical else rng.uniform(0.2, 0.8)
        t = rng.uniform(0, np.pi)
        u = xx * np.cos(t) + yy * np.sin(t)
        v = (-xx * np.sin(t) + yy * np.cos(t)) / q
        r = np.hypot(u, v) / (size / 9)
        profile = np.exp(-7.67 * (r ** 0.25 - 1)) if elliptical else np.exp(-1.68 * (r - 1)) + 2.5 * np.exp(-(r / 0.25) ** 2)
        profile = profile / profile.max() * np.clip(1 - np.hypot(xx, yy) / (size / 2), 0, 1)
        tone = np.array([1.15, 0.98, 0.76]) if elliptical else np.array([0.97, 1.0, 1.05])
        out.append(profile[..., None] * tone)
    return out


def paste(tag, count):
    rng = np.random.default_rng(315)
    pool = sprites(rng)
    for big in sorted(glob.glob(os.path.join(STILLS, f"{tag}-*.png"))):
        name = os.path.basename(big)
        if "-bg-" in name:
            continue
        moment, frame = name[len(tag) + 1:-4].rsplit("-", 1)
        im = lin(np.asarray(Image.open(big).convert("RGB"), dtype=np.float64) / 255)
        h, w = im.shape[:2]
        y = im @ np.array([0.2126, 0.7152, 0.0722])
        sky = np.percentile(y, 5)
        local = np.asarray(Image.fromarray((np.clip(y, 0, 1) * 255).astype(np.uint8)).resize((w // 16, h // 16), Image.BOX), dtype=np.float64) / 255
        r2 = np.random.default_rng(315)
        placed = 0
        for _ in range(count * 20):
            if placed == count:
                break
            x0, y0 = r2.integers(0, w), r2.integers(0, h)
            if local[min(y0 // 16, local.shape[0] - 1), min(x0 // 16, local.shape[1] - 1)] > lin(0.04) + sky:
                continue
            sprite = pool[r2.integers(len(pool))]
            size = int(np.exp(r2.uniform(np.log(24), np.log(110))))
            angle = r2.uniform(0, 360)
            s = Image.fromarray((np.clip(sprite / 1.2, 0, 1) * 255).astype(np.uint8))
            s = np.asarray(s.resize((size, size), Image.LANCZOS), dtype=np.float64) / 255 * 1.2
            gain = 10 ** r2.uniform(-1.3, -0.3)
            sh, sw = s.shape[:2]
            if x0 + sw >= w or y0 + sh >= h:
                continue
            im[y0:y0 + sh, x0:x0 + sw] += s * gain
            placed += 1
        out = np.clip(enc(im) * 255 + 0.5, 0, 255).astype(np.uint8)
        Image.fromarray(out).save(os.path.join(STILLS, f"{tag}-bg-{moment}-{frame}.png"))
        Image.fromarray(out).resize((960, 540), Image.LANCZOS).save(os.path.join(SMALL, f"{tag}-bg-{moment}.png"))
        print("pasted", placed, "into", name)


if __name__ == "__main__":
    paste(sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 30)
