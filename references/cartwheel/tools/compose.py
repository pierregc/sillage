"""Assembles the film: flight 1 with the split screen pushed in over its hold, then the other
shots with hard cuts, encoded x265 10 bit. $CARTWHEEL_REF holds panel-webb.png and title.png.
usage: compose.py <masters dir> <out.mp4> [hold start s]"""
import os, subprocess, sys
d, out = sys.argv[1], sys.argv[2]
h0 = float(sys.argv[3]) if len(sys.argv) > 3 else 30.0
ref = os.environ.get("CARTWHEEL_REF", "ref")
shots = [f"{d}/{n}.mov" for n in ("1-collision", "2-centre", "3-edge", "4-again")]
still = f"{d}/hold.png"
subprocess.run(["ffmpeg", "-v", "error", "-y", "-ss", str(h0 + 4.5), "-i", shots[0], "-frames:v", "1",
                still], check=True)
ts, te, push = h0 + 0.5, h0 + 8.8, 1.2
u_in = f"clip((t-{ts})/{push},0,1)"
u_out = f"clip(({te}-t)/{push},0,1)"
P = f"({u_in}*{u_in}*(3-2*{u_in}))*({u_out}*{u_out}*(3-2*{u_out}))"
en = f"between(t,{ts},{te})"
graph = (
    f"[1:v]format=yuva444p10le[f];[2:v]format=yuva444p10le[p];"
    f"[3:v]format=yuva444p10le,fade=t=in:st={h0 + 1.5}:d=0.8:alpha=1,"
    f"fade=t=out:st={te - push - 0.7}:d=0.6:alpha=1[t];"
    f"[0:v][f]overlay=x='-960*{P}':y=0:enable='{en}':eof_action=pass[a];"
    f"[a][p]overlay=x='3840-1920*{P}':y=0:enable='{en}':eof_action=pass[b];"
    f"[b][t]overlay=0:0:enable='{en}':eof_action=pass,format=yuv422p10le[s1];"
    "[s1][4:v][5:v][6:v]concat=n=4:v=1:a=0,format=yuv420p10le[v]")
dur = str(h0 + 12)
cmd = ["ffmpeg", "-v", "error", "-y", "-i", shots[0],
       "-loop", "1", "-framerate", "30", "-t", dur, "-i", still,
       "-loop", "1", "-framerate", "30", "-t", dur, "-i", f"{ref}/panel-webb.png",
       "-loop", "1", "-framerate", "30", "-t", dur, "-i", f"{ref}/title.png",
       *sum((["-i", s] for s in shots[1:]), []),
       "-filter_complex", graph, "-map", "[v]", "-c:v", "libx265", "-preset", os.environ.get("X265_PRESET", "medium"),
       "-crf", "14", "-pix_fmt", "yuv420p10le", "-tag:v", "hvc1", "-movflags", "+faststart", out]
subprocess.run(cmd, check=True)
