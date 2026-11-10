import Foundation

/// What a video is compressed with. All three run on the media engine of Apple Silicon.
public enum VideoCodec: String, CaseIterable, Sendable {
    case h264, hevc, prores

    /// ProRes only lives in a QuickTime movie; the others stay in an MP4.
    public var fileExtension: String { self == .prores ? "mov" : "mp4" }

    /// Whether a bit rate or a quality steers it. ProRes is a fixed rate per size.
    public var hasRateControl: Bool { self != .prores }

    /// A galaxy is mostly faint gradient on black, which a mean bit rate smears into banding,
    /// hence a generous twelve bits a pixel a second for H.264. HEVC holds the same gradient
    /// with half.
    public func defaultBitRate(width: Int, height: Int) -> Int? {
        switch self {
        case .h264: width * height * 12
        case .hevc: width * height * 6
        case .prores: nil
        }
    }
}

/// The licence a video leaves under, the author and the scene it shows, written into the
/// file so they travel with it. Read back with `mdls`, `ffprobe` or `AVAsset.metadata`.
public struct VideoMetadata: Sendable, Equatable {
    public static let licence = "CC BY 4.0"
    public static let licenceURL = "https://creativecommons.org/licenses/by/4.0/"

    public var author: String
    public var sceneID: String
    public var date: Date

    public init(sceneID: String, author: String = "Pierre Gunet-Caplain", date: Date = Date()) {
        self.sceneID = sceneID
        self.author = author
        self.date = date
    }

    public var title: String { "Sillage \(sceneID)" }

    public var copyright: String {
        let year = Calendar(identifier: .gregorian).component(.year, from: date)
        return "Copyright \(year) \(author), \(Self.licence) (\(Self.licenceURL))"
    }

    public var summary: String {
        "Sillage scene \(sceneID) by \(author), licensed \(Self.licence): \(Self.licenceURL)"
    }

    /// Two lines to paste beside the video in a chat: what it shows and under which licence.
    public var caption: String { "\(title)\n\(author), \(Self.licence) \(Self.licenceURL)\n" }
}
