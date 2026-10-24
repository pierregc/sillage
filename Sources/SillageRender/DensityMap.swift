import Foundation

/// The visible stars counted on a square grid in the xy plane, centred on the origin where an
/// encounter keeps its centre of mass, at a few instants of a clip. Two runs of one scene at
/// different particle counts give maps that compare cell by cell, whatever camera drew them.
public struct DensityMap: Sendable {
    public let size: Int
    /// Half the side of the grid, in kpc.
    public let extent: Float
    public let instants: [Int]
    /// One `size` x `size` map per instant, row major from the most negative y, as a fraction
    /// of the stars counted.
    public private(set) var maps: [[Float]] = []

    /// `count` instants spread evenly from the first frame to the last.
    public init(frames: Int, count: Int, extent: Float, size: Int = 256) {
        self.size = size
        self.extent = extent
        let last = max(frames - 1, 0)
        let wanted = max(min(count, frames), 1)
        instants =
            wanted == 1
            ? [last / 2]
            : (0..<wanted).map { Int((Double($0 * last) / Double(wanted - 1)).rounded()) }
    }

    public func wants(frame: Int) -> Bool { instants.contains(frame) }

    public mutating func add(_ positions: UnsafePointer<SIMD3<Float>>, count: Int) {
        var map = [Float](repeating: 0, count: size * size)
        let scale = Float(size) / (2 * extent)
        for index in 0..<count {
            let position = positions[index]
            let x = Int(((position.x + extent) * scale).rounded(.down))
            let y = Int(((position.y + extent) * scale).rounded(.down))
            guard x >= 0, x < size, y >= 0, y < size else { continue }
            map[y * size + x] += 1
        }
        let total = Float(max(count, 1))
        maps.append(map.map { $0 / total })
    }

    /// The maps as a NumPy `.npy` array of little-endian float32, shaped (instants, size, size).
    public func npy() -> Data {
        var header =
            "{'descr': '<f4', 'fortran_order': False, 'shape': (\(maps.count), \(size), \(size)), }"
        let unpadded = 10 + header.utf8.count + 1
        header += String(repeating: " ", count: (64 - unpadded % 64) % 64) + "\n"
        var data = Data([0x93] + Array("NUMPY".utf8) + [1, 0])
        let length = UInt16(header.utf8.count)
        data.append(contentsOf: [UInt8(length & 0xff), UInt8(length >> 8)])
        data.append(contentsOf: Array(header.utf8))
        for map in maps {
            map.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        }
        return data
    }
}
