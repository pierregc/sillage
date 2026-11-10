import Foundation
import Metal
import SillageCore

/// The reference outputs both engines must give (#281), kept in `Tests/Fixtures/engines/` and
/// described in the README there: a tree, the accelerations of a small walk dump, three frames.
/// Metal writes them (`./scripts/dev.sh fixtures`) and has to give them again in every check.
public enum EngineFixtures {
    public enum Failure: Error, CustomStringConvertible {
        case metal(String)
        case run(String)
        case dump(String)

        public var description: String {
            switch self {
            case .metal(let message), .run(let message), .dump(let message): message
            }
        }
    }

    public static let width = 256
    public static let height = 144
    public static let looks = ["red-vs-cyan", "ember", "webb"]
    /// The captured frame of the take the three frames draw, and the one the walk is dumped at.
    public static let capturedFrame = 0
    /// The small hires run the walk dump and the take come from: 1,000 light tracers.
    public static let runOptions = [
        "--particles", "3013", "--massive", "2000", "--frames", "1", "--width", String(width),
        "--height", String(height),
    ]

    static func bytes<T>(_ values: [T]) -> Data { values.withUnsafeBytes { Data($0) } }

    static func values<T>(_ data: Data, as type: T.Type) -> [T] {
        data.withUnsafeBytes { Array($0.bindMemory(to: T.self)) }
    }

    // MARK: - Tree

    public struct Tree: Equatable {
        public var order: Data
        public var nodes: Data
        public var moments: Data
        /// What only `GPUTreeBuilder` keeps, empty from the CPU: the origin and scale the codes
        /// are taken in, where each level starts, and what the renderer reads off the tree, the
        /// smoothing lengths of the drawn particles and the spacing record of each cell.
        public var frame = Data()
        public var levels = Data()
        public var smoothing = Data()
        public var spacing = Data()

        public var nodeCount: Int { nodes.count / MemoryLayout<BHNode>.stride }
    }

    public static let treeLeafCapacity = 16
    public static let treeMaximumDepth = 20
    /// The first particles of the tree are the drawn ones, each standing for `treeRatio` of
    /// them, as with light tracers; the others weigh and are not drawn, as a halo's.
    public static let treeDrawn = 16_000
    public static let treeRatio: Float = 4

    /// The fixture tree's 20,000 particles, as x, y, z, 0 and a mass each: a disk, a tight
    /// clump inside it, debris far out, and points that coincide, so that leaves at the depth
    /// ceiling hold more than a leaf's worth.
    public static func treeParticles() -> (positions: [SIMD4<Float>], mass: [Float]) {
        var generator = SeededGenerator(seed: 281)
        var positions: [SIMD4<Float>] = []
        func normal() -> SIMD4<Float> {
            SIMD4<Float>(generator.normal(), generator.normal(), generator.normal(), 0)
        }
        for _ in 0..<16_600 { positions.append(normal() * SIMD4<Float>(7, 7, 0.4, 0)) }
        for _ in 0..<2_400 { positions.append(SIMD4<Float>(3, -2, 0.1, 0) + normal() * 0.002) }
        for _ in 0..<600 { positions.append(normal() * 400) }
        for index in 0..<400 { positions.append(SIMD4<Float>(Float(index % 8) - 3.5, 0.25, 1, 0)) }
        let mass = positions.map { _ in Float(0.001 + 0.002 * generator.uniform()) }
        return (positions, mass)
    }

    private static func levelOrdered(
        _ nodes: [BHNode], _ moments: [SIMD4<Float>]
    ) throws -> (nodes: Data, moments: Data, sources: [Int]) {
        guard let sources = BarnesHutTree.levelOrder(of: nodes), sources.count == nodes.count,
            let level = BarnesHutTree.levelOrdered(nodes, moments: moments)
        else { throw Failure.dump("a tree whose cells are not each reached once from its root") }
        return (bytes(level.nodes), bytes(level.moments), sources)
    }

    /// The tree `BarnesHutTree` builds over those particles, with its second moments, level by
    /// level.
    public static func cpuTree(positions: [SIMD4<Float>], mass: [Float]) throws -> Tree {
        let tree = BarnesHutTree(leafCapacity: treeLeafCapacity, maximumDepth: treeMaximumDepth)
        tree.computesQuadrupoles = true
        tree.build(positions: positions.map { SIMD3<Float>($0.x, $0.y, $0.z) }, mass: mass)
        let level = try levelOrdered(tree.nodes, tree.quadrupoles)
        return Tree(order: bytes(tree.order), nodes: level.nodes, moments: level.moments)
    }

    /// The tree `GPUTreeBuilder` builds over them, level by level, with the lengths and the
    /// spacing records it reads off it.
    public static func metalTree(
        positions: [SIMD4<Float>], mass: [Float], device: MTLDevice? = nil
    ) throws -> Tree {
        let count = positions.count
        guard let device = device ?? MTLCreateSystemDefaultDevice(),
            let queue = device.makeCommandQueue(),
            let positionBuffer = device.makeBuffer(
                bytes: positions, length: count * 16, options: .storageModeShared),
            let massBuffer = device.makeBuffer(
                bytes: mass, length: count * 4, options: .storageModeShared),
            let sorted = device.makeBuffer(length: count * 16, options: .storageModePrivate)
        else { throw Failure.metal("no Metal device, or no room for \(count) particles") }
        let builder = try GPUTreeBuilder(
            device: device, count: count, leafCapacity: treeLeafCapacity,
            maximumDepth: treeMaximumDepth, quadrupole: true)
        var grown = 0
        repeat {
            if builder.overflowed {
                try builder.grow()
                grown += 1
            }
            guard let buffer = queue.makeCommandBuffer() else {
                throw Failure.metal("no command buffer")
            }
            builder.encode(into: buffer, positions: positionBuffer, mass: massBuffer, sorted: sorted)
            buffer.commit()
            buffer.waitUntilCompleted()
            if let error = buffer.error { throw Failure.metal("the tree build failed: \(error)") }
        } while builder.overflowed && grown < 20
        guard !builder.overflowed else { throw Failure.metal("the tree outgrew its nodes") }

        let drawn = min(treeDrawn, count)
        guard let lengths = device.makeBuffer(length: count * 4, options: .storageModeShared),
            let reading = queue.makeCommandBuffer()
        else { throw Failure.metal("no room for the smoothing lengths") }
        builder.encodeSmoothing(into: reading, lengths: lengths, drawn: drawn, ratio: treeRatio)
        builder.encodeSpacing(into: reading, drawn: drawn, ratio: treeRatio)
        reading.commit()
        reading.waitUntilCompleted()
        guard reading.error == nil, let records = builder.spacing else {
            throw Failure.metal("the tree's lengths were not read")
        }

        func read<T>(_ buffer: MTLBuffer, _ type: T.Type, _ count: Int) -> [T] {
            Array(
                UnsafeBufferPointer(
                    start: buffer.contents().bindMemory(to: T.self, capacity: count), count: count))
        }
        let nodeCount = builder.nodeCount
        let level = try levelOrdered(
            read(builder.nodes, BHNode.self, nodeCount),
            read(builder.moments, SIMD4<Float>.self, nodeCount * 2))
        let ordered = values(level.nodes, as: BHNode.self)
        // The level order keeps the builder's levels: its starts are where the depth changes.
        var depths = [Int](repeating: 0, count: nodeCount)
        var starts = [0]
        for (index, node) in ordered.enumerated() {
            if depths[index] == starts.count { starts.append(index) }
            guard !node.isLeaf else { continue }
            for child in node.childOffset..<node.childOffset + node.childCount {
                depths[child] = depths[index] + 1
            }
        }
        let levels = builder.levelStarts
        guard levels.count > starts.count, Array(levels.prefix(starts.count)) == starts,
            levels.dropFirst(starts.count).allSatisfy({ $0 == nodeCount })
        else { throw Failure.metal("the level order does not keep the builder's levels") }
        // A branch's record names its first child, which the level order moved.
        let spacing = read(records, SIMD2<UInt32>.self, nodeCount)
        let moved = level.sources.enumerated().map { index, source in
            let record = spacing[source]
            return ordered[index].isLeaf
                ? record
                : SIMD2<UInt32>(record.x, UInt32(ordered[index].childOffset) << 8 | record.y & 0xFF)
        }
        return Tree(
            order: bytes(read(builder.order, UInt32.self, count)), nodes: level.nodes,
            moments: level.moments, frame: bytes(read(builder.frame, Float.self, 8)),
            levels: bytes(levels.map { UInt32($0) }),
            smoothing: bytes(read(lengths, Float.self, drawn)), spacing: bytes(moved))
    }

    // MARK: - Walk

    /// A walk dump read back from its folder (docs/notes/cuda-walk-spike.md).
    public struct WalkDump {
        public var buffers: [String: Data]
        public var quadrupole: Bool
        public var opensHoldingCells: Bool

        private struct Manifest: Decodable {
            struct Entry: Decodable {
                var file: String
                var count: Int
                var stride: Int
            }

            var format: String
            var version: Int
            var functionConstants: [String: Bool]
            var buffers: [String: Entry]
        }

        public init(folder: URL) throws {
            let manifest = try JSONDecoder().decode(
                Manifest.self, from: Data(contentsOf: folder.appendingPathComponent("manifest.json")))
            guard manifest.format == "sillage-walk-dump", manifest.version == 1 else {
                throw Failure.dump("\(folder.path): not a walk dump of version 1")
            }
            var buffers: [String: Data] = [:]
            for (name, entry) in manifest.buffers {
                let data = try Data(contentsOf: folder.appendingPathComponent(entry.file))
                guard data.count == entry.count * entry.stride else {
                    throw Failure.dump(
                        "\(entry.file): \(data.count) bytes, not \(entry.count) of \(entry.stride)")
                }
                buffers[name] = data
            }
            self.buffers = buffers
            quadrupole = manifest.functionConstants["bhQuadrupole"] ?? false
            opensHoldingCells = manifest.functionConstants["bhOpensHoldingCells"] ?? false
        }

        public func buffer(_ name: String) throws -> Data {
            guard let data = buffers[name] else { throw Failure.dump("no \(name) in the walk dump") }
            return data
        }

        public var tracers: Int { (buffers["states"]?.count ?? 0) / 16 }

        /// Its tree level by level, so that the same run always leaves the same bytes. The
        /// walk does not tell the difference.
        public mutating func orderTree() throws {
            let level = try EngineFixtures.levelOrdered(
                values(try buffer("nodes"), as: BHNode.self),
                values(try buffer("moments"), as: SIMD4<Float>.self))
            buffers["nodes"] = level.nodes
            buffers["moments"] = level.moments
        }
    }

    /// What Metal's `bhTracerStep` gives on a dump's buffers, bound as
    /// `MetalBarnesHutSolver.walkDump` had them: the probe, then one mode 1 pass on a copy of
    /// the motions.
    public static func walk(
        _ dump: WalkDump, device: MTLDevice? = nil
    ) throws -> (accelerations: Data, motions: Data) {
        guard let device = device ?? MTLCreateSystemDefaultDevice(),
            let queue = device.makeCommandQueue(), let commands = queue.makeCommandBuffer()
        else { throw Failure.metal("no Metal device") }
        let library: MTLLibrary
        do {
            library = try ShaderCache.library(BarnesHutShaders.source, on: device)
        } catch {
            throw RenderError.shaderCompilation("\(error)")
        }
        let constants = MTLFunctionConstantValues()
        var (quadrupole, holding) = (dump.quadrupole, dump.opensHoldingCells)
        constants.setConstantValue(&quadrupole, type: .bool, index: 0)
        constants.setConstantValue(&holding, type: .bool, index: 3)
        let pipeline = try device.makeComputePipelineState(
            function: library.makeFunction(name: "bhTracerStep", constantValues: constants))

        let tracers = dump.tracers
        let stored = try dump.buffer("params")
        guard tracers > 0, stored.count == MemoryLayout<TracerStepGPU>.stride else {
            throw Failure.dump("a walk dump without tracers, or without its parameters")
        }
        func buffer(_ data: Data, length: Int? = nil) throws -> MTLBuffer {
            guard
                let made = device.makeBuffer(
                    length: max(length ?? data.count, 16), options: .storageModeShared)
            else { throw Failure.metal("no room for the walk dump") }
            data.withUnsafeBytes {
                guard let base = $0.baseAddress else { return }
                made.contents().copyMemory(from: base, byteCount: $0.count)
            }
            return made
        }
        func held(_ name: String) throws -> MTLBuffer { try buffer(try dump.buffer(name)) }
        let (states, sorted, nodes) = (try held("states"), try held("sorted"), try held("nodes"))
        let (moments, order, frame) = (try held("moments"), try held("order"), try held("frame"))
        let (massive, motions, stepped) = (try held("massive"), try held("motions"), try held("motions"))
        let (halos, holes) = (try dump.buffer("halos"), try dump.buffer("holes"))
        let probe = try buffer(Data(), length: tracers * 16)
        let unread = try buffer(Data(), length: tracers * 16)

        func encode(_ params: TracerStepGPU, motions: MTLBuffer, disks: Data, into target: MTLBuffer) {
            var p = params
            var start = 0
            while start < tracers {
                let span = min(max(MetalBarnesHutSolver.forceChunk, 1), tracers - start)
                p.chunkStart = UInt32(start)
                guard let encoder = commands.makeComputeCommandEncoder() else { return }
                encoder.setComputePipelineState(pipeline)
                encoder.setBuffer(states, offset: 0, index: 0)
                encoder.setBuffer(motions, offset: 0, index: 1)
                encoder.setBuffer(sorted, offset: 0, index: 2)
                encoder.setBuffer(nodes, offset: 0, index: 3)
                encoder.setBuffer(moments, offset: 0, index: 4)
                encoder.setBuffer(order, offset: 0, index: 5)
                encoder.setBuffer(frame, offset: 0, index: 6)
                for (index, bound) in [(7, halos), (8, holes), (10, disks)] {
                    bound.withUnsafeBytes {
                        guard let base = $0.baseAddress else { return }
                        encoder.setBytes(base, length: $0.count, index: index)
                    }
                }
                encoder.setBuffer(massive, offset: 0, index: 9)
                encoder.setBytes(&p, length: MemoryLayout<TracerStepGPU>.stride, index: 11)
                encoder.setBuffer(target, offset: 0, index: 12)
                let widest = pipeline.maxTotalThreadsPerThreadgroup
                let width = MetalBarnesHutSolver.forceThreadgroupWidth
                encoder.dispatchThreads(
                    MTLSize(width: span, height: 1, depth: 1),
                    threadsPerThreadgroup: MTLSize(
                        width: width > 0 ? min(width, widest) : widest, height: 1, depth: 1))
                encoder.endEncoding()
                start += span
            }
        }
        // The probe cools nothing, as the solver's own.
        let closing = stored.withUnsafeBytes { $0.loadUnaligned(as: TracerStepGPU.self) }
        var probing = closing
        probing.mode = 2
        probing.diskCount = 0
        let noDisk = bytes([DiskCoolingGPU(center: .zero, motion: .zero, axis: .zero, reach: .zero)])
        encode(probing, motions: motions, disks: noDisk, into: probe)
        encode(closing, motions: stepped, disks: try dump.buffer("disks"), into: unread)
        commands.commit()
        commands.waitUntilCompleted()
        if let error = commands.error { throw Failure.metal("the walk failed: \(error)") }
        return (
            Data(bytes: probe.contents(), count: tracers * 16),
            Data(bytes: stepped.contents(), count: tracers * 16)
        )
    }

    // MARK: - Frames

    /// One frame of a take as an export draws it with a look: 8-bit RGBA, rows from the top.
    public static func frame(take: URL, look: URL, device: MTLDevice? = nil) throws -> Data {
        let export = try TakeExport(
            take: RecordingFile.read(from: take), look: LookFile.decoded(from: Data(contentsOf: look)),
            capturedRate: 30, device: device)
        return Data(try export.still(atCaptured: capturedFrame, width: width, height: height))
    }
}

// MARK: - Writing them

extension EngineFixtures {
    private struct Manifest: Encodable {
        struct Entry: Encodable {
            var file: String
            var type: String
            var stride: Int
            var count: Int
        }

        struct TreeSection: Encodable {
            var particles: Int
            var nodes: Int
            var leafCapacity = EngineFixtures.treeLeafCapacity
            var maximumDepth = EngineFixtures.treeMaximumDepth
            var quadrupole = true
            var layout = "level order"
            var drawnCount = EngineFixtures.treeDrawn
            var ratio = EngineFixtures.treeRatio
            var buffers: [String: Entry]
        }

        struct WalkSection: Encodable {
            var dump = "walk"
            var format = "sillage-walk-dump"
            var layout = "level order"
            var tracers: Int
            var scene = "scene/scene.json"
            var clip = "scene/clip.json"
            var command: [String]
        }

        struct Image: Encodable {
            var look: String
            var file: String
        }

        struct FramesSection: Encodable {
            var take = "frames/take.sillage"
            var capturedFrame = EngineFixtures.capturedFrame
            var width = EngineFixtures.width
            var height = EngineFixtures.height
            var pixels = "rgba8"
            var rows = "top first"
            var images: [Image]
        }

        var format = "sillage-engine-fixtures"
        var version = 1
        var byteOrder = "little"
        var source = "Metal, ./scripts/dev.sh fixtures"
        var device: String
        var system: String
        var tree: TreeSection
        var walk: WalkSection
        var frames: FramesSection
    }

    /// Writes every reference output into `directory`, from the scene and the looks kept there.
    /// `executable` is `sillage-render`, which runs the small hires the dump and the take are of.
    public static func write(into directory: URL, executable: URL) throws {
        let manager = FileManager.default
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw Failure.metal("no Metal device")
        }
        func put(_ data: Data, _ path: String) throws {
            let url = directory.appendingPathComponent(path)
            try manager.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }

        let (positions, mass) = treeParticles()
        let tree = try metalTree(positions: positions, mass: mass, device: device)
        let reference = try cpuTree(positions: positions, mass: mass)
        guard tree.order == reference.order, tree.nodes == reference.nodes,
            tree.moments == reference.moments
        else { throw Failure.metal("Metal's tree is not the CPU's") }
        let buffers: [(name: String, type: String, stride: Int, data: Data)] = [
            ("positions", "float3", 16, bytes(positions)), ("mass", "float", 4, bytes(mass)),
            ("order", "uint", 4, tree.order), ("nodes", "BHNode", 32, tree.nodes),
            ("moments", "float4", 16, tree.moments), ("frame", "float", 4, tree.frame),
            ("levels", "uint", 4, tree.levels), ("smoothing", "float", 4, tree.smoothing),
            ("spacing", "uint2", 8, tree.spacing),
        ]
        var entries: [String: Manifest.Entry] = [:]
        for buffer in buffers {
            let file = "tree/\(buffer.name).bin"
            try put(buffer.data, file)
            entries[buffer.name] = .init(
                file: file, type: buffer.type, stride: buffer.stride,
                count: buffer.data.count / buffer.stride)
        }

        let work = manager.temporaryDirectory
            .appendingPathComponent("engine-fixtures-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: work) }
        let scene = SceneFolder(work.appendingPathComponent("engines/scene", isDirectory: true))
        try manager.createDirectory(at: scene.url, withIntermediateDirectories: true)
        for file in [scene.scene, scene.clip] {
            try manager.copyItem(
                at: directory.appendingPathComponent("scene/\(file.lastPathComponent)"), to: file)
        }
        let dumps = work.appendingPathComponent("walk", isDirectory: true)
        let dumpOptions = ["--dump-walk-frames", "\(capturedFrame):fixture"]
        let process = Process()
        process.executableURL = executable
        process.arguments =
            ["hires", scene.url.path] + runOptions + ["--dump-walk", dumps.path] + dumpOptions
        process.standardOutput = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure.run("the hires run failed with status \(process.terminationStatus)")
        }

        let dumped = dumps.appendingPathComponent(String(format: "frame-%05d", capturedFrame))
        var dump = try WalkDump(folder: dumped)
        try dump.orderTree()
        let walked = try walk(dump, device: device)
        guard walked.accelerations == (try dump.buffer("accelerations")),
            walked.motions == (try dump.buffer("motions-mode1"))
        else { throw Failure.dump("Metal does not walk the dump's buffers as the run did") }
        for (name, data) in dump.buffers { try put(data, "walk/\(name).bin") }
        // The build's commit would change the file at every commit.
        let manifest = try String(
            contentsOf: dumped.appendingPathComponent("manifest.json"), encoding: .utf8
        ).replacingOccurrences(
            of: #""commit" : "[^"]*""#, with: #""commit" : """#, options: .regularExpression)
        try put(Data(manifest.utf8), "walk/manifest.json")

        try put(Data(contentsOf: scene.take), "frames/take.sillage")
        var images: [Manifest.Image] = []
        for look in looks {
            let file = "frames/\(look).look.json"
            let drawn = try frame(
                take: scene.take, look: directory.appendingPathComponent(file), device: device)
            try put(drawn, "frames/\(look).rgba")
            images.append(.init(look: file, file: "frames/\(look).rgba"))
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let system = ProcessInfo.processInfo.operatingSystemVersion
        let command = ["hires", "scene"] + runOptions + ["--dump-walk", "walk"] + dumpOptions
        try put(
            encoder.encode(
                Manifest(
                    device: device.name,
                    system: "macOS \(system.majorVersion).\(system.minorVersion).\(system.patchVersion)",
                    tree: .init(particles: positions.count, nodes: tree.nodeCount, buffers: entries),
                    walk: .init(tracers: dump.tracers, command: command),
                    frames: .init(images: images))),
            "manifest.json")
    }
}
