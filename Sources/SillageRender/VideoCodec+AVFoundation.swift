import AVFoundation
import Foundation
import VideoToolbox

extension VideoCodec {
    /// H.264 plays everywhere, HEVC is the same picture in about half the bytes, and ProRes
    /// is for editing: large, and cut and graded without being compressed a second time.
    public var avCodec: AVVideoCodecType {
        switch self {
        case .h264: .h264
        case .hevc: .hevc
        case .prores: .proRes422HQ
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

extension VideoMetadata {
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

    private func item(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
        let made = AVMutableMetadataItem()
        made.identifier = identifier
        made.value = value as NSString
        made.dataType = kCMMetadataBaseDataType_UTF8 as String
        return made
    }
}
