import Foundation
import Metal

/// The kernel lengths a flight's frames are drawn with (#297). A length is read off a tree built
/// from the positions, and a tree built again a moment later gives lengths that jump: nothing
/// shows of it while the take plays at its own speed, but with time running a hundred times
/// slower, as it does near matter, the kernels and the point stars scattered over them shimmer
/// on a picture that is otherwise still. So the trees are built at the take's captured frames
/// alone, and a moment between two of them takes the lengths between theirs: they change
/// evenly, and a moment on a captured frame keeps that frame's own.
final class EasedSmoothing {
    /// The lengths of the last moment asked.
    let buffer: MTLBuffer
    private var fields: [(frame: Int?, field: SmoothingField)]
    private let scratch: MTLBuffer
    private let count: Int
    /// How many trees were built, for the tests.
    private(set) var builds = 0

    init(device: MTLDevice, particleCount: Int) throws {
        count = max(particleCount, 1)
        guard let buffer = device.makeBuffer(length: count * 4, options: .storageModeShared),
            let scratch = device.makeBuffer(
                length: count * MemoryLayout<SIMD3<Float>>.stride, options: .storageModeShared)
        else { throw RenderError.textureAllocation }
        self.buffer = buffer
        self.scratch = scratch
        fields = [
            (nil, try SmoothingField(device: device, particleCount: count)),
            (nil, try SmoothingField(device: device, particleCount: count)),
        ]
    }

    /// The lengths at the captured `position` of a take whose last frame is `last`.
    /// `positions` holds the particles there already; `expand` writes those of another moment
    /// into a buffer, false when it cannot. `holding`, a captured frame, gives that frame's
    /// lengths at every position instead (#510).
    func update(
        at position: Double, last: Int, positions: MTLBuffer, holding: Double? = nil,
        expand: (Double, MTLBuffer) -> Bool
    ) -> Bool {
        let asked = holding ?? position
        let lower = min(max(Int(asked.rounded(.down)), 0), last)
        let share = Float(min(max(asked - Double(lower), 0), 1))
        let wanted = share > 0 && lower < last ? [lower, lower + 1] : [lower]
        for frame in wanted where !fields.contains(where: { $0.frame == frame }) {
            guard let slot = fields.firstIndex(where: { held in !wanted.contains { $0 == held.frame } })
            else { return false }
            if Double(frame) == position {
                fields[slot].field.update(from: positions)
            } else {
                guard expand(Double(frame), scratch) else { return false }
                fields[slot].field.update(from: scratch)
            }
            fields[slot].frame = frame
            builds += 1
        }
        func lengths(_ frame: Int) -> UnsafePointer<Float>? {
            fields.first { $0.frame == frame }.map {
                UnsafePointer($0.field.buffer.contents().bindMemory(to: Float.self, capacity: count))
            }
        }
        let out = buffer.contents().bindMemory(to: Float.self, capacity: count)
        guard let before = lengths(wanted[0]) else { return false }
        guard wanted.count > 1, let after = lengths(wanted[1]) else {
            out.update(from: before, count: count)
            return true
        }
        for index in 0..<count {
            out[index] = before[index] + (after[index] - before[index]) * share
        }
        return true
    }
}
