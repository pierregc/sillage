import Foundation
import simd

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
            variant("no-gas") { $0.look.dustStrength = 0 },
            variant("no-stars") { $0.starCount = 0 },
            variant("no-sky") { $0.look.skyLevel = 0 },
            variant("hue-60") { $0.palette = $0.palette.map { rotateHue($0, by: 60) } },
            variant("hue-120") { $0.palette = $0.palette.map { rotateHue($0, by: 120) } },
            variant("hue-180") { $0.palette = $0.palette.map { rotateHue($0, by: 180) } },
            variant("hue-240") { $0.palette = $0.palette.map { rotateHue($0, by: 240) } },
            variant("high") { tilt(&$0.camera, by: 0.35) },
            variant("low") { tilt(&$0.camera, by: -0.6) },
            variant("close") { $0.camera.zoom *= 1.5 },
            variant("wide") { $0.camera.zoom *= 0.7 },
        ]
        return [base] + variants.filter { !$0.differsOnlyInName(from: base) }
    }

    /// The colour turned `degrees` around the hue wheel, brightness and saturation kept.
    static func rotateHue(_ colour: SIMD3<Float>, by degrees: Float) -> SIMD3<Float> {
        let high = max(colour.x, colour.y, colour.z)
        let low = min(colour.x, colour.y, colour.z)
        let chroma = high - low
        guard chroma > 1e-6 else { return colour }
        var hue: Float
        if high == colour.x {
            hue = (colour.y - colour.z) / chroma
        } else if high == colour.y {
            hue = 2 + (colour.z - colour.x) / chroma
        } else {
            hue = 4 + (colour.x - colour.y) / chroma
        }
        hue = (hue * 60 + degrees).truncatingRemainder(dividingBy: 360)
        if hue < 0 { hue += 360 }
        let sector = hue / 60
        let second = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let (r, g, b): (Float, Float, Float)
        switch Int(sector) {
        case 0: (r, g, b) = (chroma, second, 0)
        case 1: (r, g, b) = (second, chroma, 0)
        case 2: (r, g, b) = (0, chroma, second)
        case 3: (r, g, b) = (0, second, chroma)
        case 4: (r, g, b) = (second, 0, chroma)
        default: (r, g, b) = (chroma, 0, second)
        }
        return SIMD3(r, g, b) + SIMD3(repeating: low)
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
