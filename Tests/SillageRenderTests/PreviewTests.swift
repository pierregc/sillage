import Foundation
import ImageIO
import Testing

@testable import SillageRender

@Suite("Preview")
struct PreviewTests {
    /// A dark ramp from black to level 24 over a few bright pixels, the way a faint tail sits
    /// next to a core.
    private func faintTail(width: Int = 256, height: Int = 16) -> [UInt8] {
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

    /// Width comes down first, to its floor, then the frame rate, and then nothing is left.
    @Test func aPreviewTooBigLosesWidthThenFrameRate() throws {
        let (width, rate) = try #require(TakeExport.smaller(width: 960, framesPerSecond: 16, ratio: 0.5))
        #expect(rate == 16 && width < 960 * 3 / 4 && width > 600)
        #expect(TakeExport.smaller(width: 400, framesPerSecond: 16, ratio: 0.1)! == (320, 16))
        #expect(TakeExport.smaller(width: 320, framesPerSecond: 16, ratio: 0.5)! == (320, 10))
        #expect(TakeExport.smaller(width: 320, framesPerSecond: 10, ratio: 0.5) == nil)
    }

    @Test func gifDelaysCountInHundredths() {
        #expect(AnimatedImage.playedRate(20, format: .gif) == 20)
        #expect(abs(AnimatedImage.playedRate(16, format: .gif) - 100.0 / 6) < 1e-9)
        #expect(AnimatedImage.playedRate(100, format: .gif) == 50)
        #expect(AnimatedImage.playedRate(20, format: .webp) == 20)
    }

    @Test func aGIFLoopsOverEveryFrameWithItsPalette() throws {
        let (width, height) = (256, 16)
        let frames = [faintTail(), faintTail().map { $0 / 2 }, faintTail()]
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("preview-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: url) }
        try AnimatedImage.write(
            frames, width: width, height: height, framesPerSecond: 20, format: .gif, to: url)

        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == 3)
        let file = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        let loop = (file?[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFLoopCount]
        #expect(loop as? Int == 0)
        let frame = CGImageSourceCopyPropertiesAtIndex(source, 1, nil) as? [CFString: Any]
        let gif = frame?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        #expect(abs((gif?[kCGImagePropertyGIFDelayTime] as? Double ?? 0) - 0.05) < 1e-6)
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == width && image.height == height)

        // The ramp read back still climbs through its dark levels rather than in steps.
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let reds = Set((0..<width - 8).map { bytes[$0 * 4] })
        #expect(reds.count >= 24)
    }

    /// Noise fills the code table again and again, so every code width and every reset is
    /// crossed; ImageIO reads back exactly the indices written.
    @Test func theLZWStreamDecodesToTheIndicesWritten() throws {
        let (width, height) = (300, 200)
        var generator = SystemRandomNumberGenerator()
        let noise = (0..<width * height).map { index in
            index % 7 == 0 ? UInt8(index / width % 4) : UInt8.random(in: 0...255, using: &generator)
        }
        let colors = (0..<256).map { SIMD3<UInt8>(UInt8($0), UInt8(255 - $0), UInt8($0 / 2)) }
        let data = GIFWriter.data(
            frames: [noise, [UInt8](repeating: 3, count: width * height)],
            palette: GIFPalette(colors: colors), width: width, height: height, delay: 5)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetCount(source) == 2)
        for (frame, indices) in [(0, noise), (1, [UInt8](repeating: 3, count: width * height))] {
            let image = try #require(CGImageSourceCreateImageAtIndex(source, frame, nil))
            let context = try #require(
                CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
            let wrong = (0..<width * height).filter { bytes[$0 * 4] != indices[$0] }
            #expect(wrong.isEmpty)
        }
    }
}
