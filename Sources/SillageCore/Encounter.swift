import Foundation
import simd

/// An encounter described by its geometry rather than by where the galaxies start. The
/// starting positions and velocities are worked out backwards from the pericentre, so the
/// passage happens when and where it was asked for instead of whenever two wide draws
/// happen to cross.
public struct Encounter: Codable, Sendable, Equatable {
    /// How a disk sits against the orbit.
    public struct Disk: Codable, Sendable, Equatable {
        /// Angle between the disk's axis and the orbit's, in radians. Zero lies in the
        /// orbital plane.
        public var inclination: Float
        /// Direction of the disk's line of nodes in the orbital plane, measured from the
        /// pericentre direction, in radians.
        public var argument: Float
        /// Prograde turns with the orbit, retrograde against it.
        public var spin: Spin

        public init(inclination: Float = 0, argument: Float = 0, spin: Spin = .prograde) {
            self.inclination = inclination
            self.argument = argument
            self.spin = spin
        }
    }

    public enum Orbit: String, Sendable {
        case bound, parabolic, hyperbolic
    }

    /// Index of the galaxy the secondary passes. It must be placed already: the first galaxy,
    /// or the secondary of an earlier encounter.
    public var primary: Int
    public var secondary: Int
    /// Closest approach between the two centres, in kpc.
    public var pericentre: Float
    /// Below one bound, one parabolic, above one hyperbolic. Taken against the potential the
    /// two galaxies actually exert at pericentre, so the class is the true one.
    public var eccentricity: Float
    /// Secondary mass over primary mass.
    public var massRatio: Float
    /// When the pericentre falls, in Myr from the start of the run.
    public var pericentreTime: Float
    public var primaryDisk: Disk
    public var secondaryDisk: Disk
    /// The orbital plane in the scene: its axis tilted from z by `planeTilt`, turned about z
    /// by `planeTurn`, and the pericentre at `pericentreAngle` within the plane.
    public var planeTilt: Float
    public var planeTurn: Float
    public var pericentreAngle: Float

    public init(
        primary: Int = 0, secondary: Int = 1, pericentre: Float, eccentricity: Float,
        massRatio: Float, pericentreTime: Float, primaryDisk: Disk = Disk(),
        secondaryDisk: Disk = Disk(), planeTilt: Float = 0, planeTurn: Float = 0,
        pericentreAngle: Float = 0
    ) {
        self.primary = primary
        self.secondary = secondary
        self.pericentre = pericentre
        self.eccentricity = eccentricity
        self.massRatio = massRatio
        self.pericentreTime = pericentreTime
        self.primaryDisk = primaryDisk
        self.secondaryDisk = secondaryDisk
        self.planeTilt = planeTilt
        self.planeTurn = planeTurn
        self.pericentreAngle = pericentreAngle
    }

    public var orbit: Orbit {
        abs(eccentricity - 1) < 1e-3 ? .parabolic : eccentricity < 1 ? .bound : .hyperbolic
    }

    /// Orbit frame to scene: the orbit turns about z, its pericentre lies along x.
    var plane: simd_double3x3 {
        func aboutZ(_ angle: Float) -> simd_double3x3 {
            let c = Double(cos(angle))
            let s = Double(sin(angle))
            return simd_double3x3(
                SIMD3<Double>(c, s, 0), SIMD3<Double>(-s, c, 0), SIMD3<Double>(0, 0, 1))
        }
        let c = Double(cos(planeTilt))
        let s = Double(sin(planeTilt))
        let tilt = simd_double3x3(
            SIMD3<Double>(1, 0, 0), SIMD3<Double>(0, c, s), SIMD3<Double>(0, -s, c))
        return aboutZ(planeTurn) * tilt * aboutZ(pericentreAngle)
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case unknownGalaxy(Int)
        case notPlacedYet(Int)
        case placedTwice(Int)
        case nonPositive(String)
        /// A bound orbit reaches its apocentre before the requested time has been stepped
        /// back, so the passage asked for would not be the first one.
        case tooLateForBoundOrbit(encounter: Int, halfPeriodMyr: Float)

        public var description: String {
            switch self {
            case .unknownGalaxy(let index): "encounter names galaxy \(index), which does not exist"
            case .notPlacedYet(let index): "galaxy \(index) is a primary before it is placed"
            case .placedTwice(let index): "galaxy \(index) is the secondary of two encounters"
            case .nonPositive(let field): "\(field) must be positive"
            case .tooLateForBoundOrbit(let encounter, let half):
                String(
                    format: "encounter %d: a bound orbit only falls in for %.0f Myr", encounter,
                    half)
            }
        }
    }
}

/// The galaxy centres alone, each pulled by the mass the others hold inside the separation.
/// Fast enough to integrate thousands of times while a scene is being placed.
public struct EncounterCentres {
    /// What one galaxy pulls with, as a function of distance from its centre.
    struct Profile {
        var stellarMass: Double
        /// Plummer scale standing in for the disk and bulge, or the pair softening.
        var stellarScale: Double
        var haloMass: Double
        var haloScale: Double
        var haloPlummer: Bool
        /// A live halo is sampled out to here and carries its whole mass inside it.
        var haloEdge: Double?

        private func haloFraction(_ r: Double) -> Double {
            let a = haloScale
            return haloPlummer ? pow(r * r / (r * r + a * a), 1.5) : r * r / ((r + a) * (r + a))
        }

        func enclosed(_ r: Double) -> Double {
            let b = stellarScale
            var mass = stellarMass * pow(r * r / (r * r + b * b), 1.5)
            if haloMass > 0 {
                if let edge = haloEdge {
                    mass += haloMass * min(haloFraction(r) / haloFraction(edge), 1)
                } else {
                    mass += haloMass * haloFraction(r)
                }
            }
            return mass
        }

        func potential(_ r: Double) -> Double {
            var phi = -stellarMass / (r * r + stellarScale * stellarScale).squareRoot()
            guard haloMass > 0 else { return phi }
            let a = haloScale
            func shape(_ x: Double) -> Double {
                haloPlummer ? -1 / (x * x + a * a).squareRoot() : -1 / (x + a)
            }
            if let edge = haloEdge {
                let inside = haloMass / haloFraction(edge)
                phi += r >= edge ? -haloMass / r : inside * (shape(r) - shape(edge)) - haloMass / edge
            } else {
                phi += haloMass * shape(r)
            }
            return phi
        }
    }

    enum Coupling {
        /// Each centre is accelerated by the others' whole field and carries no reaction,
        /// which is what a rigid halo riding on its disk does.
        case rigid
        /// Equal and opposite. No dynamical friction: against self-gravitating runs the first
        /// passage already lands within a few per cent without it, and late rather than early,
        /// which a drag would only make worse.
        case live
    }

    let profiles: [Profile]
    let coupling: Coupling
    var masses: [Double] { profiles.map { $0.stellarMass + $0.haloMass } }
    public var positions: [SIMD3<Double>]
    public var velocities: [SIMD3<Double>]

    init(profiles: [Profile], coupling: Coupling, positions: [SIMD3<Double>], velocities: [SIMD3<Double>]) {
        self.profiles = profiles
        self.coupling = coupling
        self.positions = positions
        self.velocities = velocities
    }

    /// The centre model for a scene as its solver will run it.
    public init(scene: SceneConfig) {
        let selfGravitating = scene.solver.isSelfGravitating
        let live = scene.hasLiveHalos
        profiles = scene.galaxies.map { galaxy in
            let mass = Double(galaxy.potential.mass)
            guard selfGravitating else {
                // The restricted solver moves softened points, exactly as `GalaxyCenters` does.
                return Profile(
                    stellarMass: mass, stellarScale: Double(scene.centerSoftening), haloMass: 0,
                    haloScale: 1, haloPlummer: false, haloEdge: nil)
            }
            if galaxy.kind == .blackHole {
                return Profile(
                    stellarMass: mass, stellarScale: Double(galaxy.potential.scaleRadius),
                    haloMass: 0, haloScale: 1, haloPlummer: false, haloEdge: nil)
            }
            let stellar = mass * Double(galaxy.diskMassFraction)
            // An exponential disk holds half its mass inside 1.68 scale lengths and a Plummer
            // sphere inside 1.3 of its scale.
            let size = galaxy.kind == .globular ? 1 : 1.3
            return Profile(
                stellarMass: stellar,
                stellarScale: max(Double(galaxy.diskScaleLength) * size, 0.1),
                haloMass: mass - stellar,
                haloScale: Double(galaxy.potential.scaleRadius),
                haloPlummer: galaxy.potential.profile == .plummer,
                haloEdge: live && galaxy.haloParticleCount > 0
                    ? Double(max(galaxy.haloExtent, 1) * galaxy.potential.scaleRadius) : nil)
        }
        coupling = live ? .live : .rigid
        positions = scene.galaxies.map { SIMD3<Double>($0.position) }
        velocities = scene.galaxies.map { SIMD3<Double>($0.velocity) }
    }

    /// Potential energy per unit reduced mass of a pair at a separation.
    func pairPotential(_ i: Int, _ j: Int, at r: Double) -> Double {
        profiles[i].potential(r) + profiles[j].potential(r)
    }

    func accelerations() -> [SIMD3<Double>] {
        var result = [SIMD3<Double>](repeating: .zero, count: positions.count)
        for i in positions.indices {
            for j in positions.indices where j > i {
                let (a, b) = Self.pair(profiles[i], profiles[j], coupling, positions[i], positions[j])
                result[i] += a
                result[j] += b
            }
        }
        return result
    }

    /// What two galaxies do to each other, without allocating: this runs millions of times
    /// while a scene is being placed.
    static func pair(
        _ first: Profile, _ second: Profile, _ coupling: Coupling, _ x1: SIMD3<Double>,
        _ x2: SIMD3<Double>
    ) -> (SIMD3<Double>, SIMD3<Double>) {
        let offset = x1 - x2
        let r = max(simd_length(offset), 1e-6)
        let direction = offset / r
        let pullOfSecond = second.enclosed(r) / (r * r)
        let pullOfFirst = first.enclosed(r) / (r * r)
        switch coupling {
        case .rigid:
            return (-direction * pullOfSecond, direction * pullOfFirst)
        case .live:
            let m1 = first.stellarMass + first.haloMass
            let m2 = second.stellarMass + second.haloMass
            let relative = pullOfFirst + pullOfSecond
            return (
                -direction * relative * (m2 / (m1 + m2)), direction * relative * (m1 / (m1 + m2))
            )
        }
    }

    /// Kick, drift, kick. A negative step runs the encounter backwards.
    public mutating func step(_ dt: Double) {
        var acceleration = accelerations()
        for i in positions.indices {
            velocities[i] += acceleration[i] * (dt / 2)
            positions[i] += velocities[i] * dt
        }
        acceleration = accelerations()
        for i in positions.indices { velocities[i] += acceleration[i] * (dt / 2) }
    }

    public struct Passage: Sendable, Equatable {
        public var distance: Float
        /// In Myr from the start.
        public var time: Float
    }

    static let timeStep = 0.01

    /// The first local minimum of each pair's separation, integrating forward from here.
    /// `nil` for a pair that is still approaching or receding at `horizon` Myr.
    public func firstPericentres(of pairs: [(Int, Int)], horizonMyr: Float) -> [Passage?] {
        var model = self
        let dt = Self.timeStep
        let steps = Int(Double(horizonMyr) / Physics.megayearsPerTimeUnit / dt) + 1
        var found = [Passage?](repeating: nil, count: pairs.count)
        // The lowest sample so far with its two neighbours. A dip only counts once the pair
        // has clearly separated again, so a wobble from a third galaxy is not a passage.
        var lowest = pairs.map { pair -> (before: Double, at: Double, after: Double, step: Int) in
            let d = simd_distance(model.positions[pair.0], model.positions[pair.1])
            return (d, d, .infinity, 0)
        }
        var previous = lowest.map(\.at)
        for step in 1...steps {
            model.step(dt)
            for (index, pair) in pairs.enumerated() where found[index] == nil {
                let d = simd_distance(model.positions[pair.0], model.positions[pair.1])
                if d < lowest[index].at {
                    lowest[index] = (previous[index], d, .infinity, step)
                } else if lowest[index].step == step - 1 {
                    lowest[index].after = d
                }
                previous[index] = d
                let low = lowest[index]
                guard low.step > 0, low.after.isFinite, d > low.at * 1.05 + 0.2 else { continue }
                // A parabola through the three samples places the minimum between them.
                let curvature = low.before - 2 * low.at + low.after
                let shift = curvature > 0 ? 0.5 * (low.before - low.after) / curvature : 0
                let distance = low.at - 0.25 * (low.before - low.after) * shift
                let time = (Double(low.step) + shift) * dt * Physics.megayearsPerTimeUnit
                found[index] = Passage(distance: Float(distance), time: Float(time))
            }
            if found.allSatisfy({ $0 != nil }) { break }
        }
        return found
    }
}

extension SceneConfig {
    /// Applies the encounters: masses from the mass ratios, disks oriented against their
    /// orbits, and every centre's starting position and velocity worked back from the
    /// pericentres. The centre of mass ends at rest at the origin. Running it again on its
    /// own result changes nothing.
    ///
    /// With `firstPassage` off, a passage that is not the pair's first is accepted and placed
    /// as the backward construction gives it, without correcting the others' pull.
    public mutating func placeEncounters(firstPassage: Bool = true) throws {
        guard !encounters.isEmpty else { return }
        try validateEncounters()
        applyMassRatios()
        orientDisks()

        let pairs = encounters.map { ($0.primary, $0.secondary) }
        let wanted = encounters.map { (Double($0.pericentre), Double($0.pericentreTime)) }
        let horizon = Float(wanted.map(\.1).max() ?? 0) * 1.5 + 200

        // What is solved for is the passage each pair is asked for on its own, as a log
        // distance and a time; what is matched is the passage the centres make run forward
        // together. Time is weighed in units of fifty megayears.
        typealias Trial = (residual: [Double], positions: [SIMD3<Double>], velocities: [SIMD3<Double>])
        func trial(_ x: [Double]) -> Trial? {
            let asked = wanted.indices.map { (exp(x[2 * $0]), max(x[2 * $0 + 1], 1)) }
            guard let (positions, velocities) = try? startingState(asking: asked) else { return nil }
            var model = EncounterCentres(scene: self)
            model.positions = positions
            model.velocities = velocities
            let passages = model.firstPericentres(of: pairs, horizonMyr: horizon)
            var residual: [Double] = []
            for (want, got) in zip(wanted, passages) {
                guard let got else { return nil }
                residual += [log(Double(got.distance) / want.0), (Double(got.time) - want.1) / 50]
            }
            return (residual, positions, velocities)
        }
        func size(_ r: [Double]) -> Double { r.reduce(0) { $0 + $1 * $1 } }

        var x = wanted.flatMap { [log($0.0), $0.1] }
        // A first passage the centres never make leaves the backward construction as it is.
        let first = try startingState(asking: wanted, firstPassage: firstPassage)
        guard firstPassage else {
            for index in galaxies.indices {
                galaxies[index].position = SIMD3<Float>(first.0[index])
                galaxies[index].velocity = SIMD3<Float>(first.1[index])
            }
            return
        }
        var best =
            trial(x)
            ?? (Array(repeating: Double.infinity, count: x.count), first.0, first.1)
        // The backward construction is exact for an isolated pair and only approximate once
        // a third galaxy acts. Levenberg-Marquardt on a finite-difference Jacobian
        // closes the gap; a step that makes things worse is retaken shorter.
        var damping = 1e-3
        for _ in 0..<60 where size(best.residual) > 1e-8 && size(best.residual).isFinite {
            let n = x.count
            var jacobian = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
            var usable = true
            for column in 0..<n {
                // Forward, or backward when forward asks for an orbit that cannot be built.
                var moved: Trial?
                var h = 0.0
                for nudge in column % 2 == 0 ? [0.01, -0.01] : [1.0, -1.0] where moved == nil {
                    var nudged = x
                    nudged[column] += nudge
                    moved = trial(nudged)
                    h = nudge
                }
                guard let moved else {
                    usable = false
                    break
                }
                for row in 0..<n { jacobian[row][column] = (moved.residual[row] - best.residual[row]) / h }
            }
            guard usable else { break }
            var improved = false
            while damping < 1e6 {
                var normal = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
                var gradient = [Double](repeating: 0, count: n)
                for i in 0..<n {
                    for j in 0..<n {
                        for k in 0..<n { normal[i][j] += jacobian[k][i] * jacobian[k][j] }
                    }
                    normal[i][i] *= 1 + damping
                    normal[i][i] += 1e-12
                    for k in 0..<n { gradient[i] -= jacobian[k][i] * best.residual[k] }
                }
                guard let step = Self.solve(normal, gradient) else {
                    damping *= 10
                    continue
                }
                let candidate = zip(x, step).map { $0 + $1 }
                if let next = trial(candidate), size(next.residual) < size(best.residual) {
                    x = candidate
                    best = next
                    damping = max(damping / 10, 1e-7)
                    improved = true
                    break
                }
                damping *= 10
            }
            if !improved { break }
        }
        for index in galaxies.indices {
            galaxies[index].position = SIMD3<Float>(best.positions[index])
            galaxies[index].velocity = SIMD3<Float>(best.velocities[index])
        }
    }

    /// Gaussian elimination with partial pivoting, for the handful of unknowns above.
    private static func solve(_ matrix: [[Double]], _ vector: [Double]) -> [Double]? {
        var a = matrix
        var b = vector
        let n = b.count
        for column in 0..<n {
            guard
                let pivot = (column..<n).max(by: { abs(a[$0][column]) < abs(a[$1][column]) }),
                abs(a[pivot][column]) > 1e-300
            else { return nil }
            a.swapAt(column, pivot)
            b.swapAt(column, pivot)
            for row in (column + 1)..<n {
                let factor = a[row][column] / a[column][column]
                for k in column..<n { a[row][k] -= factor * a[column][k] }
                b[row] -= factor * b[column]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var sum = b[row]
            for k in (row + 1)..<n { sum -= a[row][k] * x[k] }
            x[row] = sum / a[row][row]
        }
        return x
    }

    private func validateEncounters() throws {
        var placed: Set<Int> = []
        for encounter in encounters {
            for index in [encounter.primary, encounter.secondary]
            where !galaxies.indices.contains(index) {
                throw Encounter.Failure.unknownGalaxy(index)
            }
            if placed.isEmpty { placed.insert(encounter.primary) }
            guard placed.contains(encounter.primary) else {
                throw Encounter.Failure.notPlacedYet(encounter.primary)
            }
            guard !placed.contains(encounter.secondary) else {
                throw Encounter.Failure.placedTwice(encounter.secondary)
            }
            placed.insert(encounter.secondary)
            if encounter.pericentre <= 0 { throw Encounter.Failure.nonPositive("pericentre") }
            if encounter.massRatio <= 0 { throw Encounter.Failure.nonPositive("massRatio") }
            if encounter.pericentreTime <= 0 {
                throw Encounter.Failure.nonPositive("pericentreTime")
            }
            if encounter.eccentricity < 0 { throw Encounter.Failure.nonPositive("eccentricity") }
        }
    }

    /// The secondary takes its mass from the primary, and its lengths follow as the cube root
    /// so its mean density, and with it its dynamical time and its stability, stay as drawn.
    /// The visible particles are then shared in proportion to mass, so a particle weighs the
    /// same in every galaxy: unequal particle masses heat the lighter disk numerically.
    private mutating func applyMassRatios() {
        for encounter in encounters {
            let target = galaxies[encounter.primary].potential.mass * encounter.massRatio
            var galaxy = galaxies[encounter.secondary]
            let stretch = cbrt(target / max(galaxy.potential.mass, 1e-6))
            galaxy.potential.mass = target
            galaxy.potential.scaleRadius *= stretch
            galaxy.diskScaleLength *= stretch
            galaxy.diskThickness *= stretch
            galaxies[encounter.secondary] = galaxy
        }
        let total = totalParticleCount
        let mass = galaxies.reduce(Float(0)) { $0 + $1.potential.mass }
        guard total > 0, mass > 0 else { return }
        let counts = Self.sharedCounts(
            total, weights: galaxies.map { Double($0.potential.mass / mass) },
            kinds: galaxies.map(\.kind))
        for index in galaxies.indices { galaxies[index].particleCount = counts[index] }
    }

    /// The first encounter naming a galaxy decides how its disk sits.
    private mutating func orientDisks() {
        var oriented: Set<Int> = []
        for encounter in encounters {
            for (index, disk) in [
                (encounter.primary, encounter.primaryDisk),
                (encounter.secondary, encounter.secondaryDisk),
            ] where !oriented.contains(index) {
                oriented.insert(index)
                let i = Double(disk.inclination)
                let w = Double(disk.argument)
                let axis = simd_normalize(
                    encounter.plane * SIMD3<Double>(sin(i) * sin(w), -sin(i) * cos(w), cos(i)))
                // Inverts `GalaxyConfig.orientation`, whose third column is the disk's axis.
                galaxies[index].inclination = Float(acos(min(max(axis.z, -1), 1)))
                galaxies[index].positionAngle = Float(atan2(axis.x, -axis.y))
                galaxies[index].spin = disk.spin
            }
        }
    }

    /// Each secondary is set at its pericentre beside where its primary actually is at that
    /// moment, with the galaxies already placed run forward to it, then stepped back through
    /// them to the start. The whole is then moved to rest at the origin.
    private func startingState(asking asked: [(Double, Double)], firstPassage: Bool = true) throws -> (
        [SIMD3<Double>], [SIMD3<Double>]
    ) {
        let full = EncounterCentres(scene: self)
        let profiles = full.profiles
        let coupling = full.coupling
        let masses = full.masses
        var positions = [SIMD3<Double>](repeating: .zero, count: galaxies.count)
        var velocities = positions
        var placed = [encounters[0].primary]
        for (index, encounter) in encounters.enumerated() {
            let p = encounter.primary
            let s = encounter.secondary
            let q = asked[index].0
            let e = Double(encounter.eccentricity)
            let speed = max(
                -2 * full.pairPotential(p, s, at: q) + (e - 1) * (masses[p] + masses[s]) / q, 1e-8
            ).squareRoot()
            let back = asked[index].1 / Physics.megayearsPerTimeUnit
            let steps = max(Int((back / EncounterCentres.timeStep).rounded(.up)), 1)
            let interval = back / Double(steps)

            var group = EncounterCentres(
                profiles: placed.map { profiles[$0] }, coupling: coupling,
                positions: placed.map { positions[$0] }, velocities: placed.map { velocities[$0] })
            var track = [(group.positions, group.velocities)]
            for _ in 0..<steps {
                group.step(interval)
                track.append((group.positions, group.velocities))
            }
            guard let primary = placed.firstIndex(of: p) else {
                throw Encounter.Failure.notPlacedYet(p)
            }

            // The primary is held to its path, so the pull the secondary would have given it is
            // put on the secondary instead: that keeps the pair's relative orbit exact.
            func pull(_ step: Int, _ x: SIMD3<Double>) -> SIMD3<Double> {
                var total = SIMD3<Double>.zero
                for (k, j) in placed.enumerated() {
                    let (onJ, onS) = EncounterCentres.pair(
                        profiles[j], profiles[s], coupling, track[step].0[k], x)
                    total += j == p ? onS - onJ : onS
                }
                return total
            }
            let rotation = encounter.plane
            var x = track[steps].0[primary] + rotation * SIMD3(q, 0, 0)
            var v = track[steps].1[primary] + rotation * SIMD3(0, speed, 0)
            var farthest = (distance: q, step: steps)
            for step in stride(from: steps, to: 0, by: -1) {
                v -= pull(step, x) * (interval / 2)
                x -= v * interval
                v -= pull(step - 1, x) * (interval / 2)
                let apart = simd_distance(x, track[step - 1].0[primary])
                // Stepping back, the pair can only separate until it passes apocentre. The same
                // margin as a passage needs, so a wobble from a third galaxy does not count.
                if firstPassage, apart < farthest.distance / 1.05 - 0.2 {
                    throw Encounter.Failure.tooLateForBoundOrbit(
                        encounter: index,
                        halfPeriodMyr: Float(
                            Double(steps - farthest.step) * interval * Physics.megayearsPerTimeUnit))
                }
                if apart > farthest.distance { farthest = (apart, step - 1) }
            }
            positions[s] = x
            velocities[s] = v
            placed.append(s)
        }
        let total = masses.reduce(0, +)
        var centre = SIMD3<Double>.zero
        var drift = SIMD3<Double>.zero
        for index in positions.indices {
            centre += positions[index] * masses[index]
            drift += velocities[index] * masses[index]
        }
        for index in positions.indices {
            positions[index] -= centre / total
            velocities[index] -= drift / total
        }
        return (positions, velocities)
    }
}

extension SceneConfig {
    /// Moves every pericentre from one stretch of the run to another, keeping where in it each
    /// one falls. How a generated scene is fitted to the clip it will be shown in.
    public mutating func retimeEncounters(from old: ClosedRange<Float>, to new: ClosedRange<Float>) {
        let span = max(old.upperBound - old.lowerBound, 1e-3)
        for index in encounters.indices {
            let along = (encounters[index].pericentreTime - old.lowerBound) / span
            encounters[index].pericentreTime =
                new.lowerBound + along * (new.upperBound - new.lowerBound)
        }
    }

    /// The stretch of simulated time a clip shows, in Myr, at this scene's step.
    public func clipWindow(settleSteps: Int, steps: Int) -> ClosedRange<Float> {
        let myr = timeStep * Float(Physics.megayearsPerTimeUnit)
        return Float(settleSteps) * myr...Float(settleSteps + steps) * myr
    }

    /// Places the encounters, giving way on what cannot be built rather than failing: a bound
    /// orbit that cannot fall in for long enough is opened to parabolic, then a chain hung off
    /// a secondary is hung off the first galaxy instead, then the passages are brought earlier.
    /// What was finally placed is what the scene keeps.
    public mutating func placeEncountersGivingWay() {
        for attempt in 0..<12 {
            var trial = self
            if attempt >= 1 {
                for index in trial.encounters.indices {
                    trial.encounters[index].eccentricity = max(trial.encounters[index].eccentricity, 1)
                }
            }
            if attempt >= 2 {
                let root = trial.encounters[0].primary
                for index in trial.encounters.indices { trial.encounters[index].primary = root }
            }
            if attempt >= 3 {
                let shrink = pow(Float(0.75), Float(attempt - 2))
                for index in trial.encounters.indices {
                    trial.encounters[index].pericentreTime *= shrink
                }
            }
            if (try? trial.placeEncounters()) != nil {
                self = trial
                return
            }
        }
        // A group whose first galaxy is thrown about by the others may have no first passage
        // to aim at; it still gets the passages asked for, if not as the first ones.
        try? placeEncounters(firstPassage: false)
    }
}
