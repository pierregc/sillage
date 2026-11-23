#!/usr/bin/env bash
# sheet.sh <out.jpg> <scene>...: each scene's matched frame in the look, framed like the picture, one tile each
C="$HOME/claude-workspace/ngc2207"; out="$1"; shift; LOOK="${LOOK:-$C/looks/ngc2207-a.look.json}"; tiles=()
mkdir -p "$C/out/sheet"
for n in "$@"; do
  s="$C/lib/sweep/$n"; [ -d "$s" ] || s="$C/lib/$n"
  t="$C/out/sheet/tile-$n.png"
  if [ ! -s "$t" ]; then
    "$C/tools/gpu.sh" "key-$n" "$C/tools/photokey.sh" "$s" "$LOOK" "$C/out/sheet/key-$n.png" || continue
    row=$(grep "^$n," "$C/logs/sweep.csv" | tail -1)
    python3 - "$C/out/sheet/key-$n.png" "$t" "$n" "$row" <<'PY'
import sys
from PIL import Image, ImageDraw, ImageFont
im = Image.open(sys.argv[1]).convert("RGB"); w, h = im.size; bh = round(w * 2983 / 6353)
im = im.crop((0, (h - bh) // 2, w, (h - bh) // 2 + bh)).resize((768, 361), Image.LANCZOS)
d = ImageDraw.Draw(im); f = ImageFont.truetype("/System/Library/Fonts/Avenir Next.ttc", 17, index=5)
r = sys.argv[4].split(",")
txt = f"{sys.argv[3]}   score {r[1]}   {r[3]} Myr after the passage" if len(r) > 3 else sys.argv[3]
d.text((10, 8), txt, font=f, fill=(255, 255, 255)); im.save(sys.argv[2])
PY
  fi
  tiles+=("$t")
done
python3 - "$out" "$C/ref/heic2414a-large.jpg" "${tiles[@]}" <<'PY'
import sys
from PIL import Image, ImageDraw, ImageFont
out, ref, files = sys.argv[1], sys.argv[2], sys.argv[3:]
pic = Image.open(ref).convert("RGB").resize((768, 361), Image.LANCZOS)
d = ImageDraw.Draw(pic); f = ImageFont.truetype("/System/Library/Fonts/Avenir Next.ttc", 17, index=5)
d.text((10, 8), "Webb + Hubble (heic2414a)", font=f, fill=(255, 255, 255))
ims = [pic] + [Image.open(x).convert("RGB") for x in files]
cols = 2; rows = (len(ims) + cols - 1) // cols
sheet = Image.new("RGB", (cols * 768, rows * 361))
for i, im in enumerate(ims):
    sheet.paste(im, ((i % cols) * 768, (i // cols) * 361))
sheet.save(out, quality=88)
PY
