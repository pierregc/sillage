import CoreGraphics
import Foundation
import simd

/// Palettes laid out to be judged: swatches alone, and a frame of the take in each.
public enum PaletteSheet {
    static let swatchWidth = 72
    static let swatchHeight = 36
    static let stripHeight = 16
    static let labelHeight = 22

    /// One row per palette: its name, then a block per galaxy.
    public static func swatches(_ palettes: [Palette], labels: [String]? = nil) -> CGImage? {
        let width = LookGrid.labelWidth + 5 * (swatchWidth + LookGrid.gap) + 12
        let height = palettes.count * (swatchHeight + LookGrid.gap) + LookGrid.gap
        guard let context = canvas(width: width, height: height) else { return nil }
        for (row, palette) in palettes.enumerated() {
            let top = height - LookGrid.gap - row * (swatchHeight + LookGrid.gap) - swatchHeight
            LookGrid.draw(
                labels?[row] ?? palette.name, in: context, at: CGPoint(x: 10, y: top + swatchHeight / 2 - 5),
                maximumWidth: CGFloat(LookGrid.labelWidth - 16))
            for (index, colour) in palette.colours.enumerated() {
                context.setFillColor(displayed(colour))
                context.fill(
                    CGRect(
                        x: LookGrid.labelWidth + index * (swatchWidth + LookGrid.gap), y: top,
                        width: swatchWidth, height: swatchHeight))
            }
        }
        return context.makeImage()
    }

    /// Tiles of `columns` across: the palette's name, its frame, and its colours in a strip
    /// under it; `labels` stand in for the names. `cells[i]` holds RGBA pixels of `cellWidth` by `cellHeight`.
    public static func sheet(
        cells: [[UInt8]], palettes: [Palette], cellWidth: Int, cellHeight: Int, columns: Int,
        labels: [String]? = nil
    ) -> CGImage? {
        let tileHeight = labelHeight + cellHeight + stripHeight
        let rows = (palettes.count + columns - 1) / columns
        let width = columns * (cellWidth + LookGrid.gap) + LookGrid.gap
        let height = rows * (tileHeight + LookGrid.gap) + LookGrid.gap
        guard let context = canvas(width: width, height: height) else { return nil }
        for (index, palette) in palettes.enumerated() {
            let x = LookGrid.gap + (index % columns) * (cellWidth + LookGrid.gap)
            let top = height - LookGrid.gap - (index / columns) * (tileHeight + LookGrid.gap)
            LookGrid.draw(
                labels?[index] ?? palette.name, in: context, at: CGPoint(x: x + 4, y: top - labelHeight + 6),
                maximumWidth: CGFloat(cellWidth - 8))
            if index < cells.count,
                let frame = LookGrid.cgImage(cells[index], width: cellWidth, height: cellHeight)
            {
                context.draw(
                    frame,
                    in: CGRect(
                        x: x, y: top - labelHeight - cellHeight, width: cellWidth,
                        height: cellHeight))
            }
            let band = cellWidth / max(palette.colours.count, 1)
            for (galaxy, colour) in palette.colours.enumerated() {
                context.setFillColor(displayed(colour))
                context.fill(
                    CGRect(
                        x: x + galaxy * band, y: top - tileHeight,
                        width: galaxy == palette.colours.count - 1
                            ? cellWidth - galaxy * band : band,
                        height: stripHeight))
            }
        }
        return context.makeImage()
    }

    /// A linear sRGB colour as the screen shows it.
    static func displayed(_ colour: SIMD3<Float>) -> CGColor {
        func encode(_ v: Float) -> CGFloat {
            let c = min(max(v, 0), 1)
            return CGFloat(c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055)
        }
        return CGColor(
            red: encode(colour.x), green: encode(colour.y), blue: encode(colour.z), alpha: 1)
    }

    private static func canvas(width: Int, height: Int) -> CGContext? {
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(gray: 0.08, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context
    }
}
