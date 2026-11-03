"""Spread of the tracers against the massive particles in a take, against the spread two
random halves of the tracers show between themselves: the noise the sample alone makes."""
import json
import struct
import sys

import numpy as np


def open_take(path):
    raw = np.memmap(path, dtype=np.uint8, mode="r")
    header_length = struct.unpack("<Q", bytes(raw[16:24]))[0]
    header = json.loads(bytes(raw[24 : 24 + header_length]))
    count = header["particleCount"]
    frames = header["frameCount"]
    galaxies = header["galaxyCount"]
    offset = 24 + header_length
    attrs = {}
    for name in ["population", "luminosity", "formation", "kernelScale", "birthRadius"]:
        attrs[name] = np.frombuffer(raw, dtype="<f4", count=count, offset=offset)
        offset += count * 4
    for name in ["component", "galaxy"]:
        attrs[name] = np.frombuffer(raw, dtype="<u4", count=count, offset=offset)
        offset += count * 4
    frame_fields = np.frombuffer(raw, dtype="<f4", count=frames * 8, offset=offset).reshape(frames, 8)
    offset += frames * 8 * 4
    if galaxies > 1:
        offset += frames * (galaxies - 1) * 3 * 4
    offset += frames * galaxies * 4 * 4
    positions = np.frombuffer(raw, dtype="<u2", count=frames * count * 3, offset=offset).reshape(
        frames, count, 3
    )
    return header, attrs, frame_fields, positions


def main():
    path, tracers = sys.argv[1], int(sys.argv[2])
    header, attrs, fields, positions = open_take(path)
    count = header["particleCount"]
    rng = np.random.default_rng(1)
    massive = np.arange(tracers, count)
    order = rng.permutation(tracers)
    half_a = np.sort(order[: len(massive)])
    half_b = np.sort(order[len(massive) : 2 * len(massive)])
    print("frame  Myr    rms light  rms massive  diff     halves diff")
    for frame in range(0, positions.shape[0], max(positions.shape[0] // 12, 1)):
        time, ox, oy, oz, extent = fields[frame][:5]
        scale = extent / 65535.0
        def rms(index):
            p = positions[frame, index].astype(np.float64) * scale + np.array([ox, oy, oz])
            return np.sqrt((p * p).sum(axis=1).mean())
        light = rms(np.arange(tracers))
        heavy = rms(massive)
        a, b = rms(half_a), rms(half_b)
        print(
            f"{frame:5d}  {time * 4.71:5.0f}  {light:9.3f}  {heavy:11.3f}"
            f"  {(light / heavy - 1) * 100:+6.2f} %  {(a / b - 1) * 100:+6.2f} %"
        )


main()
