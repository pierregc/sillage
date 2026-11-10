import Foundation
import Metal
import SillageCore
import simd

extension Recording {
    /// Copies one snapshot into a Metal buffer at a byte offset, as `copy(frame:to:)` does.
    @discardableResult
    public func copy(frame index: Int, into buffer: MTLBuffer, atByteOffset offset: Int)
        -> Frame?
    {
        copy(frame: index, to: buffer.contents().advanced(by: offset))
    }
}

struct ExpandParams {
    var origin0: SIMD4<Float>
    var origin1: SIMD4<Float>
    var origin2: SIMD4<Float>
    var origin3: SIMD4<Float>
    var weights: SIMD4<Float>
    var particleCount: UInt32
    var pad0: UInt32 = 0
    var pad1: UInt32 = 0
    var pad2: UInt32 = 0
}

/// Blends quantised snapshots of one take into the renderer's position buffer.
public final class SnapshotExpander {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let particleCount: Int
    private let bitsPerAxis: Int

    public init(device: MTLDevice, recording: Recording) throws {
        self.device = device
        self.particleCount = recording.particleCount
        self.bitsPerAxis = recording.bitsPerAxis

        let library: MTLLibrary
        do {
            library = try ShaderCache.library(RecordingShaders.source, on: device)
        } catch {
            throw RenderError.shaderCompilation("\(error)")
        }
        let name = bitsPerAxis > 16 ? "expandSnapshots21" : "expandSnapshots"
        guard let function = library.makeFunction(name: name) else {
            throw RenderError.pipelineCreation("missing kernel \(name)")
        }
        do {
            pipeline = try device.makeComputePipelineState(function: function)
        } catch {
            throw RenderError.pipelineCreation("\(name): \(error)")
        }
        guard let queue = device.makeCommandQueue() else { throw RenderError.noDevice }
        self.queue = queue
    }

    /// Blends two snapshots, each held wherever it happens to sit in `source`, along a
    /// straight line. What a pair with nothing either side of it can do.
    public func expand(
        first: Recording.Frame, at firstOffset: Int,
        second: Recording.Frame, at secondOffset: Int,
        from source: MTLBuffer, blend: Float, into positions: MTLBuffer
    ) {
        let s = min(max(blend, 0), 1)
        expand(
            frames: [first, first, second, second],
            at: [firstOffset, firstOffset, secondOffset, secondOffset], from: source,
            weights: SIMD4(0, 1 - s, s, 0), into: positions)
    }

    /// Blends the four snapshots around a moment, in the order `blend.keys` names them.
    public func expand(
        frames: [Recording.Frame], at offsets: [Int], blend: Recording.Blend,
        from source: MTLBuffer, into positions: MTLBuffer
    ) {
        expand(frames: frames, at: offsets, from: source, weights: blend.weights, into: positions)
    }

    /// The wait is what lets the reader overwrite those slots afterwards without racing the
    /// GPU, and costs about two milliseconds at five million particles.
    private func expand(
        frames: [Recording.Frame], at offsets: [Int], from source: MTLBuffer,
        weights: SIMD4<Float>, into positions: MTLBuffer
    ) {
        guard frames.count == 4, offsets.count == 4,
            let buffer = queue.makeCommandBuffer(),
            let encoder = buffer.makeComputeCommandEncoder()
        else { return }
        let last = Recording.lastCell(bitsPerAxis: bitsPerAxis)
        let origins = frames.map {
            SIMD4<Float>($0.origin.x, $0.origin.y, $0.origin.z, $0.extent / last)
        }
        var params = ExpandParams(
            origin0: origins[0], origin1: origins[1], origin2: origins[2], origin3: origins[3],
            weights: weights, particleCount: UInt32(particleCount))
        encoder.setComputePipelineState(pipeline)
        for (slot, offset) in offsets.enumerated() {
            encoder.setBuffer(source, offset: offset, index: slot)
        }
        encoder.setBuffer(positions, offset: 0, index: 4)
        encoder.setBytes(&params, length: MemoryLayout<ExpandParams>.stride, index: 5)
        encoder.dispatchThreads(
            MTLSize(width: particleCount, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(
                width: pipeline.maxTotalThreadsPerThreadgroup, height: 1, depth: 1))
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
    }
}
