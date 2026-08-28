import SwiftUI

struct RunningView: View {
    @ObservedObject var model: SimulationModel

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                MetalCanvas(model: model)
                    .background(.black)
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
