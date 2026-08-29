import MetalKit
import SwiftUI

/// MTKView subclass that forwards drag and scroll, which SwiftUI gestures do not cover
/// well enough for an orbit camera.
final class CanvasView: MTKView {
    var onDrag: ((CGFloat, CGFloat) -> Void)?
    var onScroll: ((CGFloat) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(event.deltaX, event.deltaY)
    }

    override func scrollWheel(with event: NSEvent) {
        onScroll?(event.scrollingDeltaY)
    }
}

struct MetalCanvas: NSViewRepresentable {
    @ObservedObject var model: SimulationModel

    func makeNSView(context: Context) -> CanvasView {
        let view = CanvasView(frame: .zero, device: model.device)
        // The composite kernel writes straight into the drawable, which needs write usage.
        view.framebufferOnly = false
        view.colorPixelFormat = .bgra8Unorm
        // Sixty rather than a hundred and twenty: the solver is on the same GPU, and nothing
        // in a galaxy moves fast enough to need more.
        view.preferredFramesPerSecond = 60
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.delegate = context.coordinator
        model.attach(canvas: view)
        view.onDrag = { dx, dy in
            model.camera.orbit(
                deltaAzimuth: Float(-dx) * 0.008, deltaElevation: Float(dy) * 0.008)
        }
        view.onScroll = { dy in
            model.camera.zoom(factor: Float(1 - dy * 0.01))
        }
        return view
    }

    func updateNSView(_ view: CanvasView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        let model: SimulationModel

        init(model: SimulationModel) { self.model = model }

        nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            MainActor.assumeIsolated { self.model.resize(to: size) }
        }

        nonisolated func draw(in view: MTKView) {
            MainActor.assumeIsolated { self.model.draw(in: view) }
        }
    }
}
