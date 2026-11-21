import Foundation
import Testing

@testable import SillageCore
@testable import SillageRender

#if canImport(simd)
    import simd
#endif

@Suite("Export")
struct ExportTests {
    /// Two galaxies drifting apart over `frames` captured frames, written and read back as a
    /// real take is.
    func take(frames: Int = 12, interval: Int = 1) throws -> RecordingFile.Loaded {
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
                population: generator.uniform(), luminosity: 1, component: .star)
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
            .appendingPathComponent("export-\(UUID().uuidString).\(RecordingFile.fileExtension)")
        defer { try? FileManager.default.removeItem(at: url) }
        try RecordingFile.write(recording, scene: scene, particles: system, to: url)
        return try RecordingFile.read(from: url)
    }

    var autoLook: LookFile {
        var file = LookFile.standard
        file.camera.mode = .auto
        file.camera.azimuthEnd = 1
        file.look.noiseLevel = 0
        return file
    }

    @Test func presetsHaveEvenSidesAndWhatsAppFitsThirtySeconds() throws {
        #expect(VideoPreset.all.map(\.name) == ["1080p", "4k", "vertical", "square", "whatsapp"])
        #expect(VideoPreset.all.allSatisfy { $0.width % 2 == 0 && $0.height % 2 == 0 })
        #expect(VideoPreset.named("4K")?.width == 3840)
        #expect(VideoPreset.named("vertical").map { ($0.width, $0.height) } ?? (0, 0) == (1080, 1920))
        let whatsapp = try #require(VideoPreset.named("whatsapp"))
        #expect(Double(whatsapp.bitsPerSecond ?? .max) * 30 / 8 <= 16_000_000)
        #expect(VideoPreset.named("cinema") == nil)
    }

    @Test func whatsAppRateFollowsTheClipDownToTheSizeLimit() throws {
        let whatsapp = try #require(VideoPreset.named("whatsapp"))
        #expect(try whatsapp.bitRate(forSeconds: 10) == 4_000_000)
        #expect(try whatsapp.bitRate(forSeconds: 20) == 4_000_000)
        let long = try #require(try whatsapp.bitRate(forSeconds: 60))
        #expect(long < 4_000_000)
        #expect(Double(long) * 60 / 8 <= 15_000_000)
        #expect(throws: SceneFolder.ExportError.self) { try whatsapp.bitRate(forSeconds: 600) }
        #expect(try VideoPreset.named("1080p")?.bitRate(forSeconds: 600) == nil)
        #expect(whatsapp.caption && VideoPreset.named("4k")?.caption == false)
    }

    @Test func theCaptionNamesTheSceneAndTheLicence() {
        let caption = VideoMetadata(sceneID: "2026-10-23/scene-0001").caption
        #expect(caption.contains("Sillage 2026-10-23/scene-0001"))
        #expect(caption.contains("CC BY 4.0 https://creativecommons.org/licenses/by/4.0/"))
    }

    @Test func aFractionalCapturedFrameBlendsBetweenItsNeighbours() throws {
        let loaded = try take(frames: 9, interval: 4)
        let recording = loaded.recording
        for frame in 0..<recording.capturedFrames {
            #expect(recording.blend(atCaptured: Double(frame)) == recording.blend(atCaptured: frame))
        }
        let between = try #require(recording.blend(atCaptured: 2.5))
        #expect(between.keys[1] == 0 && between.keys[2] == 1)
        #expect(abs(between.fraction - 0.625) < 1e-6)
    }

    @Test func aShotBetweenTwoFramesLiesBetweenTheirs() throws {
        let loaded = try take(frames: 12)
        let replay = ShotReplay(file: autoLook, take: loaded, capturedFrames: 12, framesPerSecond: 10)
        let before = replay.shot(atCaptured: 4)
        let after = replay.shot(atCaptured: 5)
        let again = ShotReplay(file: autoLook, take: loaded, capturedFrames: 12, framesPerSecond: 10)
        let middle = again.shot(atCaptured: 4.5)
        #expect(simd_distance(middle.camera.eye, (before.camera.eye + after.camera.eye) / 2) < 1e-3)
        #expect(again.shot(atCaptured: 5.0).camera.eye == after.camera.eye)
    }

    /// A fixed camera looks at the origin unless its plan names another point, and keeps that
    /// point through the turn (#254).
    @Test func aFixedCameraLooksWhereThePlanAims() throws {
        let loaded = try take(frames: 12)
        var file = autoLook
        file.camera = LookFile.CameraPlan(mode: .fixed, azimuth: 0, azimuthEnd: 1, radius: 30)
        let origin = ShotReplay(file: file, take: loaded, capturedFrames: 12, framesPerSecond: 10)
        #expect(origin.shot(atCaptured: 0).camera.target == .zero)
        file.camera.center = SIMD3(4, -2, 1)
        let aimed = ShotReplay(file: file, take: loaded, capturedFrames: 12, framesPerSecond: 10)
        for frame in [0, 6, 11] {
            let camera = aimed.shot(atCaptured: frame).camera
            #expect(camera.target == SIMD3(4, -2, 1))
            let reference = simd_distance(origin.shot(atCaptured: frame).camera.eye, .zero)
            #expect(abs(simd_distance(camera.eye, camera.target) - reference) < 1e-3)
        }
    }

    @Test func codecsAndPresetsAreNamedConsistently() throws {
        let folder = SceneFolder(path: "/library/2026-10-23/scene-0001")
        #expect(folder.sceneID == "2026-10-23/scene-0001")
        #expect(folder.export(preset: "4k").lastPathComponent == "4k.mp4")
        #expect(folder.export(preset: "4k", codec: .h264).lastPathComponent == "4k-h264.mp4")
        #expect(folder.export(preset: "4k", codec: .prores).lastPathComponent == "4k-prores.mov")
        #expect(VideoPreset.named("1080p")?.defaultCodec == .hevc)
        #expect(VideoPreset.named("whatsapp")?.defaultCodec == .h264)
        #expect(VideoPreset.all.filter { $0.codec != nil }.map(\.name) == ["whatsapp"])
        #expect(VideoCodec.prores.defaultBitRate(width: 1920, height: 1080) == nil)
        #expect(
            VideoCodec.hevc.defaultBitRate(width: 1920, height: 1080)!
                < VideoCodec.h264.defaultBitRate(width: 1920, height: 1080)!)
    }

    func looks(_ base: LookFile) -> [LookFile] {
        [LookFile.CameraPlan.Mode.fixed, .auto, .director, .immersed].map { mode in
            var file = base
            file.camera.mode = mode
            return file
        }
    }
}
