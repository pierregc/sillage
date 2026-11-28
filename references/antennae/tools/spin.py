"""spin.py <scene folder> [match name] [myr]: each disk's spin from the take at the matched moment, against
the matched view: + when the disk turns counter-clockwise on the picture (its spin towards the viewer),
- when clockwise. The picture's own sense is the Karl et al. 2010 model's from its paper's view (it was
fitted on the HI velocities of Hibbard et al. 2001): `REFERENCE`, NGC 4038 then NGC 4039."""
import json, math, struct, sys
import numpy as np

REFERENCE = None  # filled in from the Karl run: see docs/notes/antennae.md

def spins(folder, myr):
    path = f"{folder}/take.sillage"
    f = open(path, "rb"); f.read(8); f.read(8)
    head = json.loads(f.read(struct.unpack("<Q", f.read(8))[0])); base = f.tell()
    n, g, frames = head["particleCount"], head["galaxyCount"], head["frameCount"]
    off = base + 7 * 4 * n
    fr = np.fromfile(path, np.float32, frames * 8, offset=off).reshape(frames, 8)
    off += frames * 8 * 4 + frames * 3 * 4
    sp = np.fromfile(path, np.float32, frames * g * 4, offset=off).reshape(frames, g, 4)
    i = int(np.argmin(abs(fr[:, 0] * 4.714 - myr)))
    return sp[i, :, :3]

def senses(folder, view, myr):
    e, a = math.radians(view["elevation"]), math.radians(view["azimuth"])
    toward = np.array([math.sin(a) * math.cos(e), -math.cos(a) * math.cos(e), math.sin(e)])
    return [float(s @ toward / np.linalg.norm(s)) for s in spins(folder, myr)]

if __name__ == "__main__":
    s = sys.argv[1]; name = sys.argv[2] if len(sys.argv) > 2 else "antennae"
    m = json.load(open(f"{s}/match/{name}.json"))
    myr = float(sys.argv[3]) if len(sys.argv) > 3 else m["megayears"]
    print(" ".join(f"{v:+.2f}" for v in senses(s, m["view"], myr)))
