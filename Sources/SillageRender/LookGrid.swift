import CoreGraphics
import CoreText
import Foundation

/// One image of looks against key frames: a row per look, labelled with its name, and a
/// column per frame, labelled with when it is and how it was drawn.
public enum LookGrid {
    public static let labelWidth = 220
    public static let headerHeight = 34
    public static let gap = 4

    /// `cells[row][column]` holds RGBA pixels of `cellWidth` by `cellHeight`.
    public static func image(
        cells: [[[UInt8]]], rowLabels: [String], columnLabels: [String], cellWidth: Int,
        cellHeight: Int
    ) -> CGImage? {
        let columns = columnLabels.count
        let rows = rowLabels.count
        let width = labelWidth + columns * (cellWidth + gap)
        let height = headerHeight + rows * (cellHeight + gap)
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(gray: 0.08, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // CoreGraphics counts up from the bottom; the grid is laid out from the top.
        func top(_ y: Int, _ h: Int) -> CGFloat { CGFloat(height - y - h) }
        for (column, label) in columnLabels.enumerated() {
            let x = labelWidth + column * (cellWidth + gap)
            draw(label, in: context, at: CGPoint(x: CGFloat(x + 6), y: top(0, headerHeight) + 11))
        }
        for row in 0..<rows {
            let y = headerHeight + row * (cellHeight + gap)
            draw(
                rowLabels[row], in: context,
                at: CGPoint(x: 10, y: top(y, cellHeight) + CGFloat(cellHeight) / 2 - 5),
                maximumWidth: CGFloat(labelWidth - 16))
            for column in 0..<min(columns, cells[row].count) {
                guard let cell = cgImage(cells[row][column], width: cellWidth, height: cellHeight)
                else { continue }
                let x = labelWidth + column * (cellWidth + gap)
                context.draw(
                    cell,
                    in: CGRect(
                        x: CGFloat(x), y: top(y, cellHeight), width: CGFloat(cellWidth),
                        height: CGFloat(cellHeight)))
            }
        }
        return context.makeImage()
    }

    /// RGBA pixels resampled to another size.
    public static func scaled(
        _ pixels: [UInt8], from source: (width: Int, height: Int),
        to target: (width: Int, height: Int)
    ) -> [UInt8] {
        guard source != target,
            let image = cgImage(pixels, width: source.width, height: source.height)
        else { return pixels }
        var out = [UInt8](repeating: 0, count: target.width * target.height * 4)
        let drawn: Bool? = out.withUnsafeMutableBytes { buffer in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: target.width, height: target.height,
                    bitsPerComponent: 8, bytesPerRow: target.width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return nil }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: target.width, height: target.height))
            return true
        }
        return drawn == nil ? pixels : out
    }

    static func draw(
        _ text: String, in context: CGContext, at point: CGPoint, maximumWidth: CGFloat? = nil
    ) {
        let font = CTFontCreateWithName("Menlo" as CFString, 13, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(
                gray: 0.85, alpha: 1),
        ]
        var line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes))
        if let maximumWidth,
            let truncated = CTLineCreateTruncatedLine(
                line, Double(maximumWidth), .end,
                CTLineCreateWithAttributedString(
                    NSAttributedString(string: "…", attributes: attributes)))
        {
            line = truncated
        }
        context.textPosition = point
        CTLineDraw(line, context)
    }

    static func cgImage(_ pixels: [UInt8], width: Int, height: Int) -> CGImage? {
        guard pixels.count == width * height * 4,
            let provider = CGDataProvider(data: Data(pixels) as CFData)
        else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
