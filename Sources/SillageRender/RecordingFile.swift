import Foundation
import SillageCore
#if canImport(simd)
    import simd
#endif

/// Reads and writes a captured run.
///
/// A run costs minutes to compute and eight bytes a particle a frame to hold, so a quarter of a
/// million particles over five hundred frames is a gigabyte. That is worth
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
///     kernelScale                      particleCount floats, version 4 and up
///     birthRadius                      particleCount floats, version 6 and up
///     component, galaxy                particleCount 32-bit words each
///     frames                           frameCount x 8 floats
///     disk states                      frameCount x galaxyCount x 4 floats, version 3 and up
///     positions                        frameCount x particleCount x 64 bits, version 7
///                                      and up: 21 bits an axis, x lowest, the top bit 0;
///                                      frameCount x particleCount x 3 x 16 bits before
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
    /// 5 may keep one captured frame in several, which the header says, and a reader that
    /// does not know to interpolate across the gaps would play it that many times too fast.
    /// 6 adds each particle's birth radius, which the galaxy colour ramps read (#119).
    /// 7 holds each position as 21 bits an axis in eight bytes, where 16 bits took six: 32 times
    /// finer, 1.5 pc over the widest box measured (#237). The layout is otherwise version 6's,
    /// which is still written for a take held at 16 bits.
    private static let version: UInt64 = 7
    private static let oldestReadableVersion: UInt64 = 1

    public struct Header: Codable {
        public var scene: SceneConfig
        public var particleCount: Int
        public var galaxyCount: Int
        public var frameCount: Int
        /// Captured frames per stored one, and how many were captured. Absent before
        /// version 5, where every frame captured was stored.
        public var interval: Int?
        public var capturedFrames: Int?
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

        public init(scene: SceneConfig, recording: Recording, particles: ParticleSystem) {
            self.scene = scene
            self.recording = recording
            self.particles = particles
        }
    }

    public enum Failure: Error, CustomStringConvertible {
        case notARecording
        case unsupportedVersion(UInt64)
        case truncated

        public var description: String {
            switch self {
            case .notARecording: "This file is not a Sillage take"
            case .unsupportedVersion(let version): "Take in version \(version), not recognised"
            case .truncated: "Incomplete take"
            }
        }
    }

    public static func write(
        _ recording: Recording, scene: SceneConfig, particles: ParticleSystem, to url: URL
    ) throws {
        recording.finish()
        let contents = recording.contents()
        let count = recording.particleCount
        let header = Header(
            scene: scene, particleCount: count, galaxyCount: recording.galaxyCount,
            frameCount: contents.frames.count, interval: recording.interval,
            capturedFrames: recording.capturedCount)
        let encoded = try JSONEncoder().encode(header)

        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        var preamble = Data(magic.utf8)
        let version: UInt64 = recording.bitsPerAxis > 16 ? Self.version : 6
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
        try handle.write(contentsOf: bytes(of: padded(particles.kernelScale, Float(1))))
        try handle.write(contentsOf: bytes(of: padded(particles.birthRadius, Float(0))))
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
        recording.streamPositionBytes { piece in
            handle.write(
                Data(
                    bytesNoCopy: .init(mutating: piece.baseAddress!),
                    count: piece.count, deallocator: .none))
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
        // Written from version 4. A take made before it has one scale for everything, which is
        // what it looked like at the time, so one is the honest thing to fill it with.
        particles.kernelScale =
            version >= 4
            ? try take(Float.self, count) : [Float](repeating: 1, count: count)
        let birthRadius = version >= 6 ? try take(Float.self, count) : nil
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
            // `sillage-render` wrote no measurement before #186, only a placeholder for every
            // galaxy on every frame, which paints every disk's arms in the xy plane and never
            // fades them. Left out, the natal plane is painted, as for a take before version 3.
            if disks.allSatisfy({ $0.axis == SIMD3<Float>(0, 0, 1) && $0.disruption == 0 }) {
                disks = []
            }
        }
        // The run that wrote such a take wrote its disruption correctly in the curves beside it
        // (#198).
        if disks.isEmpty, header.scene.galaxies.count == galaxies,
            let curves = try? String(
                contentsOf: SceneFolder(url.deletingLastPathComponent()).hiresCurves,
                encoding: .utf8)
        {
            disks = Self.disks(curves: curves, frames: frames, scene: header.scene)
        }

        // The positions stay in the mapping rather than being copied into an array: a take of
        // several gigabytes should cost the pages that are actually looked at.
        let bits = version >= 7 ? 21 : 16
        let length = header.frameCount * count * Recording.bytesPerParticle(bitsPerAxis: bits)
        guard cursor + length <= data.count else { throw Failure.truncated }
        let positions = data[cursor..<(cursor + length)]

        let recording = Recording(
            particleCount: count, galaxyCount: galaxies, frames: frames, centers: centers,
            disks: disks, interval: header.interval ?? 1, capturedCount: header.capturedFrames,
            bitsPerAxis: bits, mapped: positions)
        recording.setDisks(
            Self.layered(
                recording, scene: header.scene, galaxy: particles.galaxyIndex,
                component: particles.component, disks: disks))
        // The renderer wants somewhere to start; the first frame is as good as it gets and
        // costs one decode.
        particles.positions = recording.positions(at: 0)
        particles.velocities = [SIMD3<Float>](repeating: .zero, count: count)
        if let birthRadius {
            particles.birthRadius = birthRadius
        } else {
            // Kept as older builds rebuilt it, so an old take with an old look replays
            // byte for byte; the colour ramps read the frame-0 centres instead, which rank
            // like the true radius (Spearman 0.85 to 0.96, #118).
            particles.birthRadius = particles.positions.map { simd_length($0) }
            let centres = recording.centers(at: 0)
            particles.colourRadius = particles.positions.indices.map { index in
                let galaxy = Int(particles.galaxyIndex[index])
                return simd_distance(
                    particles.positions[index], galaxy < centres.count ? centres[galaxy] : .zero)
            }
        }
        particles.mass = [Float](repeating: 0, count: count)
        // Everything in a take is visible; there is no dark matter in the file.
        particles.setVisibleCount(count)
        return Loaded(scene: header.scene, recording: recording, particles: particles)
    }

    /// Each disk on each stored frame as `curves-hires.csv` has it: the natal plane, disrupted
    /// as its `disruption_<galaxy>` column says, which is all the painted arms fade with. A
    /// frame takes the row of its own time, whichever captured frames the take kept. One with
    /// no row within 0.01 Myr means another run's curves, and nothing is read: the curves
    /// print the time to a thousandth, and their rows lie a captured frame apart.
    static func disks(curves: String, frames: [Recording.Frame], scene: SceneConfig) -> [DiskState] {
        let lines = curves.split(whereSeparator: \.isNewline)
        guard let header = lines.first?.split(separator: ",").map(String.init),
            let time = header.firstIndex(of: "time_myr")
        else { return [] }
        let columns = scene.galaxies.indices.compactMap { header.firstIndex(of: "disruption_\($0)") }
        guard columns.count == scene.galaxies.count else { return [] }
        let rows = lines.dropFirst().compactMap { line -> (myr: Double, disruption: [Float])? in
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count == header.count, let myr = Double(fields[time]) else { return nil }
            let disruption = columns.compactMap { Float(fields[$0]) }.filter(\.isFinite)
            return disruption.count == columns.count ? (myr, disruption) : nil
        }
        let natal = DiskState.natal(scene)
        var disks: [DiskState] = []
        disks.reserveCapacity(frames.count * natal.count)
        var row = 0
        for frame in frames {
            let myr = Double(frame.time) * Physics.megayearsPerTimeUnit
            while row + 1 < rows.count, abs(rows[row + 1].myr - myr) <= abs(rows[row].myr - myr) {
                row += 1
            }
            guard row < rows.count, abs(rows[row].myr - myr) < 0.01 else { return [] }
            for (galaxy, state) in natal.enumerated() {
                disks.append(
                    DiskState(axis: state.axis, disruption: min(max(rows[row].disruption[galaxy], 0), 1)))
            }
        }
        return disks
    }

    /// Disk material read per galaxy on each stored frame, the first so many of its own.
    static let layerSample = 10_000
    /// Heights kept per reading, in bins of a spread: as fine as any cut needs, since a cut is
    /// never above `DiskState.layerSpreads` spreads.
    static let heightBins = 400

    /// `disks` with each rotating disk's layer read off the take's own positions, frame by frame:
    /// what the painted arms fade with, which no take stores (#210). The layer needs no
    /// velocities, which a take does not hold.
    static func layered(
        _ recording: Recording, scene: SceneConfig, galaxy: [UInt32], component: [UInt32],
        disks: [DiskState]
    ) -> [DiskState] {
        let galaxies = recording.galaxyCount
        let frames = recording.count
        guard disks.count == frames * galaxies, scene.galaxies.count == galaxies else { return disks }
        var states = disks
        var picked = [[Int]](repeating: [], count: galaxies)
        for index in 0..<min(galaxy.count, component.count, recording.particleCount)
        where component[index] < ParticleComponent.halo.rawValue {
            let owner = Int(galaxy[index])
            if owner < galaxies, picked[owner].count < layerSample { picked[owner].append(index) }
        }
        let rotating = scene.galaxies.indices.filter {
            $0 < galaxies && scene.galaxies[$0].kind.isRotating && !picked[$0].isEmpty
        }
        guard !rotating.isEmpty else { return states }

        // Each frame on its own first, in parallel; the running state needs them in order.
        let axes = states.map(\.axis)
        let sampled = picked
        let bins = heightBins
        let widest = DiskState.layerSpreads
        let jobs = frames * rotating.count
        var spreads = [Float](repeating: 0, count: jobs)
        var counts = [Int32](repeating: 0, count: jobs * bins)
        spreads.withUnsafeMutableBufferPointer { spread in
            counts.withUnsafeMutableBufferPointer { count in
                // Each job writes its own slots only.
                nonisolated(unsafe) let spreadBase = spread.baseAddress!
                nonisolated(unsafe) let countBase = count.baseAddress!
                concurrentPerform(iterations: jobs) { job in
                    let frame = job / rotating.count
                    let index = rotating[job % rotating.count]
                    let config = scene.galaxies[index]
                    let sample = sampled[index]
                    let first = sample[0]
                    let positions = recording.positions(at: frame, in: first..<(sample[sample.count - 1] + 1))
                    let centres = recording.centers(at: frame)
                    guard !positions.isEmpty, index < centres.count else { return }
                    let offsets = sample.map { positions[$0 - first] - centres[index] }
                    var layer = DiskLayer(
                        axis: axes[frame * galaxies + index],
                        scaleLength: config.diskScaleLength,
                        edge: config.diskScaleLength * config.diskTruncation)
                    for offset in offsets { layer.add(offset) }
                    let fit = layer.fitted()
                    guard fit.spread > 0 else { return }
                    spreadBase[job] = fit.spread
                    for offset in offsets {
                        guard let height = fit.height(of: offset) else { continue }
                        let bin = Int(abs(height) / fit.spread / widest * Float(bins))
                        if bin < bins { countBase[job * bins + bin] += 1 }
                    }
                }
            }
        }
        for (slot, index) in rotating.enumerated() {
            var reading = DiskState.natal(scene.galaxies[index])
            let material = Float(picked[index].count)
            for frame in 0..<frames {
                let job = frame * rotating.count + slot
                let spread = spreads[job]
                guard spread > 0 else {
                    states[frame * galaxies + index].torn = reading.torn
                    continue
                }
                // The cut in bins, the last one counted in part.
                let reach = reading.layerHeight(spread: spread) / spread / widest * Float(bins)
                let whole = min(Int(reach), bins)
                var held: Float = 0
                for bin in 0..<whole { held += Float(counts[job * bins + bin]) }
                if whole < bins { held += Float(counts[job * bins + whole]) * (reach - Float(whole)) }
                reading.foldLayer(spread: spread, held: held / material)
                states[frame * galaxies + index].torn = reading.torn
            }
        }
        return states
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
