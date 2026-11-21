import SillageRender
import SwiftUI

/// A labelled slider. `onCommit` fires when the drag ends, so structural changes can rebuild
/// the simulation once instead of on every intermediate value.
struct ParameterSlider: View {
    let title: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    var format = "%.2f"
    var onCommit: (() -> Void)?
    /// What the value says, when the number alone would not.
    var reading: ((Float) -> String)?
    @Environment(\.offscreen) private var offscreen

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(reading?(value) ?? String(format: format, value))
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

/// A segmented picker, drawn as a row of labels offscreen.
struct SegmentedChoice<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(title: String, value: Value)]
    @Environment(\.offscreen) private var offscreen

    var body: some View {
        if offscreen {
            HStack(spacing: 2) {
                ForEach(options.indices, id: \.self) { index in
                    Text(options[index].title)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(options[index].value == selection ? Color(white: 0.42) : Color.clear))
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.2)))
        } else {
            Picker("", selection: $selection) {
                ForEach(options.indices, id: \.self) { index in
                    Text(options[index].title).tag(options[index].value)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }
}

/// A pop-up menu, drawn as its current choice offscreen.
struct MenuChoice<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(title: String, value: Value)]
    @Environment(\.offscreen) private var offscreen

    var body: some View {
        if offscreen {
            HStack(spacing: 6) {
                Text(options.first { $0.value == selection }?.title ?? "")
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color(white: 0.24)))
        } else {
            Picker("", selection: $selection) {
                ForEach(options.indices, id: \.self) { index in
                    Text(options[index].title).tag(options[index].value)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
    }
}

/// A text field's text in a box, as `ImageRenderer` can draw it.
struct OffscreenField: View {
    let text: String

    var body: some View {
        Text(text)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(white: 0.35)))
    }
}

/// A stepper, drawn as its two halves offscreen.
struct CountStepper: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    @Environment(\.offscreen) private var offscreen

    var body: some View {
        if offscreen {
            HStack(spacing: 8) {
                Text(title)
                Text("−   +")
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.24)))
            }
            .font(.caption)
        } else {
            Stepper(title, value: $value, in: range).font(.caption)
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

/// The controls of one section of a look, from the table both render settings panels share
/// (#226): a slider for each field, a count for the arms, a box for the pattern.
struct LookControlList: View {
    let group: LookFile.Group
    @Binding var look: RenderLook

    var body: some View {
        ForEach(group.controls) { control in
            row(control)
            if let note = control.note {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private func row(_ control: LookControl) -> some View {
        switch control.kind {
        case .slider(let path, let range, let format):
            ParameterSlider(
                title: control.title,
                value: Binding(get: { look[keyPath: path] }, set: { look[keyPath: path] = $0 }),
                range: range, format: format)
        case .count(let path, let range):
            ParameterSlider(
                title: control.title,
                value: Binding(
                    get: { Float(look[keyPath: path]) },
                    set: { look[keyPath: path] = Int($0.rounded()) }),
                range: Float(range.lowerBound)...Float(range.upperBound), format: "%.0f")
        case .webbSpikes:
            CheckToggle(
                title: control.title,
                isOn: Binding(
                    get: { look.spikePattern == .webb },
                    set: { look.spikePattern = $0 ? .webb : .even }))
        }
    }
}
