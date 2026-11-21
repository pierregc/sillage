import Foundation
import ImageIO
import Testing

@testable import SillageRender

extension PreviewTests {
    /// Width comes down first, to its floor, then the frame rate, and then nothing is left.
    @Test func aPreviewTooBigLosesWidthThenFrameRate() throws {
        let (width, rate) = try #require(TakeExport.smaller(width: 960, framesPerSecond: 16, ratio: 0.5))
        #expect(rate == 16 && width < 960 * 3 / 4 && width > 600)
        #expect(TakeExport.smaller(width: 400, framesPerSecond: 16, ratio: 0.1)! == (320, 16))
        #expect(TakeExport.smaller(width: 320, framesPerSecond: 16, ratio: 0.5)! == (320, 10))
        #expect(TakeExport.smaller(width: 320, framesPerSecond: 10, ratio: 0.5) == nil)
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
