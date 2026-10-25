import Foundation

/// Looks one step away from a base, one knob at a time, so a row of the grid reads as "this,
/// but brighter".
public enum LookVariants {
    /// The base first, then each variant named `<base>-<change>`. A change that leaves the
    /// look as it was, like taking the spikes off a look that has none, is left out.
    public static func around(_ base: LookFile) -> [LookFile] {
        func variant(_ change: String, _ apply: (inout LookFile) -> Void) -> LookFile {
            var file = base
            file.name = "\(base.name)-\(change)"
            apply(&file)
            return file
        }
        let variants = [
            variant("bright") { $0.look.brightness *= 1.5 },
            variant("dim") { $0.look.brightness *= 0.65 },
            variant("vivid") {
                $0.look.saturation *= 1.35
                $0.look.galaxyTint = min($0.look.galaxyTint + 0.3, 1)
            },
            variant("muted") {
                $0.look.saturation *= 0.6
                $0.look.galaxyTint *= 0.5
            },
            variant("spikes") {
                $0.look.spikeArms = $0.look.spikeArms > 0 ? $0.look.spikeArms : 6
                $0.look.spikeIntensity = max($0.look.spikeIntensity * 1.8, 0.5)
                $0.look.spikeLength = max($0.look.spikeLength * 1.4, 90)
            },
            variant("no-spikes") { $0.look.spikeIntensity = 0 },
            variant("bloom") {
                $0.look.bloomIntensity = max($0.look.bloomIntensity * 2.2, 0.4)
                $0.look.bloomThreshold *= 0.7
            },
            variant("no-bloom") { $0.look.bloomIntensity = 0 },
            variant("high") { tilt(&$0.camera, by: 0.35) },
            variant("low") { tilt(&$0.camera, by: -0.6) },
            variant("close") { $0.camera.zoom *= 1.5 },
            variant("wide") { $0.camera.zoom *= 0.7 },
        ]
        return [base] + variants.filter { !$0.differsOnlyInName(from: base) }
    }

    /// Raises or lowers the whole move, kept between grazing and straight down.
    private static func tilt(_ camera: inout LookFile.CameraPlan, by angle: Float) {
        let clamp = { (value: Float) in min(max(value + angle, 0.15), 1.5) }
        camera.elevation = clamp(camera.elevation)
        camera.elevationEnd = camera.elevationEnd.map(clamp)
    }
}

extension LookFile {
    func differsOnlyInName(from other: LookFile) -> Bool {
        var renamed = self
        renamed.name = other.name
        return renamed == other
    }
}
