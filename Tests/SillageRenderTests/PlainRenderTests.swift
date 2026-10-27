import Foundation
import SillageCore
import Testing
import simd

@testable import SillageRender

@Suite("Plain render and auto camera")
struct PlainRenderTests {
    @Test func plainPointsKeepEachGalaxyInItsOwnTintOnBlack() throws {
        var scene = SceneConfig.merger(particleCount: 20_000)
        scene.galaxies[0].color = SIMD3(1, 0, 0)
        scene.galaxies[1].color = SIMD3(0, 0, 1)
        let particles = RestrictedSolver.sampleParticles(for: scene)
        let renderer = try Renderer(
            particles: particles,
            settings: RenderSettings(
                width: 320, height: 180, supersample: 1, brightness: 0.12, starCount: 0,
                minimumKernel: 1.5, maximumKernel: 1.5, bloomIntensity: 0, spikeArms: 0,
                skyLevel: 0, noiseLevel: 0, plain: true))
        renderer.setDiskFrames(
            DiskFrame.make(
                scene: scene, centers: scene.galaxies.map(\.position), time: 0, strength: 0))
        let pixels = renderer.render(camera: Camera.framing(radius: 80))

        var red = 0
        var blue = 0
        var other = 0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let (r, g, b) = (pixels[offset], pixels[offset + 1], pixels[offset + 2])
            if g > 0 { other += 1 }
            if r > 0 { red += 1 }
            if b > 0 { blue += 1 }
        }
        #expect(red > 100 && blue > 100)
        #expect(other == 0)
        #expect(pixels[0] == 0 && pixels[1] == 0 && pixels[2] == 0)
    }

    @Test func aSlicedSplatDrawsTheSamePicture() throws {
        let scene = SceneConfig.merger(particleCount: 20_000)
        let particles = RestrictedSolver.sampleParticles(for: scene)
        let renderer = try Renderer(
            particles: particles,
            settings: RenderSettings(
                width: 320, height: 180, supersample: 2, brightness: 0.12, dustStrength: 0.5,
                starCount: 300, bloomIntensity: 0.3, spikeArms: 4, noiseLevel: 0))
        renderer.setDiskFrames(
            DiskFrame.make(
                scene: scene, centers: scene.galaxies.map(\.position), time: 0, strength: 1))
        let camera = Camera.framing(radius: 80)
        let whole = renderer.render(camera: camera)
        let sliced = renderer.render(camera: camera, slice: 3_000)
        #expect(whole.contains { $0 > 0 })
        #expect(sliced == whole)
    }

    @Test func theAutoCameraHoldsEveryGalaxyAtEveryFrame() {
        var camera = AutoCamera()
        let margins: [Float] = [10, 6, 8]
        for frame in 0..<400 {
            let t = Float(frame) / 400
            let centres = [
                SIMD3<Float>(-60 + 120 * t, 0, 0),
                SIMD3<Float>(60 - 140 * t * t, 30 * t, 5),
                SIMD3<Float>(0, -80 * (1 - t), 0),
            ]
            let framed = camera.frame(centres: centres, margins: margins)
            for (centre, margin) in zip(centres, margins) {
                #expect(simd_distance(centre, framed.center) + margin <= framed.radius + 1e-3)
            }
        }
    }

    @Test func theAutoCameraEasesInsteadOfJumping() {
        var camera = AutoCamera()
        _ = camera.frame(centres: [SIMD3(-20, 0, 0), SIMD3(20, 0, 0)], margins: [5])
        let before = camera.frame(centres: [SIMD3(-20, 0, 0), SIMD3(20, 0, 0)], margins: [5])
        let after = camera.frame(centres: [SIMD3(-20, 0, 0), SIMD3(30, 0, 0)], margins: [5])
        #expect(simd_distance(before.center, after.center) < 6)
    }
}
