import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum PNGWriter {
    /// `maximumWidth` scales the image down to it, keeping its proportions.
    public static func write(
        _ pixels: [UInt8], width: Int, height: Int, maximumWidth: Int? = nil, to url: URL
    ) throws {
        let data = CFDataCreate(nil, pixels, pixels.count)!
        let provider = CGDataProvider(data: data)!
        let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent)!
        let written = try maximumWidth.map { try scaled(image, toWidth: $0) } ?? image

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
