import Testing

@testable import SillageCore
@testable import SillageRender

@Suite("Look controls")
struct LookControlsTests {
    private var baseline: RenderLook { RenderLook.catalogue[1].look }

    @Test func everyControlIsResetByItsSection() {
        for group in [LookFile.Group.light, .instrument] {
            for control in group.controls {
                let moved = control.moved(baseline)
                #expect(moved != baseline, "\(control.title) did not move")
                #expect(moved.resetting(group, to: baseline) == baseline, "\(control.title)")
            }
        }
    }

    @Test func aSectionLeavesTheOthersAlone() {
        var look = baseline
        for control in LookFile.Group.light.controls { look = control.moved(look) }
        let reset = look.resetting(.instrument, to: baseline)
        #expect(reset == look)
        #expect(look.resetting(.light, to: baseline) == baseline)
    }

    @Test func theSkyAndTheHoleAreResetWithTheInstrument() {
        var look = baseline
        look.skyColour = SIMD3<Float>(0.3, 0.2, 0.1)
        look.holeShadow = 5
        #expect(look.resetting(.instrument, to: baseline) == baseline)
        #expect(look.resetting(.light, to: baseline) == look)
    }

    @Test func theFileResetUsesTheSameControls() {
        var file = LookFile(name: "a", look: baseline, starCount: 1, supersample: 1)
        let base = file
        for control in LookFile.Group.instrument.controls { file.look = control.moved(file.look) }
        #expect(file.resetting(.instrument, to: base) == base)
    }

    /// A look field is either one of the controls, one of the three the light and the instrument
    /// reset without showing, or the camera's field of view: a new field has to be placed in one of them.
    @Test func everyFieldOfALookIsAccountedFor() {
        let shown = LookFile.Group.light.controls.count + LookFile.Group.instrument.controls.count
        let unshown = 3
        let camera = 1
        #expect(Mirror(reflecting: RenderLook()).children.count == shown + unshown + camera)
    }

    @Test func titlesAreUnique() {
        let titles = (LookFile.Group.light.controls + LookFile.Group.instrument.controls).map(\.title)
        #expect(Set(titles).count == titles.count)
    }
}
