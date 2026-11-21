import Foundation
import Testing

@testable import SillageRender

@Suite("Preview")
struct PreviewTests {
    /// A dark ramp from black to level 24 over a few bright pixels, the way a faint tail sits
    /// next to a core.
    func faintTail(width: Int = 256, height: Int = 16) -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let pixel = (y * width + x) * 4
                let bright = x > width - 8
                let level = bright ? UInt8(200 + x % 50) : UInt8(x * 24 / width)
                pixels[pixel] = level
                pixels[pixel + 1] = bright ? 180 : UInt8(Double(level) * 0.8)
                pixels[pixel + 2] = bright ? 120 : UInt8(Double(level) * 1.2)
            }
        }
        return pixels
    }

    /// Every dark level of the ramp keeps a colour of its own, which a palette cut on five
    /// bits a channel or spent on the core would merge into flat steps.
    @Test func thePaletteKeepsTheDarkLevelsApart() {
        let palette = GIFPalette(frames: [faintTail()])
        let dark = Set(palette.colors.filter { $0.x <= 24 && $0.y <= 24 }.map(\.x))
        #expect(dark.count == 24)
        #expect(palette.colors.contains { $0.x >= 200 })
    }

    /// With fewer colours than levels, dithering keeps the mean level of each stretch.
    @Test func ditheringKeepsTheMeanLevel() {
        let (width, height) = (64, 64)
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for index in 0..<width * height {
            let level = UInt8(index % width / 2)
            pixels[index * 4] = level
            pixels[index * 4 + 1] = level
            pixels[index * 4 + 2] = level
        }
        let palette = GIFPalette(colors: [SIMD3(0, 0, 0), SIMD3(16, 16, 16), SIMD3(32, 32, 32)])
        let indices = palette.indices(of: pixels, width: width, height: height)
        for x in stride(from: 0, to: width, by: 8) {
            let block = (0..<height).flatMap { y in
                (x..<x + 8).map { Double(palette.colors[Int(indices[y * width + $0])].x) }
            }
            let mean = block.reduce(0, +) / Double(block.count)
            #expect(abs(mean - Double(x / 2) - 1.75) < 1)
        }
    }

    @Test func sizesReadAsMegabytesUnlessTold() {
        #expect(AnimatedImage.bytes("5MB") == 5_000_000)
        #expect(AnimatedImage.bytes("800kb") == 800_000)
        #expect(AnimatedImage.bytes("2.5") == 2_500_000)
        #expect(AnimatedImage.bytes("big") == nil && AnimatedImage.bytes("0") == nil)
    }

    @Test func gifDelaysCountInHundredths() {
        #expect(AnimatedImage.playedRate(20, format: .gif) == 20)
        #expect(abs(AnimatedImage.playedRate(16, format: .gif) - 100.0 / 6) < 1e-9)
        #expect(AnimatedImage.playedRate(100, format: .gif) == 50)
        #expect(AnimatedImage.playedRate(20, format: .webp) == 20)
    }
}
