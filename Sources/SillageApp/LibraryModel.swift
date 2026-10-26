import AVFoundation
import AppKit
import SillageRender
import SwiftUI

/// The library window's state: the scenes on disk, the choices made about them, and the one
/// clip that plays. Everything else shows a still, because a few hundred decoders at once
/// would bring the machine down long before the grid ran out of scenes.
@MainActor
final class LibraryModel: ObservableObject {
    enum Key: Equatable {
        case left, right, up, down, yes, no, clear, enlarge, close
        case digit(Int)
    }

    @Published private(set) var root: URL?
    @Published private(set) var scenes: [LibraryScene] = []
    @Published private(set) var entries: [String: SceneRatings.Entry] = [:]
    @Published private(set) var visible: [LibraryScene] = []
    @Published private(set) var playable: Set<String> = []
    @Published private(set) var playing: String?
    @Published var query = LibraryQuery() { didSet { refreshVisible() } }
    @Published var selection: String? { didSet { updatePlayback() } }
    @Published var enlarged: String? { didSet { updatePlayback() } }
    @Published var failure: String?

    /// Set by the grid from its width, so up and down move by a row.
    var columns = 4
    let player = AVQueuePlayer()
    private(set) var lastScan: TimeInterval = 0

    private var looper: AVPlayerLooper?
    private var hovered: String?
    private var hoverTask: Task<Void, Never>?
    private var watcher: Task<Void, Never>?
    private var probed: [String: Probe] = [:]
    private var writes = 0
    private var lastDigit: (scene: String, value: Int, at: Date)?

    private struct Probe: Equatable {
        var bytes: Int
        var modified: Date
    }

    nonisolated private static let rootKey = "libraryRoot"

    init(root: URL? = LibraryModel.defaultRoot()) {
        self.root = root
        player.isMuted = true
    }

    var batches: [String] { Array(Set(scenes.map(\.batch))).sorted(by: >) }

    var archetypes: [String] {
        Array(Set(scenes.map { $0.archetype ?? LibraryQuery.free })).sorted()
    }

    /// Set by the application: opens a take for look tuning in the main window.
    var onTune: ((LibraryScene) -> Void)?

    func tune(_ scene: LibraryScene) {
        enlarged = nil
        onTune?(scene)
    }

    func scene(_ id: String?) -> LibraryScene? {
        id.flatMap { id in scenes.first { $0.id == id } }
    }

    // MARK: Watching the folder

    func watch() {
        guard watcher == nil else { return }
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    var isWatching: Bool { watcher != nil }

    func stop() {
        watcher?.cancel()
        watcher = nil
        enlarged = nil
        hovered = nil
        play(nil)
    }

    func open(root: URL) {
        self.root = root
        UserDefaults.standard.set(root.path, forKey: Self.rootKey)
        scenes = []
        entries = [:]
        playable = []
        probed = [:]
        selection = nil
        enlarged = nil
        query = LibraryQuery()
        Task { await refresh() }
    }

    func pickRoot() {
        let panel = NSOpenPanel()
        panel.title = "Choisir la bibliothèque"
        panel.message = "Le dossier library, ou un seul lot."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = root
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(root: url)
    }

    /// Scans off the main actor and publishes only what changed, so a scan that finds nothing
    /// new costs the grid nothing.
    func refresh() async {
        guard let root else { return }
        let writesBefore = writes
        let started = Date()
        let (found, read) = await Task.detached {
            let scenes = SceneLibrary.scan(root)
            var entries: [String: SceneRatings.Entry] = [:]
            for batch in Set(scenes.map(\.batchURL)) {
                for (name, entry) in SceneRatings.read(batch: batch).scenes {
                    entries["\(batch.lastPathComponent)/\(name)"] = entry
                }
            }
            return (scenes, entries)
        }.value
        guard root == self.root else { return }
        lastScan = Date().timeIntervalSince(started)
        var changed = false
        if found != scenes {
            scenes = found
            changed = true
        }
        // A click while the scan was reading would be undone by what it read.
        if writes == writesBefore, read != entries {
            entries = read
            changed = true
        }
        if changed { refreshVisible() }
        await probe(found)
    }

    /// A render writes its preview as it goes, and the file only plays once it is finished.
    /// Each video is asked once per size and date, so a few hundred cost one pass.
    private func probe(_ scenes: [LibraryScene]) async {
        for scene in scenes {
            guard let video = scene.video else { continue }
            let stamp = Probe(bytes: scene.videoBytes, modified: scene.modified)
            guard probed[scene.id] != stamp else { continue }
            probed[scene.id] = stamp
            if await Self.isPlayable(video) {
                playable.insert(scene.id)
            } else {
                playable.remove(scene.id)
            }
        }
        updatePlayback()
    }

    nonisolated static func isPlayable(_ url: URL) async -> Bool {
        guard let loaded = try? await AVURLAsset(url: url).load(.isPlayable, .duration) else {
            return false
        }
        return loaded.0 && loaded.1.seconds > 0
    }

    private func refreshVisible() {
        let before = selection.flatMap { id in visible.firstIndex { $0.id == id } }
        visible = query.apply(scenes, entries: entries)
        // A choice can take the scene out of the filter; the next one takes its place.
        if let selection, !visible.contains(where: { $0.id == selection }) {
            if let before, !visible.isEmpty {
                self.selection = visible[min(before, visible.count - 1)].id
            } else {
                self.selection = nil
            }
        }
        if let enlarged, !visible.contains(where: { $0.id == enlarged }) {
            self.enlarged = selection
        }
    }

    // MARK: Choosing

    func choose(_ choice: SceneRatings.Choice, for id: String, toggle: Bool = true) {
        change(id) { entry in
            entry.choice = toggle && entry.choice == choice ? nil : choice
        }
    }

    func rate(_ value: Int, for id: String, toggle: Bool = true) {
        change(id) { entry in
            entry.rating = toggle && entry.rating == value ? nil : value
        }
    }

    func clear(_ id: String) {
        change(id) { entry in
            entry.choice = nil
            entry.rating = nil
        }
    }

    private func change(_ id: String, _ edit: (inout SceneRatings.Entry) -> Void) {
        guard let scene = scene(id) else { return }
        selection = id
        do {
            let ratings = try SceneRatings.update(batch: scene.batchURL, scene: scene.name, edit)
            writes += 1
            var updated = entries.filter { !$0.key.hasPrefix(scene.batch + "/") }
            for (name, entry) in ratings.scenes { updated["\(scene.batch)/\(name)"] = entry }
            entries = updated
            failure = nil
            refreshVisible()
        } catch {
            failure = "Impossible d'écrire \(SceneRatings.fileName) : \(error.localizedDescription)"
        }
    }

    // MARK: Keyboard

    /// One key, one change, saved at once. Digits rate; a 1 followed quickly by a 0 is a ten.
    @discardableResult
    func handle(_ key: Key, at date: Date = Date()) -> Bool {
        if key == .close {
            guard enlarged != nil else { return false }
            enlarged = nil
            return true
        }
        guard !visible.isEmpty else { return false }
        let index = selection.flatMap { id in visible.firstIndex { $0.id == id } }
        func move(_ offset: Int) {
            let target = index.map { min(max($0 + offset, 0), visible.count - 1) } ?? 0
            selection = visible[target].id
            if enlarged != nil { enlarged = selection }
        }
        switch key {
        case .left: move(-1)
        case .right: move(1)
        case .up: move(-max(columns, 1))
        case .down: move(max(columns, 1))
        case .enlarge:
            guard let selection = selection ?? visible.first?.id else { return false }
            self.selection = selection
            enlarged = enlarged == nil ? selection : nil
        default:
            guard let id = selection else {
                selection = visible.first?.id
                return true
            }
            switch key {
            case .yes: choose(.yes, for: id, toggle: false)
            case .no: choose(.no, for: id, toggle: false)
            case .clear: clear(id)
            case .digit(let value):
                if value == 0, let last = lastDigit, last.scene == id, last.value == 1,
                    date.timeIntervalSince(last.at) < 0.8
                {
                    rate(10, for: id, toggle: false)
                    lastDigit = nil
                } else {
                    rate(value, for: id, toggle: false)
                    lastDigit = (id, value, date)
                }
            default: return false
            }
        }
        return true
    }

    // MARK: Playback

    /// Waits a moment before switching, so sweeping the pointer across the grid does not
    /// open a decoder for every scene it crosses.
    func hover(_ id: String, inside: Bool) {
        hoverTask?.cancel()
        if inside {
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, let self else { return }
                self.hovered = id
                self.updatePlayback()
            }
        } else if hovered == id {
            hovered = nil
            updatePlayback()
        }
    }

    private func updatePlayback() {
        play(enlarged ?? hovered ?? selection)
    }

    private func play(_ id: String?) {
        let target = id.flatMap { playable.contains($0) ? $0 : nil }
        guard target != playing else { return }
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
        playing = nil
        guard let target, let video = scene(target)?.video else { return }
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: video))
        player.play()
        playing = target
    }

    // MARK: Where the library is

    /// The folder chosen last, else the repository's `library/` found above the application,
    /// which is where `scripts/dev.sh app` builds it.
    nonisolated static func defaultRoot() -> URL? {
        if let stored = UserDefaults.standard.string(forKey: rootKey),
            FileManager.default.fileExists(atPath: stored)
        {
            return URL(fileURLWithPath: stored, isDirectory: true)
        }
        var folder = Bundle.main.bundleURL
        for _ in 0..<6 {
            folder = folder.deletingLastPathComponent()
            let library = folder.appendingPathComponent("library", isDirectory: true)
            if FileManager.default.fileExists(atPath: library.path) { return library }
        }
        return nil
    }
}

/// Stills for the grid, downsampled once and kept while memory allows. A scene with no
/// thumbnail of its own, as in the flat batches, gets one from the middle of its video.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    nonisolated static let width = 480

    private let cache = NSCache<NSString, NSImage>()

    func key(_ scene: LibraryScene) -> String {
        "\(scene.id)|\(scene.thumbnail != nil)|\(scene.modified.timeIntervalSince1970)"
    }

    func cached(_ scene: LibraryScene) -> NSImage? { cache.object(forKey: key(scene) as NSString) }

    func load(_ scene: LibraryScene) async -> NSImage? {
        let key = key(scene)
        if let image = cache.object(forKey: key as NSString) { return image }
        guard let still = await Self.still(thumbnail: scene.thumbnail, video: scene.video) else {
            return nil
        }
        let image = NSImage(cgImage: still.image, size: .zero)
        cache.setObject(image, forKey: key as NSString)
        return image
    }

    struct Still: @unchecked Sendable { let image: CGImage }

    nonisolated static func still(thumbnail: URL?, video: URL?) async -> Still? {
        if let thumbnail, let source = CGImageSourceCreateWithURL(thumbnail as CFURL, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: width,
                ] as CFDictionary)
        {
            return Still(image: image)
        }
        guard let video else { return nil }
        let asset = AVURLAsset(url: video)
        guard let duration = try? await asset.load(.duration), duration.seconds > 0 else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: width, height: width)
        let middle = CMTime(seconds: duration.seconds / 2, preferredTimescale: 600)
        guard let still = try? await generator.image(at: middle) else { return nil }
        return Still(image: still.image)
    }
}
