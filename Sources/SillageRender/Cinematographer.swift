import Foundation
import SillageCore
import simd

/// A slow sine. Periods are given as primes so a bank of them has no common multiple and the
/// combination does not come round again inside any sitting.
public struct SlowWave: Sendable {
    public var period: Double
    public var phase: Double

    public init(period: Double, phase: Double = 0) {
        self.period = max(period, 1)
        self.phase = phase
    }

    /// Between -1 and 1.
    public func value(at seconds: Double) -> Float {
        Float(sin((seconds / period + phase) * 2 * .pi))
    }

    /// Between 0 and 1.
    public func unit(at seconds: Double) -> Float { (value(at: seconds) + 1) * 0.5 }
}

/// What there is to look at: where the galaxies are, and how big the whole thing is.
public struct Subject: Sendable {
    public var centres: [SIMD3<Float>]
    public var radius: Float

    public init(centres: [SIMD3<Float>] = [.zero], radius: Float = 60) {
        self.centres = centres.isEmpty ? [.zero] : centres
        self.radius = max(radius, 1)
    }
}

/// Decides where the camera is and what the scene looks like, as a continuous function of
/// time.
///
/// Continuity is the whole design. Every quantity either eases between two values with a
/// smoothstep — zero rate of change at each end, so shots join without a kink — or drifts at a
/// constant rate that never stops. Nothing here cuts, and nothing here is allowed to move
/// quickly: a wide shot turns through a full circle in about ten minutes.
public final class Cinematographer {
    public enum Move: CaseIterable, Sendable {
        /// Far off, the whole thing small in the frame.
        case establishing
        /// Closing slowly on one galaxy.
        case approach
        /// Inside the disk's own scale, where structure fills the frame.
        case intimate
        /// Sideways across the scene, the look-at point sweeping with it.
        case travelling
        /// Almost still, held at middle distance.
        case held
        /// Circling a chosen point at a steady rate, the point held in world space rather
        /// than swinging round with the camera.
        case orbit
    }

    private struct Framing {
        /// Multiples of the distance at which the subject fills the frame, so a change of
        /// field of view does not silently change how big the galaxy looks. One fills it;
        /// two is a wide shot; a fifth is inside the disk.
        var distance: Float = 1.6
        var elevation: Float = 0.7
        /// Sideways in the camera's own frame, which is what makes a travelling shot sweep.
        var lateral: Float = 0
        var height: Float = 0
        /// A fixed point in the world, in radii, offset from the subject. Unlike `lateral`
        /// this does not turn with the camera, so circling about it is a real orbit rather
        /// than a target that runs away.
        var offset = SIMD3<Float>.zero
        var subject: Int = -1
        var fieldOfView: Float = 0.6
        /// Radians a second of azimuth. The one thing that never eases to a stop.
        var spin: Float = 0.01
        var look: Int = 0
    }

    private struct Shot {
        var from: Framing
        var to: Framing
        var duration: Double
        var move: Move
    }

    private var generator: SeededGenerator
    private var shot: Shot
    private var sinceShot: Double = 0
    private var azimuth: Float = 0
    private var elapsed: Double = 0
    /// The look-at point is chased rather than snapped to, so a galaxy that swings about on
    /// its orbit does not drag the camera with it.
    private var heldTarget: SIMD3<Float>?
    private var haveTarget = false
    /// The last two kinds of shot, so the next one is neither.
    private var recent: [Move] = []

    /// Eight periods, all prime, from half a minute to four.
    private let waves: [SlowWave] = [
        SlowWave(period: 37, phase: 0.11), SlowWave(period: 53, phase: 0.37),
        SlowWave(period: 71, phase: 0.61), SlowWave(period: 89, phase: 0.05),
        SlowWave(period: 113, phase: 0.83), SlowWave(period: 149, phase: 0.29),
        SlowWave(period: 191, phase: 0.53), SlowWave(period: 233, phase: 0.71),
    ]

    public private(set) var camera = Camera(eye: SIMD3<Float>(0, -200, 60))
    public private(set) var look = RenderLook.observatory
    public private(set) var move: Move = .establishing

    public init(seed: UInt64 = 1) {
        generator = SeededGenerator(seed: seed)
        var opening = Framing()
        opening.distance = 2.0
        opening.look = 3
        shot = Shot(from: opening, to: opening, duration: 30, move: .establishing)
        shot.to = Cinematographer.destination(
            for: .approach, from: opening, generator: &generator)
        shot.duration = 70
        shot.move = .approach
    }

    /// One frame. `seconds` is real elapsed time, so nothing here depends on the frame rate.
    public func advance(seconds: Double, of subject: Subject) {
        let step = min(max(seconds, 0), 0.25)
        elapsed += step
        sinceShot += step
        if sinceShot >= shot.duration {
            sinceShot -= shot.duration
            let previous = shot
            let move = Cinematographer.pick(avoiding: recent, generator: &generator)
            recent = Array((recent + [move]).suffix(2))
            var destination = Cinematographer.destination(
                for: move, from: previous.to, generator: &generator)
            // A shot that ends close keeps whichever galaxy it was already on, and may only
            // pick one if it was on the barycentre. Both halves were learnt from cuts that
            // spent a quarter of a minute on nothing: aiming at the barycentre of a separated
            // pair from close range is aiming at the one place with no galaxy in it, and
            // crossing from one galaxy to the other while closing in puts the aim on the
            // midpoint exactly as the frame narrows. Coming in from the barycentre is safe by
            // comparison — it is half the distance, and the aim and the lens close together.
            if destination.distance < 0.6 {
                destination.subject =
                    previous.to.subject >= 0
                    ? previous.to.subject : Int(generator.next() % 2)
            }
            shot = Shot(
                from: previous.to, to: destination,
                duration: Double(generator.uniform(in: 55...115)),
                move: move)
        }
        self.move = shot.move

        let u = Cinematographer.smoothstep(Float(sinceShot / shot.duration))
        let framing = Cinematographer.mix(shot.from, shot.to, u)
        azimuth += framing.spin * Float(step)

        // Where the look-at point wants to be, blended across a change of subject so the
        // camera swings to the new one rather than jumping to it.
        func centre(_ index: Int) -> SIMD3<Float> {
            guard index >= 0, index < subject.centres.count else {
                return subject.centres.reduce(.zero, +) / Float(subject.centres.count)
            }
            return subject.centres[index]
        }
        // Eased across the shot rather than switched, so the aim drifts from one galaxy to
        // the other over a minute. That is only safe because a subject may not change on a
        // close shot — see `destination` — so the crossing always happens at a distance where
        // the whole scene is in frame anyway.
        let wanted = simd_mix(
            centre(shot.from.subject), centre(shot.to.subject), SIMD3(repeating: u))
        // Stops a galaxy on a fast orbit from dragging the frame along with it.
        let chase = 1 - exp(-Float(step) / 3.0)
        if haveTarget {
            heldTarget = (heldTarget ?? wanted) + (wanted - (heldTarget ?? wanted)) * chase
        } else {
            heldTarget = wanted
            haveTarget = true
        }
        let anchor = heldTarget ?? wanted

        // Slow modulation on top of the shot, so nothing is ever quite still.
        let t = elapsed
        let elevation = framing.elevation + 0.09 * waves[5].value(at: t)
        let fieldOfView = framing.fieldOfView * (1 + 0.04 * waves[7].value(at: t))
        // Where the subject exactly fills the frame. Everything is expressed against this,
        // so widening the lens pulls the camera back rather than shrinking the galaxy.
        let fill = subject.radius / tan(fieldOfView / 2) * 1.05
        let distance =
            max(framing.distance * fill, subject.radius * 0.22)
            * (1 + 0.06 * waves[6].value(at: t))

        let right = SIMD3<Float>(cos(azimuth), sin(azimuth), 0)
        let aside =
            framing.offset * subject.radius + right * (framing.lateral * subject.radius)
            + SIMD3<Float>(0, 0, 1) * (framing.height * subject.radius)
        // How far the aim may sit off the subject and still keep it well inside the frame.
        // The offsets are fractions of the whole scene, and on a widely separated pair that
        // is enough on its own to push the galaxy off the edge: an early cut spent a minute
        // aimed at empty sky with the disk clipped along the top.
        let reach = distance * tan(fieldOfView / 2) * 0.5
        var pushed = aside
        let stray = simd_length(pushed)
        if stray > reach { pushed *= reach / stray }
        let target = anchor + pushed
        let horizontal = cos(elevation) * distance
        let eye =
            target
            + SIMD3<Float>(
                horizontal * sin(azimuth), -horizontal * cos(azimuth), sin(elevation) * distance)
        camera = Camera(eye: eye, target: target, fieldOfView: fieldOfView)

        var blended = RenderLook.mix(
            RenderLook.all[shot.from.look % RenderLook.all.count],
            RenderLook.all[shot.to.look % RenderLook.all.count], u)
        blended.fieldOfView = fieldOfView
        // The oscillator bank. Multiplicative, so a look's own character survives it.
        blended.brightness *= 1 + 0.18 * waves[0].value(at: t)
        blended.bloomIntensity *= 1 + 0.33 * waves[1].value(at: t)
        blended.saturation *= 1 + 0.20 * waves[2].value(at: t)
        blended.stretch *= 1 + 0.22 * waves[3].value(at: t)
        blended.dustStrength *= 1 + 0.30 * waves[4].value(at: t)
        blended.smoothingScale *= 1 + 0.16 * waves[5].value(at: t)
        blended.skyLevel *= 1 + 0.45 * waves[6].value(at: t)
        blended.galaxyTint *= 1 + 0.25 * waves[7].value(at: t)

        // Coming in close fills the frame with disk, and the tone curve that suits a galaxy
        // seen whole turns the inside of one into white paste: measured on a single disk, the
        // mean luminance of the frame runs from 0.10 at a wide shot to 0.89 at a fifth of the
        // framing distance. Trimming the exposure alone barely moves it — the logarithmic
        // stretch is what saturates — so the stretch comes down with it, and the kernels widen
        // because the ceiling on kernel size is what lets particles resolve into grains once
        // the camera is near enough for their spacing to exceed it.
        let closeness = min(framing.distance, 1)
        blended.brightness *= closeness
        blended.stretch *= max(pow(closeness, 1.5), 0.12)
        blended.smoothingScale *= 1 + 0.9 * (1 - closeness)
        blended.maximumKernel *= 1 + 5 * (1 - closeness)
        look = blended
    }

    /// Restarts the choreography for a new scene, keeping the oscillators running so the look
    /// does not snap back to where it began.
    public func beginScene(seed: UInt64) {
        generator = SeededGenerator(seed: seed)
        var opening = Framing()
        opening.distance = Float(generator.uniform(in: 1.7...2.6))
        opening.elevation = Float(generator.uniform(in: 0.5...1.1))
        opening.look = Int(generator.next() % UInt64(RenderLook.all.count))
        opening.spin = Cinematographer.spin(0.006...0.013, &generator)
        shot = Shot(
            from: opening,
            to: Cinematographer.destination(for: .approach, from: opening, generator: &generator),
            duration: Double(generator.uniform(in: 60...100)),
            move: .approach)
        sinceShot = 0
        haveTarget = false
        recent = [.approach]
    }

    static func smoothstep(_ x: Float) -> Float {
        let u = min(max(x, 0), 1)
        return u * u * (3 - 2 * u)
    }

    private static func spin(
        _ range: ClosedRange<Float>, _ generator: inout SeededGenerator
    ) -> Float {
        let magnitude = generator.uniform(in: range)
        return generator.uniform() < 0.5 ? -magnitude : magnitude
    }

    /// Weighted so no kind dominates, and drawn from a bag with the last two kinds taken
    /// out: rejecting a repeat once still gave runs of four approaches in eight minutes,
    /// because a third of the bag was approaches and one retry is a weak filter.
    private static func pick(
        avoiding recent: [Move], generator: inout SeededGenerator
    ) -> Move {
        let bag: [Move] = [
            .establishing, .establishing, .approach, .approach, .intimate, .intimate,
            .travelling, .travelling, .held, .orbit, .orbit, .orbit,
        ]
        let allowed = bag.filter { !recent.contains($0) }
        let pool = allowed.isEmpty ? bag : allowed
        return pool[Int(generator.next() % UInt64(pool.count))]
    }

    private static func destination(
        for move: Move, from previous: Framing, generator: inout SeededGenerator
    ) -> Framing {
        var next = previous
        next.lateral = 0
        next.height = 0
        next.offset = .zero
        next.look = Int(generator.next() % UInt64(RenderLook.all.count))
        switch move {
        case .establishing:
            next.distance = generator.uniform(in: 1.5...2.7)
            next.elevation = generator.uniform(in: 0.45...1.15)
            next.fieldOfView = generator.uniform(in: 0.55...0.74)
            next.spin = spin(0.005...0.012, &generator)
            next.subject = -1
        case .approach:
            next.distance = generator.uniform(in: 0.6...1.05)
            next.elevation = generator.uniform(in: 0.12...0.65)
            next.fieldOfView = generator.uniform(in: 0.5...0.66)
            next.spin = spin(0.006...0.014, &generator)
            next.subject = Int(generator.next() % 2)
        case .intimate:
            next.distance = generator.uniform(in: 0.16...0.36)
            next.elevation = generator.uniform(in: -0.25...0.5)
            next.fieldOfView = generator.uniform(in: 0.42...0.58)
            // Closer in, the same angular rate covers far less ground, so it may be quicker.
            next.spin = spin(0.018...0.042, &generator)
            next.subject = Int(generator.next() % 2)
        case .travelling:
            next.distance = generator.uniform(in: 0.5...0.95)
            next.elevation = generator.uniform(in: -0.1...0.4)
            next.fieldOfView = generator.uniform(in: 0.52...0.7)
            next.spin = spin(0.002...0.006, &generator)
            next.lateral = generator.uniform(in: 0.7...1.6) * (generator.uniform() < 0.5 ? -1 : 1)
            next.height = generator.uniform(in: -0.25...0.25)
            next.subject = Int(generator.next() % 2)
        case .held:
            next.distance = generator.uniform(in: 0.85...1.5)
            next.elevation = generator.uniform(in: 0.2...0.9)
            next.fieldOfView = generator.uniform(in: 0.54...0.68)
            next.spin = spin(0.0015...0.005, &generator)
            next.subject = -1
        case .orbit:
            next.distance = generator.uniform(in: 0.35...0.85)
            next.elevation = generator.uniform(in: -0.15...0.75)
            next.fieldOfView = generator.uniform(in: 0.5...0.66)
            // Steady, and quick enough that a whole turn happens inside a long shot.
            next.spin = spin(0.012...0.026, &generator)
            next.subject = Int(generator.next() % 2)
            // The point circled is somewhere near the galaxy rather than its centre, so the
            // parallax between near and far material does the work.
            next.offset = SIMD3<Float>(
                generator.uniform(in: -0.16...0.16), generator.uniform(in: -0.16...0.16),
                generator.uniform(in: -0.08...0.08))
        }
        return next
    }

    private static func mix(_ a: Framing, _ b: Framing, _ t: Float) -> Framing {
        func f(_ x: Float, _ y: Float) -> Float { x + (y - x) * t }
        var out = a
        out.distance = f(a.distance, b.distance)
        out.elevation = f(a.elevation, b.elevation)
        out.lateral = f(a.lateral, b.lateral)
        out.height = f(a.height, b.height)
        // Easy to forget, and a jump of a fifth of the scene at every shot boundary when it
        // is: the point an orbit circles is a world offset, so it has to ease like the rest.
        out.offset = a.offset + (b.offset - a.offset) * t
        out.fieldOfView = f(a.fieldOfView, b.fieldOfView)
        out.spin = f(a.spin, b.spin)
        return out
    }
}
