import Foundation

/// Where the repository's own files are: `looks/`, `palettes/`, `references/telescope`,
/// `scripts/explore-batch.sh`, `library/`.
///
/// A build made in a worktree that is removed afterwards must not keep pointing at it, so the
/// root is looked for in this order: `SILLAGE_ROOT`; the root `dev.sh` wrote into the app's
/// `Info.plist` and into `sillage-root` beside the executable; and the checkout these sources
/// were compiled from (tests, `dev.sh render`).
public enum RepositoryRoot {
    public static let environmentKey = "SILLAGE_ROOT"
    public static let plistKey = "SillageRoot"
    public static let markerName = "sillage-root"

    public struct Missing: Error, CustomStringConvertible, Equatable {
        public var description: String
    }

    /// Where each candidate comes from; `current` reads the running process.
    public struct Locator {
        public var environment: [String: String]
        public var plistRoot: String?
        public var executableFolder: URL?
        public var compiledFrom: URL

        public init(
            environment: [String: String], plistRoot: String? = nil, executableFolder: URL? = nil,
            compiledFrom: URL
        ) {
            self.environment = environment
            self.plistRoot = plistRoot
            self.executableFolder = executableFolder
            self.compiledFrom = compiledFrom
        }

        public static func current() -> Locator {
            Locator(
                environment: ProcessInfo.processInfo.environment,
                plistRoot: Bundle.main.object(forInfoDictionaryKey: RepositoryRoot.plistKey) as? String,
                executableFolder: Bundle.main.executableURL?.resolvingSymlinksInPath()
                    .deletingLastPathComponent(),
                compiledFrom: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                    .deletingLastPathComponent().deletingLastPathComponent())
        }
    }

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Any] = [:]

        func value<T>(_ key: String, _ make: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            if let kept = values[key] as? T { return kept }
            let made = make()
            values[key] = made
            return made
        }
    }

    private static let cache = Cache()

    /// What `make` reads from `relative` in the repository, read once for each place it is found.
    public static func loaded<T>(_ relative: String, _ make: (URL) -> T) -> T {
        let url = place(relative)
        return cache.value(url.path) { make(url) }
    }

    private static func isRepository(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isFolder: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder)
            && isFolder.boolValue
    }

    /// The repository's root.
    public static func resolve(_ locator: Locator = .current()) throws -> URL {
        if let set = locator.environment[environmentKey], !set.isEmpty {
            let url = URL(fileURLWithPath: set, isDirectory: true).standardizedFileURL
            guard isRepository(url) else {
                throw Missing(
                    description:
                        "\(environmentKey) is \(url.path), which holds no Sillage checkout (no Package.swift): "
                        + "point it at the repository")
            }
            return url
        }
        var tried: [String] = []
        var candidates: [(String, URL)] = []
        if let path = locator.plistRoot, !path.isEmpty {
            candidates.append(("the app's Info.plist", URL(fileURLWithPath: path, isDirectory: true)))
        }
        if let folder = locator.executableFolder,
            let text = try? String(
                contentsOf: folder.appendingPathComponent(markerName), encoding: .utf8)
        {
            let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty {
                candidates.append((markerName, URL(fileURLWithPath: path, isDirectory: true)))
            }
        }
        candidates.append(("the sources it was compiled from", locator.compiledFrom))
        for (origin, url) in candidates {
            let url = url.standardizedFileURL
            if isRepository(url) { return url }
            tried.append("\(url.path) (\(origin))")
        }
        throw Missing(
            description:
                "the Sillage repository is not where this build expects it: \(tried.joined(separator: ", ")). "
                + "Set \(environmentKey) to the checkout")
    }

    /// A folder of the repository that has to exist.
    public static func folder(_ relative: String, _ locator: Locator = .current()) throws -> URL {
        let url = try resolve(locator).appendingPathComponent(relative, isDirectory: true)
        guard isDirectory(url) else {
            throw Missing(
                description:
                    "\(relative)/ is missing at \(url.path). Set \(environmentKey) to a checkout that has it")
        }
        return url
    }

    /// A file of the repository that has to exist.
    public static func file(_ relative: String, _ locator: Locator = .current()) throws -> URL {
        let url = try resolve(locator).appendingPathComponent(relative)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw Missing(
                description:
                    "\(relative) is missing at \(url.path). Set \(environmentKey) to a checkout that has it")
        }
        return url
    }

    /// A folder of the repository that may not exist yet, such as `palettes/` or `library/`.
    /// The checkout's own path when no root is found, so a later write fails where it can say so.
    public static func place(_ relative: String, _ locator: Locator = .current()) -> URL {
        ((try? resolve(locator)) ?? locator.compiledFrom).appendingPathComponent(
            relative, isDirectory: true)
    }

    /// What is missing for the style editor and the nights, one line, or nil when all is there.
    public static func problem(_ locator: Locator = .current()) -> String? {
        for name in ["looks", "references/telescope"] {
            do { _ = try folder(name, locator) } catch { return "\(error)" }
        }
        return nil
    }
}
