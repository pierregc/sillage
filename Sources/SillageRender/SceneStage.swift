import Foundation

/// Where a scene stands in its life, read from the files the stages already write, so there
/// is no state of its own to keep in sync.
public enum SceneStage: String, CaseIterable, Sendable {
    case toSort, discarded, chosen, highResolution, toStyle, ready, exported

    /// A manual no discards the scene, a flat batch of videos included. A scene with no folder
    /// has nothing to compute from, so it never gets past `toSort`. A chosen scene is chosen
    /// until it has a take; with one, a file in `exports/` is the furthest it has gone, whatever
    /// its style, then a promoted look, else the style is still to choose.
    public static func of(_ scene: LibraryScene, entry: SceneRatings.Entry?) -> SceneStage {
        if entry?.choice == .no { return .discarded }
        guard scene.folder != nil, entry?.isChosen == true else { return .toSort }
        if scene.hiresActive { return .highResolution }
        guard scene.take != nil else { return .chosen }
        if !scene.exports.isEmpty { return .exported }
        return scene.promoted ? .ready : .toStyle
    }
}

/// A list of the library the sidebar offers: one per stage, in pipeline order, then all of it.
/// Discarded scenes are in `all` and nowhere else.
public enum LibraryCollection: String, CaseIterable, Sendable, Hashable {
    case toSort, chosen, highResolution, toStyle, ready, exported, all

    public func contains(_ stage: SceneStage) -> Bool {
        switch self {
        case .all: true
        case .toSort: stage == .toSort
        case .chosen: stage == .chosen
        case .highResolution: stage == .highResolution
        case .toStyle: stage == .toStyle
        case .ready: stage == .ready
        case .exported: stage == .exported
        }
    }

    public static func counts(_ scenes: [LibraryScene]) -> [LibraryCollection: Int] {
        var counts: [LibraryCollection: Int] = [:]
        for scene in scenes {
            for collection in allCases where collection.contains(scene.stage) {
                counts[collection, default: 0] += 1
            }
        }
        return counts
    }
}

/// The five steps the scene page tracks, in pipeline order.
public enum SceneStep: String, CaseIterable, Sendable {
    case exploration, choice, highResolution, style, export

    public enum State: Sendable, Equatable { case done, next, later }

    /// A step is done when its files or its choice say so, whatever the order. The next is the
    /// first step not done, unless the scene was discarded or, past the choice, has no folder
    /// to run a stage in.
    public static func states(_ scene: LibraryScene, entry: SceneRatings.Entry?) -> [SceneStep: State] {
        var states: [SceneStep: State] = [:]
        for step in allCases { states[step] = step.isDone(scene, entry: entry) ? .done : .later }
        guard entry?.choice != .no, let next = allCases.first(where: { states[$0] != .done })
        else { return states }
        if next == .choice || scene.folder != nil { states[next] = .next }
        return states
    }

    private func isDone(_ scene: LibraryScene, entry: SceneRatings.Entry?) -> Bool {
        switch self {
        case .exploration: true
        case .choice: entry?.choice != nil || entry?.picked != nil
        case .highResolution: scene.take != nil
        case .style: scene.promoted
        case .export: !scene.exports.isEmpty
        }
    }
}

/// One video of a scene the page can play.
public struct SceneVersion: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case preview, highResolution
        /// A video in `exports/`, by its file name without the extension.
        case video(String)
    }

    public var kind: Kind
    public var url: URL
    public var id: URL { url }
}

extension LibraryScene {
    public static let videoExtensions: Set = ["mp4", "mov"]

    /// The playable files of `exports/`, which also holds captions and stills.
    public var videos: [URL] {
        exports.filter { Self.videoExtensions.contains($0.pathExtension.lowercased()) }
    }

    /// The preview, the high resolution clip once it exists, then every exported video.
    public var versions: [SceneVersion] {
        var versions = video.map { [SceneVersion(kind: .preview, url: $0)] } ?? []
        if let hiresVideo { versions.append(SceneVersion(kind: .highResolution, url: hiresVideo)) }
        versions += videos.map {
            SceneVersion(kind: .video($0.deletingPathExtension().lastPathComponent), url: $0)
        }
        return versions
    }

    /// The furthest the scene has gone: a video, else the high resolution clip, else the preview.
    public var defaultVersion: SceneVersion? {
        let versions = versions
        return versions.first { if case .video = $0.kind { true } else { false } }
            ?? versions.first { $0.kind == .highResolution } ?? versions.first
    }
}
