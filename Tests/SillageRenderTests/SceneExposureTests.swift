import Foundation
import Testing

@testable import SillageRender

@Suite("Scene exposure")
struct SceneExposureTests {
    /// A frame of `width` by `height` grey pixels, `sky` everywhere but where `values` lists
    /// lightness for the pixels from the first.
    private func frame(width: Int, height: Int, sky: UInt8, lit: [UInt8]) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for pixel in 0..<(width * height) {
            let value = pixel < lit.count ? lit[pixel] : sky
            pixels.replaceSubrange((pixel * 4)..<(pixel * 4 + 3), with: [value, value, value])
            pixels[pixel * 4 + 3] = 255
        }
        return pixels
    }

    /// OKLab L of a grey sRGB byte.
    private func lightness(_ value: UInt8) -> Float {
        let c = Float(value) / 255
        return cbrtf(c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4))
    }

    @Test func theMeterReadsTheLitPixelsCentilesAboveTheSky() throws {
        // Two thousand lit pixels over a dark sky, a ramp of greys a step apart.
        let lit = (0..<2000).map { UInt8(120 + $0 * 120 / 2000) }
        let reading = try #require(
            ExposureMeter.read(
                rgba: frame(width: 400, height: 100, sky: 10, lit: lit), width: 400, height: 100))
        let sorted = lit.map(lightness).sorted()
        #expect(abs(reading.median - ExposureMeter.centile(sorted, 0.5)) < 1e-4)
        #expect(abs(reading.top - ExposureMeter.centile(sorted, 0.99)) < 1e-4)
        #expect(abs(reading.lit - 0.05) < 1e-4)
    }

    @Test func aFrameWithTooLittleLightIsNotRead() {
        let pixels = frame(width: 100, height: 100, sky: 10, lit: [200, 200, 200])
        #expect(ExposureMeter.read(rgba: pixels, width: 100, height: 100) == nil)
    }

    @Test func aWideFrameIsReadAtTheRulersWidth() {
        let (values, width, height) = ExposureMeter.lightness(
            frame(width: 1920, height: 1080, sky: 40, lit: []), width: 1920, height: 1080)
        #expect(width == 960 && height == 540 && values.count == 960 * 540)
        #expect(abs((values.first ?? 0) - lightness(40)) < 1e-4)
    }

    /// The median and the top as a log stretch moves them, roughly as the renderer's.
    private func model(_ scale: ExposureScale, bright: Float, dim: Float) -> ExposureReading {
        let stretch = 10 * scale.stretch
        func lifted(_ energy: Float) -> Float {
            let e = energy * scale.brightness
            let l = logf(1 + e * stretch) / logf(1 + stretch)
            return cbrtf(l / (1 + l)) * 1.1
        }
        return ExposureReading(median: lifted(dim), top: lifted(bright), lit: 0.4)
    }

    @Test func theSolverPutsTheMedianAndTheTopOnTheirTargets() throws {
        let target = LookExposure()
        for (bright, dim) in [(Float(5), Float(0.05)), (30, 0.1), (3, 0.02)] {
            var draws = 0
            let solved = try #require(
                ExposureSolver.solve(target: target, stretches: true) { scale in
                    draws += 1
                    return model(scale, bright: bright, dim: dim)
                })
            #expect(abs(solved.reading.median - target.median) < ExposureSolver.tolerance)
            #expect(abs(solved.reading.top - target.top) < ExposureSolver.tolerance)
            #expect(solved.draws == draws && draws <= ExposureSolver.maximumDraws)
        }
    }

    @Test func withoutAStretchTheBrightnessAloneSetsTheTop() throws {
        let solved = try #require(
            ExposureSolver.solve(target: LookExposure(), stretches: false) { scale in
                model(scale, bright: 4, dim: 0.2)
            })
        #expect(solved.scale.stretch == 1)
        #expect(abs(solved.reading.top - 0.93) < ExposureSolver.tolerance)
    }

    @Test func aFrameAlreadyOnTargetIsDrawnOnce() throws {
        let solved = try #require(
            ExposureSolver.solve(target: LookExposure(median: 0.5, top: 0.9), stretches: true) { _ in
                ExposureReading(median: 0.5, top: 0.9, lit: 0.4)
            })
        #expect(solved.scale == .unit && solved.draws == 1)
        #expect(ExposureSolver.solve(target: LookExposure(), stretches: true) { _ in nil } == nil)
    }

    @Test func aClipIsHeldToTheMeanOfItsFramesInLog() {
        let reading = ExposureReading(median: 0.47, top: 0.93, lit: 0.4)
        let held = ExposureSolver.held([
            .init(scale: ExposureScale(brightness: 2, stretch: 0.5), reading: reading, draws: 4),
            .init(scale: ExposureScale(brightness: 0.5, stretch: 2), reading: reading, draws: 4),
        ])
        #expect(abs(held.brightness - 1) < 1e-6 && abs(held.stretch - 1) < 1e-6)
        #expect(ClipExposure.samples(of: 300) == [21, 64, 107, 150, 192, 235, 278])
        #expect(ClipExposure.samples(of: 1) == [0])
        #expect(ClipExposure.samples(of: 3) == [0, 1, 2])
    }

    @Test func aLookFileKeepsItsExposureAndOnlyWhenItHasOne() throws {
        let plain = try LookFile.decoded(from: Data(#"{"version": 1}"#.utf8))
        #expect(plain.exposure == nil)
        #expect(try !String(decoding: plain.encoded(), as: UTF8.self).contains("exposure"))
        let file = try LookFile.decoded(from: Data(#"{"version": 1, "exposure": {"top": 0.9}}"#.utf8))
        #expect(file.exposure == LookExposure(median: 0.47, top: 0.9))
        #expect(try LookFile.decoded(from: file.encoded()) == file)
        #expect(throws: DecodingError.self) {
            try LookFile.decoded(from: Data(#"{"version": 1, "exposure": {"white": 0.9}}"#.utf8))
        }
    }

    @Test func theScaleMultipliesTheLooksBrightnessAndStretch() {
        var look = LookFile.standardLook
        look.brightness = 0.5
        look.stretch = 10
        let scaled = ExposureScale(brightness: 2, stretch: 0.5).applied(to: look)
        #expect(scaled.brightness == 1 && scaled.stretch == 5 && scaled.whitePoint == look.whitePoint)
    }
}
