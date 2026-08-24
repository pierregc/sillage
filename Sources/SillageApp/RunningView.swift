import SwiftUI

struct RunningView: View {
    @ObservedObject var model: SimulationModel

    var body: some View {
        HStack(spacing: 0) {
            MetalCanvas(model: model)
                .background(.black)
                .frame(minWidth: 640, minHeight: 400)
            Divider()
            ControlPanel(model: model)
        }
    }
}
