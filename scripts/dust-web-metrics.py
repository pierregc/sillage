#!/usr/bin/env python3
"""Where a still's dust structure lives, for the dust web spike (#173).

    dust-web-metrics.py <no-dust.png> <with-dust.png>...

The dust is read as the log of the luminance a still keeps against the same still drawn with no
dust, over the body of the galaxy (where the dustless still stands above a floor). Its variance
is split into three bands by differences of blurs: under 3 px (`fine`, filaments), 3 to 12 px
(`mid`, strands and lanes' edges) and 12 to 48 px (`coarse`, lanes). `depth` is the mean dimming.
"""

import os
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from grain import blur, luminance  # noqa: E402


def bands(reference, path):
    clear = luminance(reference)
    dusty = luminance(path)
    body = blur(clear, 4.0) > 0.12
    kept = np.log(np.maximum(dusty, 1e-3)) - np.log(np.maximum(clear, 1e-3))
    kept = np.where(body, kept, 0.0).astype(np.float32)
    levels = [kept] + [blur(kept, r) for r in (1.5, 6.0, 24.0)]
    parts = [levels[i] - levels[i + 1] for i in range(3)]
    total = sum(float(np.mean(p[body] ** 2)) for p in parts)
    shares = [float(np.mean(p[body] ** 2)) / max(total, 1e-12) for p in parts]
    return {
        "depth": float(-np.mean(kept[body])),
        "rms": float(np.sqrt(total)),
        "fine": shares[0],
        "mid": shares[1],
        "coarse": shares[2],
    }


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    print("image\tdepth\trms\tfine\tmid\tcoarse")
    for path in argv[2:]:
        m = bands(argv[1], path)
        print("%s\t%.3f\t%.3f\t%.2f\t%.2f\t%.2f" % (
            os.path.basename(path), m["depth"], m["rms"], m["fine"], m["mid"], m["coarse"]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
