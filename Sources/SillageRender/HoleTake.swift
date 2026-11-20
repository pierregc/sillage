import Foundation
import SillageCore

/// One moment of a tidal disruption's run (#314): each tracer's position with the light it
/// gives, and its velocity with the tracers per unit area round it, -1 once swallowed. All a
/// run needs to go on from it to the bit (#332).
public struct TidalFrame: Sendable, Equatable {
    public var time: Double
    public var positions: [SIMD4<Float>]
    public var velocities: [SIMD4<Float>]

    public var count: Int { positions.count }

    public init(time: Double, positions: [SIMD4<Float>], velocities: [SIMD4<Float>]) {
        self.time = time
        self.positions = positions
        self.velocities = velocities
    }
}

/// A black hole close up's run as a scene folder keeps it, `take.sillage` beside its scene
/// (#332), in the takes' shape: a header that says what ran, then the frames as one run of bytes
/// at the end, memory-mapped when read back.
///
/// Layout, little-endian throughout:
///
///     "SILLHOLE" + version             16 bytes
///     header length                     8 bytes
///     header, JSON                      the scene, the counts, each frame's step
///     frames                            frameCount x (positions, velocities), tracers x 16
///                                       bytes each, as the run holds them
///
/// The frames are kept whole, not quantised as a galaxy take's: an export goes on from the
/// frame before the moment it draws and steps the run to it, which gives the frame the run
/// itself had there only if nothing was rounded on the way. So a take can be sparse, a frame
/// every 250 time units, and a video still have a moment every few.
public enum HoleTakeFile {
    public static let magic = Array("SILLHOLE".utf8)
    public static let version: UInt64 = 1

    public struct Header: Codable, Sendable, Equatable {
        public var scene: HoleSceneFile
        public var tracers: Int
        /// When the cloud was let go, the run's first moment.
        public var releaseTime: Double
        /// The steps of `scene.blackHole.timeStep` from the release to each frame kept.
        public var steps: [Int]

        public init(scene: HoleSceneFile, tracers: Int, releaseTime: Double, steps: [Int]) {
            self.scene = scene
            self.tracers = tracers
            self.releaseTime = releaseTime
            self.steps = steps
        }

        public var frameCount: Int { steps.count }
        public var timeStep: Double { Double(scene.blackHole.timeStep) }

        /// The time of a moment `step` steps after the release, as the run counts it.
        public func time(step: Int) -> Double { releaseTime + Double(step) * timeStep }

        public var times: [Double] { steps.map(time(step:)) }

        /// The steps a run of `scene` takes from the release to its end, and those whose frames a
        /// take keeps: one every `frameInterval`, and the last.
        public static func planned(_ scene: TidalDisruption, releaseTime: Double) -> (total: Int, kept: [Int])
        {
            let total = max(
                Int(((Double(scene.duration) - releaseTime) / Double(scene.timeStep)).rounded()), 0)
            let every = max(Int((scene.frameInterval / scene.timeStep).rounded()), 1)
            var kept = Array(stride(from: 0, through: total, by: every))
            if kept.last != total { kept.append(total) }
            return (total, kept)
        }
    }

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case notAHoleTake
        case unsupportedVersion(UInt64)
        case truncated(expected: Int, found: Int)
        case wrongFrame(String)

        public var description: String {
            switch self {
            case .notAHoleTake: "not a black hole take"
            case .unsupportedVersion(let version):
                "black hole take version \(version), this build reads \(HoleTakeFile.version)"
            case .truncated(let expected, let found): "take holds \(found) bytes of \(expected)"
            case .wrongFrame(let detail): "frame refused: \(detail)"
            }
        }
    }

    /// Whether the file at `url` is a black hole take, by its first eight bytes.
    public static func isHoleTake(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 8)).map(Array.init) == magic
    }

    /// Writes a take frame by frame as the run gives them, in the order of `header.steps`.
    public final class Writer {
        public let header: Header
        public let url: URL
        private let handle: FileHandle
        public private(set) var written = 0

        public init(header: Header, to url: URL) throws {
            self.header = header
            self.url = url
            try? FileManager.default.removeItem(at: url)
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
            handle = try FileHandle(forWritingTo: url)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let json = try encoder.encode(header)
            var start = Data(HoleTakeFile.magic)
            Self.append(HoleTakeFile.version, to: &start)
            Self.append(UInt64(json.count), to: &start)
            start.append(json)
            try handle.write(contentsOf: start)
        }

        static func append(_ value: UInt64, to data: inout Data) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        public func append(_ frame: TidalFrame) throws {
            guard written < header.frameCount else { throw Failure.wrongFrame("the take is full") }
            guard frame.count == header.tracers, frame.velocities.count == header.tracers else {
                throw Failure.wrongFrame("\(frame.count) tracers, the take has \(header.tracers)")
            }
            try frame.positions.withUnsafeBytes { try handle.write(contentsOf: $0) }
            try frame.velocities.withUnsafeBytes { try handle.write(contentsOf: $0) }
            written += 1
        }

        public func finish() throws {
            try handle.close()
            guard written == header.frameCount else {
                throw Failure.wrongFrame("\(written) frames written of \(header.frameCount)")
            }
        }
    }

    /// A take read back: its header, and its frames on demand from the mapped file.
    public struct Loaded: Sendable {
        public let header: Header
        private let data: Data
        private let start: Int

        public init(contentsOf url: URL) throws {
            let data = try Data(contentsOf: url, options: .alwaysMapped)
            guard data.count >= 24, Array(data.prefix(8)) == HoleTakeFile.magic else {
                throw Failure.notAHoleTake
            }
            func word(_ offset: Int) -> UInt64 {
                data.withUnsafeBytes {
                    UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
                }
            }
            let version = word(8)
            guard version == HoleTakeFile.version else { throw Failure.unsupportedVersion(version) }
            let length = Int(word(16))
            guard data.count >= 24 + length else {
                throw Failure.truncated(expected: 24 + length, found: data.count)
            }
            header = try JSONDecoder().decode(Header.self, from: data.subdata(in: 24..<(24 + length)))
            start = 24 + length
            let expected = start + header.frameCount * Self.frameBytes(header.tracers)
            guard data.count == expected else {
                throw Failure.truncated(expected: expected, found: data.count)
            }
            self.data = data
        }

        static func frameBytes(_ tracers: Int) -> Int { 2 * tracers * MemoryLayout<SIMD4<Float>>.stride }

        public var frameCount: Int { header.frameCount }

        public func frame(_ index: Int) -> TidalFrame {
            let count = header.tracers
            let bytes = count * MemoryLayout<SIMD4<Float>>.stride
            let offset = start + index * Self.frameBytes(count)
            var positions = [SIMD4<Float>](repeating: .zero, count: count)
            var velocities = [SIMD4<Float>](repeating: .zero, count: count)
            data.withUnsafeBytes { raw in
                positions.withUnsafeMutableBytes {
                    $0.copyMemory(from: UnsafeRawBufferPointer(rebasing: raw[offset..<(offset + bytes)]))
                }
                velocities.withUnsafeMutableBytes {
                    $0.copyMemory(
                        from: UnsafeRawBufferPointer(rebasing: raw[(offset + bytes)..<(offset + 2 * bytes)]))
                }
            }
            return TidalFrame(
                time: header.time(step: header.steps[index]), positions: positions, velocities: velocities)
        }

        /// The last frame kept at or before `step`, the one a run goes on from to reach it.
        public func frameIndex(before step: Int) -> Int {
            header.steps.lastIndex { $0 <= step } ?? 0
        }
    }
}
