import SwiftUI

struct RunningView: View {
    @ObservedObject var model: SimulationModel

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                // Left out of the hierarchy entirely rather than hidden: an MTKView that is
                // not there draws nothing and holds no drawables.
                if model.showCanvasWhileRunning || model.mode == .playback {
                    MetalCanvas(model: model)
                        .background(.black)
                } else {
                    ComputingView(model: model)
                }
                // Sampling several million particles takes seconds. Saying so beats a black
                // rectangle that might equally be a crash.
                if model.isPreparing {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Préparation de la scène…")
                            .font(.callout)
                            .foregroundStyle(Palette.secondary)
                    }
                }
            }
            .frame(minWidth: 640, minHeight: 400)
            Divider()
            ControlPanel(model: model)
        }
    }
}

/// What there is to see when the picture has been switched off: how far the run has got, and
/// what it will do when it gets there.
struct ComputingView: View {
    @ObservedObject var model: SimulationModel

    var body: some View {
        VStack(spacing: 14) {
            Text("Calcul en cours, affichage coupé")
                .font(.title3)
            Text(String(format: "%.0f Myr", model.elapsedMyr))
                .font(.system(size: 52, weight: .light).monospacedDigit())
            if model.stopAtMyr > 0 {
                ProgressView(value: min(model.elapsedMyr / model.stopAtMyr, 1))
                    .frame(width: 320)
                Text(String(format: "fin à %.0f Myr", model.stopAtMyr))
                    .font(.caption)
                    .foregroundStyle(Palette.secondary)
            }
            Text(
                String(
                    format: "%.1f Myr par seconde · %d images · %.0f Mo",
                    model.megayearsPerSecond, model.capturedFrames, model.capturedMegabytes)
            )
            .font(.callout.monospacedDigit())
            .foregroundStyle(Palette.secondary)

            if let destination = model.finishDestination {
                Text("sera écrite dans \(destination.lastPathComponent)")
                    .font(.caption)
                    .foregroundStyle(Palette.secondary)
            }
            if model.quitWhenFinished {
                Text("l'application se fermera ensuite")
                    .font(.caption)
                    .foregroundStyle(Palette.secondary)
            }

            Button("Réafficher") { model.showCanvasWhileRunning = true }
                .buttonStyle(.bordered)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.canvas)
    }
}
