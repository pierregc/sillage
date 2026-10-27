import Foundation
import SillageCore
import Testing
import simd

@testable import SillageRender

@Suite("Style editor")
struct StyleEditTests {
    private var scene: SceneConfig { SceneConfig.merger(particleCount: 20_000) }

    /// A scene's look as the editor finds it: its own palette, camera and field of view.
    private var base: LookFile {
        var file = LookFile.standard
        file.name = "scene"
        file.palette = [GalaxyColours(SIMD3(0.9, 0.6, 0.3)), GalaxyColours(SIMD3(0.3, 0.6, 0.9))]
        file.world = .free
        file.look.fieldOfView = 0.9
        file.camera = .init(mode: .auto, elevation: 0.4, zoom: 1.4)
        return file
    }

    private var rendering: LookFile {
        LookCatalogue.repository.first { $0.name == "webb" }!
    }

    @Test func theRepositoryCatalogueHoldsTheFortyLooksAndBothTelescopes() {
        let names = LookCatalogue.repository.map(\.name)
        #expect(names.count == 42)
        #expect(names.contains("hubble") && names.contains("webb") && !names.contains("raw"))
        #expect(LookCatalogue.renderings(.free, in: LookCatalogue.repository).count == 40)
    }

    @Test func aRenderingKeepsThePaletteTheCameraAndTheFieldOfView() {
        let file = base.withRendering(rendering)
        #expect(file.palette == base.palette && file.world == .free)
        #expect(file.camera == base.camera && file.look.fieldOfView == 0.9)
        #expect(file.look.spikePattern == .webb && file.starCount == rendering.starCount)
        #expect(file.uses(rendering: rendering))
        #expect(!base.uses(rendering: rendering))
    }

    @Test func withItsColoursARenderingBringsItsPaletteAndWorld() {
        let file = base.withRendering(rendering, colours: true)
        #expect(file.palette == rendering.palette && file.world == .telescope)
        #expect(file.camera == base.camera && file.uses(rendering: rendering))
    }

    @Test func aLockedColourSurvivesANewPalette() throws {
        let palette = try PaletteGenerator.palette(galaxies: 2, world: .telescope, seed: 9)
        let file = base.withPalette(palette, keeping: [1], in: scene)
        #expect(file.palette.count == 2)
        #expect(file.palette[1] == base.palette[1])
        #expect(file.palette[0].colour == palette.colours[0] && file.palette[0].ramp?.mapping == .mix)
        #expect(file.world == .telescope && file.paletteRecipe == palette)
        #expect(base.withPalette(palette, in: scene).palette[1].colour == palette.colours[1])
    }

    @Test func aLockOnAGalaxyBeyondThePaletteKeepsTheScenesColour() throws {
        var file = base
        file.palette = []
        let palette = try PaletteGenerator.palette(galaxies: 2, world: .free, seed: 4)
        let locked = file.withPalette(palette, keeping: [0], in: scene)
        #expect(locked.palette[0].colour == scene.galaxies[0].color)
    }

    @Test func everyGroupPutBackGivesTheBaselineBack() {
        var edited = base.withRendering(rendering)
        edited.look.brightness = 0.9
        edited.look.spikeLength = 3
        edited.starCount = 7
        edited.camera.zoom = 3
        edited.look.fieldOfView = 0.3
        var file = edited
        for group in LookFile.Group.allCases { file = file.resetting(group, to: base) }
        var expected = base
        expected.name = edited.name
        #expect(file == expected)

        let light = edited.resetting(.light, to: base)
        #expect(light.look.brightness == base.look.brightness && light.look.spikeLength == 3)
        let camera = edited.resetting(.camera, to: base)
        #expect(camera.camera == base.camera && camera.look.fieldOfView == 0.9 && camera.starCount == 7)
    }

    @Test func rotationIsTheTurnBetweenTheStartAndEndAzimuths() {
        var plan = LookFile.CameraPlan(azimuth: 0.5)
        #expect(plan.rotation == 0)
        plan.rotation = 1.2
        #expect(abs((plan.azimuthEnd ?? 0) - 1.7) < 1e-6 && abs(plan.rotation - 1.2) < 1e-6)
        plan.rotation = 0
        #expect(plan.azimuthEnd == nil)
    }
}
