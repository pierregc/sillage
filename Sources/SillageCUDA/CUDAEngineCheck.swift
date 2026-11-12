import Foundation
import SillageCore
import SillageRender

/// Whether this build of the CUDA engine gives the reference outputs (#281), checked by the
/// engine itself before a full pass may run on it (#278). `sillage-cuda check` builds the
/// fixture's tree and draws the three reference frames of `Tests/Fixtures/engines` with the
/// libraries it was linked with, on the GPU or on the CPU target, and records the outcome
/// beside them with a digest of those libraries; `sillage-cuda hires` refuses to start without
/// a record that passed for the same libraries and the same engine. The walk fixture is held
/// by `cuda/tests/solver_fixture.cu`, which `scripts/linux.sh engine-check` runs first.
public enum CUDAEngineCheck {
    public struct Item: Codable, Sendable {
        public var name: String
        public var passed: Bool
        public var detail: String
    }

    public struct Record: Codable, Sendable {
        public var engine: String
        public var device: String
        /// The libraries the check ran with (`buildDigest`).
        public var build: String
        public var date: Date
        public var items: [Item]
        public var passed: Bool { !items.isEmpty && items.allSatisfy(\.passed) }
    }

    public struct Refusal: Error, CustomStringConvertible {
        public let description: String
    }

    /// `cuda-gpu` with the GPU library, `cuda-cpu` on the CPU target.
    public static var engine: String { CUDAContext.target == .gpu ? "cuda-gpu" : "cuda-cpu" }

    /// The folder of the running binary, where `scripts/linux.sh` puts the libraries too.
    public static var folder: URL {
        (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .deletingLastPathComponent()
    }

    public static var defaultRecord: URL { folder.appendingPathComponent("engine-check.json") }

    /// A digest of the three libraries the engine runs on, in `folder`: the same for the command
    /// and the tests of one build.
    public static func buildDigest(in folder: URL = folder) -> String {
        var hash = PortableSHA256()
        for name in ["libSillageCore.so", "libSillageRender.so", "libSillageCUDA.so"] {
            if let data = try? Data(contentsOf: folder.appendingPathComponent(name), options: .alwaysMapped) {
                hash.update(data: data)
            }
        }
        return hash.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The reference frames' tolerances against Metal's, with room over what #277 measured: the
    /// look without grain agrees to rounding, the two with it but for the pixels whose grain
    /// hash lands the other side of a rounding.
    public static let frameTolerances: [(look: String, psnr: Double, largest: Int, overEight: Double)] = [
        ("red-vs-cyan", 60, 6, 0.0001),
        ("ember", 48, 40, 0.003),
        ("webb", 48, 40, 0.003),
    ]

    /// Runs every comparison the engine can run here.
    public static func run(
        context: CUDAContext, fixtures: URL, threads: Int = ProcessInfo.processInfo.activeProcessorCount
    ) -> Record {
        var items: [Item] = []
        func attempt(_ name: String, _ body: () throws -> (Bool, String)) {
            do {
                let (passed, detail) = try body()
                items.append(Item(name: name, passed: passed, detail: detail))
            } catch {
                items.append(Item(name: name, passed: false, detail: "\(error)"))
            }
        }
        attempt("tree") { try tree(context: context, fixtures: fixtures.appendingPathComponent("tree")) }
        for tolerance in frameTolerances {
            attempt("frame \(tolerance.look)") {
                let frames = fixtures.appendingPathComponent("frames")
                let reference = [UInt8](
                    try Data(contentsOf: frames.appendingPathComponent("\(tolerance.look).rgba")))
                let drawn = try CUDAStillChecks.fixtureFrame(
                    context: context, take: frames.appendingPathComponent("take.sillage"),
                    look: frames.appendingPathComponent("\(tolerance.look).look.json"), threads: threads)
                let measure = CUDAStillChecks.measure(drawn, channels: 3, reference, channels: 4)
                let passed =
                    measure.psnr >= tolerance.psnr && measure.largest <= tolerance.largest
                    && measure.overEight <= tolerance.overEight && abs(measure.meanA - measure.meanB) < 0.1
                return (passed, "\(measure)")
            }
        }
        return Record(
            engine: engine, device: context.name, build: buildDigest(), date: Date(), items: items)
    }

    /// The fixture's tree built by this engine: its order, cells, masses, moments, frame and
    /// levels to the bit, its smoothing lengths within 1e-6 and its spacing links to the bit.
    static func tree(context: CUDAContext, fixtures: URL) throws -> (Bool, String) {
        func file(_ name: String) throws -> Data {
            try Data(contentsOf: fixtures.appendingPathComponent(name))
        }
        func values<T>(_ data: Data, _ type: T.Type) -> [T] {
            data.withUnsafeBytes { Array($0.bindMemory(to: T.self)) }
        }
        func bytes<T>(_ values: [T]) -> Data { values.withUnsafeBytes { Data($0) } }
        func far(_ mine: [Float], _ theirs: [Float]) -> Int {
            guard mine.count == theirs.count else { return max(mine.count, theirs.count) }
            var count = 0
            for (a, b) in zip(mine, theirs) where a != b {
                let gap: Float = abs(a - b) / max(abs(b), 1e-30)
                if gap > 1e-6 { count += 1 }
            }
            return count
        }
        let points = values(try file("positions.bin"), SIMD4<Float>.self).map {
            SIMD3<Float>($0.x, $0.y, $0.z)
        }
        let mass = values(try file("mass.bin"), Float.self)
        let builder = try CUDATreeBuilder(context: context, count: points.count, quadrupole: true)
        let positions = try context.makeBuffer(points)
        let masses = try context.makeBuffer(mass)
        let sorted = try context.makeBuffer(length: points.count * 16)
        var grown = 0
        repeat {
            if try builder.overflowed {
                try builder.grow()
                grown += 1
            }
            try builder.build(positions: positions, mass: masses, sorted: sorted)
            try context.synchronize()
        } while try builder.overflowed && grown < 20
        let drawn = 16_000
        let lengths = try context.makeBuffer(length: drawn * 4)
        try builder.buildSmoothing(into: lengths, drawn: drawn, ratio: 4)
        try builder.buildSpacing(drawn: drawn, ratio: 4)
        let count = try builder.nodeCount
        let nodes = try builder.nodes.download(BHNode.self, count: count)
        let moments = try builder.moments.download(SIMD4<Float>.self, count: count * 2)
        guard let sources = BarnesHutTree.levelOrder(of: nodes),
            let level = BarnesHutTree.levelOrdered(nodes, moments: moments)
        else { return (false, "the cells do not make a tree") }
        let records = try builder.spacing?.download(SIMD2<UInt32>.self, count: count) ?? []
        let spacing = BarnesHutTree.levelOrdered(spacing: records, sources: sources, ordered: level.nodes)
        let expected = values(try file("spacing.bin"), SIMD2<UInt32>.self)
        var differ: [String] = []
        if bytes(try builder.order.download(UInt32.self, count: points.count)) != (try file("order.bin")) {
            differ.append("order")
        }
        if bytes(level.nodes) != (try file("nodes.bin")) { differ.append("cells") }
        if bytes(level.moments) != (try file("moments.bin")) { differ.append("moments") }
        if bytes(try builder.frame.download(Float.self, count: 8)) != (try file("frame.bin")) {
            differ.append("frame")
        }
        if bytes(try builder.levelStarts.map { UInt32($0) }) != (try file("levels.bin")) {
            differ.append("levels")
        }
        let lengthsFar = far(
            try lengths.download(Float.self, count: drawn), values(try file("smoothing.bin"), Float.self))
        if lengthsFar > 0 { differ.append("\(lengthsFar) lengths past 1e-6") }
        if spacing.map(\.y) != expected.map(\.y)
            || far(spacing.map { Float(bitPattern: $0.x) }, expected.map { Float(bitPattern: $0.x) }) > 0
        {
            differ.append("spacing records")
        }
        return (
            differ.isEmpty,
            differ.isEmpty
                ? "\(points.count) particles, \(count) cells, as the fixture"
                : "differ: " + differ.joined(separator: ", ")
        )
    }

    public static func write(_ record: Record, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: url, options: .atomic)
    }

    public static func read(from url: URL) -> Record? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: url)).flatMap { try? decoder.decode(Record.self, from: $0) }
    }

    /// Throws unless a check of these libraries on this engine passed.
    public static func require(at url: URL, context: CUDAContext) throws {
        let how = "run scripts/linux.sh engine-check (sillage-cuda check) first"
        guard let record = read(from: url) else {
            throw Refusal(description: "the engine was never checked against the reference outputs: \(how)")
        }
        guard record.engine == engine else {
            throw Refusal(
                description: "the check at \(url.path) is of \(record.engine), not \(engine): \(how)")
        }
        guard record.device == context.name else {
            throw Refusal(
                description: "the check at \(url.path) ran on \(record.device), not \(context.name): \(how)")
        }
        guard record.build == buildDigest() else {
            throw Refusal(description: "the engine was rebuilt since its check: \(how)")
        }
        guard record.passed else {
            let failed = record.items.filter { !$0.passed }.map { "\($0.name) (\($0.detail))" }
            throw Refusal(
                description: "this build does not give the reference outputs: "
                    + failed.joined(separator: "; "))
        }
    }
}
