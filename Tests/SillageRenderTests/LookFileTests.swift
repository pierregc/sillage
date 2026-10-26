import Foundation
import SillageCore
import Testing
import simd

@testable import SillageRender

@Suite("Look file")
struct LookFileTests {
    private func decoded(_ json: String) throws -> LookFile {
        try LookFile.decoded(from: Data(json.utf8))
    }

    @Test func anEmptyFileIsTheStandardLook() throws {
        #expect(try decoded(#"{"version": 1}"#) == .standard)
        #expect(try decoded(#"{"version": 1, "look": {}, "camera": {}}"#) == .standard)
    }

    @Test func aFileChangesOnlyWhatItNames() throws {
        var expected = LookFile.standard
        expected.look.brightness = 0.3
        expected.camera.azimuthEnd = 2
        #expect(
            try decoded(#"{"version": 1, "look": {"brightness": 0.3}, "camera": {"azimuthEnd": 2}}"#)
                == expected)
    }

    @Test func readingThenWritingGivesAnIdenticalFile() throws {
        var file = LookFile.raw
        file.camera = .init(
            mode: .immersed, elevation: 0.4, elevationEnd: 0.9, azimuth: 1, azimuthEnd: 3,
            zoom: 1.3, percentile: 0.9, radius: 80)
        for look in [LookFile.standard, .raw, file] {
            let written = try look.encoded()
            #expect(try LookFile.decoded(from: written) == look)
            #expect(try LookFile.decoded(from: written).encoded() == written)
        }
    }

    @Test func aMisspeltFieldOrAnUnknownVersionIsRefused() throws {
        #expect(throws: DecodingError.self) { try decoded(#"{"version": 1, "brigthness": 1}"#) }
        #expect(throws: DecodingError.self) {
            try decoded(#"{"version": 1, "look": {"brigthness": 1}}"#)
        }
        #expect(throws: DecodingError.self) {
            try decoded(#"{"version": 1, "camera": {"mode": "spinning"}}"#)
        }
        #expect(throws: DecodingError.self) { try decoded(#"{"look": {}}"#) }
        #expect(throws: LookFile.ReadError.self) { try decoded(#"{"version": 2}"#) }
    }

    /// A field added to the look cannot be silently left out of the file that replays it.
    @Test func everyFieldOfTheLookIsWritten() throws {
        func keys(_ data: Data) throws -> Set<String> {
            Set((try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]).keys)
        }
        func fields(_ value: Any) -> Set<String> {
            Set(Mirror(reflecting: value).children.compactMap(\.label))
        }
        var file = LookFile.raw
        file.paletteRecipe = Palette(
            world: .free, family: "ember", harmony: .triadic, seed: 1, colours: file.palette)
        #expect(try keys(JSONEncoder().encode(file.look)) == fields(file.look))
        #expect(try keys(file.encoded()) == fields(file))
    }

    @Test func theShippedRawFileIsTheRawLook() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("looks/raw.look.json")
        let raw = try LookFile.decoded(from: Data(contentsOf: url))
        #expect(raw == .raw)
        #expect(raw.look.bloomIntensity == 0 && raw.look.spikeIntensity == 0)
        #expect(raw.look.dustStrength == 0 && raw.look.skyLevel == 0 && raw.look.noiseLevel == 0)
        #expect(raw.starCount == 0 && raw.armStrength == 0 && raw.camera.mode == .auto && raw.plain)
        #expect(raw.look.minimumKernel == raw.look.maximumKernel)
    }

    /// What the director writes is enough to begin the same scene again and get every frame
    /// back, including a look it picked itself.
    @Test(arguments: [false, true])
    func theDirectorWritesWhatItPicked(immersed: Bool) throws {
        let subject = Subject(centres: [SIMD3(-30, 0, 0), SIMD3(30, 6, -4)], radius: 46)
        let first = Cinematographer(seed: 11)
        first.beginScene(seed: 11, immersed: immersed)
        let file = try LookFile.decoded(from: first.lookFile().encoded())
        #expect(RenderLook.all.contains(file.look))
        #expect(file.camera.mode == (immersed ? .immersed : .director))

        let second = Cinematographer(seed: 11)
        second.beginScene(seed: 11, base: file.look, immersed: file.camera.mode == .immersed)
        for _ in 0..<600 {
            first.advance(seconds: 1.0 / 30, of: subject)
            second.advance(seconds: 1.0 / 30, of: subject)
            #expect(first.look == second.look)
            #expect(first.camera.eye == second.camera.eye)
            #expect(first.camera.target == second.camera.target)
        }
    }

    /// Every field of the settings comes from the file, so a renderer built from it draws what
    /// the file says rather than `RenderSettings`'s own defaults.
    @Test func theSettingsCarryEveryFieldOfTheFile() {
        var file = LookFile.raw
        file.look = .dream
        file.starCount = 1234
        file.look.whitePoint = 7
        let s = file.renderSettings(width: 320, height: 200)
        let look = file.look
        #expect(s.width == 320 && s.height == 200)
        #expect(s.supersample == file.supersample && s.starCount == 1234)
        #expect(s.bloomLevels == file.bloomLevels && s.plain == file.plain)
        #expect(
            RenderLook(
                brightness: s.brightness, dustStrength: s.dustStrength,
                smoothingScale: s.smoothingScale, minimumKernel: s.minimumKernel,
                maximumKernel: s.maximumKernel, bloomThreshold: s.bloomThreshold,
                bloomSoftKnee: s.bloomSoftKnee, bloomIntensity: s.bloomIntensity,
                stretch: s.stretch, saturation: s.saturation, whitePoint: s.whitePoint,
                spikeArms: s.spikeArms, spikeLength: s.spikeLength,
                spikeIntensity: s.spikeIntensity, skyLevel: s.skyLevel, noiseLevel: s.noiseLevel,
                galaxyTint: s.galaxyTint, starSize: s.starSize,
                armPersistence: look.armPersistence, fieldOfView: look.fieldOfView) == look)
    }

    @Test func onlyTheFieldsThatOwnBuffersRebuildTheRenderer() {
        let base = LookFile.standard
        var live = base
        live.look = .ember
        live.armStrength = 0.4
        live.palette = [SIMD3(1, 0, 0)]
        live.camera.zoom = 2
        #expect(!live.rebuildsRenderer(from: base))
        for change in [
            { (f: inout LookFile) in f.supersample = 3 }, { $0.starCount = 10 },
            { $0.bloomLevels = 3 }, { $0.plain = true },
        ] {
            var other = base
            change(&other)
            #expect(other.rebuildsRenderer(from: base))
        }
    }

    @Test func thePaletteRecoloursOnlyTheGalaxiesItReaches() {
        var scene = SceneConfig.merger(particleCount: 2000)
        let kept = scene.galaxies[1].color
        var file = LookFile.standard
        file.palette = [SIMD3(0.1, 0.2, 0.3)]
        file.paint(&scene)
        #expect(scene.galaxies[0].color == SIMD3(0.1, 0.2, 0.3))
        #expect(scene.galaxies[1].color == kept)
    }

    @Test func aFixedPlanEasesFromItsStartToItsEnd() {
        let plan = LookFile.CameraPlan(elevation: 0.2, elevationEnd: 1.0, azimuth: 0, azimuthEnd: 2)
        let start = plan.camera(progress: 0, radius: 10, fieldOfView: 0.6)
        let end = plan.camera(progress: 1, radius: 10, fieldOfView: 0.6)
        #expect(start.eye == Camera.framing(radius: 10, elevation: 0.2, azimuth: 0).eye)
        #expect(end.eye == Camera.framing(radius: 10, elevation: 1.0, azimuth: 2).eye)
        let held = LookFile.CameraPlan(elevation: 0.7, azimuth: 1)
        #expect(
            held.camera(progress: 0.5, radius: 10, fieldOfView: 0.6).eye
                == held.camera(progress: 0, radius: 10, fieldOfView: 0.6).eye)
        let points = (1...100).map { SIMD3<Float>(Float($0), 0, 0) }
        #expect(LookFile.CameraPlan(zoom: 2, percentile: 0.5).framedRadius(positions: points) == 25.5)
        #expect(LookFile.CameraPlan(zoom: 2, radius: 40).framedRadius(positions: points) == 40)
    }

    private func threeGalaxies() -> SceneConfig {
        var scene = SceneConfig.merger(particleCount: 2000)
        scene.galaxies.append(scene.galaxies[0])
        for index in scene.galaxies.indices {
            scene.galaxies[index].color = SIMD3(Float(index) / 4, 0.5, 1)
        }
        return scene
    }

    @Test func aGalaxyColourIsWrittenWithTheOnesBeforeItAndNoneAfter() {
        let scene = threeGalaxies()
        var file = LookFile.standard
        #expect(file.colour(ofGalaxy: 2, in: scene) == scene.galaxies[2].color)
        file.setColour(SIMD3(1, 0, 0), ofGalaxy: 1, in: scene)
        #expect(file.palette == [scene.galaxies[0].color, SIMD3(1, 0, 0)])
        let painted = file.painted(scene)
        #expect(
            painted.galaxies.map(\.color) == [
                scene.galaxies[0].color, SIMD3(1, 0, 0), scene.galaxies[2].color,
            ])
        #expect(file.colour(ofGalaxy: 1, in: scene) == SIMD3(1, 0, 0))
        // Painting never feeds back: the colours are read from the scene as it came.
        #expect(file.painted(painted) == painted)
    }

    /// The app holds a look file and the take's own scene, and nothing else about the
    /// picture: opening one and saving it untouched writes the same bytes, and every edit the
    /// panel makes survives a save and a reopen.
    @Test func whatTheAppHoldsIsWhatItSaves() throws {
        let scene = threeGalaxies()
        var original = LookFile.standard
        original.name = "tuned"
        original.palette = [SIMD3(0.9, 0.8, 0.7)]
        original.camera = .init(mode: .fixed, elevation: 0.3, azimuthEnd: 1.2, zoom: 1.4)
        let written = try original.encoded()

        var held = try LookFile.decoded(from: written)
        #expect(try held.encoded() == written)

        held.look = .gloss
        held.look.spikeArms = 4
        held.starCount = 12_000
        held.supersample = 3
        held.bloomLevels = 4
        held.plain = true
        held.armStrength = 0.6
        held.setColour(SIMD3(0.2, 0.4, 1), ofGalaxy: 2, in: scene)
        held.camera.mode = .auto
        held.camera.elevationEnd = 0.9
        held.camera.percentile = 0.9
        held.camera.radius = 55
        let reopened = try LookFile.decoded(from: held.encoded())
        #expect(reopened == held)
        #expect(reopened.painted(scene).galaxies.map(\.color) == held.painted(scene).galaxies.map(\.color))
        #expect(try reopened.encoded() == held.encoded())
    }
}
