import SwiftUI

/// A labelled slider. `onCommit` fires when the drag ends, so structural changes can rebuild
/// the simulation once instead of on every intermediate value.
struct ParameterSlider: View {
    let title: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    var format = "%.2f"
    var onCommit: (() -> Void)?
    @Environment(\.offscreen) private var offscreen

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(String(format: format, value))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Palette.secondary)
            }
            if offscreen {
                OffscreenTrack(fraction: (value - range.lowerBound) / (range.upperBound - range.lowerBound))
            } else {
                Slider(value: $value, in: range) { editing in
                    if !editing { onCommit?() }
                }
            }
        }
    }
}

/// A slider's track as `ImageRenderer` can draw it, which shows a real slider as a blank.
struct OffscreenTrack: View {
    let fraction: Float

    var body: some View {
        GeometryReader { space in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(white: 0.28)).frame(height: 4)
                Capsule().fill(Color.accentColor)
                    .frame(width: space.size.width * CGFloat(min(max(fraction, 0), 1)), height: 4)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 18)
    }
}

/// A switch, drawn as a box offscreen.
struct CheckToggle: View {
    let title: String
    @Binding var isOn: Bool
    @Environment(\.offscreen) private var offscreen

    var body: some View {
        if offscreen {
            HStack(spacing: 6) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isOn ? Color.accentColor : Palette.secondary)
                Text(title)
            }
            .font(.caption)
        } else {
            Toggle(title, isOn: $isOn).font(.caption)
        }
    }
}

struct VectorEditor: View {
    let title: String
    @Binding var value: SIMD3<Float>
    let range: ClosedRange<Float>
    var onCommit: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption)
            ParameterSlider(
                title: "x", value: Binding(get: { value.x }, set: { value.x = $0 }),
                range: range, onCommit: onCommit)
            ParameterSlider(
                title: "y", value: Binding(get: { value.y }, set: { value.y = $0 }),
                range: range, onCommit: onCommit)
            ParameterSlider(
                title: "z", value: Binding(get: { value.z }, set: { value.z = $0 }),
                range: range, onCommit: onCommit)
        }
    }
}
