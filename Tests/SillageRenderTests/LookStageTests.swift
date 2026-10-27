import Foundation
import Testing
import simd

@testable import SillageRender

@Suite("Look stage")
struct LookStageTests {
    /// A flyby: closing from 58 kpc to 8 at frame 40, then apart, the tails peaking at 70.
    private func flyby(frames: Int = 100) -> [KeyFrames.Sample] {
        (0..<frames).map { frame in
            let closest = 8 + abs(Double(frame - 40)) * 1.25
            let tidal = frame < 40 ? 0.01 : 0.3 - abs(Double(frame - 70)) * 0.005
            return KeyFrames.Sample(
                frame: frame, timeMyr: 80 + Double(frame), closest: closest, tidal: tidal)
        }
    }

    @Test func keyFramesFollowTheEncounter() {
        let keys = KeyFrames.pick(flyby())
        #expect(keys.map(\.role) == [.start, .approach, .pericentre, .tails, .end])
        #expect(keys.map(\.frame) == [0, 20, 40, 70, 99])
        #expect(keys[2].timeMyr == 120)
    }

    @Test func keyFramesTooCloseTogetherAreDropped() {
        // Pericentre on the first frame: no approach, and the start falls on top of it.
        let samples = (0..<100).map {
            KeyFrames.Sample(
                frame: $0, timeMyr: Double($0), closest: 5 + Double($0), tidal: Double($0) / 200)
        }
        let keys = KeyFrames.pick(samples)
        #expect(keys.map(\.role) == [.pericentre, .middle, .end])
        #expect(Set(keys.map(\.frame)).count == keys.count)
    }

    @Test func aLoneGalaxyStillGetsThreeFrames() {
        let samples = (0..<50).map {
            KeyFrames.Sample(frame: $0, timeMyr: Double($0), closest: 0, tidal: 0)
        }
        #expect(KeyFrames.pick(samples).map(\.role) == [.start, .middle, .end])
    }

    @Test func curvesAreReadByColumnName() {
        let csv = """
            frame,time_myr,separation_kpc,extent_kpc,formed,closest_kpc,tidal_fraction,x_0
            0,79.919,54.6,30.0,1,54.6,0.0166,-23.7
            1,80.710,54.3,29.9,0,54.3,0.0170,-23.6
            """
        let samples = KeyFrames.samples(csv: csv)
        #expect(samples.count == 2)
        #expect(samples[1] == KeyFrames.Sample(frame: 1, timeMyr: 80.71, closest: 54.3, tidal: 0.017))
        #expect(KeyFrames.nearest(timeMyr: 80.5, in: samples)?.frame == 1)
    }

    @Test func variantsChangeOneThingEach() {
        var base = LookFile.standard
        base.palette = [SIMD3(1, 0.5, 0.2)]
        let variants = LookVariants.around(base)
        #expect(variants.first == base)
        #expect(Set(variants.map(\.name)).count == variants.count)
        #expect(variants.dropFirst().allSatisfy { $0.name.hasPrefix("standard-") })
        #expect(variants.filter { !$0.name.contains("-hue-") }.allSatisfy { $0.palette == base.palette })
        #expect(variants.dropFirst().allSatisfy { !$0.differsOnlyInName(from: base) })
        let named = Dictionary(uniqueKeysWithValues: variants.map { ($0.name, $0) })
        #expect(named["standard-bright"]!.look.brightness > base.look.brightness)
        #expect(named["standard-no-spikes"]!.look.spikeIntensity == 0)
        #expect(named["standard-high"]!.camera.elevation > base.camera.elevation)
        #expect(named["standard-close"]!.camera.zoom > base.camera.zoom)
        #expect(named["standard-no-gas"]!.look.dustStrength == 0)
        #expect(named["standard-hue-180"]!.palette != base.palette)
    }

    @Test func rotatingTheHueKeepsTheBrightnessAndComesBack() {
        let colour = SIMD3<Float>(1, 0.5, 0.2)
        let turned = LookVariants.rotateHue(colour, by: 120)
        #expect(abs(turned.max() - 1) < 1e-5 && abs(turned.min() - 0.2) < 1e-5)
        let back = LookVariants.rotateHue(turned, by: 240)
        #expect(simd_length(back - colour) < 1e-4)
        #expect(LookVariants.rotateHue(SIMD3(0.4, 0.4, 0.4), by: 90) == SIMD3(0.4, 0.4, 0.4))
    }

    /// Every look of the repository's catalogue reads, is named after its file, brings colours
    /// of its own and keeps the background and the spikes quiet.
    @Test func theCatalogueFilesAreVariedAndQuiet() throws {
        let looks = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("looks")
        let names = try FileManager.default.contentsOfDirectory(atPath: looks.path)
            .filter { $0.hasSuffix(".look.json") && $0 != "raw.look.json" }
        let files = try names.map {
            try LookFile.decoded(from: Data(contentsOf: looks.appendingPathComponent($0)))
        }
        for (name, file) in zip(names, files) { #expect(name == "\(file.name).look.json") }
        let added = zip(names, files).filter { !RenderLook.catalogue.map(\.id).contains($0.1.name) }
            .map(\.1).filter { $0.world == .free }
        #expect(added.count >= 30)
        #expect(Set(added.map(\.palette.first!.x)).count > 8)
        #expect(added.filter { $0.look.dustStrength == 0 }.count * 2 > added.count)
        #expect(added.allSatisfy { $0.starCount <= 1000 && $0.look.skyLevel <= 0.0008 })
        #expect(added.allSatisfy { $0.look.spikeIntensity <= 0.2 })
    }

    /// The telescope world renders as Hubble or Webb and nothing else; the free world keeps
    /// the rest of the catalogue.
    @Test func theTelescopeWorldIsHubbleAndWebb() throws {
        let catalogue = LookCatalogue.load(
            from: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("looks"))
        let telescope = LookCatalogue.renderings(.telescope, in: catalogue)
        #expect(telescope.map(\.name).sorted() == ["hubble", "webb"])
        let free = LookCatalogue.renderings(.free, in: catalogue)
        #expect(free.count + 2 == catalogue.count && free.count >= 35)

        let hubble = try #require(telescope.first { $0.name == "hubble" })
        let webb = try #require(telescope.first { $0.name == "webb" })
        #expect(hubble.look.spikeArms == 4 && hubble.look.spikePattern == .even)
        #expect(webb.look.spikeArms == 6 && webb.look.spikePattern == .webb)
        // Hubble's dust is shadow and its bulge a broad glow; Webb's dust glows instead.
        #expect(hubble.look.dustStrength > 3 * webb.look.dustStrength)
        #expect(hubble.look.bloomIntensity > webb.look.bloomIntensity)
        for file in telescope {
            #expect(file.palette.count == 5)
            #expect(PaletteGenerator.violations(file.palette, monochrome: false).isEmpty)
        }
    }

    @Test func aVariantThatChangesNothingIsLeftOut() {
        var base = LookFile.standard
        base.look.spikeIntensity = 0
        base.look.bloomIntensity = 0
        let names = LookVariants.around(base).map(\.name)
        #expect(!names.contains("standard-no-spikes") && !names.contains("standard-no-bloom"))
        #expect(names.contains("standard-spikes") && names.contains("standard-bloom"))
    }

    /// The files under `looks/` are the catalogue, and have not drifted from it.
    @Test func theRepositoryLooksAreTheCatalogue() throws {
        let looks = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("looks")
        for named in RenderLook.catalogue {
            let file = try LookFile.decoded(
                from: Data(contentsOf: looks.appendingPathComponent("\(named.id).look.json")))
            #expect(file == LookFile(name: named.id, look: named.look))
        }
    }

    @Test func promotingARowKeepsTheRawLook() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("look-\(UUID().uuidString)", isDirectory: true)
        let folder = SceneFolder(url)
        try FileManager.default.createDirectory(at: folder.looks, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: SceneFolder.LookError.self) { try folder.promote(look: "dream") }
        try LookFile.raw.encoded().write(to: folder.look)
        let dream = LookFile(name: "dream", look: .dream)
        let ink = LookFile(name: "ink", look: .ink)
        try dream.encoded().write(to: folder.lookFile(named: "dream"))
        try ink.encoded().write(to: folder.lookFile(named: "ink"))

        try folder.promote(look: "dream")
        #expect(try LookFile.decoded(from: Data(contentsOf: folder.look)) == dream)
        #expect(try LookFile.decoded(from: Data(contentsOf: folder.rawLook)) == .raw)
        try folder.promote(look: "ink")
        #expect(try LookFile.decoded(from: Data(contentsOf: folder.look)) == ink)
        #expect(try LookFile.decoded(from: Data(contentsOf: folder.rawLook)) == .raw)
    }

    @Test func theGridHasARowPerLookAndAColumnPerFrame() throws {
        let cell = [UInt8](repeating: 200, count: 40 * 20 * 4)
        let image = try #require(
            LookGrid.image(
                cells: [[cell, cell, cell], [cell, cell, cell]], rowLabels: ["a", "b"],
                columnLabels: ["start", "pericentre", "end"], cellWidth: 40, cellHeight: 20))
        #expect(image.width == LookGrid.labelWidth + 3 * (40 + LookGrid.gap))
        #expect(image.height == LookGrid.headerHeight + 2 * (20 + LookGrid.gap))
    }
}
