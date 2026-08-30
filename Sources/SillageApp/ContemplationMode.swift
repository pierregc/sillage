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
    /// Two speeds, because they are two different things to sit through: one shows a whole
    /// encounter in a minute, the other lets one breathe for five. Everything follows from
    /// the choice — the oscillators, the length of a shot, how fast the camera turns, and how
    /// close together the galaxies start.
    enum Pace: String, Sendable {
        case brisk
        case slow

        var sceneLifetime: Double { self == .brisk ? 62 : 300 }
        var fade: Double { self == .brisk ? 2.5 : 5 }
        /// Divides the oscillator periods and the shot lengths, multiplies the turn rate.
        var tempo: Double { self == .brisk ? 3.2 : 1 }
        var megayearsPerSecond: Double { self == .brisk ? 5.0 : 3.2 }
        /// How much the encounter is pulled together at the start.
        var haste: Float { self == .brisk ? 1 : 0.25 }
        var name: String { self == .brisk ? "Contemplation rapide" : "Contemplation lente" }
    }

    func startContemplation(pace: Pace = .slow) {
        contemplating = true
        contemplationPace = pace
        contemplationMyrPerSecond = pace.megayearsPerSecond
        director.tempo = pace.tempo
        showCanvasWhileRunning = true
        contemplationClock = 0
        sceneAge = 0
        sceneOrdinal = 0
        renderFade = 1
        // Smaller pieces of the force pass. A chunk is an uninterrupted hold on the GPU, and
        // here the picture is the thing that must not wait: measured against a sixty hertz
        // schedule, a million-particle chunk missed one slot in eighteen.
        MetalBarnesHutSolver.forceChunk = 450_000
        // Supersampling costs four times the fill rate and buys least on a display that is
        // already retina. Particles are the better place to spend it.
        if supersample != 1 { supersample = 1 }
        // The smoothing field builds a tree of its own, and three of those a second on top of
        // the solver's own is what froze the picture for half of every second.
        // The smoothing field builds a tree of its own, and three of those a second on top
        // of the solver's own is what saturated every core and froze the picture for half of
        // every second. Densities move slowly; this looks at them every few seconds.
        smoothingInterval = 240
        MetalBarnesHutSolver.leafCapacity = 32
        MetalBarnesHutSolver.maximumTreeDepth = 13
        // One step a pump. Four of them is a burst four times as long, and the length of the
        // burst is the whole of what a viewer feels.
        if stepsPerFrame != 1 { stepsPerFrame = 1 }
        beginContemplationScene(seed: UInt64.random(in: 1...1_000_000))
        stage = .running
        setFullScreen(true)
    }

    func stopContemplation() {
        contemplating = false
        smoothingInterval = 20
        stepsPerFrame = 4
        MetalBarnesHutSolver.leafCapacity = 16
        MetalBarnesHutSolver.maximumTreeDepth = 20
        MetalBarnesHutSolver.forceChunk = 450_000
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
        draft = .contemplation(
            particleCount: contemplationParticles, seed: seed,
            haste: contemplationPace.haste)
        scene = draft
        // One scene in three from inside a galaxy rather than outside it. Regular rather than
        // random, so a sitting always gets one before long.
        let immersed = sceneOrdinal % 3 == 2
        director.beginScene(seed: seed, immersed: immersed)
        sceneOrdinal += 1
        sceneAge = 0
        reframeWhenReady = false
        restart()
    }

    /// Moves on now. Rather than swapping on the spot it winds the clock to where the fade
    /// begins, so leaving by hand goes out exactly the way leaving on time does.
    func skipScene() {
        guard contemplating else { return }
        sceneAge = max(sceneAge, contemplationPace.sceneLifetime - contemplationPace.fade)
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
        let remaining = contemplationPace.sceneLifetime - sceneAge
        if remaining <= 0 {
            // Preparation is asynchronous, so the fade stays down until the new scene is up.
            if !isPreparing {
                contemplationRadius = 0
                beginContemplationScene(seed: UInt64.random(in: 1...1_000_000))
            }
            renderFade = 0
        } else if remaining < contemplationPace.fade {
            renderFade = Float(remaining / contemplationPace.fade)
        } else {
            // Coming back up after a swap, and after the very first scene is ready.
            renderFade = min(renderFade + Float(step / contemplationPace.fade), 1)
        }
        renderer.fade = isPreparing ? 0 : renderFade
    }
}
