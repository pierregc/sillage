import SwiftUI

/// A labelled slider. `onCommit` fires when the drag ends, so structural changes can rebuild
/// the simulation once instead of on every intermediate value.
struct ParameterSlider: View {
    let title: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    var format = "%.2f"
    var onCommit: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(String(format: format, value))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range) { editing in
                if !editing { onCommit?() }
            }
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
