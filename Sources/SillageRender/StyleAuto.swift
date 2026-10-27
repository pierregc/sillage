import Foundation
import SillageCore
import simd

/// The style Auto chooses for a scene: the best (rendering, palette) pair of a world, judged on
/// key frames of the take as they are drawn.
public enum StyleAuto {
    /// Palettes tried with each rendering, the best scored by `PaletteAuto` first.
    public static func palettesPerRendering(_ world: Palette.World) -> Int {
        4
    }
    /// Width the frames are scaled down to before they are scored.
    public static let cellWidth = 480
    /// Share of the total the palette's own score holds: harmony does not show on a frame.
    static let paletteWeight: Float = 0.2

    public struct Candidate: Sendable {
        /// The scene's look with the rendering and the palette applied.
        public var look: LookFile
        public var rendering: String
        public var palette: Palette
        public var paletteScore: PaletteScore
        public var frames: [FrameScore]
        public var total: Float
    }

    /// `base` with `rendering`'s settings and `palette`: the camera and the field of view stay
    /// the scene's, so the framing does not change with the style.
    public static func apply(
        _ rendering: LookFile, palette: Palette, to base: LookFile,
        references: [TelescopeReference] = TelescopeReference.repository
    ) -> LookFile {
        var file = base
        file.name = rendering.name
        file.look = rendering.look
        file.look.fieldOfView = base.look.fieldOfView
        file.starCount = rendering.starCount
        file.supersample = rendering.supersample
        file.bloomLevels = rendering.bloomLevels
        file.plain = rendering.plain
        file.armStrength = rendering.armStrength
        file.world = rendering.world
        file.palette = palette.galaxyColours(references: references)
        file.paletteRecipe = palette
        return file
    }

    /// Three of the key frames: the pericentre, the tails and the approach first.
    public static func frames(_ keys: [KeyFrame]) -> [KeyFrame] {
        let order: [KeyFrame.Role] = [.pericentre, .tails, .approach, .middle, .end, .start, .chosen]
        return Array(
            keys.sorted {
                (order.firstIndex(of: $0.role) ?? order.count)
                    < (order.firstIndex(of: $1.role) ?? order.count)
            }.prefix(3)
        ).sorted { $0.frame < $1.frame }
    }

    /// Renderings kept from the first round for the other palettes.
    public static let finalists = 4

    /// Each rendering drawn with the best palette on `frames` at `width` by `height`, then the
    /// best `finalists` renderings with the other palettes; every pair scored, best first.
    public static func ranked(
        sheet: LookSheet, base: LookFile, renderings: [LookFile], palettes: [PaletteAuto.Ranked],
        frames: [Int], width: Int, height: Int, framesPerSecond: Int,
        references: [TelescopeReference] = []
    ) throws -> [Candidate] {
        guard let first = palettes.first else { return [] }
        func score(_ pairs: [(LookFile, PaletteAuto.Ranked)]) throws -> [Candidate] {
            try self.score(
                pairs, sheet: sheet, base: base, frames: frames, width: width, height: height,
                framesPerSecond: framesPerSecond, references: references)
        }
        let round = try score(renderings.map { ($0, first) })
        let kept = round.prefix(finalists).compactMap { candidate in
            renderings.first { $0.name == candidate.rendering }
        }
        let more = try score(kept.flatMap { rendering in palettes.dropFirst().map { (rendering, $0) } })
        return (round + more).enumerated().sorted {
            $0.element.total != $1.element.total
                ? $0.element.total > $1.element.total : $0.offset < $1.offset
        }.map(\.element)
    }

    static func score(
        _ pairs: [(LookFile, PaletteAuto.Ranked)], sheet: LookSheet, base: LookFile,
        frames: [Int], width: Int, height: Int, framesPerSecond: Int,
        references: [TelescopeReference]
    ) throws -> [Candidate] {
        var candidates = pairs.map { rendering, ranked in
            Candidate(
                look: apply(rendering, palette: ranked.palette, to: base, references: references),
                rendering: rendering.name, palette: ranked.palette, paletteScore: ranked.score,
                frames: [], total: 0)
        }
        guard !candidates.isEmpty else { return [] }
        let cellHeight = max(
            Int((Double(cellWidth) * Double(height) / Double(width)).rounded()), 1)
        try sheet.draw(
            looks: candidates.map(\.look), frames: frames, width: width, height: height,
            cellWidth: cellWidth, cellHeight: cellHeight, framesPerSecond: framesPerSecond,
            owners: true
        ) { row, _, cell in
            let telescope = candidates[row].look.world == .telescope
            let own = references.filter { $0.name == candidates[row].palette.family }
            candidates[row].frames.append(
                FrameScore(
                    pixels: cell.pixels, width: cellWidth, height: cellHeight, owners: cell.owners,
                    references: telescope ? (own.isEmpty ? references : own) : [],
                    ramps: candidates[row].look.palette.contains { $0.ramp != nil }))
        }
        for index in candidates.indices {
            candidates[index].total =
                (1 - paletteWeight) * FrameScore.mean(candidates[index].frames)
                + paletteWeight * candidates[index].paletteScore.total
        }
        return candidates.sorted { $0.total > $1.total }
    }

    /// What `choose` found: the pairs best first, the frames they were judged on and the sheet
    /// that drew them, to draw more.
    public struct Outcome {
        public var world: Palette.World
        public var keys: [KeyFrame]
        public var ranked: [Candidate]
        public var sheet: LookSheet
        public var width: Int
        public var height: Int
        public var fps: Int
    }

    /// The pairs of a scene with a take, in `world` or else its look's world. `catalogue` is
    /// the repository's looks, `references` #125's sets. `family` keeps the palettes to one
    /// family, `fixed` to the one palette given; `favourites` join the palettes tried. The
    /// palettes come as ramps of colours unless `multicolour` is off. Nothing is written.
    public static func choose(
        _ folder: SceneFolder, world: Palette.World? = nil, family: String? = nil,
        fixed: Palette? = nil, catalogue: [LookFile], references: [TelescopeReference],
        favourites: [Palette] = [], multicolour: Bool = true
    ) throws -> Outcome {
        guard FileManager.default.fileExists(atPath: folder.take.path) else {
            throw SceneFolder.LookError.noTake(folder.url)
        }
        let base =
            (try? Data(contentsOf: folder.look)).flatMap { try? LookFile.decoded(from: $0) }
            ?? .standard
        let world = world ?? base.world
        let renderings = LookCatalogue.renderings(world, in: catalogue)
        let scene = try SceneFile.decoded(from: Data(contentsOf: folder.scene))
        let palettes: [PaletteAuto.Ranked]
        if let fixed {
            palettes = [
                PaletteAuto.Ranked(palette: fixed, score: PaletteScore(fixed, references: references))
            ]
        } else {
            palettes = Array(
                try PaletteAuto.ranked(
                    galaxies: scene.galaxies.count, world: world, family: family, seed: scene.seed,
                    telescope: references, favourites: favourites, multicolour: multicolour
                ).prefix(palettesPerRendering(world)))
        }

        let sheet = try LookSheet(take: try RecordingFile.read(from: folder.take))
        let lastFrame = sheet.capturedFrames - 1
        let samples =
            (try? String(contentsOf: folder.hiresCurves, encoding: .utf8))
            .map(KeyFrames.samples) ?? []
        var keys = frames(KeyFrames.pick(samples.filter { $0.frame <= lastFrame }))
        if keys.isEmpty {
            keys = [lastFrame / 4, lastFrame / 2, 3 * lastFrame / 4].map {
                KeyFrame(frame: $0, role: .middle, timeMyr: 0)
            }
        }
        let clip = try folder.storedClip()
        let hires = folder.storedHires()
        let width = hires?.width ?? clip.width
        let height = hires?.height ?? clip.height
        let fps = hires?.fps ?? clip.fps
        let ranked = try self.ranked(
            sheet: sheet, base: base, renderings: renderings, palettes: palettes,
            frames: keys.map(\.frame), width: width, height: height, framesPerSecond: fps,
            references: references)
        return Outcome(
            world: world, keys: keys, ranked: ranked, sheet: sheet, width: width, height: height,
            fps: fps)
    }
}
