import Foundation
import Testing

@testable import SillageCore
@testable import SillageRender

#if canImport(simd)
    import simd
#endif

/// What a take pass's checkpoint is made of (#377), without a GPU: the take and the curves cut
/// back to it, the journal and what a resumed run replays over it, the video's segments.
@Suite("Take pass checkpoints")
struct TakeCheckpointTests {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("take-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Through a checkpoint's file and back.
    private func stored<T: Codable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    private static let particles = 500
    private static let galaxies = 2

    private func system() -> ParticleSystem {
        var system = ParticleSystem()
        var generator = SeededGenerator(seed: 5)
        for index in 0..<Self.particles {
            system.append(
                position: .zero, velocity: .zero, galaxy: UInt32(index % Self.galaxies), radius: 1,
                population: generator.uniform(), luminosity: 1 + generator.uniform(), component: .star)
        }
        return system
    }

    private func offer(_ take: Recording, _ frames: Range<Int>) {
        for frame in frames {
            let positions = (0..<Self.particles).map { index in
                SIMD3<Float>(
                    sin(Float(index) * 0.37 + Float(frame) * 0.11) * 30, Float(index) * -0.021 / 3,
                    Float(frame) * 0.513 + Float(index % 13))
            }
            let centres = (0..<Self.galaxies).map { SIMD3<Float>(Float($0) / 3, Float(frame) / 7, 0.1) }
            let disks = centres.map {
                DiskState(axis: simd_normalize($0 + SIMD3<Float>(0, 0, 1)), disruption: Float(frame) / 97)
            }
            positions.withUnsafeBufferPointer {
                _ = take.offer(
                    positions: $0.baseAddress!, time: Float(frame) / 3, centers: centres, disks: disks,
                    budget: 0)
            }
        }
    }

    /// A take as its header reads and the bytes after it.
    private func content(of url: URL) throws -> [Data] {
        let data = try Data(contentsOf: url)
        let length = Int(data[16..<24].reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
        let header = try JSONSerialization.jsonObject(with: data[24..<(24 + length)])
        return [
            try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]),
            Data(data[(24 + length)...]),
        ]
    }

    /// A take kept on disk, checkpointed on a frame the interval passed over, carried on past
    /// it, then cut back to the checkpoint and resumed, is the file of a take held in memory;
    /// one cut short of what its checkpoint recorded is refused.
    @Test func aTakeOnDiskResumedFromItsCheckpointIsTheSameFile() throws {
        let folder = try temporary()
        defer { try? FileManager.default.removeItem(at: folder) }
        let scene = SceneConfig.merger(particleCount: Self.particles)
        func write(_ take: Recording, _ name: String) throws -> [Data] {
            let url = folder.appendingPathComponent(name)
            try RecordingFile.write(take, scene: scene, particles: system(), to: url)
            return try content(of: url)
        }
        let held = Recording(particleCount: Self.particles, galaxyCount: Self.galaxies, interval: 4)
        offer(held, 0..<11)
        let whole = try write(held, "held.sillage")

        let file = folder.appendingPathComponent("take.positions")
        let first = try Recording(
            particleCount: Self.particles, galaxyCount: Self.galaxies, interval: 4, file: file)
        offer(first, 0..<6)
        let progress = try stored(first.checkpoint())
        #expect(progress.offered == 6 && progress.frames.count == 2)
        #expect(progress.bytes == 2 * Self.particles * 8)
        // The interval a restart lost, a frame of it kept.
        offer(first, 6..<10)
        #expect(try Data(contentsOf: file).count == 3 * Self.particles * 8)

        let resumed = try Recording(
            particleCount: Self.particles, galaxyCount: Self.galaxies, interval: 4, file: file,
            resume: progress)
        #expect(try Data(contentsOf: file).count == progress.bytes)
        #expect(resumed.count == 2 && resumed.capturedCount == 6 && resumed.memoryByteCount < 1_000)
        offer(resumed, 6..<11)
        #expect(try write(resumed, "resumed.sillage") == whole)
        // Frames 0, 4 and 8, and the last one, which the interval passed over.
        #expect(
            try RecordingFile.read(from: folder.appendingPathComponent("resumed.sillage")).recording.count
                == 4)

        try Data(contentsOf: file).prefix(progress.bytes - 1).write(to: file)
        #expect(throws: ResumedFile.CutShort.self) {
            try Recording(
                particleCount: Self.particles, galaxyCount: Self.galaxies, interval: 4, file: file,
                resume: progress)
        }
    }

    /// The curves are cut back to the bytes their checkpoint recorded, and refused when they
    /// hold fewer.
    @Test func theCurvesAreCutBackToTheirCheckpoint() throws {
        let folder = try temporary()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("curves.csv")
        try Data("stale".utf8).write(to: url)
        let first = try ResumedFile.open(url, kept: nil)
        try first.write(contentsOf: Data("frame\n0\n1\n".utf8))
        try ResumedFile.synchronize(first)
        let kept = Int(try first.offset())
        try first.write(contentsOf: Data("2\n3".utf8))
        try first.close()

        let resumed = try ResumedFile.open(url, kept: kept)
        try resumed.write(contentsOf: Data("2\n".utf8))
        try resumed.close()
        #expect(try String(contentsOf: url, encoding: .utf8) == "frame\n0\n1\n2\n")
        #expect(throws: ResumedFile.CutShort.self) { try ResumedFile.open(url, kept: 100) }
    }

    /// Two galaxies falling together and parting, as a run's centres after each stretch.
    private func centres(_ stretch: Int) -> [SIMD3<Float>] {
        let phase = Float(stretch) * 0.19
        let apart = 4 + 60 * abs(cos(phase))
        return [
            SIMD3(apart / 2 * cos(phase / 3), apart / 2 * sin(phase / 3), 0.3 * phase),
            SIMD3(-apart / 2 * cos(phase / 3), -apart / 2 * sin(phase / 3), -0.1 * phase),
        ]
    }

    /// A resumed run that replays its journal frames, lights and steps what follows as the run
    /// that never stopped: the director, the automatic framing and a fixed one, and a step
    /// schedule judged on the run's centres.
    @Test(arguments: [LookFile.CameraPlan.Mode.director, .immersed, .auto, .fixed])
    func theJournalReplaysTheCamerasAndTheSchedule(_ mode: LookFile.CameraPlan.Mode) throws {
        let scene = SceneConfig.merger(particleCount: 2_000)
        var look = LookFile.standard
        look.camera.mode = mode
        let frames = 40
        let settle = [3, 4, 4]
        let schedule = StepSchedule(
            entries: [
                .init(fromMyr: 0, scale: 2), .init(fromMyr: 20, scale: 1), .init(fromMyr: 60, scale: 2),
            ],
            margin: 15)
        func framing() -> TakePassFraming {
            TakePassFraming(scene: scene, look: look, frames: frames, framesPerSecond: 30, reach: [8, 6])
        }
        func scheduler() -> StepScheduler {
            StepScheduler(schedule: schedule, stepMyr: 1.25, story: Story(scene: scene))
        }
        func description(_ camera: Camera, _ look: RenderLook?) -> String {
            "\(camera.eye) \(camera.target) \(camera.up) \(camera.fieldOfView) \(String(describing: look))"
        }
        /// Runs stretches `from` on: the journal's entries, and each frame's camera and light.
        func run(
            _ framing: TakePassFraming, _ scheduler: inout StepScheduler, _ journal: inout FrameJournal,
            from: Int
        ) -> [String] {
            var seen: [String] = []
            for stretch in from..<(settle.count + frames) {
                let frame = stretch < settle.count ? nil : stretch - settle.count
                let entry = FrameJournal.Entry(
                    steps: frame == nil ? settle[stretch] : 4, frame: frame,
                    time: Float(stretch + 1) * 0.37 / 3, centres: centres(stretch),
                    disks: [DiskState(axis: SIMD3(0, 0.6, 0.8), disruption: Float(stretch) / 61)])
                _ = scheduler.next(entry.steps, frame: entry.frame)
                scheduler.observe(
                    timeMyr: Double(entry.time) * Physics.megayearsPerTimeUnit, centres: entry.centres)
                journal.append(entry)
                guard let frame else { continue }
                if frame == 0, framing.radius <= 0 { framing.radius = 41.7 / 3 }
                let camera = framing.camera(frame: frame, centres: entry.centres)
                seen.append(description(camera, framing.director?.look))
            }
            return seen
        }
        var straightScheduler = scheduler()
        var straightJournal = FrameJournal()
        let first = framing()
        let straight = run(first, &straightScheduler, &straightJournal, from: 0)
        // A fixed camera may not move at all.
        #expect(straight.count == frames && (mode == .fixed || Set(straight).count > frames / 2))
        #expect(straightScheduler.switches.count >= 2)
        #expect(straightJournal.settled == 11 && straightJournal.frames == frames)

        // Stopped in the settle, then in the frames: each time the journal, as its checkpoint
        // stored it, is all the next run has.
        for stop in [2, settle.count + 17] {
            var journal = FrameJournal()
            for entry in straightJournal.entries.prefix(stop) { journal.append(entry) }
            journal = try stored(journal)
            let resumed = framing()
            if journal.frames > 0 { resumed.radius = try stored(first.radius) }
            resumed.replay(journal)
            var again = scheduler()
            for entry in journal.entries { again.replay(entry) }
            let rest = run(resumed, &again, &journal, from: stop)
            #expect(rest == Array(straight.suffix(rest.count)), "\(mode) from stretch \(stop)")
            #expect(
                again.switches == straightScheduler.switches && again.stepsRun == straightScheduler.stepsRun)
            #expect(journal.time == straightJournal.time)
        }
    }

    /// A drawing that only says what it was asked.
    private final class Told: RunVideoDrawing {
        var calls: [String] = []
        var styling: any FramePreparing { fatalError("not prepared in this test") }
        func begin(_ url: URL) throws { calls.append("begin \(url.lastPathComponent)") }
        func append(camera: Camera, still: ((any RunVideoStill) throws -> Void)?) throws {
            calls.append("frame")
        }
        func end() throws { calls.append("end") }
    }

    /// The run's own video in segments: one closed at each checkpoint, the one a kill left open
    /// drawn again by the resumed run, all of them joined at the end.
    @Test func theVideoIsCutAtCheckpointsAndJoined() throws {
        let folder = try temporary()
        defer { try? FileManager.default.removeItem(at: folder) }
        let camera = Camera(eye: SIMD3(0, 0, 10))
        let told = Told()
        let first = try RunVideoSegments(directory: folder, name: "hires.mov") { url in
            try told.begin(url)
            return told
        }
        // A checkpoint in the settle closes nothing.
        try first.cut()
        for _ in 0..<3 { try first.append(camera: camera, still: nil) }
        try first.cut()
        let saved = try stored(first.state)
        try first.append(camera: camera, still: nil)
        #expect(
            told.calls == [
                "begin hires-0000.mov", "frame", "frame", "frame", "end", "begin hires-0001.mov", "frame",
            ])

        let again = Told()
        let resumed = try RunVideoSegments(directory: folder, name: "hires.mov", resume: saved) { url in
            try again.begin(url)
            return again
        }
        for _ in 3..<5 { try resumed.append(camera: camera, still: nil) }
        var joined: [String] = []
        try resumed.finish(into: folder.appendingPathComponent("hires.mov")) { parts, url, frames in
            joined = parts.map(\.lastPathComponent) + [url.lastPathComponent, String(frames)]
        }
        #expect(again.calls == ["begin hires-0001.mov", "frame", "frame", "end"])
        #expect(joined == ["hires-0000.mov", "hires-0001.mov", "hires.mov", "5"])
    }
}
