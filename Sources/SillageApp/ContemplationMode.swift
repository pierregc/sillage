import AppKit
import Foundation
import MetalKit
import SillageCore
import SillageRender
import simd

/// Full screen, no panel, nobody at the keyboard. A scene is generated, framed and lit by
/// `Cinematographer`, watched for a while, and replaced by another one.
///
/// Level 1 throughout, and that is a decision rather than a shortcut: contemplation has to
/// hold its frame rate for hours, and the tree solver gets slower as a merger concentrates.
/// Tracers in rigid potentials cost one cheap kernel a step and leave the GPU to the picture.
/// Nothing is captured either — an hour of takes would fill the memory budget many times over
/// to record something nobody is going to replay.
extension SimulationModel {
    /// How long a scene is watched before the next one, and how long the fade between them
    /// lasts. Long: the shots inside a scene run to two minutes, and cutting away before a
    /// few of them have played would defeat the point.
    /// Settable so the headless check can drive several changes of scene in a short run:
    /// the swap is the riskiest part of this, since it prepares a scene asynchronously while
    /// the screen is fading.
    static var sceneLifetime: Double = 690
    static var sceneFade: Double = 5

    func startContemplation() {
        contemplating = true
        showCanvasWhileRunning = true
        contemplationClock = 0
        sceneAge = 0
        renderFade = 1
        // Supersampling costs four times the fill rate and buys least on a display that is
        // already retina. Particles are the better place to spend it.
        if supersample != 1 { supersample = 1 }
        beginContemplationScene(seed: UInt64.random(in: 1...1_000_000))
        stage = .running
        setFullScreen(true)
    }

    func stopContemplation() {
        contemplating = false
        renderFade = 1
        renderer?.fade = 1
        setFullScreen(false)
        stage = .setup
    }

    /// No-op with no window, which is the case in every headless check.
    private func setFullScreen(_ wanted: Bool) {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first else { return }
        let already = window.styleMask.contains(.fullScreen)
        if already != wanted { window.toggleFullScreen(nil) }
    }

    func beginContemplationScene(seed: UInt64) {
        draft = .contemplation(particleCount: contemplationParticles, seed: seed)
        scene = draft
        director.beginScene(seed: seed)
        sceneAge = 0
        reframeWhenReady = false
        restart()
    }

    /// One frame of contemplation: move the camera, relight the scene, and hand over to the
    /// next one when this has been watched long enough.
    func advanceContemplation(seconds: Double) {
        guard contemplating, let renderer else { return }
        let step = min(max(seconds, 0), 0.25)
        contemplationClock += step
        sceneAge += step

        // The subject follows the galaxies, so a pair that swings apart stays in frame.
        let centres = solver?.centers ?? scene.galaxies.map(\.position)
        if contemplationRadius <= 0 {
            contemplationRadius = max(seeded.framingRadius() ?? 40, 8)
        }
        director.advance(
            seconds: step, of: Subject(centres: centres, radius: contemplationRadius))
        renderer.apply(director.look)

        // Fade out over the last seconds of a scene, swap while the screen is black, fade in.
        let remaining = Self.sceneLifetime - sceneAge
        if remaining <= 0 {
            // Preparation is asynchronous, so the fade stays down until the new scene is up.
            if !isPreparing {
                contemplationRadius = 0
                beginContemplationScene(seed: UInt64.random(in: 1...1_000_000))
            }
            renderFade = 0
        } else if remaining < Self.sceneFade {
            renderFade = Float(remaining / Self.sceneFade)
        } else {
            // Coming back up after a swap, and after the very first scene is ready.
            renderFade = min(renderFade + Float(step / Self.sceneFade), 1)
        }
        renderer.fade = isPreparing ? 0 : renderFade
    }
}
