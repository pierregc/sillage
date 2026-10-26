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
