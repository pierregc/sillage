import Foundation

/// A GIF89a written by hand: one global palette for every frame, LZW compressed, looping.
///
/// ImageIO merges the palettes of an animation into one of its own a few levels deep, and
/// told to keep each frame's, prints an empty line for every row it writes.
enum GIFWriter {
    static func data(
        frames: [[UInt8]], palette: GIFPalette, width: Int, height: Int, delay hundredths: Int
    ) -> Data {
        var out = Data("GIF89a".utf8)
        out.append(little: width)
        out.append(little: height)
        // A global table of 256 entries, eight bits a channel.
        out.append(contentsOf: [0xF7, 0, 0])
        for index in 0..<256 {
            let color = index < palette.colors.count ? palette.colors[index] : SIMD3(0, 0, 0)
            out.append(contentsOf: [color.x, color.y, color.z])
        }
        // Loop forever.
        out.append(contentsOf: [0x21, 0xFF, 11])
        out.append(contentsOf: Data("NETSCAPE2.0".utf8))
        out.append(contentsOf: [3, 1, 0, 0, 0])

        var compressed = [Data](repeating: Data(), count: frames.count)
        compressed.withUnsafeMutableBufferPointer { compressed in
            DispatchQueue.concurrentPerform(iterations: frames.count) { index in
                compressed[index] = lzw(frames[index])
            }
        }
        for frame in compressed {
            // Graphic control: keep the frame in place, no transparency.
            out.append(contentsOf: [0x21, 0xF9, 4, 0x04])
            out.append(little: hundredths)
            out.append(contentsOf: [0, 0])
            out.append(0x2C)
            out.append(little: 0)
            out.append(little: 0)
            out.append(little: width)
            out.append(little: height)
            out.append(0)
            out.append(8)
            var start = 0
            while start < frame.count {
                let length = min(255, frame.count - start)
                out.append(UInt8(length))
                out.append(frame[frame.startIndex + start..<frame.startIndex + start + length])
                start += length
            }
            out.append(0)
        }
        out.append(0x3B)
        return out
    }

    /// Variable width LZW over eight bit indices, codes packed from the low bit.
    static func lzw(_ indices: [UInt8]) -> Data {
        let clear = 256
        let end = 257
        // children[code * 256 + byte]: the code for that string plus the byte, 0 for none.
        var children = [UInt16](repeating: 0, count: 4096 * 256)
        var next = 258
        var size = 9
        var bits: UInt32 = 0
        var held = 0
        var out = Data()
        out.reserveCapacity(indices.count)

        func emit(_ code: Int) {
            bits |= UInt32(code) << held
            held += size
            while held >= 8 {
                out.append(UInt8(bits & 0xFF))
                bits >>= 8
                held -= 8
            }
        }

        emit(clear)
        guard var current = indices.first.map(Int.init) else {
            emit(end)
            if held > 0 { out.append(UInt8(bits & 0xFF)) }
            return out
        }
        children.withUnsafeMutableBufferPointer { children in
            for byte in indices.dropFirst() {
                let slot = current * 256 + Int(byte)
                let child = Int(children[slot])
                if child != 0 {
                    current = child
                    continue
                }
                emit(current)
                if next < 4096 {
                    children[slot] = UInt16(next)
                    // The decoder widens a code later than the encoder adds it.
                    if next == 1 << size { size += 1 }
                    next += 1
                } else {
                    emit(clear)
                    for index in children.indices { children[index] = 0 }
                    next = 258
                    size = 9
                }
                current = Int(byte)
            }
        }
        emit(current)
        emit(end)
        if held > 0 { out.append(UInt8(bits & 0xFF)) }
        return out
    }
}

extension Data {
    fileprivate mutating func append(little value: Int) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8 & 0xFF))
    }
}
