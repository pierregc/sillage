import MetalKit
import SwiftUI

/// The setup screen's viewport. Shows the draft scene exactly as configured, never stepped,
/// so a parameter can be judged while it is being set.
struct PreviewCanvas: NSViewRepresentable {
    @ObservedObject var model: SimulationModel

    func makeNSView(context: Context) -> CanvasView {
        let view = CanvasView(frame: .zero, device: model.device)
        view.framebufferOnly = false
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 60
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.delegate = context.coordinator
        view.onDrag = { dx, dy in
            model.previewCamera.orbit(
                deltaAzimuth: Float(-dx) * 0.008, deltaElevation: Float(dy) * 0.008)
        }
        view.onScroll = { dy in model.previewCamera.zoom(factor: Float(1 - dy * 0.01)) }
        model.attachPreview(canvas: view)
        return view
    }

    func updateNSView(_ view: CanvasView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        let model: SimulationModel

        init(model: SimulationModel) { self.model = model }

        nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            MainActor.assumeIsolated { self.model.resizePreview(to: size) }
        }

        nonisolated func draw(in view: MTKView) {
            MainActor.assumeIsolated { self.model.drawPreview(in: view) }
        }
    }
}
