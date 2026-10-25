import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum PNGWriter {
    /// `maximumWidth` scales the image down to it, keeping its proportions.
    public static func write(
        _ pixels: [UInt8], width: Int, height: Int, maximumWidth: Int? = nil, to url: URL
    ) throws {
        try write(image(pixels, width: width, height: height), maximumWidth: maximumWidth, to: url)
    }

    public static func image(_ pixels: [UInt8], width: Int, height: Int) -> CGImage {
        let data = CFDataCreate(nil, pixels, pixels.count)!
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: CGDataProvider(data: data)!,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent)!
    }

    /// A video frame as it sits in the encoder's buffer, BGRA with padded rows, which
    /// CoreGraphics reads as it is. Copied, since the encoder recycles the buffer.
    public static func image(bgra buffer: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard
            let data = CFDataCreate(
                nil, base.assumingMemoryBound(to: UInt8.self), stride * height),
            let provider = CGDataProvider(data: data)
        else { return nil }
        return CGImage(
            width: CVPixelBufferGetWidth(buffer), height: height, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    public static func write(_ image: CGImage, maximumWidth: Int?, to url: URL) throws {
        try write(maximumWidth.map { try scaled(image, toWidth: $0) } ?? image, to: url)
    }

    public static func write(_ written: CGImage, to url: URL) throws {
        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, written, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private static func scaled(_ image: CGImage, toWidth target: Int) throws -> CGImage {
        guard target < image.width else { return image }
        let height = max(image.height * target / image.width, 1)
        guard
            let context = CGContext(
                data: nil, width: target, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw CocoaError(.fileWriteUnknown) }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: target, height: height))
        guard let result = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        return result
    }
}
