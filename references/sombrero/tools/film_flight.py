"""film_flight.py <out.flight.json>: the Sombrero film, one continuous take of 100 s on a take recorded from 0 Myr,
the close passes at 12 to 18 Myr while the dust is still thin. Eye and aim carried by the galaxy in its disk's axes (x, y in the plane, z along the spin).
  0-12 s   far, 65 kpc across, time fast
  12-30 s  in to Hubble's framing (26.5 kpc across, 6 degrees above the plane, roll 5.6), time slows to a near stop
  30-55 s  down onto the ring's rim, 0.6 kpc up, looking in so the bulge rises as a dome, a quarter turn along it
  55-70 s  through the dust and in to 3 kpc from the core, still turning
  70-80 s  out under the plane, facing the core
  80-100 s back to 80 kpc, 15 degrees above the plane, time fast: more than a turn of the ring"""
import json, math, sys
E = math.radians(6)
FOV = 2 * math.atan(65 / (16 / 9) / 2 / 200)          # 65 kpc across at 200 kpc
def disk(x, y, z): return {"galaxy": 0, "offset": [round(x, 3), round(y, 3), round(z, 3)], "disk": True}
def ring(phi, r, z): p = math.radians(phi); return disk(r * math.cos(p), r * math.sin(p), z)
core = disk(0, 0, 0)
view = lambda d: disk(0, -d * math.cos(E), d * math.sin(E))
keys = [
    {"at": 0, "myr": 0.5, "eye": view(200), "aim": core, "fov": round(FOV, 4), "roll": 0},
    {"at": 12, "myr": 6, "eye": view(170), "aim": core},
    {"at": 24, "myr": 10.5, "eye": view(100), "aim": core, "roll": 0.0977},
    {"at": 30, "myr": 12, "eye": view(81.4), "aim": core},
    # onto the rim of the near side, 0.6 kpc up, looking in towards the core so the bulge rises as a dome,
    # then a quarter turn with the rotation (counter-clockwise about +z)
    {"at": 37, "myr": 12.6, "eye": ring(-90, 8.2, 0.6), "aim": ring(-70, 3.0, 0.4), "fov": 1.0, "roll": 0, "pace": "nearness"},
    {"at": 43, "eye": ring(-67, 8.1, 0.6), "aim": ring(-45, 3.0, 0.4)},
    {"at": 49, "eye": ring(-44, 8.1, 0.6), "aim": ring(-20, 3.0, 0.4)},
    {"at": 55, "myr": 15, "eye": ring(-20, 8.0, 0.5), "aim": ring(10, 4.0, 0.2)},
    # through the dust and in, still turning
    {"at": 61, "eye": ring(5, 6.0, -0.05), "aim": ring(45, 4.0, -0.1), "pace": "nearness"},
    {"at": 70, "myr": 17, "eye": ring(40, 3.0, -0.35), "aim": ring(90, 2.5, -0.2)},
    # out under the plane, facing the core
    {"at": 78, "myr": 18, "eye": ring(80, 7.0, -2.5), "aim": core},
    # back out as time runs ever faster, the ring's settling hidden in the recession; a turn and more
    {"at": 86, "myr": 40, "eye": ring(60, 30, -6), "aim": core, "fov": 0.6},
    {"at": 100, "myr": 440, "eye": disk(0, -80 * math.cos(math.radians(15)), 80 * math.sin(math.radians(15))), "aim": core},
]
json.dump({"version": 1, "inside": {"dustSlabs": 1.2, "starColours": 0.3}, "keys": keys}, open(sys.argv[1], "w"), indent=1)
