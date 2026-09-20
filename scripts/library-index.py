#!/usr/bin/env python3
"""Contact sheet for a night of scripts/library.sh output: index.csv -> index.html."""

import csv
import html
import os
import sys

STYLE = """
:root { color-scheme: dark }
body { background: #0b0b0d; color: #d8d8dc; font: 14px/1.5 -apple-system, sans-serif;
       margin: 0; padding: 32px }
h1 { font-size: 16px; font-weight: 500; margin: 0 0 4px }
.sub { color: #76767e; margin-bottom: 28px }
.scene { display: flex; gap: 20px; padding: 16px 0; border-top: 1px solid #1d1d22 }
video { width: 480px; background: #000; border-radius: 3px }
.meta { min-width: 0 }
.id { font-size: 15px }
.id .status { color: #c2603f; margin-left: 8px }
dl { display: grid; grid-template-columns: max-content auto; gap: 2px 14px; margin: 10px 0 }
dt { color: #76767e }
dd { margin: 0 }
code { display: block; background: #15151a; color: #9fb0c0; padding: 8px 10px;
       border-radius: 3px; font-size: 12px; overflow-x: auto; white-space: pre; user-select: all }
.empty { color: #76767e }
"""


def whole(row, key, default=0):
    try:
        return int(float(row.get(key) or default))
    except (TypeError, ValueError):
        return default


def size(count):
    if count <= 0:
        return "-"
    value = float(count)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if value < 1024 or unit == "TB":
            return "%d %s" % (value, unit) if unit == "B" else "%.1f %s" % (value, unit)
        value /= 1024


def duration(row):
    frames, fps = whole(row, "frames"), whole(row, "fps", 60)
    if frames <= 0 or fps <= 0:
        return "-"
    return "%.0f s (%d frames)" % (frames / fps, frames)


def rows_of(path):
    """Whatever the file yields. A partial or garbled index is still worth a page."""
    rows = []
    try:
        with open(path, newline="", encoding="utf-8", errors="replace") as handle:
            reader = csv.DictReader(handle)
            if not reader.fieldnames or "id" not in reader.fieldnames:
                return rows
            for row in reader:
                if row.get("id"):
                    rows.append(row)
    except csv.Error as error:
        print("index.csv truncated at row %d: %s" % (len(rows) + 1, error), file=sys.stderr)
    except OSError as error:
        print(error, file=sys.stderr)
    # A retried scene appends a second row; the last one is the one that stands.
    return list({row["id"]: row for row in rows}.values())


# The tempo is not stored as its parameters, only as its name, so the mapping lives here too.
TEMPOS = {
    "derive": (0.0, 2, 1, 1), "lent": (0.2, 4, 2, 2), "proche": (0.7, 6, 3, 2),
    "pose": (0.5, 8, 4, 2), "trio": (0.6, 9, 5, 3), "large": (0.9, 12, 7, 2),
    "quatuor": (0.8, 12, 8, 4), "ballet": (1.0, 16, 11, 4),
}
IMMERSED = {"derive", "lent", "proche"}


def rerender(row):
    tempo = row.get("tempo", "")
    haste, scale, per_frame, galaxies = TEMPOS.get(tempo, TEMPOS["pose"])
    frames = max(whole(row, "frames", 900), 1)
    return (
        "./scripts/dev.sh render --preset contemplation --director --solver barnes-hut"
        " --seed %s --particles %d --galaxies %d%s --haste %s --dt-scale %d --settle 400"
        " --steps %d --frames %d --width 3840 --height 2160 --video %s-4k.mov"
        % (row.get("seed", "?"), max(whole(row, "particles", 700000), 1) * 2,
           whole(row, "galaxies", galaxies) or galaxies,
           " --immersed" if tempo in IMMERSED else "",
           haste, scale, frames * per_frame, frames, row["id"])
    )


def card(row, directory):
    ident = row["id"]
    status = row.get("status") or "?"
    video = ident + ".mov"
    playable = os.path.exists(os.path.join(directory, video))
    parts = ['<div class="scene">']
    if playable:
        parts.append(
            '<video muted loop playsinline controls preload="metadata" src="%s"></video>'
            % html.escape(video)
        )
    else:
        parts.append('<div class="meta empty">no video</div>')
    parts.append('<div class="meta"><div class="id">%s%s</div><dl>' % (
        html.escape(ident),
        "" if status == "ok" else '<span class="status">%s</span>' % html.escape(status)))
    fields = [
        ("seed", html.escape(str(row.get("seed", "?")))),
        ("tempo", "%s, %s galaxies" % (html.escape(str(row.get("tempo", "?"))),
                                       html.escape(str(row.get("galaxies", "?"))))),
        ("durée", duration(row)),
        ("taille", "%s vidéo, %s prise" % (size(whole(row, "video_bytes")),
                                           size(whole(row, "take_bytes")))),
        ("rendu", "%s x %s, %s particules, %s s"
                  % (html.escape(str(row.get("width", "?"))),
                     html.escape(str(row.get("height", "?"))),
                     html.escape(str(row.get("particles", "?"))),
                     html.escape(str(row.get("wall_seconds", "?"))))),
    ]
    for name, value in fields:
        parts.append("<dt>%s</dt><dd>%s</dd>" % (name, value))
    parts.append("</dl><code>%s</code></div></div>" % html.escape(rerender(row)))
    return "\n".join(parts)


def main(argv):
    directory = argv[1] if len(argv) > 1 else "."
    rows = rows_of(os.path.join(directory, "index.csv"))
    failed = sum(1 for row in rows if (row.get("status") or "") != "ok")
    body = "\n".join(card(row, directory) for row in rows)
    if not body:
        body = '<p class="empty">index.csv is empty or unreadable.</p>'
    page = (
        "<!doctype html>\n<html lang=\"fr\"><head><meta charset=\"utf-8\">"
        "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
        "<title>%s</title><style>%s</style></head><body>\n"
        "<h1>%s</h1>\n<div class=\"sub\">%d scènes, %d en échec. "
        "Les vidéos sont muettes exprès.</div>\n%s\n</body></html>\n"
        % (html.escape(os.path.basename(os.path.abspath(directory))), STYLE,
           html.escape(os.path.basename(os.path.abspath(directory))), len(rows), failed, body)
    )
    target = os.path.join(directory, "index.html")
    with open(target, "w", encoding="utf-8") as handle:
        handle.write(page)
    print("%s: %d scenes" % (target, len(rows)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
