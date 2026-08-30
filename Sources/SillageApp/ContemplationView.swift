import SwiftUI

/// The whole window, and nothing else. No panel, no readouts: anything on screen that is not
/// the scene is something to read rather than something to look at.
struct ContemplationView: View {
    @ObservedObject var model: SimulationModel
    @State private var showHint = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            MetalCanvas(model: model)
                .ignoresSafeArea()
            if showHint {
                VStack {
                    Spacer()
                    Text("ZQSD pour voler  ·  espace : scène suivante  ·  échap : revenir")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.35))
                        .padding(.bottom, 26)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .background(Color.black)
        .onAppear {
            // Says how to get out, then gets out of the way.
            Task {
                try? await Task.sleep(for: .seconds(6))
                withAnimation(.easeInOut(duration: 2.5)) { showHint = false }
            }
        }
    }
}
