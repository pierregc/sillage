"""The Antennae (NGC 4038/9) as Karl et al. 2010 or Privon et al. 2013 modelled them.

usage: make_scene.py <out folder> <karl|privon> [--template scene.json] [key=value ...]

Writes <out>/scene.json and <out>/view.json. Without a template the galaxies are built from
scratch; with one, its first two galaxies give the fields the papers do not set (arms, dust,
clumps). Overrides: pericentre, eccentricity, pericentreTime (Myr), i1, w1, i2, w2 (degrees,
Toomre and Toomre's angles), node (descending or ascending), turn (degrees from Sillage's
pericentre line to the paper's x, for view.json), truncation (scale lengths),
haloExtent (scale radii), q (Toomre Q), seed, diskScale (both disks' scale lengths and heights
times this), massRatio (NGC 4039's mass over NGC 4038's: its potential's mass times the ratio, its
scale radius and disk times its square root, as for NGC 2207). NGC 4038 is the primary, NGC 4039 the secondary, both prograde.

Toomre and Toomre's (i, w) are read for each disk against its own companion's orbit: z along
the orbit's angular momentum, x towards the companion at pericentre, w counted in the orbit
plane from a node to the pericentre, along the motion. Toomre and Toomre leave the node open:
from the descending one (the companion goes down through the disk, away from its spin side) the
spin is (-sin i sin w, -sin i cos w, cos i); from the ascending one, (sin i sin w, sin i cos w,
cos i), the same disk turned half a turn about z, which draws the mirror image from a view near
the orbit plane. The descending reading is the default: it draws Privon et al.'s tails on the
sides their figure 6a shows (docs/notes/antennae.md); node=ascending gives the other.
Sillage counts a disk's argument from the primary-to-secondary pericentre line for both disks,
with the axis (sin i sin a, -sin i cos a, cos i): from the descending node a = -w for the primary
and 180 - w for the secondary, whose companion lies the other way; from the ascending node
180 - w and -w.
"""
import json, math, os, sys

G = 4.30091e-6  # kpc (km/s)^2 / Msun
MASS = 1e10  # Sillage's mass unit, Msun

# Karl et al. 2010 (arXiv:1003.0685), Table 1 and section 2: equal masses, Mvir 5.52e11 Msun,
# Hernquist halo of concentration 15 (Springel, Di Matteo and Hernquist 2005), disk 0.075 and
# bulge 0.025 of Mvir, a fifth of the disk in gas, r_vir 168 kpc, pericentre 10.4 kpc, both
# disks inclined 60 degrees, arguments 30 (NGC 4038) and 60 (NGC 4039); best match 1.24 Gyr,
# 40 Myr after the second passage, about 600 after the first; view (93, 69, 253.5) about x, y, z.
KARL = dict(
    cite="Karl, Naab, Johansson, Kotarba, Boily, Renaud and Theis 2010, ApJL 715, L88 (arXiv:1003.0685)",
    mvir=55.2, c=15.0, rvir=168.0, disk=0.075, bulge=0.025, gas=0.2,
    scale=(6.28, 4.12), height=(1.26, 0.82), bulgeScale=(1.26, 0.82),
    pericentre=10.4, eccentricity=1.0, i=(60.0, 60.0), w=(30.0, 60.0),
    sinceFirst=600.0, secondToView=40.0, toMerger=50.0,
    view=(93.0, 69.0, 253.5), turn=180.0, distanceMpc=30.8, lengthScale=1.4,
)

# Privon et al. 2013 (arXiv:1305.5865), Table 1 and sections 3.4 and 4.3: Identikit, equal
# masses, parabolic, p = 0.25 of L = 19.7 kpc, V = 265 km/s, disks (65, 345) and (70, 95), seen
# 3.62 time units (260 Myr) after the first pericentre at t = 5.62, 70 Myr before the merger,
# view (-20, 283, -5). Mass model of Barnes and Hibbard 2009: NFW halo of scale 0.25, Hernquist
# bulge of scale 0.02, exponential disk of scale 1/12; halo 80 % of the mass, bulge and disk 20 %
# (taken as 1 : 3, the particle counts 8k : 24k at equal masses); circular speed 1.26 V at three
# disk scale lengths.
PRIVON = dict(
    cite="Privon, Barnes, Evans, Hibbard, Yun, Mazzarella, Armus and Surace 2013, ApJ 771, 120 (arXiv:1305.5865)",
    L=19.7, V=265.0, p=0.25, halo=0.8, bulge=0.05, disk=0.15, ad=1 / 12, ab=0.02, ah=0.25, vc3=1.26,
    gas=0.2, eccentricity=1.0, i=(65.0, 70.0), w=(345.0, 95.0),
    sinceFirst=260.0, toMerger=70.0, view=(-20.0, 283.0, -5.0), turn=0.0, tView=5.62, tPeri=2.0,
)


def hernquist_from_nfw(m200, c, r200):
    """Springel, Di Matteo and Hernquist 2005, eq. 2: the Hernquist scale whose inner density
    is the NFW halo's of the same mass."""
    rs = r200 / c
    return rs * math.sqrt(2 * (math.log(1 + c) - c / (1 + c)))


def kept(extent):
    """Share of a Hernquist mass inside `extent` scale radii."""
    return (extent / (extent + 1)) ** 2


def karl_galaxies(m, extent):
    a = hernquist_from_nfw(m["mvir"], m["c"], m["rvir"])
    stellar = (m["disk"] + m["bulge"]) * m["mvir"]
    # Sillage's live halo carries its whole mass inside haloExtent; Karl's Hernquist halo runs
    # on. The halo is given the mass Karl's holds inside that edge, so the profile inside is his.
    halo = (1 - m["disk"] - m["bulge"]) * m["mvir"] * kept(extent)
    total = halo + stellar
    out = []
    for k in range(2):
        out.append(dict(mass=total, scaleRadius=a, diskMassFraction=stellar / total,
                        bulgeFraction=m["bulge"] / (m["disk"] + m["bulge"]),
                        diskScaleLength=m["scale"][k], diskThickness=m["height"][k],
                        bulgeExtent=m["bulgeScale"][k] / m["scale"][k], dust=m["gas"]))
    return out


def privon_galaxies(m, extent):
    """An NFW halo has no Sillage profile: the Hernquist halo here holds the Identikit halo's
    mass inside its edge and the mass inside three disk scale lengths that gives the paper's
    circular speed there."""
    unit = m["V"] ** 2 * m["L"] / G / MASS
    total = (m["halo"] + m["bulge"] + m["disk"]) / m["halo"] * unit  # halo = 1 Identikit unit
    halo = total * m["halo"] / (m["halo"] + m["bulge"] + m["disk"])
    stellar = total - halo
    mb = stellar * m["bulge"] / (m["bulge"] + m["disk"])
    md = stellar - mb
    ad, ab = m["ad"] * m["L"], m["ab"] * m["L"]
    r = 3 * ad
    vc = m["vc3"] * m["V"]
    inside = vc * vc * r / G / MASS
    baryons = mb * (r / (r + ab)) ** 2 + md * (1 - math.exp(-3) * 4)
    want = (inside - baryons) * kept(extent) / halo  # (r / (r + a))^2
    a = r / math.sqrt(want) - r
    return [dict(mass=total, scaleRadius=a, diskMassFraction=stellar / total,
                 bulgeFraction=mb / stellar, diskScaleLength=ad, diskThickness=0.1 * ad,
                 bulgeExtent=m["ab"] / m["ad"], dust=m["gas"]) for _ in range(2)]


def sillage_argument(w, primary, node):
    turn = 0 if node == "descending" else 180
    return math.radians((turn - w) if primary else (180 - turn - w)) % (2 * math.pi)


def toomre_spin(i, w, primary, node):
    """The spin in Sillage's orbit frame (x from primary to secondary at pericentre)."""
    i, w = math.radians(i), math.radians(w)
    side = (1 if node == "ascending" else -1) * (1 if primary else -1)
    return [side * math.sin(i) * math.sin(w), side * math.sin(i) * math.cos(w), math.cos(i)]


def rotation(angles):
    """Rotations about x, then y, then z, by the given degrees: R = Rz Ry Rx."""
    ax, ay, az = (math.radians(v) for v in angles)
    cx, sx, cy, sy, cz, sz = math.cos(ax), math.sin(ax), math.cos(ay), math.sin(ay), math.cos(az), math.sin(az)
    rx = [[1, 0, 0], [0, cx, -sx], [0, sx, cx]]
    ry = [[cy, 0, sy], [0, 1, 0], [-sy, 0, cy]]
    rz = [[cz, -sz, 0], [sz, cz, 0], [0, 0, 1]]
    mul = lambda p, q: [[sum(p[r][k] * q[k][c] for k in range(3)) for c in range(3)] for r in range(3)]
    return mul(rz, mul(ry, rx))


def match_view(angles, sky, turn=0.0):
    """The match's elevation, azimuth and roll that draw the paper's projection. R takes the
    simulation to (x', y', z'). 'sky' reads x' to the right (west on a north-up picture), y' up
    (north) and z' towards the viewer: both papers draw their sky panels so, the southern tail's
    tip to the west as on the sky. 'mirror' reads x' as east (left), y' north and z' away.
    `turn`: the papers do not say where their pericentre lies; their x is taken as Sillage's
    pericentre line turned that many degrees about z."""
    mul = lambda p, q: [[sum(p[r][k] * q[k][c] for k in range(3)) for c in range(3)] for r in range(3)]
    R = mul(rotation(angles), rotation((0, 0, -turn)))
    xp, yp, zp = R[0], R[1], R[2]
    if sky == "mirror":
        right, down, toward = [-v for v in xp], [-v for v in yp], [-v for v in zp]
    else:
        right, down, toward = xp, [-v for v in yp], zp
    e = math.asin(max(-1, min(1, toward[2])))
    a = math.atan2(toward[0], -toward[1])
    cam_x = [math.cos(a), math.sin(a), 0]
    cam_y = [math.sin(a) * math.sin(e), -math.cos(a) * math.sin(e), -math.cos(e)]
    dot = lambda p, q: sum(u * v for u, v in zip(p, q))
    roll = math.atan2(-dot(right, cam_y), dot(right, cam_x))
    return dict(elevation=round(math.degrees(e), 3), azimuth=round(math.degrees(a) % 360, 3),
                roll=round(math.degrees(roll), 3))


def spiral(name, g, extent, truncation, q, template):
    base = dict(
        armCount=2, armIrregularity=0.45, armMassContrast=0.4, armPitch=0.45, armStreaming=1,
        armStrength=0.5, bulgeFlattening=0.8, clumpiness=0.04, dissipationTime=300,
        dustFraction=g["dust"], dustMassFraction=g["dust"], haloParticleRatio=1.5,
        kind="spiral", massLopsidedness=0.03, outskirtFraction=0.12, patternShare=0.9,
        starFormingFraction=0.05, velocityDispersion=0.05, youngClumpiness=0.45)
    if template:
        base.update({k: v for k, v in template.items() if k in base and k not in ("dustFraction", "dustMassFraction", "kind", "haloParticleRatio")})
    base.update(
        name=name, potential={"mass": round(g["mass"], 4), "profile": "hernquist", "scaleRadius": round(g["scaleRadius"], 4)},
        diskMassFraction=round(g["diskMassFraction"], 5), bulgeFraction=round(g["bulgeFraction"], 5),
        diskScaleLength=round(g["diskScaleLength"], 4), diskThickness=round(g["diskThickness"], 4),
        bulgeExtent=round(g["bulgeExtent"], 4), diskTruncation=truncation, haloExtent=extent,
        toomreQ=q, particleShare=0.5, position=[0, 0, 0], velocity=[0, 0, 0], inclination=0,
        positionAngle=0, spin="prograde")
    return base


def build(model, overrides, template=None):
    m = dict(KARL if model == "karl" else PRIVON)
    o = dict(overrides)
    extent = float(o.get("haloExtent", 12))
    truncation = float(o.get("truncation", 6))
    q = float(o.get("q", 1.5))
    node = o.get("node", "descending")
    if node not in ("descending", "ascending"):
        sys.exit("node is descending or ascending")
    i1, i2 = float(o.get("i1", m["i"][0])), float(o.get("i2", m["i"][1]))
    w1, w2 = float(o.get("w1", m["w"][0])), float(o.get("w2", m["w"][1]))
    if model == "karl":
        gals = karl_galaxies(m, extent)
        peri = m["pericentre"]
    else:
        gals = privon_galaxies(m, extent)
        peri = m["p"] * m["L"]
    peri = float(o.get("pericentre", peri))
    t = float(o.get("pericentreTime", 200))
    turn = float(o.get("turn", m["turn"]))
    size, ratio = float(o.get("diskScale", 1)), float(o.get("massRatio", 1))
    for g in gals:
        g["diskScaleLength"] *= size; g["diskThickness"] *= size
    if ratio != 1:
        gals[1] = dict(gals[1], mass=gals[1]["mass"] * ratio, scaleRadius=gals[1]["scaleRadius"] * math.sqrt(ratio),
                       diskScaleLength=gals[1]["diskScaleLength"] * math.sqrt(ratio),
                       diskThickness=gals[1]["diskThickness"] * math.sqrt(ratio))
    temps = (template or {}).get("galaxies", [None, None])
    galaxies = [spiral(n, g, extent, truncation, q, tp) for n, g, tp in zip(("NGC 4038", "NGC 4039"), gals, temps)]
    disk = lambda i, w, primary: {"inclination": round(math.radians(i), 6),
                                  "argument": round(sillage_argument(w, primary, node), 6), "spin": "prograde"}
    scene = dict(
        version=1, name="The Antennae after " + ("Karl et al. 2010" if model == "karl" else "Privon et al. 2013"),
        seed=int(o.get("seed", 20261127)), solver="restricted", timeStepScale=7, openingAngle=0.9,
        centerSoftening=1.2, galaxies=galaxies,
        encounters=[{"primary": 0, "secondary": 1, "pericentre": peri,
                     "eccentricity": float(o.get("eccentricity", m["eccentricity"])), "massRatio": ratio,
                     "pericentreTime": t, "primaryDisk": disk(i1, w1, True),
                     "secondaryDisk": disk(i2, w2, False), "planeTilt": 0, "planeTurn": 0,
                     "pericentreAngle": 0}])
    view = dict(
        model=model, cite=m["cite"], paperAngles=list(m["view"]),
        toomre={"NGC 4038": [i1, w1], "NGC 4039": [i2, w2]}, node=node,
        spins={"NGC 4038": [round(v, 6) for v in toomre_spin(i1, w1, True, node)],
               "NGC 4039": [round(v, 6) for v in toomre_spin(i2, w2, False, node)]},
        firstPericentreMyr=t, viewMyr=t + m["sinceFirst"], mergerMyr=t + m["sinceFirst"] + m["toMerger"],
        turn=turn, sky=match_view(m["view"], "sky", turn), mirror=match_view(m["view"], "mirror", turn))
    return scene, view


def main(argv):
    if len(argv) < 2 or argv[1] not in ("karl", "privon"):
        sys.exit(__doc__)
    out, model, rest = argv[0], argv[1], argv[2:]
    template = None
    if "--template" in rest:
        k = rest.index("--template")
        template = json.load(open(rest[k + 1]))
        rest = rest[:k] + rest[k + 2:]
    overrides = dict(a.split("=", 1) for a in rest)
    scene, view = build(model, overrides, template)
    os.makedirs(out, exist_ok=True)
    json.dump(scene, open(os.path.join(out, "scene.json"), "w"), indent=2, sort_keys=True)
    json.dump(view, open(os.path.join(out, "view.json"), "w"), indent=2, sort_keys=True)


if __name__ == "__main__":
    main(sys.argv[1:])
