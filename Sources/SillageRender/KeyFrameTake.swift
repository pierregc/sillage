import Foundation
import SillageCore

/// Every drawn particle at a few frames of a full pass (#239), the key frames of the massive
/// pass's curves, kept in a take of their own for posters and thumbnails in any style: one
/// stored frame each, in order, with `keyframes.json` beside it saying which frame each was.
/// With `blocks`, each key frame goes to disk as soon as it is taken, so a run that resumes
/// keeps those it took before (#240), and the take is put together from them at the end.
public final class KeyFrameTake {
    public typealias Entry = KeyFrameEntry

    /// One key frame on disk: its box and what the take keeps beside the positions.
    struct Block: Codable {
        var time: Float
        var origin: SIMD3<Float>
        var extent: Float
        var centers: [SIMD3<Float>]
        var disks: [DiskState]
    }

    public let keys: [KeyFrame]
    public let blocks: URL?
    private let particleCount: Int
    private let galaxyCount: Int
    private let recording: Recording
    public private(set) var entries: [Entry] = []

    /// `taken` are the key frames a checkpoint says were kept before; any other block in
    /// `blocks` was left by the interval it lost and is removed.
    public init(
        keys: [KeyFrame], particleCount: Int, galaxyCount: Int, blocks: URL? = nil,
        taken: [Entry] = []
    ) throws {
        self.keys = keys.sorted { $0.frame < $1.frame }
        self.blocks = blocks
        self.particleCount = particleCount
        self.galaxyCount = galaxyCount
        recording = Recording(particleCount: particleCount, galaxyCount: galaxyCount, interval: 1)
        if let blocks {
            try FileManager.default.createDirectory(at: blocks, withIntermediateDirectories: true)
            let kept = Set(taken.map(\.frame))
            for name in (try? FileManager.default.contentsOfDirectory(atPath: blocks.path)) ?? []
            where !kept.contains(Self.frame(of: name) ?? -1) {
                try? FileManager.default.removeItem(at: blocks.appendingPathComponent(name))
            }
            entries = taken
        } else {
            recording.reserve(frames: keys.count)
        }
    }

    public func wants(frame: Int) -> Bool {
        keys.contains { $0.frame == frame } && !entries.contains { $0.frame == frame }
    }

    public func offer(
        frame: Int, positions: UnsafePointer<SIMD3<Float>>, time: Float, centers: [SIMD3<Float>],
        disks: [DiskState]
    ) throws {
        guard let key = keys.first(where: { $0.frame == frame }) else { return }
        if let blocks {
            let one = Recording(
                particleCount: particleCount, galaxyCount: galaxyCount, interval: 1,
                bitsPerAxis: recording.bitsPerAxis)
            one.append(positions: positions, time: time, centers: centers, disks: disks)
            let contents = one.contents()
            guard let box = contents.frames.first else { return }
            let data = blocks.appendingPathComponent(Self.name(frame, "positions"))
            FileManager.default.createFile(atPath: data.path, contents: nil)
            let handle = try FileHandle(forWritingTo: data)
            try one.streamPositionBytes { try handle.write(contentsOf: Data($0)) }
            try handle.close()
            // Written last: a block without it was cut short.
            try JSONEncoder().encode(
                Block(
                    time: box.time, origin: box.origin, extent: box.extent, centers: contents.centers,
                    disks: contents.disks)
            ).write(to: blocks.appendingPathComponent(Self.name(frame, "json")), options: .atomic)
        } else {
            recording.append(positions: positions, time: time, centers: centers, disks: disks)
        }
        entries.append(
            Entry(
                frame: frame, role: key.role.rawValue,
                timeMyr: Double(time) * Physics.megayearsPerTimeUnit))
    }

    /// The take, and its list beside it at `list`.
    public func write(scene: SceneConfig, particles: ParticleSystem, to url: URL, list: URL) throws {
        guard !entries.isEmpty else { return }
        let ordered = entries.sorted { $0.frame < $1.frame }
        if let blocks {
            // The blocks' positions one after another, mapped rather than read in.
            let all = blocks.appendingPathComponent("all.positions")
            FileManager.default.createFile(atPath: all.path, contents: nil)
            let handle = try FileHandle(forWritingTo: all)
            var frames: [Recording.Frame] = []
            var centers: [SIMD3<Float>] = []
            var disks: [DiskState] = []
            for entry in ordered {
                let block = try JSONDecoder().decode(
                    Block.self,
                    from: Data(contentsOf: blocks.appendingPathComponent(Self.name(entry.frame, "json"))))
                frames.append(Recording.Frame(time: block.time, origin: block.origin, extent: block.extent))
                centers += block.centers
                disks += block.disks
                try handle.write(
                    contentsOf: Data(
                        contentsOf: blocks.appendingPathComponent(Self.name(entry.frame, "positions")),
                        options: .alwaysMapped))
            }
            try handle.close()
            let assembled = Recording(
                particleCount: particleCount, galaxyCount: galaxyCount, frames: frames, centers: centers,
                disks: disks, interval: 1, capturedCount: frames.count, bitsPerAxis: recording.bitsPerAxis,
                mapped: try Data(contentsOf: all, options: .alwaysMapped))
            try RecordingFile.write(assembled, scene: scene, particles: particles, to: url)
            try? FileManager.default.removeItem(at: all)
        } else {
            try RecordingFile.write(recording, scene: scene, particles: particles, to: url)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(ordered).write(to: list, options: .atomic)
    }

    private static func name(_ frame: Int, _ kind: String) -> String {
        String(format: "frame-%06d.%@", frame, kind)
    }

    private static func frame(of name: String) -> Int? {
        guard name.hasPrefix("frame-") else { return nil }
        return Int(name.dropFirst(6).prefix { $0.isNumber })
    }
}
