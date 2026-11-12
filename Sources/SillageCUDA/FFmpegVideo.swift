import Foundation
import SillageCore
import SillageRender

/// Videos encoded by ffmpeg on Linux (#278), where VideoToolbox is not: the frames piped in raw,
/// HEVC with libx265 and H.264 with libx264 at a preset's rate, ProRes 422 HQ with prores_ks.
/// `SILLAGE_FFMPEG` and `SILLAGE_FFPROBE` name the binaries, `ffmpeg` and `ffprobe` on the path
/// otherwise. NVENC is not used: rented containers often do not expose it, and the CPU encoders
/// keep up with a frame every few seconds.
public enum FFmpegVideo {
    public struct Failure: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
        init(_ message: String) { self.message = message }
    }

    static var ffmpeg: String { ProcessInfo.processInfo.environment["SILLAGE_FFMPEG"] ?? "ffmpeg" }
    static var ffprobe: String { ProcessInfo.processInfo.environment["SILLAGE_FFPROBE"] ?? "ffprobe" }

    /// The encoder's options for `codec` at `bitsPerSecond`, the codec's own default when nil.
    static func encoding(_ codec: VideoCodec, width: Int, height: Int, bitsPerSecond: Int?) -> [String] {
        let rate = bitsPerSecond ?? codec.defaultBitRate(width: width, height: height)
        let colour = [
            "-vf", "scale=out_color_matrix=bt709:out_range=tv", "-colorspace", "bt709",
            "-color_primaries", "bt709", "-color_trc", "bt709",
        ]
        switch codec {
        case .hevc:
            return colour + [
                "-c:v", "libx265", "-pix_fmt", "yuv420p", "-tag:v", "hvc1", "-x265-params", "log-level=error",
            ] + (rate.map { ["-b:v", String($0)] } ?? [])
        case .h264:
            return colour + ["-c:v", "libx264", "-pix_fmt", "yuv420p"]
                + (rate.map { ["-b:v", String($0)] } ?? [])
        case .prores:
            return colour + ["-c:v", "prores_ks", "-profile:v", "3", "-pix_fmt", "yuv422p10le"]
        }
    }

    /// The licence, the author and the scene, as the Mac's videos carry them.
    static func tags(_ metadata: VideoMetadata?) -> [String] {
        guard let metadata else { return [] }
        return [
            "-metadata", "title=\(metadata.title)", "-metadata", "artist=\(metadata.author)",
            "-metadata", "copyright=\(metadata.copyright)", "-metadata", "comment=\(metadata.summary)",
        ]
    }

    /// Runs a tool to its end, its standard error kept for a failure.
    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [tool] + arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw Failure("\(tool) did not start: \(error)")
        }
        let printed = output.fileHandleForReading.readDataToEndOfFile()
        let complaint = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure(
                "\(tool) \(arguments.joined(separator: " ")) failed: "
                    + String(decoding: complaint, as: UTF8.self))
        }
        return String(decoding: printed, as: UTF8.self)
    }

    /// The frames a video holds, counted packet by packet.
    public static func frameCount(_ url: URL) throws -> Int {
        let printed = try run(
            ffprobe,
            [
                "-v", "error", "-select_streams", "v:0", "-count_packets", "-show_entries",
                "stream=nb_read_packets", "-of", "csv=p=0", url.path,
            ])
        guard let count = Int(printed.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw Failure("ffprobe gave no frame count for \(url.lastPathComponent): \(printed)")
        }
        return count
    }

    /// Joins whole segments into one video without encoding them again (the concat demuxer,
    /// `-c copy`), and checks it holds `frames` frames, as many as the segments.
    public static func join(
        _ parts: [URL], into url: URL, frames: Int, framesPerSecond: Int, metadata: VideoMetadata?
    ) throws {
        guard !parts.isEmpty else { throw RunVideos.Failure.join("no segment") }
        var counted = 0
        for part in parts { counted += try frameCount(part) }
        let list = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).segments.txt")
        let lines = parts.map { "file '\($0.path.replacingOccurrences(of: "'", with: "'\\''"))'\n" }
        try lines.joined().write(to: list, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: list) }
        try? FileManager.default.removeItem(at: url)
        let hevc =
            (try? run(
                ffprobe,
                [
                    "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=codec_name", "-of",
                    "csv=p=0", parts[0].path,
                ]
            ))?.contains("hevc") == true
        do {
            try run(
                ffmpeg,
                [
                    "-hide_banner", "-loglevel", "error", "-y", "-f", "concat", "-safe", "0", "-i", list.path,
                    "-c", "copy",
                ]
                    + (hevc ? ["-tag:v", "hvc1"] : []) + tags(metadata) + ["-f", format(of: url), url.path])
        } catch {
            throw RunVideos.Failure.join("\(error)")
        }
        let joined = try frameCount(url)
        guard joined == frames, counted == frames else {
            throw RunVideos.Failure.join(
                "\(joined) frames in the video, \(counted) in the segments, \(frames) drawn")
        }
    }

    /// The container for a file name: a QuickTime movie for `.mov`, an MP4 otherwise.
    static func format(of url: URL) -> String { url.pathExtension.lowercased() == "mov" ? "mov" : "mp4" }

    /// The ffmpeg run here, and which of the encoders a full pass uses it has.
    public static func probe() throws -> (version: String, encoders: [String]) {
        let version =
            try run(ffmpeg, ["-hide_banner", "-version"]).split(separator: "\n").first.map(String.init) ?? ""
        let listed = try run(ffmpeg, ["-hide_banner", "-encoders"])
        let encoders = ["libx265", "libx264", "prores_ks"].filter { name in
            listed.split(separator: "\n").contains {
                $0.split(separator: " ").dropFirst().first == Substring(name)
            }
        }
        return (version, encoders)
    }
}

/// One video encoded by ffmpeg, its frames piped in as 8-bit RGB rows from the top.
public final class FFmpegVideoWriter {
    public let url: URL
    public let width: Int
    public let height: Int
    public private(set) var frames = 0
    private let process: Process
    private let input: FileHandle
    private let log: URL
    private var finished = false

    public init(
        url: URL, width: Int, height: Int, framesPerSecond: Int, codec: VideoCodec, bitsPerSecond: Int?,
        metadata: VideoMetadata?
    ) throws {
        self.url = url
        self.width = width
        self.height = height
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        log = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments =
            [
                FFmpegVideo.ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-f", "rawvideo", "-pix_fmt",
                "rgb24", "-s", "\(width)x\(height)", "-framerate", String(max(framesPerSecond, 1)), "-i", "-",
            ]
            + FFmpegVideo.encoding(codec, width: width, height: height, bitsPerSecond: bitsPerSecond)
            + FFmpegVideo.tags(metadata) + ["-f", FFmpegVideo.format(of: url), url.path]
        let pipe = Pipe()
        process.standardInput = pipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = try FileHandle(forWritingTo: log)
        input = pipe.fileHandleForWriting
        do {
            try process.run()
        } catch {
            throw FFmpegVideo.Failure("ffmpeg did not start: \(error)")
        }
    }

    /// Hands a frame to the encoder: `width * height * 3` bytes.
    public func append(_ pixels: UnsafeRawBufferPointer) throws {
        guard pixels.count == width * height * 3 else {
            throw FFmpegVideo.Failure("a frame of \(pixels.count) bytes for \(width) by \(height)")
        }
        do {
            try input.write(contentsOf: Data(pixels))
        } catch {
            throw FFmpegVideo.Failure("ffmpeg stopped taking frames: \(complaint())")
        }
        frames += 1
    }

    /// Closes the video and checks it holds every frame handed over.
    public func finish() throws {
        guard !finished else { return }
        finished = true
        try input.close()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw FFmpegVideo.Failure("ffmpeg failed on \(url.lastPathComponent): \(complaint())")
        }
        let counted = try FFmpegVideo.frameCount(url)
        guard counted == frames else {
            throw FFmpegVideo.Failure(
                "\(url.lastPathComponent) holds \(counted) frames of the \(frames) drawn")
        }
        try? FileManager.default.removeItem(at: log)
    }

    private func complaint() -> String {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").trimmingCharacters(
            in: .whitespacesAndNewlines)
    }

    /// A video never finished is stopped where it is, as a killed run leaves it.
    deinit {
        guard !finished else { return }
        try? input.close()
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }
}
