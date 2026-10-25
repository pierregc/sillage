import SillageCore
import simd

/// What the app's look tuning needs on top of drawing a file: editing one galaxy's colour
/// without writing the others into the file.
extension LookFile {
    /// The colour galaxy `index` is drawn in: the palette's if it reaches that far, the
    /// scene's own otherwise.
    public func colour(ofGalaxy index: Int, in scene: SceneConfig) -> SIMD3<Float> {
        if index < palette.count { return palette[index] }
        return index < scene.galaxies.count ? scene.galaxies[index].color : SIMD3(1, 1, 1)
    }

    /// Gives galaxy `index` its own colour. The palette is ordered, so the galaxies before it
    /// are written in the colours they already have; the ones after it are left out.
    public mutating func setColour(
        _ colour: SIMD3<Float>, ofGalaxy index: Int, in scene: SceneConfig
    ) {
        while palette.count <= index {
            palette.append(self.colour(ofGalaxy: palette.count, in: scene))
        }
        palette[index] = colour
    }

    /// `scene` drawn with this file's palette.
    public func painted(_ scene: SceneConfig) -> SceneConfig {
        var out = scene
        paint(&out)
        return out
    }
}
