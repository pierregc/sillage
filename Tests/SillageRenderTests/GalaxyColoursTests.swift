import Foundation
import Metal
import Testing
import simd

@testable import SillageCore
@testable import SillageRender

@Suite("Galaxy colours")
struct GalaxyColoursTests {
    private let ramp = GalaxyColours(
        SIMD3(1, 1, 1),
        ramp: .init(
            mapping: .radius, core: SIMD3(1, 0, 0), disk: SIMD3(0, 1, 0),
            outskirts: SIMD3(0, 0, 1), young: SIMD3(1, 1, 0), knot: SIMD3(1, 0, 1)))

    @Test func anOldPaletteReadsAsOneColourAndWritesBackTheSame() throws {
        let json = #"{"version": 1, "palette": [[0.9, 0.7, 0.5], [0.3, 0.7, 1]]}"#
        let file = try LookFile.decoded(from: Data(json.utf8))
        #expect(file.palette == [GalaxyColours(SIMD3(0.9, 0.7, 0.5)), GalaxyColours(SIMD3(0.3, 0.7, 1))])
        #expect(file.palette.allSatisfy { $0.ramp == nil })
        let written = try JSONSerialization.jsonObject(with: file.encoded()) as? [String: Any]
        #expect((written?["palette"] as? [[Double]])?.count == 2)
    }

    @Test func aRampSurvivesTheRoundTripAndAStrayFieldIsRefused() throws {
        var file = LookFile.standard
        file.palette = [ramp, GalaxyColours(SIMD3(0.2, 0.4, 0.6))]
        let back = try LookFile.decoded(from: file.encoded())
        #expect(back.palette == file.palette)
        let stray =
            #"{"version": 1, "palette": [{"colour": [1, 1, 1], "mapping": "mix", "core": [1, 0, 0], "disk": [0, 1, 0], "outskirts": [0, 0, 1], "young": [1, 1, 0], "knot": [1, 0, 1], "hue": 3}]}"#
        #expect(throws: (any Error).self) { try LookFile.decoded(from: Data(stray.utf8)) }
        let noBlend = stray.replacingOccurrences(of: #", "hue": 3"#, with: "")
        #expect(try LookFile.decoded(from: Data(noBlend.utf8)).palette[0].ramp?.blend == 0.75)
    }

    /// Asks the shader's own `rampColour` and checks it against the stops.
    private func shaderColours(_ entry: GalaxyColours, _ queries: [SIMD4<Float>]) throws
        -> [SIMD3<Float>]
    {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let probe = """
            kernel void rampProbe(constant GalaxyRamp &ramp [[buffer(0)]],
                                  device const float4 *queries [[buffer(1)]],
                                  device float4 *out [[buffer(2)]],
                                  uint id [[thread_position_in_grid]]) {
                float4 q = queries[id];
                out[id] = float4(rampColour(ramp, q.x, uint(q.y), q.z), 0.0);
            }
            """
        let library = try device.makeLibrary(source: Shaders.source + probe, options: nil)
        let pipeline = try device.makeComputePipelineState(
            function: try #require(library.makeFunction(name: "rampProbe")))
        var gpu = GalaxyRamp(entry)
        let input = try #require(
            device.makeBuffer(bytes: queries, length: queries.count * 16, options: .storageModeShared))
        let output = try #require(
            device.makeBuffer(length: queries.count * 16, options: .storageModeShared))
        let queue = try #require(device.makeCommandQueue())
        let buffer = try #require(queue.makeCommandBuffer())
        let encoder = try #require(buffer.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setBytes(&gpu, length: MemoryLayout<GalaxyRamp>.stride, index: 0)
        encoder.setBuffer(input, offset: 0, index: 1)
        encoder.setBuffer(output, offset: 0, index: 2)
        encoder.dispatchThreads(
            MTLSize(width: queries.count, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: queries.count, height: 1, depth: 1))
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        let values = output.contents().bindMemory(to: SIMD4<Float>.self, capacity: queries.count)
        return (0..<queries.count).map { SIMD3(values[$0].x, values[$0].y, values[$0].z) }
    }

    private func close(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Bool { simd_distance(a, b) < 1e-5 }

    @Test func theRampIsLookedUpAtItsEndsAndInTheMiddle() throws {
        let ancient = ParticleSystem.ancient
        let star = Float(ParticleComponent.star.rawValue)
        let radii: [Float] = [0, 0.5, 1, 1.7, 2.4, 3.45, 4.5, 9]
        let got = try shaderColours(ramp, radii.map { SIMD4($0, star, ancient, 0) })
        let r = ramp.ramp!
        let expected: [SIMD3<Float>] = [
            r.core, (r.core + r.disk) / 2, r.disk, r.disk, r.disk, (r.disk + r.outskirts) / 2,
            r.outskirts, r.outskirts,
        ]
        for (index, radius) in radii.enumerated() {
            #expect(close(got[index], expected[index]), "radius \(radius)")
            #expect(close(ramp.colour(atScaleLengths: radius), expected[index]), "radius \(radius)")
        }
        // The radius mapping colours a bulge star and a knot by where they were born.
        let bulge = Float(ParticleComponent.bulge.rawValue)
        let knot = Float(ParticleComponent.hiiRegion.rawValue)
        let others = try shaderColours(ramp, [SIMD4(4.5, bulge, ancient, 0), SIMD4(0, knot, -1, 0)])
        #expect(close(others[0], r.outskirts) && close(others[1], r.core))
    }

    @Test func theMixMappingColoursEachComponent() throws {
        var mixed = ramp
        mixed.ramp?.mapping = .mix
        let r = mixed.ramp!
        let ancient = ParticleSystem.ancient
        func q(_ radius: Float, _ kind: ParticleComponent, _ born: Float = ancient) -> SIMD4<Float> {
            SIMD4(radius, Float(kind.rawValue), born, 0)
        }
        let got = try shaderColours(
            mixed,
            [
                q(4, .bulge), q(0, .outskirt), q(0, .hiiRegion, -0.2), q(0, .dust, 0.3),
                q(0, .star, 0.5), q(0, .star), q(1.7, .star), q(5, .star),
                q(0, .star, ParticleSystem.unformed),
            ])
        let expected = [
            r.core, r.outskirts, r.young, r.young, r.young, r.core, r.disk, r.outskirts, r.core,
        ]
        for index in got.indices { #expect(close(got[index], expected[index]), "query \(index)") }
    }

    @Test func eachWorldDrawsTheRampItWasChosenWith() {
        let colour = SIMD3<Float>(0.55, 0.75, 1.0)
        let free = GalaxyColours.ramped(colour, world: .free, family: "ice-and-fire")
        let telescope = GalaxyColours.ramped(colour, world: .telescope)
        #expect(free.colour == colour && telescope.colour == colour)
        #expect(free.ramp?.mapping == .radius && telescope.ramp?.mapping == .mix)
        func luminance(_ c: SIMD3<Float>) -> Float { simd_dot(c, SIMD3(0.2126, 0.7152, 0.0722)) }
        for ramp in [free.ramp!, telescope.ramp!] {
            for c in [ramp.core, ramp.disk, ramp.outskirts, ramp.young, ramp.knot] {
                #expect(abs(luminance(c) - 1) < 1e-3 && c.min() >= 0)
            }
            #expect(ramp.blend == 0.75)
        }
        // Free: the palette's hue, more vivid; a core turned toward gold; outskirts on the
        // family's other arc.
        let own = OKLab.lch(colour)
        let disk = OKLab.lch(free.ramp!.disk)
        #expect(abs(disk.z - own.z) < 2)
        #expect(OKLab.lch(free.ramp!.core).z < own.z - 30)
        let outer = OKLab.lch(free.ramp!.outskirts).z
        #expect(outer >= 15 && outer <= 70)
        // Telescope: a warm core and a cool young colour, whatever the galaxy's own colour.
        let warm = OKLab.lab(telescope.ramp!.core)
        let cool = OKLab.lab(telescope.ramp!.young)
        #expect(warm.z > 0 && cool.z < 0)
    }

    @Test func aTelescopePaletteTakesItsSetsColours() throws {
        let json = """
            {"regions": {
              "core": {"median": [0.8, 0.0, 0.0], "vivid": {"warm": {"share": 1, "median": [0.8, 0.05, 0.09]}}},
              "disk": {"median": [0.5, 0.0, 0.0]},
              "knots": {"median": [0.6, 0, 0], "vivid": {
                "warm": {"share": 0.7, "median": [0.6, 0.12, 0.03]},
                "cool": {"share": 0.3, "median": [0.6, -0.03, -0.1]}}}
            }}
            """
        let set = try TelescopeReference(data: Data(json.utf8), name: "test-set")
        let regions = try #require(set.ramp)
        #expect(regions.outskirts == regions.disk)
        let palette = Palette(
            world: .telescope, family: "test-set", harmony: .analogous, seed: 1,
            colours: [SIMD3(0.8, 0.8, 0.8)])
        let entry = try #require(palette.galaxyColours(references: [set]).first)
        let expected = GalaxyColours.ramped(
            SIMD3(0.8, 0.8, 0.8), world: .telescope, regions: regions)
        #expect(entry == expected)
        #expect(entry != GalaxyColours.ramped(SIMD3(0.8, 0.8, 0.8), world: .telescope))
    }

    /// One colour per galaxy draws exactly what it drew before the ramps existed; a ramp
    /// changes the picture.
    @Test func onlyARampChangesThePicture() throws {
        let scene = SceneConfig.merger(particleCount: 20_000)
        let particles = RestrictedSolver.sampleParticles(for: scene)
        let renderer = try Renderer(
            particles: particles,
            settings: RenderSettings(
                width: 160, height: 90, supersample: 1, bloomLevels: 3, noiseLevel: 0))
        renderer.upload(positions: particles.positions)
        renderer.setDiskFrames(
            DiskFrame.make(scene: scene, centers: scene.galaxies.map(\.position), time: 0, strength: 1))
        let camera = Camera.framing(radius: 60)
        let before = renderer.render(camera: camera)
        renderer.setGalaxyColours(scene.galaxies.map { GalaxyColours($0.color) })
        #expect(renderer.render(camera: camera) == before)
        renderer.setGalaxyColours([
            GalaxyColours.ramped(scene.galaxies[0].color, world: .free, family: "nebula")
        ])
        #expect(renderer.render(camera: camera) != before)
        renderer.setGalaxyColours([])
        #expect(renderer.render(camera: camera) == before)
    }
}
