import CoreGraphics
import Foundation
import Metal
import SillageCore

/// One frame of a take drawn with each rendering, small, for the style editor's Rendu section
/// (#114). Drawn at the clip's size and scaled down as the look stage does (#22), and kept by
/// frame, camera and look, so coming back to a frame or a palette draws nothing.
///
/// Not safe to call from two threads at once: the caller keeps it on one queue.
public final class RenderingThumbnails: @unchecked Sendable {
    public struct Thumbnail: Sendable {
        public var pixels: [UInt8]
        public var width: Int
        public var height: Int

        public var image: CGImage? { LookGrid.cgImage(pixels, width: width, height: height) }
    }

    /// Three to a row of the inspector on a Retina screen.
    public static let width = 192
    /// About ten frames of every rendering.
    public static let capacity = 420
    /// Particles splatted per command buffer, so the canvas never waits for a whole picture.
    public static let slice = 250_000

    public let clipWidth: Int
    public let clipHeight: Int
    public let height: Int
    private let sheet: LookSheet
    private var cache: [String: Thumbnail] = [:]
    private var order: [String] = []

    public init(take: RecordingFile.Loaded, clipWidth: Int, clipHeight: Int, device: MTLDevice? = nil)
        throws
    {
        sheet = try LookSheet(take: take, device: device)
        self.clipWidth = clipWidth
        self.clipHeight = clipHeight
        height = max(Int((Double(Self.width) * Double(clipHeight) / Double(clipWidth)).rounded()), 1)
    }

    /// What a thumbnail is kept under: everything that changes its pixels.
    public static func key(_ file: LookFile, frame: Int, camera: Camera) -> String {
        let look = (try? file.encoded()).map { String(decoding: $0, as: UTF8.self) } ?? file.name
        return "\(frame) \(camera.eye) \(camera.target) \(camera.up) \(camera.fieldOfView) \(look)"
    }

    public func cached(_ file: LookFile, frame: Int, camera: Camera) -> Thumbnail? {
        cache[Self.key(file, frame: frame, camera: camera)]
    }

    /// Draws the `looks` not kept yet at the captured `frame` through `camera`, in the gaps
    /// `pacer` finds between the canvas's frames, handing each to `each` with its index as it
    /// is drawn. Stops between two looks once `cancelled` says so. Returns how many were drawn.
    @discardableResult
    public func draw(
        _ looks: [LookFile], frame: Int, camera: Camera, pacer: CanvasPacer? = nil,
        cancelled: () -> Bool = { false },
        each: (Int, Thumbnail) -> Void
    ) throws -> Int {
        let keys = looks.map { Self.key($0, frame: frame, camera: camera) }
        var missing: [Int] = []
        for (index, key) in keys.enumerated() {
            if let kept = cache[key] { each(index, kept) } else { missing.append(index) }
        }
        guard !missing.isEmpty, !cancelled() else { return 0 }
        let last = max(sheet.capturedFrames - 1, 0)
        try sheet.build(missing.map { looks[$0] }, width: clipWidth, height: clipHeight)
        do {
            try sheet.draw(
                looks: missing.map { looks[$0] }, frames: [min(max(frame, 0), last)],
                width: clipWidth, height: clipHeight, cellWidth: Self.width, cellHeight: height,
                framesPerSecond: 30, camera: camera, slice: Self.slice,
                pacer: pacer
            ) { row, _, cell in
                let index = missing[row]
                let thumbnail = Thumbnail(pixels: cell.pixels, width: Self.width, height: height)
                keep(thumbnail, under: keys[index])
                each(index, thumbnail)
                if cancelled() { throw CancellationError() }
            }
        } catch is CancellationError {}
        return missing.filter { cache[keys[$0]] != nil }.count
    }

    private func keep(_ thumbnail: Thumbnail, under key: String) {
        if cache.updateValue(thumbnail, forKey: key) == nil { order.append(key) }
        while order.count > Self.capacity { cache[order.removeFirst()] = nil }
    }
}
