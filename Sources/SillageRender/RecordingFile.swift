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
///     component, galaxy                particleCount 32-bit words each
///     frames                           frameCount x 8 floats
///     positions                        frameCount x particleCount x 3 x 16 bits
///
/// The bulk sits at the end so it can be written and read as one run of bytes, and the file
/// is memory-mapped rather than loaded: a take is often larger than is comfortable to hold
/// twice over.
public enum RecordingFile {
    public static let fileExtension = "sillage"
    private static let magic = "SILLAGE\n"
    private static let version: UInt64 = 1

    public struct Header: Codable {
        public var scene: SceneConfig
        public var particleCount: Int
        public var galaxyCount: Int
        public var frameCount: Int
    }

    /// A take as it comes back off disk: the run, and the per-particle attributes the
    /// renderer needs to draw it.
    public struct Loaded {
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

        func padded<T>(_ values: [T], _ fallback: T) -> [T] {
            values.count == count ? values : [T](repeating: fallback, count: count)
        }
        try handle.write(contentsOf: bytes(of: padded(particles.population, Float(0.5))))
        try handle.write(contentsOf: bytes(of: padded(particles.luminosity, Float(1))))
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
        try handle.write(contentsOf: bytes(of: contents.storage))
    }

    public static func read(from url: URL) throws -> Loaded {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count > 24, Data(data[0..<8]) == Data(magic.utf8) else {
            throw Failure.notARecording
        }
        let version = read(UInt64.self, from: data, at: 8)
        guard version == Self.version else { throw Failure.unsupportedVersion(version) }
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
        particles.component = try take(UInt32.self, count)
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
        let storage = try take(UInt16.self, header.frameCount * count * 3)

        let recording = Recording(
            particleCount: count, galaxyCount: galaxies, frames: frames, centers: centers,
            storage: storage)
        // The renderer wants somewhere to start; the first frame is as good as it gets and
        // costs one decode.
        particles.positions = recording.positions(at: 0)
        particles.velocities = [SIMD3<Float>](repeating: .zero, count: count)
        particles.birthRadius = particles.positions.map { simd_length($0) }
        particles.mass = [Float](repeating: 0, count: count)
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
