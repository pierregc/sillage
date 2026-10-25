import AVFoundation
import Foundation
import VideoToolbox

/// What a video is compressed with. All three run on the media engine of Apple Silicon.
public enum VideoCodec: String, CaseIterable, Sendable {
    case h264, hevc, prores

    /// H.264 plays everywhere, HEVC is the same picture in about half the bytes, and ProRes
    /// is for editing: large, and cut and graded without being compressed a second time.
    public var avCodec: AVVideoCodecType {
        switch self {
        case .h264: .h264
        case .hevc: .hevc
        case .prores: .proRes422HQ
        }
    }

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

    func compressionProperties(
        width: Int, height: Int, framesPerSecond: Int32, bitsPerSecond: Int?, quality: Double?
    ) -> [String: Any] {
        var properties: [String: Any] = [AVVideoExpectedSourceFrameRateKey: framesPerSecond]
        switch self {
        case .h264: properties[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        case .hevc: properties[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main_AutoLevel as String
        case .prores: return properties
        }
        if let quality {
            properties[AVVideoQualityKey] = quality
        } else if let rate = bitsPerSecond ?? defaultBitRate(width: width, height: height) {
            properties[AVVideoAverageBitRateKey] = rate
        }
        return properties
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

    /// The facts under the keys the container keeps: QuickTime keys in a movie, which Finder,
    /// `mdls` and `ffprobe` read, and the common identifiers in an MP4, which AVFoundation
    /// stores as its user data atoms (`cprt`, `dscp`, `titl`, `auth`, `date`) and `AVAsset`
    /// reads back. `ffprobe` and Spotlight skip those in an MP4, whatever wrote them.
    func items(quickTime: Bool) -> [AVMetadataItem] {
        let day = ISO8601DateFormatter().string(from: date)
        if quickTime {
            return [
                item(.quickTimeMetadataDisplayName, title),
                item(.quickTimeMetadataAuthor, author),
                item(.quickTimeMetadataCopyright, copyright),
                item(.quickTimeMetadataDescription, summary),
                item(.quickTimeMetadataCreationDate, day),
            ]
        }
        return [
            item(.commonIdentifierTitle, title),
            item(.commonIdentifierCreator, author),
            item(.commonIdentifierCopyrights, copyright),
            item(.commonIdentifierDescription, summary),
            item(.commonIdentifierCreationDate, day),
        ]
    }

    /// Two lines to paste beside the video in a chat: what it shows and under which licence.
    public var caption: String { "\(title)\n\(author), \(Self.licence) \(Self.licenceURL)\n" }

    private func item(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
        let made = AVMutableMetadataItem()
        made.identifier = identifier
        made.value = value as NSString
        made.dataType = kCMMetadataBaseDataType_UTF8 as String
        return made
    }
}
