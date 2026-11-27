#!/usr/bin/env bash
# Fetches the Antennae pictures again into references/antennae/pictures (run on the Mac: a cloud
# machine cannot reach these hosts), builds the panel and the checks.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"; p="$here/pictures"; mkdir -p "$p"
curl -fsSL --max-time 600 -o "$p/antennae-ls-wide.jpg" \
  "https://www.legacysurvey.org/viewer/jpeg-cutout?ra=180.452&dec=-18.885&width=3000&height=3000&layer=ls-dr10&pixscale=0.40"
curl -fsSL -o "$p/heic0615a.tif" https://esahubble.org/media/archives/images/original/heic0615a.tif
python3 -I - "$p" <<'P'
import sys
from PIL import Image
Image.MAX_IMAGE_PIXELS = None
p = sys.argv[1]
Image.open(f"{p}/heic0615a.tif").convert("RGB").save(f"{p}/heic0615a-large.jpg", quality=95)
P
"$here/tools/panel.py" "$p/antennae-ls-wide.jpg" "$p"
"$here/tools/frame.py" "$p/antennae-ls-wide.jpg" "$p/heic0615a.tif" "$p"
