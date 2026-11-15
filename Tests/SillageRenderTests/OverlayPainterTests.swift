import CoreGraphics
import Foundation
import Metal
import Testing

@testable import SillageCore
@testable import SillageRender

/// The overlay drawn over finished frames (#317), and the exports that draw it.
@Suite("Overlay drawing")
struct OverlayPainterTests {
    private let width = 320
    private let height = 180

    private func black() -> [UInt8] {
        (0..<(width * height)).flatMap { _ in [UInt8(0), 0, 0, 255] }
    }

    private func line(_ text: String, x: Double, flushRight: Bool = false, alpha: Double = 0.9)
        -> OverlayFrame.Line
    {
        OverlayFrame.Line(
            text: text, x: x, baseline: 160, flushRight: flushRight, size: 14, weight: .light,
            tracking: 0.2, tabular: false, alpha: alpha)
    }

    /// The columns and rows of every pixel `after` changed from `before`.
    private func changed(_ before: [UInt8], _ after: [UInt8]) -> [(x: Int, y: Int)] {
        stride(from: 0, to: before.count, by: 4).compactMap { index in
            before[index..<(index + 4)] == after[index..<(index + 4)]
                ? nil : ((index / 4) % width, (index / 4) / width)
        }
    }

    @Test func aLineDrawsWhereItIsAndNowhereElse() throws {
        var frame = OverlayFrame()
        frame.lines = [line("They pass through each other", x: 20)]
        var pixels = black()
        OverlayPainter().draw(frame, intoRGBA: &pixels, width: width, height: height)
        let lit = changed(black(), pixels)
        #expect(lit.count > 100)
        #expect(lit.allSatisfy { $0.x >= 18 && $0.x < 240 && $0.y > 145 && $0.y < 166 })
        // White over black, so grey: the same in every channel, and never full white at 0.9.
        let brightest = stride(from: 0, to: pixels.count, by: 4).map { pixels[$0] }.max()!
        #expect(brightest > 150 && brightest < 235)
    }

    @Test func aLineSetFlushRightEndsAtItsAnchor() {
        var frame = OverlayFrame()
        frame.lines = [line("100,000 light years", x: 300, flushRight: true)]
        var pixels = black()
        OverlayPainter().draw(frame, intoRGBA: &pixels, width: width, height: height)
        let right = changed(black(), pixels).map(\.x).max() ?? 0
        #expect(right >= 296 && right <= 301)
    }

    @Test func nothingIsDrawnWhenNothingShows() {
        var faded = OverlayFrame()
        faded.lines = [line("Gone", x: 20, alpha: 0)]
        faded.bars = [OverlayFrame.Bar(x: 20, y: 100, length: 80, thickness: 2, tick: 4, alpha: 0)]
        for frame in [OverlayFrame(), faded] {
            var pixels = black()
            OverlayPainter().draw(frame, intoRGBA: &pixels, width: width, height: height)
            #expect(pixels == black())
        }
    }

    @Test func aBarIsAsLongAsAsked() {
        var frame = OverlayFrame()
        frame.bars = [OverlayFrame.Bar(x: 40, y: 100, length: 120, thickness: 2, tick: 5, alpha: 1)]
        var pixels = black()
        OverlayPainter().draw(frame, intoRGBA: &pixels, width: width, height: height)
        let lit = changed(black(), pixels)
        #expect(lit.map(\.x).min() == 40 && lit.map(\.x).max() == 159)
        #expect(lit.map(\.y).max() == 100 && lit.map(\.y).min() == 94)
    }

    private func export() throws -> TakeExport {
        let take = try overlayTake(frames: 60, separation: overlaySeparation)
        var look = LookFile.standard
        look.palette = take.scene.galaxies.map { GalaxyColours($0.color) }
        return try TakeExport(take: take, look: look, capturedRate: 30)
    }

    /// Asked for nothing, an export draws the frames it drew before the overlay existed; asked
    /// for a clock, only the clock's corner changes.
    @Test func anExportDrawsTheOverlayAndNothingElse() throws {
        let export = try export()
        let plain = try export.frames(width: 192, height: 108, framesPerSecond: 30, duration: 1.5)
        export.overlay = OverlayRequest(overlay: Overlay())
        #expect(try export.frames(width: 192, height: 108, framesPerSecond: 30, duration: 1.5) == plain)
        export.overlay = OverlayRequest(overlay: Overlay(clock: Overlay.Clock(), size: 4))
        let clocked = try export.frames(width: 192, height: 108, framesPerSecond: 30, duration: 1.5)
        #expect(clocked[0] == plain[0])
        let last = clocked.count - 1
        var touched: [(x: Int, y: Int)] = []
        for index in stride(from: 0, to: plain[last].count, by: 4)
        where plain[last][index..<(index + 4)] != clocked[last][index..<(index + 4)] {
            touched.append(((index / 4) % 192, (index / 4) / 192))
        }
        #expect(!touched.isEmpty)
        #expect(touched.allSatisfy { $0.x > 96 && $0.y > 80 })
    }

    /// The frame the encoder takes carries the overlay as the read-back frames do.
    @Test func theEncoderTakesTheOverlaidFrame() throws {
        let export = try export()
        export.overlay = OverlayRequest(
            overlay: Overlay(title: Overlay.Title(text: "Two"), clock: Overlay.Clock(), size: 4))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("overlay-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        var still: CGImage?
        _ = try export.write(
            to: url, width: 192, height: 108, framesPerSecond: 30, duration: 1.5, stills: [40],
            still: { _, image in still = image })
        let image = try #require(still)
        let bgra = try #require(image.dataProvider?.data as Data?)
        let frames = try export.frames(width: 192, height: 108, framesPerSecond: 30, duration: 1.5)
        var largest = 0
        for y in 0..<108 {
            for x in 0..<192 {
                let read = y * image.bytesPerRow + x * 4
                let drawn = (y * 192 + x) * 4
                for channel in 0..<3 {
                    largest = max(
                        largest, abs(Int(bgra[read + 2 - channel]) - Int(frames[40][drawn + channel])))
                }
            }
        }
        #expect(largest <= 1)
        export.overlay = nil
        let bare = try export.frames(width: 192, height: 108, framesPerSecond: 30, duration: 1.5)
        #expect(frames[40] != bare[40])
    }
}
