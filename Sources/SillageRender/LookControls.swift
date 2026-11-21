import Foundation

/// A control of the render settings panels, declared once for the workshop's run panel and the
/// style editor's fine settings (#226), and the reset of a section is made from the controls it
/// lists, so a field cannot be shown without being reset.
public struct LookControl: Identifiable {
    public enum Kind {
        case slider(WritableKeyPath<RenderLook, Float>, range: ClosedRange<Float>, format: String)
        case count(WritableKeyPath<RenderLook, Int>, range: ClosedRange<Int>)
        /// Webb's spike pattern over the even one.
        case webbSpikes
    }

    public let title: String
    public let kind: Kind
    /// A line of explanation under the control.
    public let note: String?
    public var id: String { title }

    static func slider(
        _ title: String, _ path: WritableKeyPath<RenderLook, Float>, _ range: ClosedRange<Float>,
        format: String = "%.2f", note: String? = nil
    ) -> LookControl {
        LookControl(title: title, kind: .slider(path, range: range, format: format), note: note)
    }

    /// Puts this control's field of `baseline` into `look`.
    func reset(_ look: inout RenderLook, to baseline: RenderLook) {
        switch kind {
        case .slider(let path, _, _): look[keyPath: path] = baseline[keyPath: path]
        case .count(let path, _): look[keyPath: path] = baseline[keyPath: path]
        case .webbSpikes: look.spikePattern = baseline.spikePattern
        }
    }

    /// A value of this control's field different from `look`'s, for tests.
    func moved(_ look: RenderLook) -> RenderLook {
        var moved = look
        switch kind {
        case .slider(let path, let range, _):
            let value = look[keyPath: path]
            moved[keyPath: path] =
                value - range.lowerBound > range.upperBound - value
                ? range.lowerBound : range.upperBound
        case .count(let path, let range):
            let value = look[keyPath: path]
            moved[keyPath: path] = value == range.upperBound ? range.lowerBound : range.upperBound
        case .webbSpikes:
            moved.spikePattern = look.spikePattern == .webb ? .even : .webb
        }
        return moved
    }
}

extension LookFile.Group {
    /// The controls of the section, in the order both panels show them.
    public var controls: [LookControl] {
        switch self {
        case .light:
            return [
                .slider("Brightness", \.brightness, 0.02...2.0),
                .slider("Logarithmic stretch", \.stretch, 0...60, format: "%.0f"),
                .slider("Saturation", \.saturation, 0...3),
                .slider(
                    "Tint per galaxy", \.galaxyTint, 0...1,
                    note:
                        "0: each star has its population's colour. 1: each galaxy keeps its own, which makes the stars it loses readable."
                ),
                .slider("Dust opacity", \.dustStrength, 0...1.2, format: "%.3f"),
                .slider("Dust web", \.dustWeb, 0...1),
                .slider(
                    "Painted arm strength", \.armPersistence, 0...2,
                    note: "Above 1 the arms are plain invention, which the softest styles own up to."
                ),
            ]
        case .instrument:
            return [
                .slider("Star smoothing", \.smoothingScale, 0.4...5.0),
                .slider("Minimum kernel (px)", \.minimumKernel, 0.5...6),
                .slider("Maximum kernel (px)", \.maximumKernel, 4...160, format: "%.0f"),
                .slider(
                    "Stars under the kernel (projection)", \.columnSmoothing, 0...120,
                    format: "%.0f"),
                .slider("Compact sources", \.glint, 0...1),
                .slider("Young star width", \.youngWidth, 0.25...4),
                .slider("Knot width", \.knotWidth, 0.25...4),
                .slider("Old disk width", \.oldWidth, 0.25...4),
                .slider("Bulge width", \.bulgeWidth, 0.25...4),
                .slider("Glow", \.bloomIntensity, 0...2),
                .slider("Glow threshold", \.bloomThreshold, 0.05...1.5),
                .slider("Threshold softness", \.bloomSoftKnee, 0...1),
                .slider("Diffraction spikes", \.spikeIntensity, 0...1.5),
                LookControl(title: "Spike arms", kind: .count(\.spikeArms, range: 0...8), note: nil),
                .slider("Spike length", \.spikeLength, 0...200, format: "%.0f"),
                .slider("Spike sharpness", \.spikeSharpness, 0...1),
                LookControl(title: "Webb spikes", kind: .webbSpikes, note: nil),
                .slider("Field star size", \.starSize, 0.2...4),
                .slider("White point", \.whitePoint, 1...20, format: "%.1f"),
                .slider("Sky background", \.skyLevel, 0...0.006, format: "%.4f"),
                .slider(
                    "Twinkle (sensor noise)", \.noiseLevel, 0...0.004, format: "%.4f",
                    note:
                        "At zero, two frames of a paused scene are identical to the bit: this noise is what makes the whole background flicker. For stars that twinkle as they move, see the minimum kernel."
                ),
            ]
        case .detail, .camera:
            return []
        }
    }
}

extension RenderLook {
    /// This look with the fields of the light or instrument section taken from `baseline`, and
    /// anything else as it is.
    public func resetting(_ group: LookFile.Group, to baseline: RenderLook) -> RenderLook {
        var look = self
        for control in group.controls { control.reset(&look, to: baseline) }
        if group == .instrument {
            look.skyColour = baseline.skyColour
            look.holeShadow = baseline.holeShadow
        }
        return look
    }
}
