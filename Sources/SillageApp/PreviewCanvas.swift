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
        // Drawn only when something changes. The preview is a still: it never steps, and
        // redrawing three hundred thousand particles sixty times a second to show the same
        // picture was taking most of the GPU while the user moved a slider.
        view.preferredFramesPerSecond = 60
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.delegate = context.coordinator
        view.onDrag = { [weak view] dx, dy in
            model.previewCamera.orbit(
                deltaAzimuth: Float(-dx) * 0.008, deltaElevation: Float(dy) * 0.008)
            view?.needsDisplay = true
        }
        view.onScroll = { [weak view] dy in
            model.previewCamera.zoom(factor: Float(1 - dy * 0.01))
            view?.needsDisplay = true
        }
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
