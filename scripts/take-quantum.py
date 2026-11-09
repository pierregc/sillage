#!/usr/bin/env python3
"""How finely a take holds its positions.

    take-quantum.py <take.sillage>...

A take stores each frame on a grid over the box of every visible particle, 21 bits an axis
since version 7 and 16 before, so the quantum is the frame's extent over 2097151 or 65535.
For the first, middle and last stored frames this prints the quantum, how many particles
share a quantum cell with another one, and the quantum a box over the central 99.9 % of the
particles would give, with the share left outside it, first over the whole scene and then
with one such box per galaxy.
Reads the frame table and three frames of positions, never the whole file. Needs numpy.
"""

import json
import mmap
import struct
import sys

import numpy as np

EMITTING = (0, 1, 4, 5)


def box(cells, quantum, levels):
    low = np.percentile(cells, 0.05, axis=0)
    high = np.percentile(cells, 99.95, axis=0)
    outside = np.any((cells < low) | (cells > high), axis=1).mean()
    return (high - low).max() * quantum / levels, outside


def frame_cells(data, offset, count, bits):
    """Cells of one frame, one row a particle, and a key that is the same for a shared cell."""
    if bits == 21:
        words = np.frombuffer(data, dtype="<u8", count=count, offset=offset)
        mask = np.uint64(0x1FFFFF)
        cells = np.stack(
            [words & mask, (words >> np.uint64(21)) & mask, (words >> np.uint64(42)) & mask], axis=1
        )
        return cells.astype(np.int64), words
    cells = np.frombuffer(data, dtype="<u2", count=count * 3, offset=offset)
    cells = cells.reshape(count, 3).astype(np.int64)
    return cells, (cells[:, 0] << 32) | (cells[:, 1] << 16) | cells[:, 2]


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
    bits = 21 if version >= 7 else 16
    width = 8 if bits == 21 else 6
    levels = (1 << bits) - 1
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
    if offset + frames * count * width != len(data):
        print(f"{path}: unexpected size, layout not understood")
        return

    extent = table[:, 4]
    quantum = extent / levels * 1000
    emitting = np.isin(components, EMITTING)
    print(
        f"{path}: version {version}, {bits} bits an axis, {count} particles, {frames} frames "
        f"(interval {header.get('interval')}), {len(data) / 1e9:.2f} GB, "
        f"extent {extent[0]:.0f} to {extent.max():.0f} kpc, quantum {quantum[0]:.3f} to {quantum.max():.3f} pc"
    )
    for frame in sorted({0, frames // 2, frames - 1}):
        cells, keys = frame_cells(data, offset + frame * count * width, count, bits)
        _, shared = np.unique(keys, return_counts=True)
        crowded = shared[shared > 1].sum()
        lit = np.unique(keys[emitting]).size / max(emitting.sum(), 1)
        central, outside = box(cells, quantum[frame], levels)
        boxes = [box(cells[owners == galaxy], quantum[frame], levels) for galaxy in np.unique(owners)]
        each = max(size for size, _ in boxes)
        apart = sum(share * (owners == galaxy).sum() for (_, share), galaxy in zip(boxes, np.unique(owners))) / count
        print(
            f"  frame {frame:4d}  {table[frame, 0] * 4.71:6.0f} Myr  quantum {quantum[frame]:7.3f} pc  "
            f"sharing a cell {crowded / count * 100:5.2f} %  emitting distinct {lit * 100:6.2f} %  "
            f"most in one cell {shared.max()}  central 99.9 %: quantum {central:6.3f} pc, "
            f"{outside * 100:.2f} % outside; one a galaxy: quantum {each:6.3f} pc, {apart * 100:.2f} % outside"
        )


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    for argument in sys.argv[1:]:
        report(argument)
