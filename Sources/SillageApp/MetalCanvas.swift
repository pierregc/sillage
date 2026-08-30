import MetalKit
import SwiftUI

/// MTKView subclass that forwards drag, scroll and the keyboard, none of which SwiftUI
/// gestures cover well enough for a camera.
///
/// Keys are held rather than handled: `keyDown` only records that a key is down, and the
/// frame reads the set. Acting on the events themselves would move the camera at the key
/// repeat rate, which arrives in irregular bursts and looks like judder however smoothly the
/// scene is drawn.
final class CanvasView: MTKView {
    var onDrag: ((CGFloat, CGFloat) -> Void)?
    var onScroll: ((CGFloat) -> Void)?
    var onToggleFlight: (() -> Void)?
    var onEscape: (() -> Void)?
    var onSpace: (() -> Void)?

    private(set) var held: Set<UInt16> = []
    private(set) var modifiers: NSEvent.ModifierFlags = []

    enum Key {
        static let w: UInt16 = 13
        static let a: UInt16 = 0
        static let s: UInt16 = 1
        static let d: UInt16 = 2
        static let q: UInt16 = 12
        static let e: UInt16 = 14
        static let c: UInt16 = 8
        static let f: UInt16 = 3
        static let space: UInt16 = 49
        static let escape: UInt16 = 53
        /// Everything that moves the camera, for deciding when a viewer has taken hold.
        /// Space is left out: in contemplation it means the next scene, and taking the
        /// camera because somebody asked to move on would be the opposite of what they meant.
        static let movement: Set<UInt16> = [w, a, s, d, q, e, c, left, right, up, down]
        static let left: UInt16 = 123
        static let right: UInt16 = 124
        static let down: UInt16 = 125
        static let up: UInt16 = 126
    }

    override var acceptsFirstResponder: Bool { true }

    /// Only the running canvas takes the keyboard on sight. The setup preview is the same
    /// class, and grabbing focus there would pull it out of whatever field is being typed in.
    var grabsKeyboard = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if grabsKeyboard { window?.makeFirstResponder(self) }
    }

    override func mouseDown(with event: NSEvent) {
        // A slider in the panel takes the focus away, and the keys go quiet until the canvas
        // is clicked again. Taking it back here is what makes that recoverable.
        window?.makeFirstResponder(self)
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(event.deltaX, event.deltaY)
    }

    override func scrollWheel(with event: NSEvent) {
        onScroll?(event.scrollingDeltaY)
    }

    override func keyDown(with event: NSEvent) {
        // Not super: an unhandled key press beeps.
        if !event.isARepeat, event.keyCode == Key.f { onToggleFlight?() }
        if event.keyCode == Key.escape { onEscape?() }
        if !event.isARepeat, event.keyCode == Key.space { onSpace?() }
        held.insert(event.keyCode)
    }

    override func keyUp(with event: NSEvent) {
        held.remove(event.keyCode)
    }

    override func flagsChanged(with event: NSEvent) {
        modifiers = event.modifierFlags
    }

    /// Holds a key without an event. The headless checks are the only way to verify this
    /// application on this machine, and there is no synthesising a real key press into a view
    /// without a window server session.
    func hold(_ key: UInt16, _ down: Bool) {
        if down { held.insert(key) } else { held.remove(key) }
    }

    /// Anything held when the window goes away would otherwise stay held forever.
    override func resignFirstResponder() -> Bool {
        held.removeAll()
        return super.resignFirstResponder()
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
        view.grabsKeyboard = true
        view.delegate = context.coordinator
        model.attach(canvas: view)
        view.onDrag = { dx, dy in
            model.takeCamera()
            if model.isFlying {
                model.flight.look(deltaYaw: Float(dx) * 0.005, deltaPitch: Float(-dy) * 0.005)
            } else {
                model.camera.orbit(
                    deltaAzimuth: Float(-dx) * 0.008, deltaElevation: Float(dy) * 0.008)
            }
        }
        view.onScroll = { dy in
            model.takeCamera()
            // In flight the wheel is the throttle: there is no distance to a target to change.
            if model.isFlying {
                model.flight.changeSpeed(factor: Float(1 - dy * 0.02))
            } else {
                model.camera.zoom(factor: Float(1 - dy * 0.01))
            }
        }
        view.onToggleFlight = { model.toggleFlight() }
        view.onEscape = { if model.contemplating { model.stopContemplation() } }
        // Space means "up" while flying and "the next one" while contemplating, which never
        // overlap: contemplation has no flying in it.
        view.onSpace = { if model.contemplating { model.skipScene() } }
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
