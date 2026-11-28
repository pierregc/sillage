"""sheet25.py <work dir> <picture> <out.jpg>: the sheet of 25 from <work>/final25.csv and the stills of
finalstills.sh: the wide panel, then one tile a finalist (its number, score, time since each passage, a flag
when its score moved more than the gap to the 26th between its two runs), five to a row; under them a strip for
each of the best five: the approach, the impact (the first passage) and the matched moment, from the matched view."""
import csv, os, sys
from PIL import Image, ImageDraw, ImageFont

W, H = 384, 432
font = ImageFont.truetype("/System/Library/Fonts/Avenir Next.ttc", 18, index=5)
small = ImageFont.truetype("/System/Library/Fonts/Avenir Next.ttc", 14, index=0)

def tile(path, lines):
    im = Image.open(path).convert("RGB").resize((W, H), Image.LANCZOS) if os.path.exists(path) else Image.new("RGB", (W, H), (40, 0, 0))
    d = ImageDraw.Draw(im)
    for k, t in enumerate(lines):
        d.text((10, 8 + 21 * k), t, font=font if k == 0 else small, fill=(255, 255, 255))
    return im

def main(work, picture, out):
    rows = list(csv.DictReader(open(f"{work}/final25.csv")))
    tiles = [tile(picture, ["wide picture", "Legacy Surveys DR10, 102.5 kpc across"])]
    for r in rows:
        s = f"{work}/lib/{r['name']}/stills"
        p2 = f", {float(r['since_peri2']):+.0f} after the 2nd" if r.get("since_peri2") else ""
        tiles.append(tile(f"{s}/match.png", [f"{r['rank']}  score {float(r['score']):.3f}" + ("  noisy" if r["noise_flag"] else ""),
                                             f"{float(r['since_peri1']):+.0f} Myr after the 1st passage{p2}",
                                             f"family {r['family']}, 200 k score {float(r['score_200k']):.3f}"]))
    cols = 5; grid = (len(tiles) + cols - 1) // cols
    strips = [[tile(f"{work}/lib/{r['name']}/stills/{k}.png", [f"{r['rank']}  {label}"]) for k, label in
               (("approach", "approach"), ("impact", "impact, 1st passage"), ("match", "matched moment"))] for r in rows[:5]]
    sheet = Image.new("RGB", (cols * W, (grid + len(strips)) * H + 40), (12, 12, 12))
    for i, im in enumerate(tiles):
        sheet.paste(im, ((i % cols) * W, (i // cols) * H))
    d = ImageDraw.Draw(sheet); y0 = grid * H
    d.text((10, y0 + 8), "The best five: approach, impact, matched moment (same view)", font=font, fill=(255, 255, 255))
    for j, strip in enumerate(strips):
        for i, im in enumerate(strip):
            sheet.paste(im, (i * W, y0 + 40 + j * H))
    sheet.save(out, quality=86)

if __name__ == "__main__":
    main(*sys.argv[1:4])
