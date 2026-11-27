"""take_q.py <take.sillage>...: the toomreQ and effectiveToomreQ each take's galaxies ran at (its header's scene)."""
import json, struct, sys
for p in sys.argv[1:]:
    f = open(p, "rb"); f.read(16); n = struct.unpack("<Q", f.read(8))[0]; h = json.loads(f.read(n))
    for g in h["scene"]["galaxies"]:
        print(p.split("/")[-2], "toomreQ", g.get("toomreQ"), "effectiveToomreQ", g.get("effectiveToomreQ"))
