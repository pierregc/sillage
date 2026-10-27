import AVFoundation
import CoreMedia
import Foundation
import ImageIO

/// A file of a scene's `exports/` as the page lists it: a video, or an animated WebP or GIF.
public struct ExportedFile: Sendable, Equatable, Identifiable {
    public var url: URL
    /// The preset in the file name (`4k` of `4k-aurora.mp4`), absent for a name of the user's own.
    public var preset: String?
    /// The look in the file name, when the name carries one.
    public var style: String?
    /// `H.264`, `HEVC`, `ProRes`, `WebP` or `GIF`.
    public var codec: String
    /// `1080p`, `4K`, or the pixels when the size has no name.
    public var size: String?
    public var seconds: Double?
    public var bytes: Int
    public var date: Date
    /// The `.txt` beside the video, which the whatsapp preset writes.
    public var caption: URL?

    public var id: URL { url }
    public var isImage: Bool { Self.imageExtensions.contains(url.pathExtension.lowercased()) }

    public static let imageExtensions: Set = ["webp", "gif"]

    /// Everything of `exports/` the page can show, newest first. Captions are not rows: they
    /// belong to the video they sit beside.
    public static func list(_ urls: [URL]) async -> [ExportedFile] {
        let names = Set(urls.map(\.lastPathComponent))
        var files: [ExportedFile] = []
        for url in urls {
            let ext = url.pathExtension.lowercased()
            guard LibraryScene.videoExtensions.contains(ext) || imageExtensions.contains(ext) else {
                continue
            }
            let captionName = url.deletingPathExtension().lastPathComponent + ".txt"
            files.append(
                await read(
                    url,
                    caption: names.contains(captionName)
                        ? url.deletingLastPathComponent().appendingPathComponent(captionName) : nil))
        }
        return files.sorted { ($0.date, $1.url.lastPathComponent) > ($1.date, $0.url.lastPathComponent) }
    }

    public static func read(_ url: URL, caption: URL? = nil) async -> ExportedFile {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let (preset, style) = names(of: url.deletingPathExtension().lastPathComponent)
        var file = ExportedFile(
            url: url, preset: preset, style: style,
            codec: url.pathExtension.lowercased() == "mov" ? "ProRes" : "",
            size: nil, seconds: nil, bytes: (attributes?[.size] as? Int) ?? 0,
            date: (attributes?[.modificationDate] as? Date) ?? .distantPast, caption: caption)
        if file.isImage {
            file.codec = url.pathExtension.lowercased() == "gif" ? "GIF" : "WebP"
            let source = CGImageSourceCreateWithURL(url as CFURL, nil)
            if let source,
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                let width = properties[kCGImagePropertyPixelWidth] as? Int,
                let height = properties[kCGImagePropertyPixelHeight] as? Int
            {
                file.size = sizeName(width: width, height: height)
            }
            return file
        }
        let asset = AVURLAsset(url: url)
        if let duration = try? await asset.load(.duration), duration.isNumeric {
            file.seconds = duration.seconds
        }
        if let track = try? await asset.loadTracks(withMediaType: .video).first {
            if let size = try? await track.load(.naturalSize) {
                file.size = sizeName(width: Int(size.width), height: Int(size.height))
            }
            if let formats = try? await track.load(.formatDescriptions), let format = formats.first {
                file.codec = codecName(CMFormatDescriptionGetMediaSubType(format)) ?? file.codec
            }
        }
        return file
    }

    /// `4k-aurora` is the 4k preset with the aurora look; `1080p-h264` the same preset in
    /// another codec, which names no look; `1080p-2` a second export of the same.
    public static func names(of stem: String) -> (preset: String?, style: String?) {
        var parts = stem.split(separator: "-").map(String.init)
        guard let first = parts.first, VideoPreset.named(first) != nil else { return (nil, nil) }
        parts.removeFirst()
        if let last = parts.last, VideoCodec(rawValue: last) != nil { parts.removeLast() }
        if let last = parts.last, Int(last) != nil { parts.removeLast() }
        return (first, parts.isEmpty ? nil : parts.joined(separator: "-"))
    }

    static func sizeName(width: Int, height: Int) -> String {
        switch (width, height) {
        case (3840, 2160): "4K"
        case (1920, 1080): "1080p"
        case (1280, 720): "720p"
        default: "\(width)×\(height)"
        }
    }

    static func codecName(_ subtype: FourCharCode) -> String? {
        switch subtype {
        case kCMVideoCodecType_H264: "H.264"
        case kCMVideoCodecType_HEVC: "HEVC"
        case kCMVideoCodecType_AppleProRes422HQ, kCMVideoCodecType_AppleProRes422,
            kCMVideoCodecType_AppleProRes4444:
            "ProRes"
        default: nil
        }
    }
}
