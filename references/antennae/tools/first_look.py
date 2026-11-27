"""first_look.py <karl|privon> <out.png> [key=value ...]: a cloud check of a scene's conventions,
not a run. Test particles in the two galaxies' rigid mass profiles (make_scene.py's), the centres
on their mutual orbit with a drag inside 80 kpc that stands in for the live halos' and brings the
second passage near the paper's (0.017 for Privon, 0.0125 for Karl: drag=k), drawn from the
paper's view on its sky (x' right, y' up) at three moments after the first pericentre. Only to
catch a tail on the wrong side: nothing is tuned on it. turn=deg: the paper's
frame takes Sillage's pericentre line turned that much about z. Overrides go to make_scene.py."""
import math, os, sys
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import make_scene as ms

TU = 4.714  # Myr per Sillage time unit


def enclosed(g):
    M, a, f = g["potential"]["mass"], g["potential"]["scaleRadius"], g["diskMassFraction"]
    halo, stellar = M * (1 - f) / ms.kept(g["haloExtent"]), M * f
    mb = stellar * g["bulgeFraction"]; md = stellar - mb
    ad = g["diskScaleLength"]; ab = g["bulgeExtent"] * ad
    edge = g["haloExtent"] * a
    return lambda r: (halo * (np.minimum(r, edge) / (np.minimum(r, edge) + a)) ** 2
                      + mb * (r / (r + ab)) ** 2 + md * (1 - np.exp(-r / ad) * (1 + r / ad)))


def run(scene, view, since, drag, n=4000, dt=0.1):
    g = scene["galaxies"]; mass = [enclosed(g[0]), enclosed(g[1])]
    e = scene["encounters"][0]; q = e["pericentre"]; tp = e["pericentreTime"] / TU
    rr = np.linspace(q, 3000, 200000); pull = (mass[0](rr) + mass[1](rr)) / rr ** 2
    v = math.sqrt(2 * (np.trapezoid(pull, rr) + (mass[0](3000) + mass[1](3000)) / 3000))
    x, u = np.array([q, 0, 0.]), np.array([0, v, 0.])
    rel = lambda d: -(mass[0](np.linalg.norm(d)) + mass[1](np.linalg.norm(d))) / np.linalg.norm(d) ** 3 * d
    for _ in range(int(tp / dt)):
        u -= rel(x) * dt / 2; x -= u * dt; u -= rel(x) * dt / 2
    C, CV = np.array([-x / 2, x / 2]), np.array([-u / 2, u / 2])
    rng = np.random.default_rng(1); P, V, who = [], [], []
    for k, name in enumerate(("NGC 4038", "NGC 4039")):
        s = np.array(view["spins"][name]); s /= np.linalg.norm(s)
        t = np.cross(s, [1, 0, 0]); t /= np.linalg.norm(t); w = np.cross(s, t)
        ad, cut = g[k]["diskScaleLength"], g[k]["diskTruncation"]
        R = rng.gamma(2, ad, 3 * n); R = R[R < cut * ad][:n]; phi = rng.uniform(0, 2 * np.pi, len(R))
        p = (np.cos(phi)[:, None] * t + np.sin(phi)[:, None] * w) * R[:, None]
        P.append(p + C[k]); V.append(np.cross(s, p / R[:, None]) * np.sqrt(mass[k](R) / R)[:, None] + CV[k])
        who.append(np.full(len(R), k))
    P, V, who = np.vstack(P), np.vstack(V), np.concatenate(who)

    def accel(P, C):
        a = np.zeros_like(P)
        for c, m in zip(C, mass):
            d = P - c; r = np.linalg.norm(d, axis=1) + 0.3
            a -= (m(r) / r ** 3)[:, None] * d
        return a

    def centres(C, CV, t):
        d = C[1] - C[0]; r = np.linalg.norm(d)
        f = np.array([mass[1](r) / r ** 3 * d, -mass[0](r) / r ** 3 * d])
        if t > tp - 20 / TU and r < 80:
            f += np.array([1, -1])[:, None] * drag * (CV[1] - CV[0]) / 2
        return f

    out, t, want = [], 0.0, [tp * TU + s for s in since]
    while len(out) < len(want):
        V += accel(P, C) * dt / 2; CV += centres(C, CV, t) * dt / 2
        P += V * dt; C += CV * dt; t += dt
        V += accel(P, C) * dt / 2; CV += centres(C, CV, t) * dt / 2
        if t * TU >= want[len(out)]:
            out.append((P.copy(), C.copy()))
    return out, who


def main(argv):
    model, path, rest = argv[0], argv[1], dict(a.split("=", 1) for a in argv[2:])
    drag = float(rest.pop("drag", 0.017 if model == "privon" else 0.0125))
    turn = math.radians(float(rest.pop("turn", (ms.KARL if model == "karl" else ms.PRIVON)["turn"])))
    scene, view = ms.build(model, rest)
    since = [150, 230, 260] if model == "privon" else [300, 450, 600]
    out, who = run(scene, view, since, drag)
    import matplotlib; matplotlib.use("Agg"); import matplotlib.pyplot as plt
    # turn: where the paper's frame puts the pericentre, degrees about z from Sillage's +x
    R = np.array(ms.rotation(view["paperAngles"])) @ np.array(ms.rotation((0, 0, -math.degrees(turn))))
    fig, axes = plt.subplots(1, 3, figsize=(15, 5.6))
    for ax, s, (P, C) in zip(axes, since, out):
        p = (P - C.mean(0)) @ R.T; c = (C - C.mean(0)) @ R.T
        for k, colour in ((0, "red"), (1, "green")):
            ax.scatter(p[who == k, 0], p[who == k, 1], s=0.3, c=colour)
        ax.plot(c[:, 0], c[:, 1], "k+", ms=12)
        ax.set_aspect("equal"); ax.set_xlim(-80, 80); ax.set_ylim(-90, 70)
        ax.set_title(f"{model}, node {view['node']}, turn {math.degrees(turn):.0f}: {s} Myr after", fontsize=9)
    fig.suptitle("NGC 4038 red, NGC 4039 green, north up, west right, kpc")
    fig.tight_layout(); fig.savefig(path, dpi=70)


if __name__ == "__main__":
    main(sys.argv[1:])
