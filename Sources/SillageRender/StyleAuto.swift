import Foundation
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
    public static func apply(_ rendering: LookFile, palette: Palette, to base: LookFile) -> LookFile {
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
        file.palette = palette.colours
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
                look: apply(rendering, palette: ranked.palette, to: base),
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
                    references: telescope ? (own.isEmpty ? references : own) : []))
        }
        for index in candidates.indices {
            candidates[index].total =
                (1 - paletteWeight) * FrameScore.mean(candidates[index].frames)
                + paletteWeight * candidates[index].paletteScore.total
        }
        return candidates.sorted { $0.total > $1.total }
    }
}
