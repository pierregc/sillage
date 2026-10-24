import Foundation

/// One scene as the library sees it: where its files are and what the batch index says
/// about it. Read from the folder layout of `SceneFolder`, and from the flat batches
/// `scripts/library.sh` wrote before it, where a scene is `<batch>/<id>.mov`.
public struct LibraryScene: Sendable, Equatable, Identifiable {
    public var batch: String
    public var batchURL: URL
    public var name: String
    public var video: URL?
    public var thumbnail: URL?
    public var archetype: String?
    public var tempo: String?
    public var galaxies: Int?
    public var seed: String?
    /// How promising the scene looks from its curves alone (#45), higher first.
    public var score: Double?
    /// Size and date of the video, which change for as long as a render is writing it.
    public var videoBytes: Int
    public var modified: Date

    public var id: String { "\(batch)/\(name)" }

    public init(
        batch: String, batchURL: URL, name: String, video: URL? = nil, thumbnail: URL? = nil,
        archetype: String? = nil, tempo: String? = nil, galaxies: Int? = nil, seed: String? = nil,
        score: Double? = nil, videoBytes: Int = 0, modified: Date = .distantPast
    ) {
        self.batch = batch
        self.batchURL = batchURL
        self.name = name
        self.video = video
        self.thumbnail = thumbnail
        self.archetype = archetype
        self.tempo = tempo
        self.galaxies = galaxies
        self.seed = seed
        self.score = score
        self.videoBytes = videoBytes
        self.modified = modified
    }
}

/// The choices made about a batch, `ratings.json` in the batch folder. Keyed by scene folder
/// name; the scenes whose choice is `yes` are what the next milestone starts from:
/// `jq -r '.scenes | to_entries[] | select(.value.choice == "yes") | .key' ratings.json`.
public struct SceneRatings: Codable, Sendable, Equatable {
    public enum Choice: String, Codable, Sendable { case yes, no }

    public struct Entry: Codable, Sendable, Equatable {
        public var choice: Choice?
        public var rating: Int?
        public var updated: Date?

        public init(choice: Choice? = nil, rating: Int? = nil, updated: Date? = nil) {
            self.choice = choice
            self.rating = rating
            self.updated = updated
        }

        public var isEmpty: Bool { choice == nil && rating == nil }
    }

    public static let fileName = "ratings.json"
    public static let ratingRange = 0...10

    public var version = 1
    public var scenes: [String: Entry] = [:]

    public init(scenes: [String: Entry] = [:]) { self.scenes = scenes }

    public var chosen: [String] { scenes.filter { $0.value.choice == .yes }.keys.sorted() }

    public static func url(batch: URL) -> URL { batch.appendingPathComponent(fileName) }

    /// An empty set when the file is missing or unreadable: a garbled file must not stop the
    /// batch from being browsed, and the next write replaces it.
    public static func read(batch: URL) -> SceneRatings {
        guard let data = try? Data(contentsOf: url(batch: batch)) else { return SceneRatings() }
        return (try? decoder.decode(SceneRatings.self, from: data)) ?? SceneRatings()
    }

    public func write(batch: URL) throws {
        try Self.encoder.encode(self).write(to: Self.url(batch: batch), options: .atomic)
    }

    /// Reads the file as it is now, changes one scene and writes it back, so a scene rated
    /// by another tool in the meantime keeps its rating.
    @discardableResult
    public static func update(
        batch: URL, scene: String, at date: Date = Date(), _ change: (inout Entry) -> Void
    ) throws -> SceneRatings {
        var ratings = read(batch: batch)
        var entry = ratings.scenes[scene] ?? Entry()
        change(&entry)
        entry.rating = entry.rating.map { min(max($0, ratingRange.lowerBound), ratingRange.upperBound) }
        // Whole seconds, which is what the file keeps.
        entry.updated = Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
        ratings.scenes[scene] = entry.isEmpty ? nil : entry
        try ratings.write(batch: batch)
        return ratings
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public enum SceneLibrary {
    /// Every scene under `root`, which is either a library of batch folders or one batch.
    /// Cheap enough to run every couple of seconds over a few hundred scenes: directory
    /// listings, one small index per batch, nothing decoded.
    public static func scan(_ root: URL) -> [LibraryScene] {
        let root = root.standardizedFileURL
        var scenes = scenes(inBatch: root)
        for folder in directories(in: root) where !isSceneFolder(folder) {
            scenes += Self.scenes(inBatch: folder)
        }
        return scenes
    }

    public static func isSceneFolder(_ url: URL) -> Bool {
        let folder = SceneFolder(url)
        return [folder.preview, folder.thumbnail, folder.scene].contains {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    static func scenes(inBatch batch: URL) -> [LibraryScene] {
        let name = batch.lastPathComponent
        let index = indexRows(batch.appendingPathComponent("index.csv"))
        var scenes: [LibraryScene] = []
        for url in directories(in: batch) where isSceneFolder(url) {
            let folder = SceneFolder(url)
            let video = exists(folder.preview) ? folder.preview : nil
            scenes.append(
                described(
                    LibraryScene(
                        batch: name, batchURL: batch, name: url.lastPathComponent, video: video,
                        thumbnail: exists(folder.thumbnail) ? folder.thumbnail : nil,
                        archetype: archetype(in: folder.scene), score: score(in: folder.interest)),
                    index: index))
        }
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: batch, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        for file in files where file.pathExtension == "mov" {
            scenes.append(
                described(
                    LibraryScene(
                        batch: name, batchURL: batch,
                        name: file.deletingPathExtension().lastPathComponent, video: file),
                    index: index))
        }
        return scenes
    }

    private static func described(_ scene: LibraryScene, index: [String: [String: String]])
        -> LibraryScene
    {
        var scene = scene
        if let row = index[scene.name] {
            scene.tempo = row["tempo"].flatMap { $0.isEmpty ? nil : $0 }
            scene.galaxies = row["galaxies"].flatMap { Int($0) }
            scene.seed = row["seed"].flatMap { $0.isEmpty ? nil : $0 }
            if scene.archetype == nil, let archetype = row["archetype"], !archetype.isEmpty {
                scene.archetype = archetype
            }
            if scene.score == nil { scene.score = row["score"].flatMap { Double($0) } }
        }
        if let video = scene.video,
            let attributes = try? FileManager.default.attributesOfItem(atPath: video.path)
        {
            scene.videoBytes = (attributes[.size] as? Int) ?? 0
            scene.modified = (attributes[.modificationDate] as? Date) ?? .distantPast
        }
        return scene
    }

    /// The scene file records its archetype from #42 on. Read without decoding the whole
    /// file, so a scene file from before or after does not hide the scene.
    /// What drew the scene: an archetype, or `free`.
    private static func archetype(in url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return (object["draw"] as? [String: Any])?["generator"] as? String
    }

    /// Written by `scripts/interest.py` beside the curves the moment the scene is explored.
    private static func score(in url: URL) -> Double? {
        guard let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return (object["score"] as? NSNumber)?.doubleValue
    }

    /// The last row for an id stands, as in the contact sheet: a retried scene appends one.
    static func indexRows(_ url: URL) -> [String: [String: String]] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard let header = lines.first?.split(separator: ",", omittingEmptySubsequences: false)
        else { return [:] }
        let names = header.map(String.init)
        var rows: [String: [String: String]] = [:]
        for line in lines.dropFirst() {
            let values = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            var row: [String: String] = [:]
            for (name, value) in zip(names, values) { row[name] = value }
            if let id = row["id"], !id.isEmpty { rows[id] = row }
        }
        return rows
    }

    private static func directories(in url: URL) -> [URL] {
        let entries =
            (try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles))
            ?? []
        return entries.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}

/// What the library shows and in which order. Pure, so the grid and the tests agree.
public struct LibraryQuery: Sendable, Equatable {
    public enum Choice: String, CaseIterable, Sendable { case all, yes, no, undecided }

    public enum Rating: Sendable, Hashable {
        case any, unrated
        case atLeast(Int)
    }

    public enum Order: String, CaseIterable, Sendable { case batch, rating, newest, score }

    public var choice = Choice.all
    public var rating = Rating.any
    public var batch: String?
    public var archetype: String?
    public var order = Order.batch

    public init() {}

    public func apply(_ scenes: [LibraryScene], entries: [String: SceneRatings.Entry])
        -> [LibraryScene]
    {
        let kept = scenes.filter { scene in
            let entry = entries[scene.id]
            switch choice {
            case .all: break
            case .yes: guard entry?.choice == .yes else { return false }
            case .no: guard entry?.choice == .no else { return false }
            case .undecided: guard entry?.choice == nil else { return false }
            }
            switch rating {
            case .any: break
            case .unrated: guard entry?.rating == nil else { return false }
            case .atLeast(let floor): guard (entry?.rating ?? -1) >= floor else { return false }
            }
            if let batch, scene.batch != batch { return false }
            if let archetype, (scene.archetype ?? Self.free) != archetype { return false }
            return true
        }
        // Newest batch first, since the batch that just ran is the one waiting to be sorted.
        let byBatch: (LibraryScene, LibraryScene) -> Bool = {
            $0.batch != $1.batch ? $0.batch > $1.batch : $0.name < $1.name
        }
        switch order {
        case .batch:
            return kept.sorted(by: byBatch)
        case .newest:
            return kept.sorted { $0.modified != $1.modified ? $0.modified > $1.modified : byBatch($0, $1) }
        // Unscored scenes last but still there: the score orders, it never hides.
        case .score:
            return kept.sorted {
                let (left, right) = ($0.score ?? -.infinity, $1.score ?? -.infinity)
                return left != right ? left > right : byBatch($0, $1)
            }
        case .rating:
            func key(_ scene: LibraryScene) -> (Int, Int) {
                let entry = entries[scene.id]
                let choice = entry?.choice == .yes ? 2 : entry?.choice == nil ? 1 : 0
                return (entry?.rating ?? -1, choice)
            }
            return kept.sorted {
                let (left, right) = (key($0), key($1))
                return left != right ? left > right : byBatch($0, $1)
            }
        }
    }

    /// What a scene with no recorded archetype is filed under, as #42 will write it.
    public static let free = "free"
}
