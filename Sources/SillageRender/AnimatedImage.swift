import Foundation

/// A looping animation that plays where a video does not: a README, a contact sheet, a chat.
public enum AnimatedImage {
    public enum Format: String, CaseIterable, Sendable {
        case webp, gif
    }

    public enum Failure: Error, CustomStringConvertible {
        case noWebPEncoder
        case encoder(String)
        case write

        public var description: String {
            switch self {
            case .noWebPEncoder:
                "WebP needs img2webp, which ImageIO lacks: brew install webp, or --format gif"
            case .encoder(let message): "img2webp failed: \(message)"
            case .write: "could not write the animation"
            }
        }
    }

    /// Writes `frames`, RGBA, looping forever at `framesPerSecond`.
    public static func write(
        _ frames: [[UInt8]], width: Int, height: Int, framesPerSecond: Int, format: Format,
        quality: Int = 80, to url: URL
    ) throws {
        try? FileManager.default.removeItem(at: url)
        switch format {
        case .gif: try writeGIF(frames, width: width, height: height, framesPerSecond, to: url)
        case .webp:
            try writeWebP(
                frames, width: width, height: height, framesPerSecond, quality: quality, to: url)
        }
    }

    /// `5MB`, `800KB` or `5`, read as megabytes, in bytes.
    public static func bytes(_ text: String) -> Int? {
        let lowered = text.lowercased().replacingOccurrences(of: " ", with: "")
        let units: [(String, Double)] = [("kb", 1e3), ("mb", 1e6), ("k", 1e3), ("m", 1e6)]
        let (number, scale) =
            units.first { lowered.hasSuffix($0.0) }
            .map { (String(lowered.dropLast($0.0.count)), $0.1) } ?? (lowered, 1e6)
        guard let value = Double(number), value > 0 else { return nil }
        return Int(value * scale)
    }

    /// GIF delays count in hundredths of a second, so the rate played is the nearest one
    /// that does.
    public static func playedRate(_ framesPerSecond: Int, format: Format) -> Double {
        switch format {
        case .gif: 100 / Double(max((100 / Double(framesPerSecond)).rounded(), 2))
        case .webp: 1000 / (1000 / Double(framesPerSecond)).rounded()
        }
    }

    private static func writeGIF(
        _ frames: [[UInt8]], width: Int, height: Int, _ framesPerSecond: Int, to url: URL
    ) throws {
        let palette = GIFPalette(frames: frames)
        var mapped = [[UInt8]](repeating: [], count: frames.count)
        mapped.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: frames.count) { index in
                out[index] = palette.indices(of: frames[index], width: width, height: height)
            }
        }
        let delay = Int((100 / playedRate(framesPerSecond, format: .gif)).rounded())
        let data = GIFWriter.data(
            frames: mapped, palette: palette, width: width, height: height, delay: delay)
        do { try data.write(to: url) } catch { throw Failure.write }
    }

    /// img2webp from libwebp, given every frame as a PNG: ImageIO reads WebP but does not
    /// write it.
    static func img2webp() -> URL? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let folders = path.split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin"]
        return folders.map { URL(fileURLWithPath: $0).appendingPathComponent("img2webp") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func writeWebP(
        _ frames: [[UInt8]], width: Int, height: Int, _ framesPerSecond: Int, quality: Int,
        to url: URL
    ) throws {
        guard let tool = img2webp() else { throw Failure.noWebPEncoder }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("sillage-webp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = frames.indices.map {
            folder.appendingPathComponent(String(format: "%05d.png", $0))
        }
        var written = [Bool](repeating: false, count: frames.count)
        written.withUnsafeMutableBufferPointer { written in
            DispatchQueue.concurrentPerform(iterations: frames.count) { index in
                written[index] =
                    (try? PNGWriter.write(
                        frames[index], width: width, height: height, to: files[index])) != nil
            }
        }
        guard !written.contains(false) else { throw Failure.write }

        let delay = Int((1000 / Double(framesPerSecond)).rounded())
        let process = Process()
        process.executableURL = tool
        process.arguments =
            ["-loop", "0", "-lossy", "-q", "\(quality)", "-d", "\(delay)"]
            + files.map(\.path) + ["-o", url.path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let message = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure.encoder(
                String(decoding: message, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
