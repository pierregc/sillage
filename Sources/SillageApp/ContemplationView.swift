import SillageRender
import SwiftUI

/// The whole window, and nothing else. No panel, no readouts by default: anything on screen
/// that is not the scene is something to read rather than something to look at.
struct ContemplationView: View {
    @ObservedObject var model: SimulationModel
    @State private var showHint = true
    @State private var showReadout = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            MetalCanvas(model: model)
                .ignoresSafeArea()
            if showReadout {
                LFOReadout(model: model)
                    .padding(22)
                    .transition(.opacity)
            }
            if showHint {
                VStack {
                    Spacer()
                    Text(
                        "ZQSD pour voler  ·  espace : scène suivante  ·  I : oscillateurs  ·  échap : revenir"
                    )
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.35))
                    .padding(.bottom, 26)
                }
                .frame(maxWidth: .infinity)
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .background(Color.black)
        .onAppear {
            model.onToggleReadout = {
                withAnimation(.easeInOut(duration: 0.35)) { showReadout.toggle() }
            }
            // Says how to get out, then gets out of the way.
            Task {
                try? await Task.sleep(for: .seconds(8))
                withAnimation(.easeInOut(duration: 2.5)) { showHint = false }
            }
        }
    }
}

/// What the oscillators are doing, live.
///
/// Driven by the view's own clock rather than by the model's publishers: the values change
/// sixty times a second and republishing them would rebuild this view — and everything else
/// observing the model — at frame rate, which is the whole of what makes a picture stutter.
/// Ten times a second is more than enough to watch a drift that takes minutes.
struct LFOReadout: View {
    @ObservedObject var model: SimulationModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            VStack(alignment: .leading, spacing: 5) {
                Text("oscillateurs")
                    .font(.caption2.smallCaps())
                    .foregroundStyle(.white.opacity(0.4))
                ForEach(model.director.readings) { reading in
                    HStack(spacing: 8) {
                        Text(reading.name)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.white.opacity(0.55))
                            .frame(width: 74, alignment: .leading)
                        Swing(fraction: reading.fraction)
                            .frame(width: 96, height: 3)
                        Text(format(reading.value))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.75))
                            .frame(width: 54, alignment: .trailing)
                    }
                }
                Text(caption)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.top, 3)
            }
            .padding(12)
            .background(.black.opacity(0.32), in: RoundedRectangle(cornerRadius: 8))
        }
        .allowsHitTesting(false)
    }

    private var caption: String {
        let camera = model.cameraIsManual ? "à la main" : "\(model.director.move)"
        return "\(camera) · \(model.director.immersed ? "immergé" : "orbital")"
    }

    /// Small values here run to thousandths and large ones to hundreds.
    private func format(_ value: Float) -> String {
        let magnitude = abs(value)
        if magnitude >= 100 { return String(format: "%.0f", value) }
        if magnitude >= 1 { return String(format: "%.2f", value) }
        return String(format: "%.4f", value)
    }
}

/// Where a value sits in the span its oscillator carries it across.
struct Swing: View {
    let fraction: Float

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.14))
                Capsule()
                    .fill(.white.opacity(0.7))
                    .frame(width: 3)
                    .offset(x: (geometry.size.width - 3) * CGFloat(fraction))
            }
        }
    }
}
