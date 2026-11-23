"""film_flight.py <out.flight.json>: the Sombrero film, one continuous take of 100 s on a take running 204 to
448 Myr. Eye and aim carried by the galaxy in its disk's axes (x, y in the plane, z along the spin).
  0-12 s   far, 65 kpc across, time fast
  12-30 s  in to Hubble's framing (26.5 kpc across, 6 degrees above the plane, roll 5.6), time slows to a near stop
  30-55 s  down onto the ring's rim, a quarter turn along it 0.25 kpc above the dust, the bulge on the inner side
  55-70 s  through the dust and in to 3 kpc from the core, still turning
  70-80 s  out under the plane, facing the core
  80-100 s back to 80 kpc, 30 degrees above the plane, time fast: more than a turn of the ring"""
import json, math, sys
E = math.radians(6)
FOV = 2 * math.atan(65 / (16 / 9) / 2 / 200)          # 65 kpc across at 200 kpc
def disk(x, y, z): return {"galaxy": 0, "offset": [round(x, 3), round(y, 3), round(z, 3)], "disk": True}
def ring(phi, r, z): p = math.radians(phi); return disk(r * math.cos(p), r * math.sin(p), z)
core = disk(0, 0, 0)
view = lambda d: disk(0, -d * math.cos(E), d * math.sin(E))
keys = [
    {"at": 0, "myr": 205, "eye": view(200), "aim": core, "fov": round(FOV, 4), "roll": 0},
    {"at": 12, "myr": 240, "eye": view(170), "aim": core},
    {"at": 24, "myr": 256, "eye": view(100), "aim": core, "roll": 0.0977},
    {"at": 30, "myr": 258, "eye": view(81.4), "aim": core},
    # the rim on the near side, then a quarter turn with the rotation (counter-clockwise about +z)
    {"at": 37, "myr": 258.3, "eye": ring(-90, 8.0, 0.3), "aim": ring(-55, 7.4, 0.0), "fov": 1.0, "roll": 0, "pace": "nearness"},
    {"at": 43, "eye": ring(-67, 7.9, 0.25), "aim": ring(-32, 7.3, 0.0)},
    {"at": 49, "eye": ring(-44, 7.9, 0.25), "aim": ring(-9, 7.3, 0.0)},
    {"at": 55, "myr": 259, "eye": ring(-20, 7.9, 0.25), "aim": ring(15, 7.2, 0.0)},
    # through the dust and in, still turning
    {"at": 61, "eye": ring(5, 6.0, -0.05), "aim": ring(45, 4.0, -0.1), "pace": "nearness"},
    {"at": 70, "myr": 259.5, "eye": ring(40, 3.0, -0.35), "aim": ring(90, 2.5, -0.2)},
    # out under the plane, facing the core
    {"at": 78, "myr": 260, "eye": ring(80, 7.0, -2.5), "aim": core},
    # back out, time fast: 188 Myr, a turn and a half of the ring (about 125 Myr a turn)
    {"at": 88, "myr": 300, "eye": ring(60, 30, -6), "aim": core, "fov": 0.6},
    {"at": 100, "myr": 446, "eye": disk(0, -80 * math.cos(math.radians(30)), 80 * math.sin(math.radians(30))), "aim": core},
]
json.dump({"version": 1, "inside": {"dustSlabs": 1.2}, "keys": keys}, open(sys.argv[1], "w"), indent=1)
