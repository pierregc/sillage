#!/usr/bin/env python3
"""How finely a take holds its positions.

    take-quantum.py <take.sillage>...

A take stores each frame at 16 bits an axis over the box of every visible particle, so the
quantum is the frame's extent over 65535. For the first, middle and last stored frames this
prints the quantum, how many particles share a quantum cell with another one, and the quantum
a box over the central 99.9 % of the particles would give, with the share left outside it,
first over the whole scene and then with one such box per galaxy.
Reads the frame table and three frames of positions, never the whole file. Needs numpy.
"""

import json
import mmap
import struct
import sys

import numpy as np

EMITTING = (0, 1, 4, 5)


def box(cells, quantum):
    low = np.percentile(cells, 0.05, axis=0)
    high = np.percentile(cells, 99.95, axis=0)
    outside = np.any((cells < low) | (cells > high), axis=1).mean()
    return (high - low).max() * quantum / 65535, outside


def report(path):
    with open(path, "rb") as handle:
        data = mmap.mmap(handle.fileno(), 0, access=mmap.ACCESS_READ)
    if data[0:8] != b"SILLAGE\n":
        print(f"{path}: not a take")
        return
    version = struct.unpack("<Q", data[8:16])[0]
    length = struct.unpack("<Q", data[16:24])[0]
    header = json.loads(data[24 : 24 + length])
    count, frames, galaxies = header["particleCount"], header["frameCount"], header["galaxyCount"]
    offset = 24 + length
    floats = 2 + (version >= 2) + (version >= 4) + (version >= 6)
    offset += floats * 4 * count
    components = np.frombuffer(data, dtype="<u4", count=count, offset=offset)
    owners = np.frombuffer(data, dtype="<u4", count=count, offset=offset + 4 * count)
    offset += 2 * 4 * count
    table = np.frombuffer(data, dtype="<f4", count=frames * 8, offset=offset).reshape(frames, 8)
    offset += frames * 8 * 4
    if galaxies > 1:
        offset += frames * (galaxies - 1) * 3 * 4
    if version >= 3:
        offset += frames * galaxies * 4 * 4
    if offset + frames * count * 6 != len(data):
        print(f"{path}: unexpected size, layout not understood")
        return

    extent = table[:, 4]
    quantum = extent / 65535 * 1000
    emitting = np.isin(components, EMITTING)
    print(
        f"{path}: {count} particles, {frames} frames (interval {header.get('interval')}), "
        f"extent {extent[0]:.0f} to {extent.max():.0f} kpc, quantum {quantum[0]:.2f} to {quantum.max():.2f} pc"
    )
    for frame in sorted({0, frames // 2, frames - 1}):
        cells = np.frombuffer(data, dtype="<u2", count=count * 3, offset=offset + frame * count * 6)
        cells = cells.reshape(count, 3).astype(np.int64)
        keys = (cells[:, 0] << 32) | (cells[:, 1] << 16) | cells[:, 2]
        _, shared = np.unique(keys, return_counts=True)
        crowded = shared[shared > 1].sum()
        lit = np.unique(keys[emitting]).size / max(emitting.sum(), 1)
        central, outside = box(cells, quantum[frame])
        boxes = [box(cells[owners == galaxy], quantum[frame]) for galaxy in np.unique(owners)]
        each = max(size for size, _ in boxes)
        apart = sum(share * (owners == galaxy).sum() for (_, share), galaxy in zip(boxes, np.unique(owners))) / count
        print(
            f"  frame {frame:4d}  {table[frame, 0] * 4.71:6.0f} Myr  quantum {quantum[frame]:6.2f} pc  "
            f"sharing a cell {crowded / count * 100:5.2f} %  emitting distinct {lit * 100:6.2f} %  "
            f"most in one cell {shared.max()}  central 99.9 %: quantum {central:5.2f} pc, "
            f"{outside * 100:.2f} % outside; one a galaxy: quantum {each:5.2f} pc, {apart * 100:.2f} % outside"
        )


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    for argument in sys.argv[1:]:
        report(argument)
