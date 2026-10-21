import Foundation
import Metal
import SillageCore

/// The Barnes-Hut tree built on the GPU: bounds, Morton codes, a radix sort, the node split
/// one level at a time, then the masses and second moments folded back up.
///
/// Same tree as `BarnesHutTree` to the bit, laid out level by level rather than depth first.
/// Siblings stay contiguous and in octant order, which is all the traversal relies on.
public final class GPUTreeBuilder {
    public enum Phase: String, CaseIterable, Sendable {
        case bounds, morton, sort, nodes, masses
    }

    struct Params {
        var count: UInt32
        var leafCapacity: UInt32
        var maximumDepth: UInt32
        var nodeCapacity: UInt32
        var level: UInt32 = 0
        var shift: UInt32 = 0
        var tiles: UInt32
        var tableLength: UInt32
        var moments: UInt32
    }

    public let count: Int
    public let maximumDepth: Int
    public let quadrupole: Bool
    public private(set) var nodeCapacity: Int
    public private(set) var nodes: MTLBuffer
    /// Two per node with `quadrupole`, as `BarnesHutTree.quadrupoles` lays them out.
    public private(set) var moments: MTLBuffer
    /// Particle indices in Morton order, which the traversal reads as `order`.
    public let order: MTLBuffer
    public let codes: MTLBuffer
    private let spareCodes: MTLBuffer
    private let spareOrder: MTLBuffer
    private let table: MTLBuffer
    private let sums: MTLBuffer
    private let counters: MTLBuffer
    private let levels: MTLBuffer
    private let frame: MTLBuffer
    private var params: Params
    private let device: MTLDevice
    private let tiles: Int
    private let scanBlocks: Int
    private let pipelines: [String: MTLComputePipelineState]

    static let tileSize = 2048
    static let radixBits = 8
    /// Threadgroups for the kernels that stride over a level or over every node.
    static let strideGroups = 1024

    public init(
        device: MTLDevice, count: Int, leafCapacity: Int = 16, maximumDepth: Int = 20,
        quadrupole: Bool = false, nodeCapacity: Int? = nil
    ) throws {
        self.device = device
        self.count = max(count, 1)
        self.maximumDepth = min(max(maximumDepth, 1), 21)
        self.quadrupole = quadrupole
        self.nodeCapacity = max(nodeCapacity ?? self.count, 1)
        tiles = (self.count + Self.tileSize - 1) / Self.tileSize
        let tableLength = tiles << Self.radixBits
        scanBlocks = (tableLength + 1023) / 1024
        params = Params(
            count: UInt32(self.count), leafCapacity: UInt32(max(leafCapacity, 1)),
            maximumDepth: UInt32(self.maximumDepth), nodeCapacity: UInt32(self.nodeCapacity),
            tiles: UInt32(tiles), tableLength: UInt32(tableLength), moments: quadrupole ? 1 : 0)

        // The codes must come out exactly as the CPU's, so no fast math.
        let options = MTLCompileOptions()
        if #available(macOS 15.0, *) { options.mathMode = .safe }
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: GPUTreeShaders.source, options: options)
        } catch {
            throw RenderError.shaderCompilation("\(error)")
        }
        var pipelines: [String: MTLComputePipelineState] = [:]
        for name in [
            "gtReset", "gtBounds", "gtRoot", "gtMorton", "gtRadixCount", "gtScanReduce",
            "gtScanTop", "gtScanDown", "gtRadixScatter", "gtCloseLevel", "gtSplit", "gtGather",
            "gtLeafSums", "gtFold", "gtNormalize", "gtFoldMoments",
        ] {
            guard let function = library.makeFunction(name: name) else {
                throw RenderError.pipelineCreation("missing kernel \(name)")
            }
            let pipeline = try device.makeComputePipelineState(function: function)
            let needed = name == "gtScanTop" ? 1024 : 256
            guard pipeline.maxTotalThreadsPerThreadgroup >= needed else {
                throw RenderError.pipelineCreation(
                    "\(name) allows \(pipeline.maxTotalThreadsPerThreadgroup) threads a group")
            }
            pipelines[name] = pipeline
        }
        self.pipelines = pipelines

        func buffer(_ length: Int) throws -> MTLBuffer { try Self.buffer(length, on: device) }
        nodes = try buffer(self.nodeCapacity * MemoryLayout<BHNode>.stride)
        moments = try buffer(quadrupole ? self.nodeCapacity * 2 * MemoryLayout<SIMD4<Float>>.stride : 0)
        codes = try buffer(self.count * 8)
        spareCodes = try buffer(self.count * 8)
        order = try buffer(self.count * 4)
        spareOrder = try buffer(self.count * 4)
        table = try buffer(tableLength * 4)
        sums = try buffer(scanBlocks * 4)
        counters = try buffer(8 * 4)
        levels = try buffer(24 * 4)
        frame = try buffer(8 * 4)
    }

    private static func buffer(_ length: Int, on device: MTLDevice) throws -> MTLBuffer {
        guard let made = device.makeBuffer(length: max(length, 16), options: .storageModeShared)
        else { throw RenderError.textureAllocation }
        return made
    }

    /// Doubles the node buffers after a build that ran out of them, which then has to run
    /// again: once the flag is up the mass passes stop, so an overflowed build leaves no tree.
    public func grow() throws {
        let capacity = nodeCapacity * 2
        nodes = try Self.buffer(capacity * MemoryLayout<BHNode>.stride, on: device)
        if quadrupole {
            moments = try Self.buffer(capacity * 2 * MemoryLayout<SIMD4<Float>>.stride, on: device)
        }
        nodeCapacity = capacity
        params.nodeCapacity = UInt32(capacity)
    }

    public var nodeCount: Int { min(Int(counters.contents().load(as: UInt32.self)), nodeCapacity) }
    public var overflowed: Bool { counters.contents().load(fromByteOffset: 4, as: UInt32.self) != 0 }
    /// Where each level starts in `nodes`, the last entry being the node count.
    public var levelStarts: [Int] {
        (0..<(maximumDepth + 2)).map {
            Int(levels.contents().load(fromByteOffset: $0 * 4, as: UInt32.self))
        }
    }

    /// The masses phase gathers the particles into `sorted` and sums the leaves from there,
    /// which leaves the force pass nothing to gather.
    public func encode(
        into buffer: MTLCommandBuffer, positions: MTLBuffer, mass: MTLBuffer, sorted: MTLBuffer
    ) {
        for phase in Phase.allCases {
            encode(phase, into: buffer, positions: positions, mass: mass, sorted: sorted)
        }
    }

    public func encode(
        _ phase: Phase, into buffer: MTLCommandBuffer, positions: MTLBuffer, mass: MTLBuffer,
        sorted: MTLBuffer
    ) {
        guard let encoder = buffer.makeComputeCommandEncoder() else { return }
        switch phase {
        case .bounds:
            dispatch(encoder, "gtReset", groups: 1, width: 32, params: nil) {
                $0.setBuffer(counters, offset: 0, index: 0)
                $0.setBuffer(levels, offset: 0, index: 1)
            }
            dispatch(encoder, "gtBounds", groups: 512, width: 256, params: 2) {
                $0.setBuffer(positions, offset: 0, index: 0)
                $0.setBuffer(counters, offset: 0, index: 1)
            }
            dispatch(encoder, "gtRoot", groups: 1, width: 32, params: 4) {
                $0.setBuffer(counters, offset: 0, index: 0)
                $0.setBuffer(nodes, offset: 0, index: 1)
                $0.setBuffer(frame, offset: 0, index: 2)
                $0.setBuffer(levels, offset: 0, index: 3)
            }
        case .morton:
            encoder.setComputePipelineState(pipelines["gtMorton"]!)
            encoder.setBuffer(positions, offset: 0, index: 0)
            encoder.setBuffer(codes, offset: 0, index: 1)
            encoder.setBuffer(order, offset: 0, index: 2)
            encoder.setBuffer(frame, offset: 0, index: 3)
            var p = params
            encoder.setBytes(&p, length: MemoryLayout<Params>.stride, index: 4)
            encoder.dispatchThreads(
                MTLSize(width: count, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        case .sort:
            let passes = (64 + Self.radixBits - 1) / Self.radixBits
            for pass in 0..<passes {
                let even = pass % 2 == 0
                let keysIn = even ? codes : spareCodes
                let keysOut = even ? spareCodes : codes
                let valuesIn = even ? order : spareOrder
                let valuesOut = even ? spareOrder : order
                let shift = pass * Self.radixBits
                dispatch(encoder, "gtRadixCount", groups: tiles, width: 256, params: 2, shift: shift) {
                    $0.setBuffer(keysIn, offset: 0, index: 0)
                    $0.setBuffer(table, offset: 0, index: 1)
                }
                dispatch(encoder, "gtScanReduce", groups: scanBlocks, width: 256, params: 2) {
                    $0.setBuffer(table, offset: 0, index: 0)
                    $0.setBuffer(sums, offset: 0, index: 1)
                }
                dispatch(encoder, "gtScanTop", groups: 1, width: 1024, params: 1) {
                    $0.setBuffer(sums, offset: 0, index: 0)
                }
                dispatch(encoder, "gtScanDown", groups: scanBlocks, width: 256, params: 2) {
                    $0.setBuffer(table, offset: 0, index: 0)
                    $0.setBuffer(sums, offset: 0, index: 1)
                }
                dispatch(encoder, "gtRadixScatter", groups: tiles, width: 256, params: 5, shift: shift) {
                    $0.setBuffer(keysIn, offset: 0, index: 0)
                    $0.setBuffer(valuesIn, offset: 0, index: 1)
                    $0.setBuffer(keysOut, offset: 0, index: 2)
                    $0.setBuffer(valuesOut, offset: 0, index: 3)
                    $0.setBuffer(table, offset: 0, index: 4)
                }
            }
        case .nodes:
            for level in 0...maximumDepth {
                dispatch(encoder, "gtCloseLevel", groups: 1, width: 32, params: 2, level: level) {
                    $0.setBuffer(counters, offset: 0, index: 0)
                    $0.setBuffer(levels, offset: 0, index: 1)
                }
                guard level < maximumDepth else { break }
                dispatch(
                    encoder, "gtSplit", groups: Self.strideGroups, width: 256, params: 5, level: level
                ) {
                    $0.setBuffer(nodes, offset: 0, index: 0)
                    $0.setBuffer(codes, offset: 0, index: 1)
                    $0.setBuffer(counters, offset: 0, index: 2)
                    $0.setBuffer(levels, offset: 0, index: 3)
                    $0.setBuffer(frame, offset: 0, index: 4)
                }
            }
        case .masses:
            encoder.setComputePipelineState(pipelines["gtGather"]!)
            encoder.setBuffer(sorted, offset: 0, index: 0)
            encoder.setBuffer(positions, offset: 0, index: 1)
            encoder.setBuffer(mass, offset: 0, index: 2)
            encoder.setBuffer(order, offset: 0, index: 3)
            var p = params
            encoder.setBytes(&p, length: MemoryLayout<Params>.stride, index: 4)
            encoder.dispatchThreads(
                MTLSize(width: count, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
            dispatch(encoder, "gtLeafSums", groups: Self.strideGroups, width: 256, params: 3) {
                $0.setBuffer(nodes, offset: 0, index: 0)
                $0.setBuffer(sorted, offset: 0, index: 1)
                $0.setBuffer(levels, offset: 0, index: 2)
                $0.setBuffer(moments, offset: 0, index: 4)
                $0.setBuffer(counters, offset: 0, index: 5)
            }
            for level in stride(from: maximumDepth - 1, through: 0, by: -1) {
                dispatch(encoder, "gtFold", groups: Self.strideGroups, width: 256, params: 2, level: level) {
                    $0.setBuffer(nodes, offset: 0, index: 0)
                    $0.setBuffer(levels, offset: 0, index: 1)
                    $0.setBuffer(counters, offset: 0, index: 3)
                }
            }
            dispatch(encoder, "gtNormalize", groups: Self.strideGroups, width: 256, params: 2) {
                $0.setBuffer(nodes, offset: 0, index: 0)
                $0.setBuffer(levels, offset: 0, index: 1)
                $0.setBuffer(counters, offset: 0, index: 3)
            }
            guard quadrupole else { break }
            for level in stride(from: maximumDepth - 1, through: 0, by: -1) {
                dispatch(
                    encoder, "gtFoldMoments", groups: Self.strideGroups, width: 256, params: 2, level: level
                ) {
                    $0.setBuffer(nodes, offset: 0, index: 0)
                    $0.setBuffer(levels, offset: 0, index: 1)
                    $0.setBuffer(moments, offset: 0, index: 3)
                    $0.setBuffer(counters, offset: 0, index: 4)
                }
            }
        }
        encoder.endEncoding()
    }

    private func dispatch(
        _ encoder: MTLComputeCommandEncoder, _ name: String, groups: Int, width: Int,
        params index: Int?, level: Int = 0, shift: Int = 0,
        _ bind: (MTLComputeCommandEncoder) -> Void
    ) {
        encoder.setComputePipelineState(pipelines[name]!)
        bind(encoder)
        if let index {
            var p = params
            p.level = UInt32(level)
            p.shift = UInt32(shift)
            encoder.setBytes(&p, length: MemoryLayout<Params>.stride, index: index)
        }
        encoder.dispatchThreadgroups(
            MTLSize(width: max(groups, 1), height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
    }

    /// How this tree compares with a CPU build over the same positions. Both are walked from
    /// the root, so the two layouts may differ; masses are compared to the bit.
    public struct Comparison: Sendable {
        public var nodes = (gpu: 0, cpu: 0)
        public var orderMatches = false
        public var firstDifference: String?
        public var massesCompared = 0
        public var massesDiffering = 0
        public var largestRelativeGap: Float = 0
        public var momentsCompared = 0
        public var momentsDiffering = 0
    }

    public func compare(with tree: BarnesHutTree) -> Comparison {
        var result = Comparison()
        let gpuCount = nodeCount
        result.nodes = (gpuCount, tree.nodes.count)
        let gpuOrder = UnsafeBufferPointer(
            start: order.contents().bindMemory(to: UInt32.self, capacity: count), count: count)
        result.orderMatches = tree.order.count == count && tree.order.elementsEqual(gpuOrder)
        let gpuNodes = UnsafeBufferPointer(
            start: nodes.contents().bindMemory(to: BHNode.self, capacity: gpuCount), count: gpuCount)
        let cpuNodes = tree.nodes
        let gpuMoments = UnsafeBufferPointer(
            start: moments.contents().bindMemory(to: SIMD4<Float>.self, capacity: gpuCount * 2),
            count: quadrupole ? gpuCount * 2 : 0)
        guard gpuCount > 0, !cpuNodes.isEmpty else {
            if gpuCount != cpuNodes.count { result.firstDifference = "one tree is empty" }
            return result
        }
        var stack = [(0, 0)]
        while let (g, c) = stack.popLast() {
            guard g < gpuCount, c < cpuNodes.count else {
                result.firstDifference = "gpu node \(g) or cpu node \(c) is out of range"
                return result
            }
            let a = gpuNodes[g]
            let b = cpuNodes[c]
            if a.packed.x.bitPattern != b.packed.x.bitPattern || a.signedCount != b.signedCount
                || (a.isLeaf && a.range != b.range)
            {
                result.firstDifference =
                    "gpu node \(g) (\(a.packed.x), \(a.range), \(a.signedCount)) against"
                    + " cpu node \(c) (\(b.packed.x), \(b.range), \(b.signedCount))"
                return result
            }
            result.massesCompared += 1
            if !Self.identical(a.comMass, b.comMass) {
                result.massesDiffering += 1
                for axis in 0..<4 {
                    let gap = abs(a.comMass[axis] - b.comMass[axis])
                    let scale = axis == 3 ? abs(b.comMass[3]) : max(abs(b.comMass[axis]), 1e-3)
                    if scale > 0 { result.largestRelativeGap = max(result.largestRelativeGap, gap / scale) }
                }
            }
            if quadrupole && tree.quadrupoles.count == cpuNodes.count * 2 {
                result.momentsCompared += 1
                if !Self.identical(gpuMoments[2 * g], tree.quadrupoles[2 * c])
                    || !Self.identical(gpuMoments[2 * g + 1], tree.quadrupoles[2 * c + 1])
                {
                    result.momentsDiffering += 1
                }
            }
            if !a.isLeaf {
                for k in 0..<a.childCount { stack.append((a.childOffset + k, b.childOffset + k)) }
            }
        }
        return result
    }

    private static func identical(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> Bool {
        unsafeBitCast(a, to: SIMD4<UInt32>.self) == unsafeBitCast(b, to: SIMD4<UInt32>.self)
    }
}
