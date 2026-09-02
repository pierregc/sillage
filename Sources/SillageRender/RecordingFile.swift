import Foundation
import SillageCore
import simd

/// Reads and writes a captured run.
///
/// A run costs minutes to compute and six bytes a particle a frame to hold, so a quarter of a
/// million particles over five hundred frames is three quarters of a gigabyte. That is worth
/// keeping: everything about how it looks — exposure, colour, the telescope, the camera — is
/// decided at draw time and none of it is baked in. Reopening a take is not watching a video,
/// it is getting the run back.
///
/// Layout, little-endian throughout:
///
///     "SILLAGE\n" + version           16 bytes
///     header length                    8 bytes
///     header, JSON                     the scene, the counts
///     population, luminosity           particleCount floats each
///     formation                        particleCount floats, version 2 and up
///     component, galaxy                particleCount 32-bit words each
///     frames                           frameCount x 8 floats
///     disk states                      frameCount x galaxyCount x 4 floats, version 3 and up
///     positions                        frameCount x particleCount x 3 x 16 bits
///
/// The bulk sits at the end so it can be written and read as one run of bytes, and the file
/// is memory-mapped rather than loaded: a take is often larger than is comfortable to hold
/// twice over.
public enum RecordingFile {
    public static let fileExtension = "sillage"
    private static let magic = "SILLAGE\n"
    /// 2 adds the per-particle formation times. Version 1 is still read: a run made before
    /// there was any star formation had none to record, so every particle in one is simply as
    /// old as the galaxy, which is exactly what the sentinel says.
    /// 3 adds the per-frame disk states: the plane each galaxy's disk actually turns in and
    /// how much of a disk is left of it. Four floats per galaxy per frame against six bytes
    /// per particle per frame, so on any take worth keeping it is not measurable. It has to be
    /// stored rather than derived, because a replay has no solver to measure it and the arms
    /// are painted into the plane it names: falling back to the scene's natal plane replays a
    /// merged spiral with its arms still in it.
    private static let version: UInt64 = 3
    private static let oldestReadableVersion: UInt64 = 1

    public struct Header: Codable {
        public var scene: SceneConfig
        public var particleCount: Int
        public var galaxyCount: Int
        public var frameCount: Int
    }

    /// A take as it comes back off disk: the run, and the per-particle attributes the
    /// renderer needs to draw it.
    /// `Recording` guards itself with a lock and everything else here is a value, so this
    /// crosses from the queue that read the file to the main actor safely. Saying so is not
    /// decoration: the newer compiler on CI rejects the hand-off outright.
    public struct Loaded: Sendable {
        public var scene: SceneConfig
        public var recording: Recording
        public var particles: ParticleSystem
    }

    public enum Failure: Error, CustomStringConvertible {
        case notARecording
        case unsupportedVersion(UInt64)
        case truncated

        public var description: String {
            switch self {
            case .notARecording: "Ce fichier n'est pas une prise Sillage"
            case .unsupportedVersion(let version): "Prise en version \(version), non reconnue"
            case .truncated: "Prise incomplète"
            }
        }
    }

    public static func write(
        _ recording: Recording, scene: SceneConfig, particles: ParticleSystem, to url: URL
    ) throws {
        let contents = recording.contents()
        let count = recording.particleCount
        let header = Header(
            scene: scene, particleCount: count, galaxyCount: recording.galaxyCount,
            frameCount: contents.frames.count)
        let encoded = try JSONEncoder().encode(header)

        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        var preamble = Data(magic.utf8)
        preamble.append(contentsOf: withUnsafeBytes(of: version.littleEndian) { Array($0) })
        preamble.append(
            contentsOf: withUnsafeBytes(of: UInt64(encoded.count).littleEndian) { Array($0) })
        try handle.write(contentsOf: preamble)
        try handle.write(contentsOf: encoded)

        // A take holds only what is drawn, and the sampler puts those first, so the leading
        // run of each attribute is exactly what belongs with it.
        func padded<T>(_ values: [T], _ fallback: T) -> [T] {
            if values.count >= count { return Array(values[0..<count]) }
            return [T](repeating: fallback, count: count)
        }
        try handle.write(contentsOf: bytes(of: padded(particles.population, Float(0.5))))
        try handle.write(contentsOf: bytes(of: padded(particles.luminosity, Float(1))))
        try handle.write(contentsOf: bytes(of: padded(particles.formation, ParticleSystem.ancient)))
        try handle.write(contentsOf: bytes(of: padded(particles.component, UInt32(0))))
        try handle.write(contentsOf: bytes(of: padded(particles.galaxyIndex, UInt32(0))))

        // Written field by field rather than as a struct: a SIMD3 carries invisible padding,
        // and a file that depends on it is a file that breaks on the next compiler.
        var frameFields: [Float] = []
        frameFields.reserveCapacity(contents.frames.count * 8)
        for (index, frame) in contents.frames.enumerated() {
            frameFields.append(contentsOf: [
                frame.time, frame.origin.x, frame.origin.y, frame.origin.z, frame.extent,
            ])
            let centre =
                index * recording.galaxyCount < contents.centers.count
                ? contents.centers[index * recording.galaxyCount] : SIMD3<Float>.zero
            frameFields.append(contentsOf: [centre.x, centre.y, centre.z])
        }
        try handle.write(contentsOf: bytes(of: frameFields))

        // Every galaxy's centre after the first, so the common case stays one contiguous run.
        if recording.galaxyCount > 1 {
            var rest: [Float] = []
            for index in contents.frames.indices {
                for galaxy in 1..<recording.galaxyCount {
                    let slot = index * recording.galaxyCount + galaxy
                    let centre =
                        slot < contents.centers.count ? contents.centers[slot] : SIMD3<Float>.zero
                    rest.append(contentsOf: [centre.x, centre.y, centre.z])
                }
            }
            try handle.write(contentsOf: bytes(of: rest))
        }
        // The disk states, every galaxy on every frame. Field by field for the same reason the
        // frames are: a SIMD3 carries padding a file must not depend on. Only the two things
        // the renderer reads are kept — the coherence and its reference are the solver's
        // working, and nothing measures anything during a replay.
        var disks: [Float] = []
        disks.reserveCapacity(contents.frames.count * recording.galaxyCount * 4)
        for index in contents.frames.indices {
            for galaxy in 0..<recording.galaxyCount {
                let slot = index * recording.galaxyCount + galaxy
                let fallback =
                    galaxy < scene.galaxies.count
                    ? DiskState.natal(scene.galaxies[galaxy])
                    : DiskState(axis: SIMD3<Float>(0, 0, 1))
                let state = slot < contents.disks.count ? contents.disks[slot] : fallback
                disks.append(
                    contentsOf: [state.axis.x, state.axis.y, state.axis.z, state.disruption])
            }
        }
        try handle.write(contentsOf: bytes(of: disks))

        // Written straight out of the take's own memory, in bounded pieces. Copying it into
        // a Data first meant a second copy of the whole run: at two gigabytes held, saving
        // cost another two.
        recording.withPositionBytes { source in
            var offset = 0
            let chunk = 64 << 20
            while offset < source.count {
                let length = min(chunk, source.count - offset)
                let piece = UnsafeRawBufferPointer(rebasing: source[offset..<(offset + length)])
                handle.write(
                    Data(
                        bytesNoCopy: .init(mutating: piece.baseAddress!),
                        count: length, deallocator: .none))
                offset += length
            }
        }
    }

    public static func read(from url: URL) throws -> Loaded {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count > 24, Data(data[0..<8]) == Data(magic.utf8) else {
            throw Failure.notARecording
        }
        let version = read(UInt64.self, from: data, at: 8)
        guard version >= Self.oldestReadableVersion, version <= Self.version else {
            throw Failure.unsupportedVersion(version)
        }
        let headerLength = Int(read(UInt64.self, from: data, at: 16))
        guard data.count >= 24 + headerLength else { throw Failure.truncated }
        let header = try JSONDecoder().decode(
            Header.self, from: Data(data[24..<(24 + headerLength)]))

        let count = header.particleCount
        let galaxies = max(header.galaxyCount, 1)
        var cursor = 24 + headerLength
        func take<T>(_ type: T.Type, _ n: Int) throws -> [T] {
            let length = n * MemoryLayout<T>.size
            guard cursor + length <= data.count else { throw Failure.truncated }
            let slice = Data(data[cursor..<(cursor + length)])
            cursor += length
            return slice.withUnsafeBytes { Array($0.bindMemory(to: T.self)) }
        }

        var particles = ParticleSystem()
        particles.population = try take(Float.self, count)
        particles.luminosity = try take(Float.self, count)
        // A take carries the whole star formation history in this one static array: every
        // particle's formation time is written once and never rewritten, so replaying at any
        // moment shows exactly the knots that had formed by then.
        particles.formation =
            version >= 2 ? try take(Float.self, count) : []
        particles.component = try take(UInt32.self, count)
        if particles.formation.isEmpty {
            // A version 1 take was made before there was any star formation to record, so it
            // has no history and nothing can invent one. What it does have is the knots the
            // sampler placed, and giving those the spread of ages the sampler would give them
            // now is closer to the run than making the whole galaxy uniformly old — which
            // would replay it with no ionised knot anywhere in it.
            var seeded = SeededGenerator(seed: 0x5111_4A6E)
            particles.formation = particles.component.map { kind in
                kind == ParticleComponent.hiiRegion.rawValue
                    ? -seeded.uniform() * StarFormation.seedSpreadMyr
                        / Float(Physics.megayearsPerTimeUnit)
                    : ParticleSystem.ancient
            }
        }
        particles.galaxyIndex = try take(UInt32.self, count)

        let fields = try take(Float.self, header.frameCount * 8)
        var frames: [Recording.Frame] = []
        var centers = [SIMD3<Float>](repeating: .zero, count: header.frameCount * galaxies)
        frames.reserveCapacity(header.frameCount)
        for index in 0..<header.frameCount {
            let base = index * 8
            frames.append(
                Recording.Frame(
                    time: fields[base],
                    origin: SIMD3<Float>(fields[base + 1], fields[base + 2], fields[base + 3]),
                    extent: fields[base + 4]))
            centers[index * galaxies] = SIMD3<Float>(
                fields[base + 5], fields[base + 6], fields[base + 7])
        }
        if galaxies > 1 {
            let rest = try take(Float.self, header.frameCount * (galaxies - 1) * 3)
            var slot = 0
            for index in 0..<header.frameCount {
                for galaxy in 1..<galaxies {
                    centers[index * galaxies + galaxy] = SIMD3<Float>(
                        rest[slot], rest[slot + 1], rest[slot + 2])
                    slot += 3
                }
            }
        }
        var disks: [DiskState] = []
        if version >= 3 {
            let fields = try take(Float.self, header.frameCount * galaxies * 4)
            disks.reserveCapacity(header.frameCount * galaxies)
            for slot in 0..<(header.frameCount * galaxies) {
                let base = slot * 4
                disks.append(
                    DiskState(
                        axis: SIMD3<Float>(fields[base], fields[base + 1], fields[base + 2]),
                        disruption: fields[base + 3]))
            }
        }

        // The positions stay in the mapping rather than being copied into an array: a take of
        // several gigabytes should cost the pages that are actually looked at.
        let length = header.frameCount * count * 3 * MemoryLayout<UInt16>.size
        guard cursor + length <= data.count else { throw Failure.truncated }
        let positions = data[cursor..<(cursor + length)]

        let recording = Recording(
            particleCount: count, galaxyCount: galaxies, frames: frames, centers: centers,
            disks: disks, mapped: positions)
        // The renderer wants somewhere to start; the first frame is as good as it gets and
        // costs one decode.
        particles.positions = recording.positions(at: 0)
        particles.velocities = [SIMD3<Float>](repeating: .zero, count: count)
        particles.birthRadius = particles.positions.map { simd_length($0) }
        particles.mass = [Float](repeating: 0, count: count)
        // Everything in a take is visible; there is no dark matter in the file.
        particles.setVisibleCount(count)
        return Loaded(scene: header.scene, recording: recording, particles: particles)
    }

    private static func bytes<T>(of values: [T]) -> Data {
        values.withUnsafeBytes { Data($0) }
    }

    private static func read<T>(_ type: T.Type, from data: Data, at offset: Int) -> T {
        Data(data[offset..<(offset + MemoryLayout<T>.size)]).withUnsafeBytes {
            $0.loadUnaligned(as: T.self)
        }
    }
}
