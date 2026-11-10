import Foundation

/// What `MetalBarnesHutSolver.walkDump()` captures (#271): every buffer `bhTracerStep` binds,
/// byte for byte as the GPU holds it, and Metal's answers on that state, for the CUDA spike in
/// `cuda/spike/` to load. The format is in docs/notes/cuda-walk-spike.md.
public struct TracerWalkDump {
    struct Buffer {
        var name: String
        var binding: Int
        var type: String
        var stride: Int
        var count: Int
        var bytes: Data

        init(_ name: String, _ binding: Int, _ type: String, _ stride: Int, _ count: Int, _ bytes: Data) {
            (self.name, self.binding, self.type, self.stride, self.count, self.bytes) =
                (name, binding, type, stride, count, bytes)
        }
    }

    struct TracerSort: Encodable {
        var interval: Int
        /// The solver's `stepsSinceTracerSort` as held.
        var counter: Int
        /// 0 when the walk order was sorted at this step's tree build.
        var stepsSinceSort: Int
    }

    var buffers: [Buffer]
    var params: TracerStepGPU
    var counts: [String: Int]
    var functionConstants: [String: Bool]
    var tracerSort: TracerSort

    /// Where the dump comes from, for the reader.
    public struct Run {
        public var scene: String
        public var label: String
        public var frame: Int
        public var step: Int
        public var timeMyr: Double
        public var dtScale: Float?
        public var commit: String
        public var device: String

        public init(
            scene: String, label: String, frame: Int, step: Int, timeMyr: Double, dtScale: Float?,
            commit: String, device: String
        ) {
            (self.scene, self.label, self.frame, self.step, self.timeMyr) =
                (scene, label, frame, step, timeMyr)
            (self.dtScale, self.commit, self.device) = (dtScale, commit, device)
        }
    }

    private struct Manifest: Encodable {
        struct Entry: Encodable {
            var file: String
            var binding: Int
            var type: String
            var count: Int
            var stride: Int
        }

        struct Params: Encodable {
            var tracerCount: UInt32
            var haloCount: UInt32
            var timeStep: Float
            var openingAngleSquared: Float
            var softeningSquared: Float
            var gravitationalConstant: Float
            var chunkStart: UInt32
            var sortChunk: UInt32
            var holeCount: UInt32
            var diskCount: UInt32
            var mode: UInt32
        }

        var format = "sillage-walk-dump"
        var version = 1
        var byteOrder = "little"
        var source = "Metal, sillage-render hires --dump-walk"
        var scene: String
        var label: String
        var frame: Int
        var step: Int
        var time: Double
        var timeUnit = "Myr"
        var dtScale: Float?
        var commit: String
        var device: String
        var counts: [String: Int]
        var functionConstants: [String: Bool]
        var tracerSort: TracerSort
        var params: Params
        var buffers: [String: Entry]
    }

    /// The commit of the checkout the running binary was built in, with `+changes` when its
    /// tracked files differ from it; empty outside a checkout.
    public static func sourceCommit(executable: URL? = Bundle.main.executableURL) -> String {
        guard let folder = executable?.deletingLastPathComponent().path else { return "" }
        func git(_ arguments: [String]) -> String? {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", folder] + arguments
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let head = git(["rev-parse", "HEAD"]) else { return "" }
        let changes = git(["status", "--porcelain", "--untracked-files=no"]) ?? ""
        return changes.isEmpty ? head : head + "+changes"
    }

    /// Writes `<directory>/frame-<5 digits>/`: one `.bin` a buffer and `manifest.json`.
    @discardableResult
    public func write(to directory: URL, run: Run) throws -> URL {
        let folder = directory.appendingPathComponent(
            String(format: "frame-%05d", run.frame), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var entries: [String: Manifest.Entry] = [:]
        for buffer in buffers {
            precondition(buffer.bytes.count == buffer.count * buffer.stride, buffer.name)
            let file = buffer.name + ".bin"
            try buffer.bytes.write(to: folder.appendingPathComponent(file))
            entries[buffer.name] = Manifest.Entry(
                file: file, binding: buffer.binding, type: buffer.type, count: buffer.count,
                stride: buffer.stride)
        }
        let p = params
        let manifest = Manifest(
            scene: run.scene, label: run.label, frame: run.frame, step: run.step, time: run.timeMyr,
            dtScale: run.dtScale, commit: run.commit, device: run.device, counts: counts,
            functionConstants: functionConstants, tracerSort: tracerSort,
            params: Manifest.Params(
                tracerCount: p.tracerCount, haloCount: p.haloCount, timeStep: p.timeStep,
                openingAngleSquared: p.openingAngleSquared, softeningSquared: p.softeningSquared,
                gravitationalConstant: p.gravitationalConstant, chunkStart: p.chunkStart,
                sortChunk: p.sortChunk, holeCount: p.holeCount, diskCount: p.diskCount, mode: p.mode),
            buffers: entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(to: folder.appendingPathComponent("manifest.json"))
        return folder
    }
}
