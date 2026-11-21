import Foundation
import Testing

@testable import SillageCore
@testable import SillageRender

/// Key frames where asked, an extract of a take, and where a take of some moments of a run
/// stands in it (#379). Portable: no frame is drawn here.
@Suite("Key frames where asked")
struct HeldFramesTests {
    /// Captured frames a megayear apart from 100 Myr.
    private let megayears = (0..<20).map { 100 + Double($0) }

    @Test func chosenMomentsAddTheirNearestFrameAndTheSpanAfterIt() throws {
        let picked = [
            KeyFrame(frame: 0, role: .start, timeMyr: 100),
            KeyFrame(frame: 8, role: .pericentre, timeMyr: 108),
            KeyFrame(frame: 19, role: .end, timeMyr: 119),
        ]
        let keys = try KeyFrames.adding(
            chosen: try KeyFrames.moments("104.4,107.8"), span: 3, to: picked, megayears: megayears)
        #expect(keys.map(\.frame) == [0, 4, 5, 6, 8, 9, 10, 19])
        #expect(keys.filter { $0.role == .chosen }.map(\.frame) == [4, 5, 6, 8, 9, 10])
        #expect(keys.first { $0.frame == 9 }?.timeMyr == 109)
        // The span stops at the run's last frame; one frame by default.
        let end = try KeyFrames.adding(chosen: [119], span: 4, to: [], megayears: megayears)
        #expect(end.map(\.frame) == [19])
        #expect(
            try KeyFrames.adding(chosen: [100.2], span: 1, to: [], megayears: megayears).map(\.frame) == [0])
        #expect(throws: KeyFrames.Failure.outsideClip(myr: 130, first: 100, last: 119)) {
            try KeyFrames.adding(chosen: [130], span: 1, to: [], megayears: megayears)
        }
        #expect(throws: KeyFrames.Failure.self) { try KeyFrames.moments("452,x") }
    }

    @Test func heldFramesPlaceAMomentOfTheRunAmongThemAndRefuseTheRest() throws {
        // Frames 3 alone, 7 to 9, and 15 of a run kept one in two.
        let held = try HeldFrames(times: [103, 107, 108, 109, 115], megayears: megayears, interval: 2)
        #expect(held.runs.map { $0.first...$0.last } == [0...0, 1...3, 4...4])
        #expect(held.description == "103.000 Myr, 107.000 to 109.000 Myr (3 frames), 115.000 Myr")
        let frozen = try held.place(atCaptured: 3)
        #expect(frozen.stored == 0 && frozen.run == 0...0)
        // A moment typed to three decimals still lands on its frame.
        #expect(try held.place(atCaptured: 3.004).stored == 0)
        let slow = try held.place(atCaptured: 8.25)
        #expect(abs(slow.stored - 2.25) < 1e-12 && slow.run == 1...3)
        #expect(try held.place(atCaptured: 9).stored == 3)
        #expect(throws: HeldFrames.Failure.self) { try held.place(atCaptured: 4) }
        do {
            _ = try held.place(atCaptured: 10.5)
            Issue.record("a moment between two runs was placed")
        } catch let failure as HeldFrames.Failure {
            #expect(
                failure.description.contains("110.500 Myr") && failure.description.contains(held.description))
        }
        // Two frames further apart than the framing take's stored ones are two runs.
        let apart = try HeldFrames(times: [103, 106], megayears: megayears, interval: 2)
        #expect(apart.runs.count == 2)
        #expect(throws: HeldFrames.Failure.self) {
            try HeldFrames(times: [90], megayears: megayears, interval: 1)
        }
    }

    @Test func aBlendWithinARunLeansOnItsFramesAlone() throws {
        let recording = Recording(particleCount: 1, galaxyCount: 1)
        for time: Float in [1, 5, 5.1, 5.2, 9] {
            let point = [SIMD3<Float>(time, 0, 0)]
            point.withUnsafeBufferPointer {
                recording.append(positions: $0.baseAddress!, time: time, centers: [.zero])
            }
        }
        // Frames 1 to 3: a tangent at either end from the run's own frames, not frame 0 or 4.
        let blend = try #require(recording.blend(atStored: 1.5, within: 1...3))
        #expect(blend.keys == SIMD4(1, 1, 2, 3))
        #expect(abs(blend.time - 5.05) < 1e-5)
        let held = try #require(recording.blend(atStored: 4, within: 4...4))
        #expect(held.keys == SIMD4(4, 4, 4, 4) && held.weights == SIMD4(0, 1, 0, 0))
        let pair = try #require(recording.blend(atStored: 2.5, within: 2...3))
        #expect(pair.keys == SIMD4(2, 2, 3, 3))
        #expect(abs(pair.weights[1] - 0.5) < 1e-6 && abs(pair.weights[2] - 0.5) < 1e-6)
    }

    private func take(frames: Int, interval: Int = 1) throws -> (url: URL, loaded: RecordingFile.Loaded) {
        let particles = 400
        let scene = SceneConfig.merger(particleCount: particles)
        let recording = Recording(particleCount: particles, galaxyCount: 2, interval: interval)
        var system = ParticleSystem()
        var generator = SeededGenerator(seed: 7)
        for index in 0..<particles {
            system.append(
                position: .zero, velocity: .zero, galaxy: UInt32(index % 2), radius: 1,
                population: generator.uniform(), luminosity: 1)
        }
        for frame in 0..<frames {
            let positions = (0..<particles).map { _ in
                SIMD3<Float>(
                    generator.uniform() * 60 - 30, generator.uniform() * 60 - 30, generator.uniform() * 10 - 5
                )
            }
            let time = Float(frame) * 0.7
            positions.withUnsafeBufferPointer {
                _ = recording.offer(
                    positions: $0.baseAddress!, time: time, centers: [SIMD3(time, 0, 0), SIMD3(-time, 1, 0)],
                    disks: [
                        DiskState(axis: SIMD3(0, 0, 1), disruption: Float(frame) / 100),
                        DiskState(axis: SIMD3(0, 1, 0)),
                    ], budget: 0)
            }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "held-\(UUID().uuidString).sillage")
        try RecordingFile.write(recording, scene: scene, particles: system, to: url)
        return (url, try RecordingFile.read(from: url))
    }

    private func bytes(_ recording: Recording, frame: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: recording.frameBytes)
        out.withUnsafeMutableBytes { _ = recording.copy(frame: frame, to: $0.baseAddress!) }
        return out
    }

    @Test(arguments: [1, 3])
    func anExtractReadBackGivesTheFramesItWasCutFromToTheByte(_ interval: Int) throws {
        let source = try take(frames: 25, interval: interval)
        defer { try? FileManager.default.removeItem(at: source.url) }
        let recording = source.loaded.recording
        let myr = { (index: Int) in Double(recording.frames[index].time) * Physics.megayearsPerTimeUnit }
        let kept = try TakeExtract.frames(of: recording, at: [myr(2) + 0.01, myr(6)], span: 3)
        #expect(kept == [2, 3, 4, 6, 7, 8])
        let out = source.url.deletingPathExtension().appendingPathExtension("extract.sillage")
        defer { try? FileManager.default.removeItem(at: out) }
        let lines = try TakeExtract.command([
            "extract", source.url.path, "--at", "\(myr(2)),\(myr(6))", "--span", "3", out.path,
        ])
        #expect(lines.count == kept.count + 1)
        #expect(!FileManager.default.fileExists(atPath: out.appendingPathExtension("positions").path))
        let back = try RecordingFile.read(from: out)
        let extracted = back.recording
        #expect(extracted.count == kept.count && extracted.capturedFrames == kept.count)
        #expect(extracted.interval == 1 && extracted.bitsPerAxis == recording.bitsPerAxis)
        #expect(back.particles.count == source.loaded.particles.count)
        #expect(back.particles.galaxyIndex == source.loaded.particles.galaxyIndex)
        #expect(back.particles.population == source.loaded.particles.population)
        for (index, frame) in kept.enumerated() {
            let a = try #require(recording.frame(at: frame))
            let b = try #require(extracted.frame(at: index))
            #expect(a.time == b.time && a.origin == b.origin && a.extent == b.extent)
            #expect(recording.centers(at: frame) == extracted.centers(at: index))
            #expect(recording.disks(at: frame).map(\.axis) == extracted.disks(at: index).map(\.axis))
            #expect(
                recording.disks(at: frame).map(\.disruption) == extracted.disks(at: index).map(\.disruption))
            #expect(bytes(recording, frame: frame) == bytes(extracted, frame: index), "frame \(frame)")
        }
        // An extract of the extract is the same frames again, to the byte.
        let again = out.deletingPathExtension().appendingPathExtension("again.sillage")
        defer { try? FileManager.default.removeItem(at: again) }
        _ = try TakeExtract.command(["extract", out.path, "--at", "\(myr(6))", "--span", "2", again.path])
        let twice = try RecordingFile.read(from: again).recording
        #expect(twice.count == 2)
        #expect(bytes(twice, frame: 1) == bytes(recording, frame: 7))
        #expect(throws: TakeExtract.Failure.self) {
            try TakeExtract.command(["extract", source.url.path, "--at", "9000", out.path])
        }
        #expect(throws: TakeExtract.Failure.usage) {
            try TakeExtract.command(["extract", source.url.path, out.path])
        }
    }

    @Test func theCommandsKnowTheirNewOptions() {
        #expect(
            RenderCommands.check(["take", "extract", "a.sillage", "--at", "452", "--span", "4", "b.sillage"])
                == .run)
        if case .refused = RenderCommands.check([
            "take", "extract", "a.sillage", "--at", "452", "--span", "x", "b",
        ]) {
        } else {
            Issue.record("--span x was taken")
        }
        #expect(
            RenderCommands.check([
                "hires", "folder", "--pass", "full", "--key-frames-at", "452,520", "--key-frames-span", "30",
            ])
                == .run)
    }
}
