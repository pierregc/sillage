import AVFoundation
import Foundation
import Testing
import simd

@testable import SillageCore
@testable import SillageRender

@Suite("Export")
struct ExportTests {
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

    private var autoLook: LookFile {
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

    /// A take that ends off its interval still plays the frames it captured, not one more.
    @Test func aTakeEndingOffTheIntervalKeepsItsLength() throws {
        let loaded = try take(frames: 11, interval: 3)
        #expect(loaded.recording.count == 5 && loaded.recording.capturedFrames == 11)
        let export = try TakeExport(take: loaded, look: autoLook, capturedRate: 10)
        #expect(export.positions(framesPerSecond: 10, start: 0, duration: nil).count == 11)
        let end = try #require(loaded.recording.blend(atCaptured: 10))
        #expect(end.fraction == 1)
    }

    /// At the take's own rate every captured frame is drawn once; at twice the rate the frames
    /// between fall halfway; start and duration cut it in seconds.
    @Test func framesFollowTheRateStartAndDuration() throws {
        let export = try TakeExport(take: take(frames: 12), look: autoLook, capturedRate: 10)
        #expect(export.positions(framesPerSecond: 10, start: 0, duration: nil) == (0..<12).map(Double.init))
        let doubled = export.positions(framesPerSecond: 20, start: 0, duration: nil)
        #expect(doubled.count == 23 && doubled[1] == 0.5 && doubled.last == 11)
        #expect(export.positions(framesPerSecond: 10, start: 0.5, duration: 0.3) == [5, 6, 7])
        #expect(export.positions(framesPerSecond: 10, start: 0.8, duration: 9).count == 4)
        #expect(export.positions(framesPerSecond: 10, start: 99, duration: nil) == [11])
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

    /// The grid and the export replay the camera the same way, so a still of one and the same
    /// frame of the other are the same picture, to the byte.
    @Test func aFrameOfTheExportIsTheSameAsTheGridsStill() throws {
        let loaded = try take(frames: 12, interval: 3)
        var file = autoLook
        file.palette = loaded.scene.galaxies.map(\.color)
        let (width, height) = (96, 54)
        for frame in [0, 7] {
            let cells = try LookSheet(take: loaded).render(
                looks: [file], frames: [frame], width: width, height: height, cellWidth: width,
                cellHeight: height, framesPerSecond: 10)
            let still = try TakeExport(take: loaded, look: file, capturedRate: 10)
                .still(atCaptured: frame, width: width, height: height)
            #expect(cells[0][0] == still)
            #expect(still.contains { $0 > 0 && $0 < 255 })
        }
    }

    @Test func anExportIsAnH264MP4OfTheFramesAsked() async throws {
        let export = try TakeExport(take: take(frames: 12), look: autoLook, capturedRate: 10)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        var seen = 0
        let report = try export.write(
            to: url, width: 64, height: 36, framesPerSecond: 20, duration: 0.5
        ) { done, _ in seen = done }
        #expect(report.frames == 10 && seen == 10)

        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(size == CGSize(width: 64, height: 36))
        let format = try #require(try await track.load(.formatDescriptions).first)
        #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_H264)
        let duration = try await asset.load(.duration)
        #expect(abs(duration.seconds - 0.5) < 0.01)
    }

    private func exported(
        _ codec: VideoCodec, metadata: VideoMetadata? = nil, quality: Double? = nil
    ) async throws -> (AVURLAsset, URL) {
        let export = try TakeExport(take: take(frames: 12), look: autoLook, capturedRate: 10)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-\(UUID().uuidString).\(codec.fileExtension)")
        _ = try export.write(
            to: url, width: 128, height: 72, framesPerSecond: 10, codec: codec, quality: quality,
            metadata: metadata)
        return (AVURLAsset(url: url), url)
    }

    private func subtype(_ asset: AVURLAsset) async throws -> (FourCharCode, CGSize) {
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let format = try #require(try await track.load(.formatDescriptions).first)
        return (
            CMFormatDescriptionGetMediaSubType(format), try await track.load(.naturalSize)
        )
    }

    @Test func hevcIsTaggedHvc1InAnMP4() async throws {
        let (asset, url) = try await exported(.hevc)
        defer { try? FileManager.default.removeItem(at: url) }
        let (codec, size) = try await subtype(asset)
        #expect(codec == kCMVideoCodecType_HEVC && size == CGSize(width: 128, height: 72))
        // `hvc1` is what QuickTime and iOS play; `hev1` is what they refuse.
        let bytes = try Data(contentsOf: url)
        #expect(bytes.range(of: Data("hvc1".utf8)) != nil)
        #expect(bytes.range(of: Data("hev1".utf8)) == nil)
        #expect(url.pathExtension == "mp4")
    }

    @Test func proResIs422HQInAMovie() async throws {
        let (asset, url) = try await exported(.prores)
        defer { try? FileManager.default.removeItem(at: url) }
        let (codec, _) = try await subtype(asset)
        #expect(codec == kCMVideoCodecType_AppleProRes422HQ)
        #expect(url.pathExtension == "mov")
        #expect(try Data(contentsOf: url).prefix(12).suffix(4) == Data("qt  ".utf8))
        #expect(abs(try await asset.load(.duration).seconds - 1.2) < 0.01)
    }

    @Test func aQualityStandsInForTheBitRate() async throws {
        for codec in [VideoCodec.h264, .hevc] {
            let (asset, url) = try await exported(codec, quality: 0.5)
            defer { try? FileManager.default.removeItem(at: url) }
            #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
        }
    }

    @Test func everyExportCarriesItsLicenceAuthorAndScene() async throws {
        let metadata = VideoMetadata(
            sceneID: "2026-10-23/scene-0001", author: "Ada Lovelace",
            date: Date(timeIntervalSince1970: 1_792_000_000))
        for codec in VideoCodec.allCases {
            let (asset, url) = try await exported(codec, metadata: metadata)
            defer { try? FileManager.default.removeItem(at: url) }
            let items = try await asset.load(.metadata)
            var found: [String: String] = [:]
            for item in items {
                if let key = item.identifier?.rawValue, let value = try await item.load(.stringValue) {
                    found[key] = value
                }
            }
            let all = found.values.joined(separator: "\n")
            #expect(all.contains("CC BY 4.0"), "\(codec)")
            #expect(all.contains("https://creativecommons.org/licenses/by/4.0/"), "\(codec)")
            #expect(all.contains("Ada Lovelace"), "\(codec)")
            #expect(all.contains("2026-10-23/scene-0001"), "\(codec)")
            #expect(all.contains("2026"), "\(codec)")
        }
    }

    @Test func codecsAndPresetsAreNamedConsistently() throws {
        let folder = SceneFolder(path: "/library/2026-10-23/scene-0001")
        #expect(folder.sceneID == "2026-10-23/scene-0001")
        #expect(folder.export(preset: "4k").lastPathComponent == "4k.mp4")
        #expect(folder.export(preset: "4k", codec: .hevc).lastPathComponent == "4k-hevc.mp4")
        #expect(folder.export(preset: "4k", codec: .prores).lastPathComponent == "4k-prores.mov")
        #expect(VideoPreset.named("whatsapp")?.codec == .h264)
        #expect(VideoPreset.all.filter { $0.codec != nil }.map(\.name) == ["whatsapp"])
        #expect(VideoCodec.prores.defaultBitRate(width: 1920, height: 1080) == nil)
        #expect(
            VideoCodec.hevc.defaultBitRate(width: 1920, height: 1080)!
                < VideoCodec.h264.defaultBitRate(width: 1920, height: 1080)!)
    }
}
