import Foundation
import Testing
import simd

@testable import SillageCore
@testable import SillageRender

/// The canvas against the export (#177): the plan replayed at a scrubbed playhead is the shot
/// the export draws there, and the mouse edits the plan itself.
@Suite("Plan playhead")
struct PlanPlayheadTests {
    /// Two galaxies passing each other over `frames` captured frames, written and read back as
    /// a real take is.
    private func take(frames: Int, interval: Int) throws -> RecordingFile.Loaded {
        let particles = 3000
        var scene = SceneConfig.merger(particleCount: particles)
        scene.seed = 41
        let recording = Recording(particleCount: particles, galaxyCount: 2, interval: interval)
        var system = ParticleSystem()
        var generator = SeededGenerator(seed: 5)
        var start: [SIMD3<Float>] = []
        for index in 0..<particles {
            let position = SIMD3<Float>(
                generator.uniform() * 30 - 15, generator.uniform() * 30 - 15, generator.uniform() * 2 - 1)
            start.append(position)
            system.append(
                position: position, velocity: .zero, galaxy: UInt32(index % 2), radius: 1,
                population: generator.uniform(), luminosity: 1, component: .star)
        }
        for frame in 0..<frames {
            let t = Float(frame) / Float(max(frames - 1, 1))
            let centers = [
                SIMD3<Float>(-40 + 80 * t, 12 * sin(3 * t), 0),
                SIMD3<Float>(40 - 80 * t, -12 * sin(3 * t), 2),
            ]
            let positions = start.enumerated().map { index, position in
                position + centers[index % 2]
            }
            positions.withUnsafeBufferPointer {
                recording.append(positions: $0.baseAddress!, time: Float(frame) * 0.05, centers: centers)
            }
        }
        recording.finish()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-\(UUID().uuidString).\(RecordingFile.fileExtension)")
        defer { try? FileManager.default.removeItem(at: url) }
        try RecordingFile.write(recording, scene: scene, particles: system, to: url)
        return try RecordingFile.read(from: url)
    }

    private func file(_ mode: LookFile.CameraPlan.Mode, zoom: Float = 0.445) -> LookFile {
        var file = LookFile.standard
        file.camera = .init(mode: mode, elevation: 0.7, azimuthEnd: 0.6, zoom: zoom)
        return file
    }

    @Test(arguments: [
        LookFile.CameraPlan.Mode.auto, .director, .fixed, .immersed,
    ])
    func theCanvasDrawsTheShotTheExportDraws(_ mode: LookFile.CameraPlan.Mode) throws {
        // At ten frames a second the director has room for its close shots.
        let loaded = try take(frames: 121, interval: 4)
        let look = file(mode)
        let export = try TakeExport(take: loaded, look: look, capturedRate: 10)
        let playhead = PlanPlayhead(take: loaded, capturedRate: 10)
        // Forwards between frames, back past where it was, to the start, to the end.
        for position in [17.5, 17.5, 61.25, 22, 22.75, 0, 94.6, 120] {
            let canvas = playhead.shot(look, atCaptured: position, aspect: 16.0 / 9.0)
            let exported = try #require(
                export.shots(atCaptured: [position], width: 1280, height: 720).first)
            #expect(canvas.camera.eye == exported.camera.eye)
            #expect(canvas.camera.target == exported.camera.target)
            #expect(canvas.camera.fieldOfView == exported.camera.fieldOfView)
            #expect(canvas.look == exported.look)
        }
    }

    /// An edit of the plan is drawn at once, without stepping the playhead.
    @Test func anEditedPlanIsReplayedAtThePlayhead() throws {
        let loaded = try take(frames: 41, interval: 2)
        let playhead = PlanPlayhead(take: loaded, capturedRate: 30)
        var look = file(.director, zoom: 1)
        let near = playhead.shot(look, atCaptured: 30.5, aspect: 1).camera
        look.camera.zoom = 0.5
        let far = playhead.shot(look, atCaptured: 30.5, aspect: 1).camera
        let exported = try #require(
            try TakeExport(take: loaded, look: look, capturedRate: 30)
                .shots(atCaptured: [30.5], width: 1080, height: 1080).first)
        #expect(far.eye == exported.camera.eye)
        #expect(simd_distance(far.eye, far.target) > simd_distance(near.eye, near.target) * 1.5)
    }

    /// The director's plan takes another camera plan and lens without reading the take again,
    /// and frames every shot as a plan made afresh with them would.
    @Test func aReplannedDirectorIsThePlanMadeAfresh() throws {
        let loaded = try take(frames: 121, interval: 4)
        let first = file(.director)
        var second = file(.director, zoom: 1.7)
        second.camera = second.camera.turned(azimuth: 1.1, elevation: -0.4)
        second.look.fieldOfView = 0.8
        let plan = ShotPlan(take: loaded, file: first, framesPerSecond: 10)
        #expect(plan.closeShare > 0)
        let replanned = plan.replanned(camera: second.camera, fieldOfView: second.look.fieldOfView)
        let afresh = ShotPlan(take: loaded, file: second, framesPerSecond: 10)
        #expect(replanned.shots == afresh.shots)
        for position in stride(from: 0.0, through: 120, by: 2.5) {
            let a = replanned.camera(atCaptured: position, aspect: 16.0 / 9.0)
            let b = afresh.camera(atCaptured: position, aspect: 16.0 / 9.0)
            #expect(a.eye == b.eye && a.target == b.target && a.up == b.up && a.fieldOfView == b.fieldOfView)
        }
    }

    @Test func aRadiusSortedOnceIsTheOneMeasuredEachTime() {
        var generator = SeededGenerator(seed: 9)
        let points = (0..<500).map { _ in
            SIMD3<Float>(generator.uniform() * 80 - 40, generator.uniform() * 80 - 40, 0)
        }
        let sorted = points.map { simd_length($0) }.sorted()
        for plan in [
            LookFile.CameraPlan(zoom: 0.445), .init(zoom: 2, percentile: 0.5), .init(zoom: 3, radius: 40),
        ] {
            #expect(plan.framedRadius(sortedRadii: sorted) == plan.framedRadius(positions: points))
        }
    }

    /// The canvas counts its playhead in stored frames, the export in captured ones, and a take
    /// rarely ends on its interval.
    @Test func aStoredPlayheadStandsAtTheCapturedFrameAnExportDraws() throws {
        let recording = try take(frames: 11, interval: 3).recording
        #expect(recording.count == 5 && recording.capturedFrames == 11)
        #expect(recording.capturedPosition(atStored: 2.5) == 7.5)
        #expect(recording.capturedPosition(atStored: 3.5) == 9.5)
        #expect(recording.capturedPosition(atStored: 4) == 10)
        #expect(recording.capturedPosition(atStored: 9) == 10)
        for stored in stride(from: 0.0, through: 4, by: 0.25) {
            let canvas = try #require(recording.blend(at: stored))
            let export = try #require(
                recording.blend(atCaptured: recording.capturedPosition(atStored: stored)))
            #expect(abs(canvas.time - export.time) < 1e-6)
            #expect(simd_distance(recording.centers(at: canvas)[0], recording.centers(at: export)[0]) < 1e-4)
        }
    }

    @Test func aDragTurnsThePlanAndKeepsItsMoveOverTheClip() {
        let plan = LookFile.CameraPlan(
            mode: .fixed, elevation: 1.2, elevationEnd: 0.9, azimuth: 3, azimuthEnd: 3.6)
        let turned = plan.turned(azimuth: 0.4, elevation: 0.5)
        #expect(turned.elevation == LookFile.CameraPlan.steepest)
        #expect(abs((turned.elevationEnd ?? 0) - (LookFile.CameraPlan.steepest - 0.3)) < 1e-5)
        // Past half a turn the start wraps, and the end goes round with it.
        #expect(abs(turned.azimuth - (3.4 - 2 * .pi)) < 1e-5)
        #expect(abs(turned.rotation - plan.rotation) < 1e-5)
        let still = LookFile.CameraPlan(mode: .fixed).turned(azimuth: -0.2, elevation: 0.1)
        #expect(still.azimuthEnd == nil && still.elevationEnd == nil && still.azimuth == -0.2)
    }

    @Test func theWheelZoomsOrScalesTheRadiusThePlanNames() {
        #expect(LookFile.CameraPlan(zoom: 1).zoomed(by: 2).zoom == 2)
        #expect(LookFile.CameraPlan(zoom: 4).zoomed(by: 2).zoom == LookFile.CameraPlan.zoomRange.upperBound)
        #expect(LookFile.CameraPlan(mode: .director, zoom: 0.3).zoomed(by: 0.5).zoom == 0.2)
        let named = LookFile.CameraPlan(mode: .fixed, radius: 60).zoomed(by: 2)
        #expect(named.radius == 30 && named.zoom == 1)
        // Auto frames its own radius, which only the zoom reaches.
        let auto = LookFile.CameraPlan(mode: .auto, radius: 60).zoomed(by: 2)
        #expect(auto.radius == 60 && auto.zoom == 2)
        // The director's wide shots follow the plan's angles; the immersed one chooses its own.
        #expect(LookFile.CameraPlan(mode: .director).placesCamera)
        #expect(!LookFile.CameraPlan(mode: .immersed).placesCamera)
    }
}
