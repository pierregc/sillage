import Foundation
import SillageCore
import Testing
import simd

@testable import SillageRender

@Suite("Frame score")
struct FrameScoreTests {
    static let width = 160
    static let height = 90

    /// A dark sky with two soft discs, one per galaxy, in sRGB 8-bit RGBA, with each pixel's
    /// galaxy plus one.
    static func frame(
        colours: (SIMD3<Float>, SIMD3<Float>) = (SIMD3(1, 0.55, 0.3), SIMD3(0.35, 0.6, 1)),
        gain: Float = 0.75, skyNoise: Float = 0, arms: Float = 0
    ) -> (pixels: [UInt8], owners: [UInt8]) {
        var random = SeededGenerator(seed: 7)
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        var owners = [UInt8](repeating: 0, count: width * height)
        let centres = [SIMD2<Float>(50, 45), SIMD2<Float>(112, 45)]
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                var colour = SIMD3<Float>(repeating: 0.02)
                colour += SIMD3(repeating: (Float(random.next() % 1000) / 1000 - 0.5) * skyNoise)
                for (galaxy, centre) in centres.enumerated() {
                    let r = simd_distance(SIMD2(Float(x), Float(y)), centre) / 28
                    guard r < 1 else { continue }
                    let tint = galaxy == 0 ? colours.0 : colours.1
                    let angle = atan2(Float(y) - centre.y, Float(x) - centre.x)
                    let wave = 1 - arms * (0.5 + 0.5 * sin(2 * angle + 9 * r))
                    let level = gain * (1 - r * r) * wave + 0.05
                    let white = (1 - r) * 0.5
                    colour = tint * level * (1 - white) + SIMD3(repeating: level * white)
                    owners[i] = UInt8(galaxy + 1)
                }
                for c in 0..<3 {
                    pixels[4 * i + c] = UInt8(min(max(colour[c], 0), 1) * 255)
                }
            }
        }
        return (pixels, owners)
    }

    static func score(_ frame: (pixels: [UInt8], owners: [UInt8])) -> FrameScore {
        FrameScore(pixels: frame.pixels, width: width, height: height, owners: frame.owners)
    }

    @Test func aFrameHalfClippedRanksBelowABalancedOne() {
        let balanced = Self.frame()
        var clipped = balanced
        for i in 0..<(Self.width * Self.height / 2) {
            for c in 0..<3 { clipped.pixels[4 * i + c] = 255 }
        }
        let good = Self.score(balanced)
        let bad = Self.score(clipped)
        #expect(bad.measures.clipped > 0.5)
        #expect(bad.clipping < 0.05 && good.clipping > 0.9)
        #expect(bad.total < good.total - 0.1)
    }

    @Test func dimAndWashedOutFramesAreExposedWorse() {
        let balanced = Self.score(Self.frame())
        let dim = Self.score(Self.frame(gain: 0.12))
        let washed = Self.score(Self.frame(gain: 3))
        #expect(balanced.exposure > dim.exposure && balanced.exposure > washed.exposure)
    }

    @Test func galaxiesDrawnAlikeAreNotApart() {
        let apart = Self.score(Self.frame())
        let alike = Self.score(Self.frame(colours: (SIMD3(1, 0.55, 0.3), SIMD3(1, 0.57, 0.32))))
        #expect(apart.separation > 0.9)
        #expect(alike.separation < 0.2)
        #expect(alike.colourfulness < apart.colourfulness)
    }

    @Test func armsDrawnShowMoreDetailThanASmoothGlow() {
        let smooth = Self.score(Self.frame())
        let armed = Self.score(Self.frame(arms: 0.8))
        #expect(armed.measures.detail > 2 * smooth.measures.detail)
        #expect(armed.detail > smooth.detail)
    }

    @Test func aNoisySkyScoresLower() {
        let clean = Self.score(Self.frame())
        let noisy = Self.score(Self.frame(skyNoise: 0.08))
        #expect(noisy.measures.skyNoise > clean.measures.skyNoise)
        #expect(noisy.noise < clean.noise - 0.3)
    }

    @Test func theTelescopeWorldIsJudgedOnTheReferenceTones() throws {
        let set = try TelescopeReference(data: Data(referenceJSON.utf8), name: "hubble-visible")
        let frame = Self.frame()
        let score = FrameScore(
            pixels: frame.pixels, width: Self.width, height: Self.height, owners: frame.owners,
            references: [set])
        #expect(score.reference != nil)
        #expect(Self.score(frame).reference == nil)
        let green = Self.frame(colours: (SIMD3(0.3, 1, 0.3), SIMD3(0.3, 1, 0.6)))
        let off = FrameScore(
            pixels: green.pixels, width: Self.width, height: Self.height, owners: green.owners,
            references: [set])
        #expect(off.reference! < score.reference!)
    }

    @Test func autoJudgesThreeKeyFramesAroundThePericentre() {
        let keys: [KeyFrame] = [
            KeyFrame(frame: 0, role: .start, timeMyr: 0),
            KeyFrame(frame: 100, role: .approach, timeMyr: 0),
            KeyFrame(frame: 200, role: .pericentre, timeMyr: 0),
            KeyFrame(frame: 400, role: .tails, timeMyr: 0),
            KeyFrame(frame: 600, role: .end, timeMyr: 0),
        ]
        #expect(StyleAuto.frames(keys).map(\.frame) == [100, 200, 400])
        #expect(StyleAuto.frames(Array(keys.prefix(2))).map(\.frame) == [0, 100])
    }

    @Test func applyingAStyleKeepsTheScenesCameraAndFraming() throws {
        var base = LookFile.standard
        base.camera.mode = .director
        base.look.fieldOfView = 0.42
        var rendering = LookFile(name: "hubble", world: .telescope)
        rendering.look.bloomIntensity = 0.9
        rendering.look.fieldOfView = 0.7
        rendering.camera.mode = .fixed
        let palette = try PaletteGenerator.palette(galaxies: 2, world: .free, seed: 3)
        let file = StyleAuto.apply(rendering, palette: palette, to: base)
        #expect(file.camera.mode == .director && file.look.fieldOfView == 0.42)
        #expect(file.look.bloomIntensity == 0.9 && file.world == .telescope)
        #expect(file.palette == palette.colours && file.paletteRecipe == palette)
    }
}
