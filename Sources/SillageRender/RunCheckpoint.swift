import CryptoKit
import Foundation
import SillageCore

/// A long run's checkpoint (#240), so a restart costs at most an interval of it rather than the
/// run. A directory holding, for checkpoint `n`, `particles-n.bin` (what changes of every
/// particle) and `state-n.json` (the rest: the solver's counters, where the frames and the
/// videos stand, the key frames taken), with `current` naming the last whole one, and
/// `massive.bin`, the massive particles as sampled, written once; the video segments and key
/// frame blocks sit beside them. Each file is written aside and renamed into place, `current`
/// last, and the checkpoint before is removed only then.
public struct RunCheckpoint: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory.standardizedFileURL }

    public var segments: URL { directory.appendingPathComponent("segments", isDirectory: true) }
    public var keyFrames: URL { directory.appendingPathComponent("keyframes", isDirectory: true) }
    var current: URL { directory.appendingPathComponent("current") }
    var massive: URL { directory.appendingPathComponent("massive.bin") }
    func particles(_ index: Int) -> URL { directory.appendingPathComponent("particles-\(index).bin") }
    func state(_ index: Int) -> URL { directory.appendingPathComponent("state-\(index).json") }

    /// What a run is: a checkpoint of another one is not resumed.
    public struct Identity: Codable, Sendable, Equatable {
        /// The run's command line, less what only says where to put a check's output.
        public var arguments: [String]
        /// `scene.json` and the look as read.
        public var scene: String
        public var look: String
        /// The take the videos are framed on: its size and when it was written.
        public var framing: String
        public var particles: Int
        public var massive: Int?
        /// The step the run takes, in simulation units.
        public var timeStep: Float
        public var presets: [String]
        /// The binary and its libraries: told when it changed, not refused.
        public var code: String

        public init(
            arguments: [String], scene: String, look: String, framing: String, particles: Int,
            massive: Int?, timeStep: Float, presets: [String], code: String
        ) {
            self.arguments = Self.kept(arguments)
            self.scene = scene
            self.look = look
            self.framing = framing
            self.particles = particles
            self.massive = massive
            self.timeStep = timeStep
            self.presets = presets
            self.code = code
        }

        /// Options that say where a check writes or how often to checkpoint, not what runs.
        static let ignored: Set<String> = [
            "--checkpoint-frames", "--checkpoint-steps", "--draw-stills", "--draw-stills-dir",
            "--state-out",
        ]

        static func kept(_ arguments: [String]) -> [String] {
            var kept: [String] = []
            var index = 0
            while index < arguments.count {
                if arguments[index] == "--resume" {
                    index += 1
                } else if ignored.contains(arguments[index]) {
                    index += 2
                } else {
                    kept.append(arguments[index])
                    index += 1
                }
            }
            return kept
        }

        /// What differs from `other` that makes it another run; the code is left out.
        public func differences(from other: Identity) -> [String] {
            var found: [String] = []
            if arguments != other.arguments {
                let mine = Set(arguments)
                let theirs = Set(other.arguments)
                let changed = mine.symmetricDifference(theirs).sorted().prefix(6)
                found.append("its command line (\(changed.joined(separator: " ")))")
            }
            if scene != other.scene { found.append("scene.json") }
            if look != other.look { found.append("the look") }
            if framing != other.framing { found.append("the massive take") }
            if particles != other.particles || massive != other.massive {
                found.append("the particles")
            }
            if timeStep != other.timeStep { found.append("the step") }
            if presets != other.presets { found.append("the videos") }
            return found
        }
    }

    /// The rest of a run's state.
    public struct Run: Codable, Sendable {
        public var version = 1
        public var identity: Identity
        /// This checkpoint's number.
        public var index: Int
        /// The next frame to draw, and the settle steps done.
        public var frame: Int
        public var settled: Int
        /// Seconds of the run kept so far, the lost intervals left out.
        public var elapsed: Double
        public var resumes: Int
        public var everyFrames: Int
        public var everySteps: Int
        public var solver: MetalBarnesHutSolver.State
        public var videos: RunVideos.Progress?
        public var keyFrames: [KeyFrameTake.Entry]
        public var saved: Date

        public init(
            identity: Identity, index: Int, frame: Int, settled: Int, elapsed: Double,
            resumes: Int, everyFrames: Int, everySteps: Int, solver: MetalBarnesHutSolver.State,
            videos: RunVideos.Progress?, keyFrames: [KeyFrameTake.Entry], saved: Date = Date()
        ) {
            self.identity = identity
            self.index = index
            self.frame = frame
            self.settled = settled
            self.elapsed = elapsed
            self.resumes = resumes
            self.everyFrames = everyFrames
            self.everySteps = everySteps
            self.solver = solver
            self.videos = videos
            self.keyFrames = keyFrames
            self.saved = saved
        }
    }

    public struct Saved: Sendable {
        public var seconds: Double
        public var bytes: Int
    }

    /// Writes checkpoint `run.index`: the particles, then the state, each aside then renamed,
    /// then `current` names it; the one before is removed only once it does.
    @discardableResult
    public func save(_ run: Run, particles write: (FileHandle) throws -> Void) throws -> Saved {
        let started = Date()
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let previous = currentIndex()
        let data = particles(run.index)
        try Self.durable(data, write)
        let encoded = try Self.encoder.encode(run)
        try Self.durable(state(run.index)) { try $0.write(contentsOf: encoded) }
        try Self.durable(current) { try $0.write(contentsOf: Data("\(run.index)\n".utf8)) }
        if let previous, previous != run.index {
            try? manager.removeItem(at: particles(previous))
            try? manager.removeItem(at: state(previous))
        }
        let bytes = (try? manager.attributesOfItem(atPath: data.path)[.size] as? Int) ?? 0
        return Saved(seconds: Date().timeIntervalSince(started), bytes: bytes)
    }

    /// The last whole checkpoint, with its particles opened at their start; nil when none.
    public func load() throws -> (run: Run, particles: FileHandle)? {
        guard let run = stored() else { return nil }
        return (run, try FileHandle(forReadingFrom: particles(run.index)))
    }

    /// The last whole checkpoint's state alone, to tell whether a run would resume it.
    public func stored() -> Run? {
        guard let index = currentIndex(), hasMassiveSet else { return nil }
        return (try? Data(contentsOf: state(index))).flatMap { try? Self.decoder.decode(Run.self, from: $0) }
    }

    /// Writes the massive particles as sampled, which never change but for what
    /// `particles-n.bin` keeps, so a run resumed from here samples nothing: with light tracers
    /// sampling costs 1.5 us a drawn particle, five minutes at 200 M (#238).
    @discardableResult
    public func saveMassive(_ system: ParticleSystem) throws -> Saved {
        let started = Date()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.durable(massive) { handle in
            try Self.write([UInt64(system.count), UInt64(system.visibleCount)], to: handle)
            try Self.write(system.positions, to: handle)
            try Self.write(system.velocities, to: handle)
            for values in [
                system.birthRadius, system.population, system.luminosity, system.formation,
                system.kernelScale, system.mass,
            ] {
                try Self.write(values, to: handle)
            }
            for values in [system.galaxyIndex, system.component] { try Self.write(values, to: handle) }
        }
        return Saved(seconds: Date().timeIntervalSince(started), bytes: 16 + system.count * 64)
    }

    /// The massive particles `saveMassive` wrote.
    public func massiveSet() throws -> ParticleSystem {
        let handle = try FileHandle(forReadingFrom: massive)
        defer { try? handle.close() }
        let header = try Self.read(2, of: UInt64.self, from: handle)
        let count = Int(header[0])
        var system = ParticleSystem()
        system.positions = try Self.read(count, of: SIMD3<Float>.self, from: handle)
        system.velocities = try Self.read(count, of: SIMD3<Float>.self, from: handle)
        system.birthRadius = try Self.read(count, of: Float.self, from: handle)
        system.population = try Self.read(count, of: Float.self, from: handle)
        system.luminosity = try Self.read(count, of: Float.self, from: handle)
        system.formation = try Self.read(count, of: Float.self, from: handle)
        system.kernelScale = try Self.read(count, of: Float.self, from: handle)
        system.mass = try Self.read(count, of: Float.self, from: handle)
        system.galaxyIndex = try Self.read(count, of: UInt32.self, from: handle)
        system.component = try Self.read(count, of: UInt32.self, from: handle)
        system.setVisibleCount(Int(header[1]))
        return system
    }

    private static func write<T>(_ values: [T], to handle: FileHandle) throws {
        try values.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress, !bytes.isEmpty else { return }
            try write(UnsafeMutableRawPointer(mutating: base), bytes.count, to: handle)
        }
    }

    /// `length` bytes from `start`, a piece at a time: one write of 2 GB or more fails on macOS
    /// (`EINVAL`), and a buffer of 200 M positions is 3.2 GB.
    static func write(_ start: UnsafeMutableRawPointer, _ length: Int, to handle: FileHandle) throws {
        var done = 0
        while done < length {
            let piece = min(length - done, 256 << 20)
            try handle.write(
                contentsOf: Data(bytesNoCopy: start.advanced(by: done), count: piece, deallocator: .none))
            done += piece
        }
    }

    private static func read<T>(_ count: Int, of _: T.Type, from handle: FileHandle) throws -> [T] {
        let length = count * MemoryLayout<T>.stride
        return try [T](unsafeUninitializedCapacity: count) { buffer, initialized in
            let bytes = UnsafeMutableRawBufferPointer(buffer)
            var done = 0
            while done < length {
                let piece = min(length - done, 256 << 20)
                guard let data = try handle.read(upToCount: piece), data.count == piece else {
                    throw MetalBarnesHutSolver.CheckpointError.truncated
                }
                data.copyBytes(to: UnsafeMutableRawBufferPointer(rebasing: bytes[done..<(done + piece)]))
                done += piece
            }
            initialized = count
        }
    }

    /// Removes every checkpoint, its segments and blocks with it.
    public func clear() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A checkpoint is only whole with the massive set it was taken over.
    private var hasMassiveSet: Bool { FileManager.default.fileExists(atPath: massive.path) }

    func currentIndex() -> Int? {
        (try? String(contentsOf: current, encoding: .utf8)).flatMap {
            Int($0.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Writes `url` aside, flushed to the disk itself, then renamed into place: `fsync` on macOS
    /// leaves the data in the drive's cache, where a power cut loses it (`F_FULLFSYNC` does not).
    private static func durable(_ url: URL, _ body: (FileHandle) throws -> Void) throws {
        let aside = url.appendingPathExtension("partial")
        FileManager.default.createFile(atPath: aside.path, contents: nil)
        let handle = try FileHandle(forWritingTo: aside)
        do {
            try body(handle)
            if fcntl(handle.fileDescriptor, F_FULLFSYNC) != 0 { try handle.synchronize() }
        } catch {
            try? handle.close()
            throw error
        }
        try handle.close()
        try rename(aside, to: url)
    }

    private static func rename(_ from: URL, to: URL) throws {
        guard Foundation.rename(from.path, to.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return decoder
    }
}

extension RunCheckpoint {
    /// A file's size and modification date, which say whether it is still the one a run read.
    public static func stamp(_ url: URL) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = attributes?[.size] as? Int ?? 0
        let date = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(size) bytes, \(date)"
    }

    /// A digest of this binary and the libraries beside it.
    public static func codeVersion(executable: URL? = Bundle.main.executableURL) -> String {
        guard let executable else { return "" }
        let folder = executable.deletingLastPathComponent()
        var hash = SHA256()
        for url in [executable]
            + ["libSillageCore.dylib", "libSillageRender.dylib"].map({ folder.appendingPathComponent($0) })
        {
            if let data = try? Data(contentsOf: url, options: .alwaysMapped) { hash.update(data: data) }
        }
        return hash.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether a full pass run with `arguments` would resume the checkpoint here: the same
    /// command line, scene, look and framing take.
    public func resumable(arguments: [String], scene: URL, look: URL?, framing: URL) -> Bool {
        guard let run = stored() else { return false }
        let identity = run.identity
        return identity.arguments == Identity.kept(arguments)
            && identity.scene == ((try? String(contentsOf: scene, encoding: .utf8)) ?? "")
            && identity.look == (look.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "")
            && identity.framing == Self.stamp(framing)
    }
}
