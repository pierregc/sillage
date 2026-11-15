import CoreGraphics
import CoreText
import CoreVideo
import Foundation

/// Draws an `OverlayFrame` over a finished frame on the CPU, after the tone curve, the bloom
/// and the grain, at the frame's own size: the text is never blurred, bloomed or grainy, and
/// 4K text is set at 4K. Core Text, which Linux does not have: the CUDA pass refuses an
/// overlay (`RunVideos`).
public final class OverlayPainter {
    private struct FontKey: Hashable {
        var name: String?
        var size: Double
        var weight: OverlayFrame.Weight
        var tabular: Bool
    }

    private var fonts: [FontKey: CTFont] = [:]
    private let space = CGColorSpaceCreateDeviceRGB()

    public init() {}

    /// Over the BGRA pixel buffer an encoder takes.
    public func draw(_ frame: OverlayFrame, into pixels: CVPixelBuffer) {
        guard !frame.isEmpty else { return }
        CVPixelBufferLockBaseAddress(pixels, [])
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        guard
            let context = CGContext(
                data: CVPixelBufferGetBaseAddress(pixels), width: CVPixelBufferGetWidth(pixels),
                height: CVPixelBufferGetHeight(pixels), bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        draw(frame, in: context, height: Double(CVPixelBufferGetHeight(pixels)))
    }

    /// Over RGBA bytes, as `Renderer.render` reads a frame back.
    public func draw(_ frame: OverlayFrame, intoRGBA pixels: inout [UInt8], width: Int, height: Int) {
        guard !frame.isEmpty, pixels.count >= width * height * 4 else { return }
        pixels.withUnsafeMutableBytes { bytes in
            guard
                let context = CGContext(
                    data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return }
            draw(frame, in: context, height: Double(height))
        }
    }

    func draw(_ frame: OverlayFrame, in context: CGContext, height: Double) {
        context.setAllowsFontSmoothing(false)
        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)
        if frame.shadow > 0 {
            context.setShadow(
                offset: .zero, blur: frame.shadow, color: CGColor(gray: 0, alpha: 0.45))
        }
        for bar in frame.bars where bar.alpha > 0 {
            context.setFillColor(CGColor(gray: 1, alpha: bar.alpha))
            // From the top left to Core Graphics' bottom left.
            let y = height - bar.y
            context.fill(
                CGRect(x: bar.x, y: y - bar.thickness / 2, width: bar.length, height: bar.thickness))
            for end in [bar.x, bar.x + bar.length - bar.thickness] {
                context.fill(
                    CGRect(x: end, y: y + bar.thickness / 2, width: bar.thickness, height: bar.tick))
            }
        }
        for line in frame.lines where line.alpha > 0 && !line.text.isEmpty {
            let font = self.font(
                FontKey(name: frame.font, size: line.size, weight: line.weight, tabular: line.tabular))
            let attributes: [CFString: Any] = [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: CGColor(gray: 1, alpha: line.alpha),
                kCTKernAttributeName: line.tracking,
            ]
            let text = CFAttributedStringCreate(nil, line.text as CFString, attributes as CFDictionary)!
            let set = CTLineCreateWithAttributedString(text)
            // The tracking after the last letter is no part of the line's width.
            let width = CTLineGetTypographicBounds(set, nil, nil, nil) - line.tracking
            context.textPosition = CGPoint(
                x: line.flushRight ? line.x - width : line.x, y: height - line.baseline)
            CTLineDraw(set, context)
        }
        context.setShadow(offset: .zero, blur: 0, color: nil)
    }

    private func font(_ key: FontKey) -> CTFont {
        if let made = fonts[key] { return made }
        var descriptor: CTFontDescriptor
        if let name = key.name {
            descriptor = CTFontDescriptorCreateWithNameAndSize(name as CFString, key.size)
        } else {
            let system = CTFontCreateUIFontForLanguage(.system, key.size, nil)!
            descriptor = CTFontDescriptorCreateCopyWithAttributes(
                CTFontCopyFontDescriptor(system),
                [kCTFontTraitsAttribute: [kCTFontWeightTrait: key.weight == .light ? -0.4 : 0]]
                    as CFDictionary)
        }
        if key.tabular {
            descriptor = CTFontDescriptorCreateCopyWithFeature(
                descriptor, NSNumber(value: kNumberSpacingType), NSNumber(value: kMonospacedNumbersSelector))
        }
        let made = CTFontCreateWithFontDescriptor(descriptor, key.size, nil)
        fonts[key] = made
        return made
    }
}
