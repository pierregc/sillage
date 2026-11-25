#!/usr/bin/env python3
"""contact.py VIDEO OUT.jpg TILE_W LABEL=SECONDS ...: frames of a video in a labelled sheet, three a row (#509)."""
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tools"))
import film_split  # noqa: E402

video, out, tw = sys.argv[1], sys.argv[2], int(sys.argv[3])
with tempfile.TemporaryDirectory() as work:
    items = []
    for i, arg in enumerate(sys.argv[4:]):
        label, at = arg.rsplit("=", 1)
        png = os.path.join(work, f"{i:02d}.png")
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-ss", at, "-i", video, "-frames:v", "1", png], check=True)
        items.append(f"{label}  {float(at):.1f} s={png}")
    film_split.sheet(out, tw, items)
print(out)
