import Foundation
import Testing

@testable import SillageCore
@testable import SillageRender

#if canImport(simd)
    import simd
#endif

extension PlanPlayheadTests {
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
}
