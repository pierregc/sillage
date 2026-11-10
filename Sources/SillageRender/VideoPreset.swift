import Foundation

/// A size and a bit rate under a name, for the places a video ends up.
public struct VideoPreset: Sendable, Equatable {
    public var name: String
    public var width: Int
    public var height: Int
    /// Absent, the encoder's generous default for the size.
    public var bitsPerSecond: Int?
    /// Set when the place only takes one codec, which then cannot be changed.
    public var codec: VideoCodec?
    /// The most a file may weigh for the place to take it whole; the bit rate then follows
    /// the clip's length down from `bitsPerSecond` to stay under it.
    public var maxBytes: Int?
    /// Whether a caption to paste beside the video is written next to it.
    public var caption = false

    /// HEVC holds the picture in half the bytes of H.264, so it is what a preset exports
    /// with unless it names another.
    public var defaultCodec: VideoCodec { codec ?? .hevc }

    public static let all = [
        VideoPreset(name: "1080p", width: 1920, height: 1080),
        VideoPreset(name: "4k", width: 3840, height: 2160),
        VideoPreset(name: "vertical", width: 1080, height: 1920),
        VideoPreset(name: "square", width: 1080, height: 1080),
        // A video sent from WhatsApp Web or Desktop is kept whole under 16 MB: thirty seconds
        // at 4 Mbit/s is 15, so a clip over 27 s gets a leaner rate. H.264 in an MP4 plays in every
        // browser and app, which HEVC does not.
        VideoPreset(
            name: "whatsapp", width: 1280, height: 720, bitsPerSecond: 4_000_000, codec: .h264,
            maxBytes: 15_000_000, caption: true),
    ]

    /// The rate for a clip of `seconds`: the preset's own, or the one that keeps the file
    /// under `maxBytes` when that is lower (a tenth of margin, the encoder only averages).
    public func bitRate(forSeconds seconds: Double, floor: Int = 500_000) throws -> Int? {
        guard let maxBytes else { return bitsPerSecond }
        let fitting = Int(Double(maxBytes) * 8 * 0.9 / max(seconds, 1e-9))
        let rate = min(bitsPerSecond ?? fitting, fitting)
        guard rate >= floor else {
            throw SceneFolder.ExportError.tooLong(preset: name, seconds: seconds)
        }
        return rate
    }

    public static func named(_ name: String) -> VideoPreset? {
        all.first { $0.name == name.lowercased() }
    }
}
