import Foundation
import SillageCore
import Testing

@testable import SillageRender
#if canImport(simd)
    import simd
#endif

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

    /// Every shipped style draws the compact sources at the style glint, the raw look aside.
    @Test func theShippedStylesTurnTheGlintDown() {
        #expect(LookCatalogue.repository.allSatisfy { $0.look.glint == RenderLook.styleGlint })
        #expect(RenderLook.all.allSatisfy { $0.glint == RenderLook.styleGlint })
        #expect(LookFile.standard.look.glint == RenderLook.styleGlint && LookFile.raw.look.glint == 1)
    }

    /// Every shipped style that carries dust draws it as the web (#197); one with none has
    /// nothing to draw it with, nor has the raw look.
    @Test func theShippedStylesDrawTheirDustAsAWeb() {
        let web = RenderLook.styleDustWeb
        #expect(web > 0)
        let dusty = LookCatalogue.repository.filter { $0.look.dustStrength > 0 }.map(\.name)
        #expect(dusty.count >= 12 && dusty.contains("hubble") && dusty.contains("webb"))
        for file in LookCatalogue.repository {
            #expect(file.look.dustWeb == (file.look.dustStrength > 0 ? web : 0), "\(file.name)")
        }
        #expect(RenderLook.all.allSatisfy { $0.dustStrength > 0 && $0.dustWeb == web })
        #expect(LookFile.standard.look.dustWeb == web && LookFile.raw.look.dustWeb == 0)
    }

    /// A scene's look written before the dust web existed keeps its grains; a style chosen for
    /// it, by hand or by Auto, brings the catalogue's web.
    @Test func onlyANewStyleDrawsTheWeb() throws {
        let written = String(decoding: try base.encoded(), as: UTF8.self)
        let older = written.replacingOccurrences(of: #""dustWeb" : 1,"#, with: "")
        #expect(older != written)
        let old = try LookFile.decoded(from: Data(older.utf8))
        var expected = base
        expected.look.dustWeb = 0
        #expect(old == expected)
        let palette = try PaletteGenerator.palette(galaxies: 2, world: .telescope, seed: 9)
        for rendering in LookCatalogue.repository {
            let web = rendering.look.dustWeb
            #expect(old.withRendering(rendering).look.dustWeb == web)
            #expect(StyleAuto.apply(rendering, palette: palette, to: old).look.dustWeb == web)
        }
    }

    /// A scene's look written before the glint existed keeps its sparkle; a style chosen for
    /// it, by hand or by Auto, brings the catalogue's.
    @Test func onlyANewStyleTurnsTheGlintDown() throws {
        let written = String(decoding: try base.encoded(), as: UTF8.self)
        let older = written.replacingOccurrences(of: #""glint" : 0.3,"#, with: "")
        #expect(older != written)
        let old = try LookFile.decoded(from: Data(older.utf8))
        var expected = base
        expected.look.glint = 1
        #expect(old == expected)
        let palette = try PaletteGenerator.palette(galaxies: 2, world: .telescope, seed: 9)
        for rendering in LookCatalogue.repository {
            #expect(old.withRendering(rendering).look.glint == RenderLook.styleGlint)
            #expect(StyleAuto.apply(rendering, palette: palette, to: old).look.glint == RenderLook.styleGlint)
        }
    }

    /// Auto's pair is scored and promoted with its rendering's own dust and web: #174 held the
    /// dust back, the web brought it back (#197). Everything else is the rendering's too, and a
    /// rendering chosen by hand draws the same.
    @Test func aGeneratedStyleDrawsItsRenderingsDust() throws {
        let palette = try PaletteGenerator.palette(galaxies: 2, world: .telescope, seed: 9)
        for rendering in LookCatalogue.repository {
            let auto = StyleAuto.apply(rendering, palette: palette, to: base)
            #expect(auto.look.dustStrength == rendering.look.dustStrength)
            #expect(auto.look.dustWeb == rendering.look.dustWeb)
            var look = auto.look
            look.fieldOfView = rendering.look.fieldOfView
            #expect(look == rendering.look)
            #expect(base.withRendering(rendering).look == auto.look)
            #expect(StyleAuto.generated(rendering) == rendering)
        }
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
        edited.look.dustWeb = 0.2
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

    /// Every field a group's controls edit goes back with that group's reset (#209), and the
    /// four together give back every field but the palette, its world and the name. The
    /// controls are the app's, which no test can build: what they bind is read from the
    /// editor's source, the `binding(\.…)` calls of the view each `FineGroup` shows.
    @Test func aResetPutsBackEveryFieldItsGroupsControlsEdit() throws {
        let source = try String(contentsOf: Self.editor, encoding: .utf8)
        var baseline = base
        baseline.camera.elevationEnd = 0.2
        baseline.camera.azimuthEnd = 0.1
        let edited = try Self.moved(baseline)
        var all = edited
        for group in LookFile.Group.allCases {
            let paths = try #require(Self.bound(group, in: source), "the controls of \(group)")
            #expect(paths.count >= 5, "\(group): \(paths)")
            let reset = edited.resetting(group, to: baseline)
            for path in paths {
                let value = Self.value(path, in: baseline)
                #expect(value != nil && Self.value(path, in: edited) != value, "\(path) is moved")
                #expect(Self.value(path, in: reset) == value, "\(group) puts back \(path)")
            }
            all = all.resetting(group, to: baseline)
        }
        var expected = baseline
        expected.name = edited.name
        expected.palette = edited.palette
        expected.world = edited.world
        #expect(all == expected)
    }

    static let editor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/SillageApp/StyleEditor.swift")

    /// The key paths the controls of `group` bind, as "look.glint".
    static func bound(_ group: LookFile.Group, in source: String) -> [String]? {
        guard let opening = source.range(of: "group: .\(group.rawValue)) {") else { return nil }
        let view = source[opening.upperBound...].drop { $0.isWhitespace }.prefix { $0.isLetter }
        guard !view.isEmpty, let start = source.range(of: "struct \(view): View {") else { return nil }
        let end = source.range(of: "\n}\n", range: start.upperBound..<source.endIndex)
        return source[start.upperBound..<(end?.lowerBound ?? source.endIndex)]
            .components(separatedBy: "binding(\\.").dropFirst()
            .map { String($0.prefix { $0.isLetter || $0 == "." }) }
    }

    /// The value at a path such as "look.glint", read through the file's mirror.
    static func value(_ path: String, in file: LookFile) -> String? {
        var value: Any = file
        for label in path.split(separator: ".").map(String.init) {
            guard let child = Mirror(reflecting: value).children.first(where: { $0.label == label })
            else { return nil }
            value = child.value
        }
        return String(describing: value)
    }

    /// `file` with every number one higher, every switch flipped and the spike pattern swapped:
    /// no field keeps its value but the version, the name and the world.
    static func moved(_ file: LookFile) throws -> LookFile {
        func move(_ value: Any) -> Any {
            switch value {
            case let object as [String: Any]: return object.mapValues(move)
            case let array as [Any]: return array.map(move)
            case let flag as NSNumber where CFGetTypeID(flag) == CFBooleanGetTypeID():
                return !flag.boolValue
            case let number as NSNumber:
                let double = number.doubleValue
                if double == double.rounded() { return Int(double) + 1 }
                return double + 1
            case let name as String:
                return RenderLook.SpikePattern(rawValue: name).map { $0 == .even ? "webb" : "even" } ?? name
            default: return value
            }
        }
        let object = try #require(JSONSerialization.jsonObject(with: file.encoded()) as? [String: Any])
        var moved = try #require(move(object) as? [String: Any])
        moved["version"] = object["version"]
        return try LookFile.decoded(from: JSONSerialization.data(withJSONObject: moved))
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
