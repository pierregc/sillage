import Foundation

/// What an `explore`, a `hires` or an `export` did, as one JSON object an agent reads instead of
/// the lines meant for a person (#466): `--summary <file>`, or `--summary -` for the last line of
/// the output. It is written as the process exits, whatever way it exits, with every file of
/// the scene folder (and `--out`) written since the command started.
public final class RunSummary: @unchecked Sendable {
    public struct Written: Codable, Equatable, Sendable {
        public var path: String
        public var bytes: Int
    }

    public struct Record: Codable, Equatable, Sendable {
        public var command: String
        public var engine: String
        public var target: String
        public var status: Int32
        public var error: String?
        public var seconds: Double
        public var written: [Written]
    }

    nonisolated(unsafe) public private(set) static var current: RunSummary?

    let command: String
    let engine: String
    let target: URL
    let extra: URL?
    let destination: String
    let started: Date
    var status: Int32 = 0
    var error: String?

    init(command: String, engine: String, target: URL, extra: URL?, destination: String, started: Date) {
        self.command = command
        self.engine = engine
        self.target = target
        self.extra = extra
        self.destination = destination
        self.started = started
    }

    /// The value after `--summary` in `arguments`, if any.
    public static func destination(in arguments: [String]) -> String? {
        arguments.firstIndex(of: "--summary").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
    }

    /// Starts a summary when `arguments` ask for one; it is written when the process exits.
    public static func begin(command: String, engine: String, target: String, arguments: [String]) {
        guard current == nil, let destination = destination(in: arguments) else { return }
        let out = arguments.firstIndex(of: "--out").flatMap {
            $0 + 1 < arguments.count ? arguments[$0 + 1] : nil
        }
        current = RunSummary(
            command: command, engine: engine, target: URL(fileURLWithPath: target),
            extra: out.map { URL(fileURLWithPath: $0) }, destination: destination, started: Date())
        atexit { RunSummary.current?.write() }
    }

    /// Records how the command ends, before it exits with `status`.
    public static func end(status: Int32, error: String? = nil) {
        current?.status = status
        if let error { current?.error = error }
    }

    public func record(now: Date = Date()) -> Record {
        Record(
            command: command, engine: engine, target: target.path, status: status, error: error,
            seconds: (now.timeIntervalSince(started) * 10).rounded() / 10,
            written: Self.written(in: [target] + (extra.map { [$0] } ?? []), since: started))
    }

    /// Files under `roots` modified since `since`, outside hidden folders, in path order.
    static func written(in roots: [URL], since: Date) -> [Written] {
        let manager = FileManager.default
        var found: [String: Int] = [:]
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        func consider(_ url: URL) {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                let date = values.contentModificationDate, date >= since.addingTimeInterval(-1)
            else { return }
            found[url.standardizedFileURL.path] = values.fileSize ?? 0
        }
        for root in roots {
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: root.path, isDirectory: &isDirectory) else { continue }
            guard isDirectory.boolValue else {
                consider(root)
                continue
            }
            let walker = manager.enumerator(
                at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
            while let url = walker?.nextObject() as? URL { consider(url) }
        }
        return found.keys.sorted().map { Written(path: $0, bytes: found[$0] ?? 0) }
    }

    func write() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(record()) else { return }
        if destination == "-" {
            fflush(nil)
            FileHandle.standardOutput.write(data + Data("\n".utf8))
        } else {
            try? data.write(to: URL(fileURLWithPath: destination), options: .atomic)
        }
    }
}
