import Foundation
import Metal
import SillageCore
import simd

/// Per-particle smoothing length, the distance over which a particle's light is spread.
///
/// A galaxy has on the order of a hundred billion stars, so every pixel of a real image
/// contains millions of them and the surface is continuous. A million particles splatted at a
/// fixed size resolves the particles themselves, which is exactly why a simulation reads as a
/// point cloud however many points it has. Giving each particle a kernel the size of its own
/// local interparticle spacing, and dividing its brightness by the kernel's area so the flux
/// is conserved, makes the surface continuous everywhere at the same particle count. It is
/// the standard trick of astrophysical visualisation and it is the only thing that removes
/// the granularity.
///
/// The length comes from the Barnes-Hut tree, which already adapts to density: a leaf holding
/// `n` particles in a cell of width `w` implies a number density of n/w^3, and the radius
/// enclosing `k` neighbours follows from that. Level 2 rebuilds that tree every step anyway.
/// Safe to hand to the simulation queue: the model runs one refresh at a time and nothing
/// else touches the field while one is in flight. The buffer it writes is read by the
/// renderer on another thread, which is the same arrangement the position buffers are under.
extension SmoothingField: @unchecked Sendable {}

public final class SmoothingField {
    public private(set) var buffer: MTLBuffer
    public private(set) var lastMilliseconds = 0.0
    private let device: MTLDevice
    private var lengths: [Float]
    private let tree = BarnesHutTree(leafCapacity: 24)
    private let count: Int

    // How many neighbours the kernel spans and any hand tuning on top are both nothing but
    // a multiplier on the length, so neither is applied here. The raw spacing is stored and
    // the shader scales it, which makes the setting free to change instead of forcing a tree
    // rebuild every time it moves.

    public init(device: MTLDevice, particleCount: Int) throws {
        self.device = device
        self.count = max(particleCount, 1)
        self.lengths = [Float](repeating: 0.05, count: self.count)
        guard let buffer = device.makeBuffer(length: self.count * 4, options: .storageModeShared)
        else { throw RenderError.textureAllocation }
        self.buffer = buffer
        upload()
    }

    /// Fills the lengths from a tree that has already been built this step.
    public func update(from source: BarnesHutTree) {
        let clock = Date()
        lengths.withUnsafeMutableBufferPointer { target in
            source.order.withUnsafeBufferPointer { order in
                for node in source.nodes where node.isLeaf {
                    let particles = node.particleCount
                    guard particles > 0 else { continue }
                    // packed.x is the cell width squared.
                    let width = sqrt(max(node.packed.x, 1e-12))
                    let length = width * pow(1 / Float(particles), 1.0 / 3.0)
                    let start = node.particleStart
                    for slot in start..<(start + particles) {
                        let particle = Int(order[slot])
                        if particle < target.count { target[particle] = length }
                    }
                }
            }
        }
        upload()
        lastMilliseconds = Date().timeIntervalSince(clock) * 1000
    }

    /// Builds a tree of its own from a Metal buffer, for the restricted solver and for
    /// playback, neither of which keeps one.
    public func update(from buffer: MTLBuffer) {
        let pointer = buffer.contents().bindMemory(to: SIMD3<Float>.self, capacity: count)
        update(positions: Array(UnsafeBufferPointer(start: pointer, count: count)))
    }

    /// Builds a tree of its own, for the restricted solver which does not keep one.
    public func update(positions: [SIMD3<Float>]) {
        let clock = Date()
        tree.build(positions: positions, mass: [])
        update(from: tree)
        lastMilliseconds = Date().timeIntervalSince(clock) * 1000
    }

    private func upload() {
        lengths.withUnsafeBytes {
            buffer.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count)
        }
    }
}
