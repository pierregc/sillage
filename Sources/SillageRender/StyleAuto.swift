import Foundation
import SillageCore
#if canImport(simd)
    import simd
#endif

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

    /// The most dust a generated style draws with, whatever its rendering's; nil draws each
    /// rendering's own. It held the dust back while it read as coarse blobs (#174), and nil
    /// since the dust is drawn as a web (#197); 0 would hold it back again.
    public static let dustCap: Float? = nil

    /// `rendering` as a generated style draws it, its dust held to `dustCap`.
    public static func generated(_ rendering: LookFile) -> LookFile {
        var file = rendering
        if let dustCap { file.look.dustStrength = min(file.look.dustStrength, dustCap) }
        return file
    }

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
    /// the scene's, so the framing does not change with the style. The dust is held to
    /// `dustCap` before the pair is scored, so the frames judged are the ones the style ships.
    public static func apply(
        _ rendering: LookFile, palette: Palette, to base: LookFile,
        references: [TelescopeReference] = TelescopeReference.repository
    ) -> LookFile {
        var file = base
        file.name = rendering.name
        file.look = generated(rendering).look
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
}
