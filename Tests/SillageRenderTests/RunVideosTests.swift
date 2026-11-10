import CoreGraphics
import Foundation
import Metal
import Testing

@testable import SillageCore
@testable import SillageRender
#if canImport(simd)
    import simd
#endif

/// The videos a full pass draws as it runs (#239), against what `export` draws from a take.
@Suite("Videos drawn during the run")
struct RunVideosTests {
    /// Two galaxies drifting apart over `frames` captured frames, written and read back as a
    /// real take is.
    private func take(frames: Int = 12, interval: Int = 1) throws -> RecordingFile.Loaded {
        let particles = 2000
        let scene = SceneConfig.merger(particleCount: particles)
        let recording = Recording(particleCount: particles, galaxyCount: 2, interval: interval)
        var system = ParticleSystem()
        var generator = SeededGenerator(seed: 3)
        var start: [SIMD3<Float>] = []
        for index in 0..<particles {
            let position = SIMD3<Float>(
                generator.uniform() * 20 - 10, generator.uniform() * 20 - 10,
                generator.uniform() - 0.5)
            start.append(position)
            system.append(
                position: position, velocity: .zero, galaxy: UInt32(index % 2), radius: 1,
                population: generator.uniform(), luminosity: 1,
                formation: index % 7 == 0 ? Float(index % 5) * 0.2 : ParticleSystem.ancient,
                component: index % 7 == 0 ? .dust : .star)
        }
        for frame in 0..<frames {
            let drift = Float(frame) * 0.4
            let positions = start.enumerated().map { index, position in
                position + SIMD3<Float>(index % 2 == 0 ? -drift : drift, 0, 0)
            }
            let centers = [SIMD3<Float>(-drift - 5, 0, 0), SIMD3<Float>(drift + 5, 0, 0)]
            positions.withUnsafeBufferPointer {
                recording.append(
                    positions: $0.baseAddress!, time: Float(frame) * 0.1, centers: centers)
            }
        }
        recording.finish()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("run-\(UUID().uuidString).\(RecordingFile.fileExtension)")
        defer { try? FileManager.default.removeItem(at: url) }
        try RecordingFile.write(recording, scene: scene, particles: system, to: url)
        return try RecordingFile.read(from: url)
    }

    private func look(_ mode: LookFile.CameraPlan.Mode, _ loaded: RecordingFile.Loaded) -> LookFile {
        var file = LookFile.standard
        file.camera.mode = mode
        file.camera.azimuthEnd = 1
        if mode == .fixed { file.camera.radius = 30 }
        file.palette = loaded.scene.galaxies.map { GalaxyColours($0.color) }
        return file
    }

    private func bytes(_ image: CGImage) -> [UInt8] {
        guard let data = image.dataProvider?.data as Data? else { return [] }
        return [UInt8](data)
    }

    /// Fed the take's own positions frame by frame, as the solver would feed them, the full
    /// pass draws every frame of every format to the byte as `export` draws it from the take.
    @Test(arguments: [LookFile.CameraPlan.Mode.auto, .fixed, .immersed, .director])
    func aRunDrawsWhatTheExportOfItsTakeDraws(_ mode: LookFile.CameraPlan.Mode) throws {
        let loaded = try take(frames: 12)
        let file = look(mode, loaded)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("run-videos-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let presets = [
            VideoPreset(name: "wide", width: 96, height: 54),
            VideoPreset(name: "tall", width: 54, height: 96),
        ]

        var exported: [String: [Int: [UInt8]]] = [:]
        for preset in presets {
            var frames: [Int: [UInt8]] = [:]
            _ = try TakeExport(take: loaded, look: file, capturedRate: 10, device: device).write(
                to: folder.appendingPathComponent("export-\(preset.name).mp4"), width: preset.width,
                height: preset.height, framesPerSecond: 10, stills: Set(0..<12),
                still: { frame, image in frames[frame] = bytes(image) })
            exported[preset.name] = frames
        }

        // What the solver would hold: a buffer of positions, refreshed each frame.
        let count = loaded.recording.particleCount
        let positions = try #require(
            device.makeBuffer(length: count * MemoryLayout<SIMD3<Float>>.stride, options: .storageModeShared))
        let expander = try SnapshotExpander(device: device, recording: loaded.recording)
        let stream = try #require(SnapshotStream(device: device, recording: loaded.recording))
        let smoothing = try SmoothingField(device: device, particleCount: count)
        let drawing = try Renderer(
            device: device, particles: loaded.particles,
            settings: file.renderSettings(width: 16, height: 16), externalPositions: positions)
        let videos = try RunVideos(
            formats: presets.map {
                try RunVideos.Format(
                    preset: $0, frames: 12, framesPerSecond: 10,
                    url: folder.appendingPathComponent("run-\($0.name).mp4"))
            },
            look: file, framing: loaded, capturedRate: 10, drawing: drawing,
            smoothing: smoothing.buffer)
        var drawn: [String: [Int: [UInt8]]] = [:]
        for frame in 0..<12 {
            let blend = try #require(loaded.recording.blend(atCaptured: frame))
            #expect(expander.expand(blend, of: loaded.recording, through: stream, into: positions))
            smoothing.update(from: positions)
            try videos.draw(frame: frame, centres: loaded.recording.centers(at: blend)) { format, image in
                drawn[format.preset.name, default: [:]][frame] = bytes(image)
            }
        }
        let reports = try videos.finish()
        #expect(reports.map(\.frames) == [12, 12])
        for preset in presets {
            let video = SceneFolder.partial(folder.appendingPathComponent("run-\(preset.name).mp4"))
            #expect(FileManager.default.fileExists(atPath: video.path))
            for frame in 0..<12 {
                let mine = try #require(drawn[preset.name]?[frame])
                #expect(mine == exported[preset.name]?[frame], "\(mode) \(preset.name) frame \(frame)")
                #expect(mine.contains { $0 > 0 && $0 < 255 })
            }
        }
        // The centres given are the take's own: nothing strayed.
        #expect(videos.checkedFrames == 12 && videos.drift == 0 && videos.firstDrift == nil)
    }

    /// A renderer over another's particles draws what one of its own does, at any size.
    @Test func aRendererSharingAnothersParticlesDrawsTheSame() throws {
        let loaded = try take(frames: 2)
        let file = look(.fixed, loaded)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let camera = Camera(eye: SIMD3(0, -40, 15), target: .zero, fieldOfView: 0.8)
        for (width, height) in [(64, 36), (36, 64)] {
            let settings = file.renderSettings(width: width, height: height)
            let own = try Renderer(device: device, particles: loaded.particles, settings: settings)
            let first = try Renderer(
                device: device, particles: loaded.particles,
                settings: file.renderSettings(width: 8, height: 8))
            let shared = try Renderer(sharing: first, settings: settings)
            for renderer in [own, shared] { renderer.apply(file) }
            #expect(shared.positions === first.positions)
            #expect(shared.luminosityNormalisation == own.luminosityNormalisation)
            let image = own.render(camera: camera)
            #expect(shared.render(camera: camera) == image)
            #expect(image.contains { $0 > 0 })
        }
    }

    /// The stars a run formed count as the youngest there are in a take's exposure, which a
    /// live run does not know yet: a full pass takes it from the massive take, as an export of
    /// that take does (docs/notes/render-during-hires.md).
    @Test func starsFormedInTheRunLowerATakesExposure() throws {
        let loaded = try take(frames: 2)
        let formation = loaded.particles.formation
        let live = formation.map { $0 >= 0 && $0 < 1e8 ? ParticleSystem.unformed : $0 }
        #expect(
            Renderer.luminosityNormalisation(formation: formation)
                < Renderer.luminosityNormalisation(formation: live))
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try Renderer(
            device: device, particles: loaded.particles,
            settings: look(.fixed, loaded).renderSettings(width: 8, height: 8))
        #expect(renderer.luminosityNormalisation == Renderer.luminosityNormalisation(formation: formation))
    }

    /// Every drawn particle at the key frames only, one stored frame each, and which they are.
    @Test func keyFramesKeepEveryParticleAtTheirFrames() throws {
        let loaded = try take(frames: 12)
        let keys = [
            KeyFrame(frame: 9, role: .tails, timeMyr: 0), KeyFrame(frame: 0, role: .start, timeMyr: 0),
            KeyFrame(frame: 4, role: .pericentre, timeMyr: 0),
        ]
        let count = loaded.recording.particleCount
        let kept = try KeyFrameTake(keys: keys, particleCount: count, galaxyCount: 2)
        for frame in 0..<12 {
            guard kept.wants(frame: frame) else { continue }
            let positions = loaded.recording.positions(at: frame)
            try positions.withUnsafeBufferPointer {
                try kept.offer(
                    frame: frame, positions: $0.baseAddress!, time: Float(frame) * 0.1,
                    centers: loaded.recording.centers(at: frame), disks: [])
            }
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("keys-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("keyframes.sillage")
        let list = folder.appendingPathComponent("keyframes.json")
        try kept.write(scene: loaded.scene, particles: loaded.particles, to: url, list: list)

        let read = try RecordingFile.read(from: url)
        #expect(read.recording.count == 3 && read.recording.particleCount == count)
        let entries = try JSONDecoder().decode([KeyFrameTake.Entry].self, from: Data(contentsOf: list))
        #expect(entries.map(\.frame) == [0, 4, 9])
        #expect(entries.map(\.role) == ["start", "pericentre", "tails"])
        let step = try read.recording.quantum(of: #require(read.recording.frame(at: 2)))
        let original = loaded.recording.positions(at: 9)
        let again = read.recording.positions(at: 2)
        #expect(zip(original, again).allSatisfy { simd_distance($0, $1) <= step * 2 })
        #expect(abs((read.recording.frame(at: 1)?.time ?? 0) - 0.4) < 1e-6)
    }
}
