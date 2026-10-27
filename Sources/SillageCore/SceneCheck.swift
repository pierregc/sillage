import Foundation
import simd

/// Whether a scene is worth simulating, judged from its galaxy centres alone before a single
/// particle is drawn. The centres run through the same model the encounters were placed with,
/// so the whole check costs a few milliseconds against minutes for the scene it can spare.
public struct SceneCheck: Sendable, Equatable {
    public struct Limits: Sendable, Equatable {
        /// Toomre Q a disk may have at any radius that matters. Below the floor it fragments
        /// within an orbit; above the ceiling it is too hot to raise arms.
        public var toomre: ClosedRange<Float> = 1.0...3.0
        /// Two galaxies overlap at the start when their centres are closer than this share of
        /// the sum of the radii holding nine tenths of their disks.
        public var overlap: Float = 0.5
        /// The frame needed to hold every galaxy may grow to this many times the one the clip
        /// opens on, which is the widest shot the director takes, or a galaxy leaves it.
        public var field: Float = 4

        public init() {}
    }

    public enum Reason: Sendable, Equatable, CustomStringConvertible {
        /// Nothing in the window comes closer than the disks' combined radii.
        case noApproach(closest: Float, needed: Float)
        case unstableDisk(galaxy: Int, toomre: Float)
        case overlapAtStart(first: Int, second: Int, separation: Float, limit: Float)
        case leavesFrame(radius: Float, limit: Float)

        public var description: String {
            switch self {
            case .noApproach(let closest, let needed):
                String(format: "no approach: closest %.1f kpc, needs under %.1f", closest, needed)
            case .unstableDisk(let galaxy, let toomre):
                String(format: "disk %d unstable: Toomre Q %.2f", galaxy, toomre)
            case .overlapAtStart(let first, let second, let separation, let limit):
                String(
                    format: "galaxies %d and %d overlap at the start: %.1f kpc apart, limit %.1f",
                    first, second, separation, limit)
            case .leavesFrame(let radius, let limit):
                String(format: "leaves the frame: needs %.0f kpc, limit %.0f", radius, limit)
            }
        }
    }

    /// Closest approach of the nearest pair within the window, with the time it happens.
    /// `nil` for a scene of one galaxy, which has no encounter to find.
    public var closestApproach: (distance: Float, time: Float)?
    /// Lowest and highest Toomre Q over the rotating disks.
    public var toomre: ClosedRange<Float>?
    /// Smallest separation at the start over the limit it is held to; below one is an overlap.
    public var startClearance: Float?
    /// The widest frame the window needs over the one it opens on.
    public var fieldRatio: Float
    public var reasons: [Reason]

    public var accepted: Bool { reasons.isEmpty }

    public static func == (lhs: SceneCheck, rhs: SceneCheck) -> Bool {
        lhs.reasons == rhs.reasons && lhs.fieldRatio == rhs.fieldRatio
    }

    /// What a galaxy's disk reaches to, in kpc.
    static func reach(_ galaxy: GalaxyConfig) -> Float {
        max(galaxy.diskScaleLength * galaxy.diskTruncation, 0.1)
    }

    /// The radius holding nine tenths of an exponential disk's light: where it visibly ends.
    static func brightReach(_ galaxy: GalaxyConfig) -> Float {
        max(galaxy.diskScaleLength * min(galaxy.diskTruncation, 3.9), 0.1)
    }

    /// Runs the centres of `scene` forward and judges them over `window`, in Myr from the
    /// start of the run: the stretch a clip actually shows.
    public static func evaluate(
        _ scene: SceneConfig, window: ClosedRange<Float>, limits: Limits = Limits()
    ) -> SceneCheck {
        var reasons: [Reason] = []
        let count = scene.galaxies.count

        // Disks first: it needs no simulation.
        var lowest = Float.infinity
        var highest: Float = 0
        for (index, galaxy) in scene.galaxies.enumerated() where galaxy.kind.isRotating {
            let equilibrium = DiskEquilibrium(
                config: galaxy, selfGravitating: scene.solver.isSelfGravitating)
            var low = Float.infinity
            var high: Float = 0
            // From the bulge's edge to where the disk fades, which is where a disk shows.
            let inner = galaxy.diskScaleLength * 0.4
            let outer = max(min(galaxy.diskTruncation, 3.5) * galaxy.diskScaleLength, inner)
            for step in 0...8 {
                let radius = inner + (outer - inner) * Float(step) / 8
                let q = equilibrium.toomreQ(
                    atRadius: radius, radialDispersion: equilibrium.radialDispersion(atRadius: radius))
                low = min(low, q)
                high = max(high, q)
            }
            lowest = min(lowest, low)
            highest = max(highest, high)
            if low < limits.toomre.lowerBound || high > limits.toomre.upperBound {
                let worst = low < limits.toomre.lowerBound ? low : high
                reasons.append(.unstableDisk(galaxy: index, toomre: worst))
            }
        }

        var report = SceneCheck(
            closestApproach: nil,
            toomre: lowest <= highest ? lowest...highest : nil,
            startClearance: nil, fieldRatio: 0, reasons: [])
        guard count > 1 else {
            report.reasons = reasons
            return report
        }

        var model = EncounterCentres(scene: scene)
        let reaches = scene.galaxies.map(reach)
        let bright = scene.galaxies.map(brightReach)
        let pairs = (0..<count).flatMap { i in ((i + 1)..<count).map { (i, $0) } }
        var closest = pairs.map { _ in (distance: Float.infinity, time: Float(0)) }

        func separation(_ pair: (Int, Int)) -> Float {
            Float(simd_distance(model.positions[pair.0], model.positions[pair.1]))
        }

        // The start.
        var clearance = Float.infinity
        for pair in pairs {
            let limit = limits.overlap * (bright[pair.0] + bright[pair.1])
            let apart = separation(pair)
            if apart / limit < clearance { clearance = apart / limit }
            if apart < limit {
                reasons.append(
                    .overlapAtStart(
                        first: pair.0, second: pair.1, separation: apart, limit: limit))
            }
        }
        report.startClearance = clearance

        // The window. Leapfrog at a short fixed step, sampled at every step.
        let dt = 0.02
        let myr = Float(Physics.megayearsPerTimeUnit * dt)
        let steps = Int((Double(window.upperBound) / Physics.megayearsPerTimeUnit / dt).rounded(.up))
        // The director frames the scene once, from where it stands when the clip opens, and
        // every shot is a multiple of that. What the field has to hold is therefore measured
        // against the same moment: how far, over the opening frame, the galaxies get from the
        // origin the camera is aimed at.
        func frame() -> Float {
            var radius: Float = 0
            for (index, position) in model.positions.enumerated() {
                radius = max(radius, Float(simd_length(position)) + bright[index])
            }
            return radius
        }
        var opening: Float?
        var widest: Float = 0
        for step in 0...max(steps, 0) {
            let time = Float(step) * myr
            if window.contains(time) {
                if opening == nil { opening = max(frame(), bright.max() ?? 1) }
                widest = max(widest, frame())
                for (index, pair) in pairs.enumerated() {
                    let apart = separation(pair)
                    if apart < closest[index].distance { closest[index] = (apart, time) }
                }
            }
            if step < steps { model.step(dt) }
        }
        report.fieldRatio = widest / (opening ?? 1)
        if report.fieldRatio > limits.field {
            reasons.append(
                .leavesFrame(radius: widest, limit: limits.field * (opening ?? 1)))
        }

        // At least one pair has to come within its disks' combined reach.
        let approaches = pairs.indices.map { index in
            (
                closest[index],
                reaches[pairs[index].0] + reaches[pairs[index].1]
            )
        }
        if let best = approaches.min(by: { $0.0.distance / $0.1 < $1.0.distance / $1.1 }) {
            report.closestApproach = best.0
            if best.0.distance >= best.1 {
                reasons.append(.noApproach(closest: best.0.distance, needed: best.1))
            }
        }
        report.reasons = reasons
        return report
    }
}

extension SceneConfig {
    /// The centres a camera frames: a black hole's only while it is near a galaxy with stars,
    /// eased back onto that galaxy between one and two of its reaches, so a hole flying off
    /// on its way out does not take the frame with it.
    public func framedCentres(_ centres: [SIMD3<Float>]) -> [SIMD3<Float>] {
        guard centres.count == galaxies.count, hasBlackHole else { return centres }
        let hosts = galaxies.indices.filter { galaxies[$0].kind != .blackHole }
        return centres.indices.map { index in
            guard galaxies[index].kind == .blackHole,
                let host = hosts.min(by: {
                    simd_distance(centres[$0], centres[index]) < simd_distance(centres[$1], centres[index])
                })
            else { return centres[index] }
            let reach = SceneCheck.reach(galaxies[host])
            let t = min(max((simd_distance(centres[index], centres[host]) - reach) / reach, 0), 1)
            let near = 1 - t * t * (3 - 2 * t)
            return centres[host] + (centres[index] - centres[host]) * near
        }
    }

    /// The check for a clip of `steps` steps after `settleSteps` of settling.
    public func sanityCheck(
        settleSteps: Int, steps: Int, limits: SceneCheck.Limits = SceneCheck.Limits()
    ) -> SceneCheck {
        SceneCheck.evaluate(
            self, window: clipWindow(settleSteps: settleSteps, steps: steps), limits: limits)
    }
}
