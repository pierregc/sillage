import Foundation
import SillageCore
import simd

/// What the style editor (#113) does to a look file: a rendering over the palette, a palette
/// with some colours locked, a group of settings put back.
extension LookFile {
    /// The fine settings the editor folds, each with its own reset. Together they hold every
    /// field of the file but the palette, its world and the name.
    public enum Group: String, CaseIterable, Sendable {
        case light, instrument, detail, camera
    }

    /// `rendering`'s light, instrument and buffers on this file. The palette and its world,
    /// the camera and the field of view stay, unless `colours`, which takes the rendering's
    /// palette and world too.
    public func withRendering(_ rendering: LookFile, colours: Bool = false) -> LookFile {
        var file = self
        file.name = rendering.name
        file.look = rendering.look
        file.look.fieldOfView = look.fieldOfView
        file.starCount = rendering.starCount
        file.supersample = rendering.supersample
        file.bloomLevels = rendering.bloomLevels
        file.plain = rendering.plain
        file.armStrength = rendering.armStrength
        if colours {
            file.palette = rendering.palette
            file.paletteRecipe = rendering.paletteRecipe
            file.world = rendering.world
        }
        return file
    }

    /// Whether this file draws with `rendering` untouched, whatever its palette and camera.
    public func uses(rendering: LookFile) -> Bool {
        var applied = withRendering(rendering)
        applied.name = name
        return applied == self
    }

    /// `palette` ramped in its world on every galaxy of `scene`, except the `locked` ones,
    /// which keep the colours they have.
    public func withPalette(
        _ palette: Palette, keeping locked: Set<Int> = [], in scene: SceneConfig,
        references: [TelescopeReference] = TelescopeReference.repository
    ) -> LookFile {
        let drawn = palette.galaxyColours(references: references)
        var file = self
        file.palette = scene.galaxies.indices.map { index in
            if !locked.contains(index), index < drawn.count { return drawn[index] }
            return index < self.palette.count
                ? self.palette[index] : GalaxyColours(colour(ofGalaxy: index, in: scene))
        }
        file.paletteRecipe = palette
        file.world = palette.world
        return file
    }

    /// Every galaxy but the `locked` ones in a ramp of colours around its own colour, or in that
    /// colour alone. The colours themselves stay, so a hand-picked one is kept; the recipe, if
    /// any, records the switch.
    public func withRamps(
        _ on: Bool, keeping locked: Set<Int> = [],
        references: [TelescopeReference] = TelescopeReference.repository
    ) -> LookFile {
        var file = self
        file.palette = palette.enumerated().map { index, entry in
            if locked.contains(index) { return entry }
            return on
                ? .ramped(
                    entry.colour, world: world, family: paletteRecipe?.family,
                    references: references)
                : GalaxyColours(entry.colour)
        }
        file.paletteRecipe = paletteRecipe?.withMulticolour(on)
        return file
    }

    /// Whether some galaxy is drawn in more than one colour.
    public var hasRamps: Bool { palette.contains { $0.ramp != nil } }

    /// This file with `group` taken from `baseline`.
    public func resetting(_ group: Group, to baseline: LookFile) -> LookFile {
        var file = self
        let from = baseline.look
        switch group {
        case .light:
            file.look.brightness = from.brightness
            file.look.stretch = from.stretch
            file.look.saturation = from.saturation
            file.look.galaxyTint = from.galaxyTint
            file.look.dustStrength = from.dustStrength
            file.look.dustWeb = from.dustWeb
            file.look.armPersistence = from.armPersistence
        case .instrument:
            file.look.smoothingScale = from.smoothingScale
            file.look.minimumKernel = from.minimumKernel
            file.look.maximumKernel = from.maximumKernel
            file.look.columnSmoothing = from.columnSmoothing
            file.look.glint = from.glint
            file.look.holeShadow = from.holeShadow
            file.look.bloomIntensity = from.bloomIntensity
            file.look.bloomThreshold = from.bloomThreshold
            file.look.bloomSoftKnee = from.bloomSoftKnee
            file.look.whitePoint = from.whitePoint
            file.look.spikeArms = from.spikeArms
            file.look.spikeLength = from.spikeLength
            file.look.spikeIntensity = from.spikeIntensity
            file.look.spikePattern = from.spikePattern
            file.look.spikeSharpness = from.spikeSharpness
            file.look.starSize = from.starSize
            file.look.skyLevel = from.skyLevel
            file.look.skyColour = from.skyColour
            file.look.noiseLevel = from.noiseLevel
        case .detail:
            file.starCount = baseline.starCount
            file.supersample = baseline.supersample
            file.bloomLevels = baseline.bloomLevels
            file.plain = baseline.plain
            file.armStrength = baseline.armStrength
        case .camera:
            file.camera = baseline.camera
            file.look.fieldOfView = from.fieldOfView
        }
        return file
    }
}

extension LookFile.CameraPlan {
    /// How far the camera turns about the scene over the clip, in radians. Zero holds the
    /// start angle, which is what a plan with no end azimuth does.
    public var rotation: Float {
        get { (azimuthEnd ?? azimuth) - azimuth }
        set { azimuthEnd = abs(newValue) < 1e-4 ? nil : azimuth + newValue }
    }

    /// Whether the plan's angles and lens place the camera: in Fixed and Auto, and for the
    /// director's wide shots, which its close ones turn to face. The immersed director chooses
    /// its own, and only the radius the plan frames reaches it.
    public var placesCamera: Bool { mode != .immersed }

    /// The zoom the editor offers, and the elevation it keeps clear of the pole.
    public static let zoomRange: ClosedRange<Float> = 0.2...5
    public static let steepest: Float = 1.5

    /// Turned as the orbit rig turns under a drag (#177). The end angles follow the start, so
    /// the move over the clip is kept and the view at every playhead turns alike.
    public func turned(azimuth: Float, elevation: Float) -> Self {
        var plan = self
        let climb = (elevationEnd ?? self.elevation) - self.elevation
        let rotation = self.rotation
        plan.elevation = min(max(self.elevation + elevation, -Self.steepest), Self.steepest)
        plan.azimuth = (self.azimuth + azimuth).remainder(dividingBy: 2 * .pi)
        if elevationEnd != nil {
            plan.elevationEnd = min(max(plan.elevation + climb, -Self.steepest), Self.steepest)
        }
        if azimuthEnd != nil { plan.azimuthEnd = plan.azimuth + rotation }
        return plan
    }

    /// Closer by `factor`, as the wheel moves the orbit rig: the zoom, or outside Auto the
    /// radius the plan names, which the zoom does not reach.
    public func zoomed(by factor: Float) -> Self {
        var plan = self
        if radius > 0, mode != .auto {
            plan.radius = max(radius / factor, 0.5)
        } else {
            plan.zoom = min(max(zoom * factor, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        }
        return plan
    }
}

extension LookCatalogue {
    /// The looks of this repository's `looks/`, which the style editor offers as renderings.
    public static let repository = load(
        from: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("looks", isDirectory: true))
}
