import Foundation

/// What a galaxy was drawn as. Finer than `GalaxyKind`, which says how its stars are laid
/// down: an elliptical and a globular are both spheroids, a dwarf is a small disk.
public enum GalaxyFamily: String, Codable, Sendable, CaseIterable {
    case spiral, disk, elliptical, dwarf, globular
    case blackHole = "black-hole"
}

/// How a scene was drawn, kept in its scene file.
public struct SceneDraw: Codable, Sendable, Equatable {
    /// `free` for a free draw, otherwise the archetype it was drawn from.
    public var generator: String
    public var batchSeed: UInt64
    /// Place in the batch, from zero. An archetype drawn on its own counts its own scenes.
    public var index: Int
    /// The point of the sequence the scene came from: the batch's for a free draw, where the
    /// points skipped between two scenes were too close to one already drawn, and the
    /// archetype's own for an archetype.
    public var point: Int
    /// Each galaxy's family, in the scene's order.
    public var families: [GalaxyFamily]

    public init(
        generator: String, batchSeed: UInt64, index: Int, point: Int, families: [GalaxyFamily]
    ) {
        self.generator = generator
        self.batchSeed = batchSeed
        self.index = index
        self.point = point
        self.families = families
    }
}

/// Scenes spread evenly over what a scene can physically be, rather than drawn independently
/// and left to clump.
///
/// What most changes a scene comes from a Sobol sequence: how many galaxies, what the first
/// two are, their arms, bulges and thickness, the mass ratio and the geometry of the first
/// encounter, how fast the companion comes in among it. What only shades it comes from a
/// stream seeded by the point: dust, clumps, the orbital plane, and every galaxy past the
/// second. A candidate too close to a scene already in the batch, by `SceneConfig.signature`,
/// is passed over.
///
/// A scene is found again from the batch seed and its index alone. The batch is replayed up to
/// it as drafts, galaxies and encounters with nothing placed, which is a few microseconds each.
public struct FreeDraw: Sendable {
    public static let generator = "free"
    /// Least signature distance between two scenes of a batch.
    public static let defaultSpacing: Float = 0.3

    public var batchSeed: UInt64
    public var spacing: Float
    /// Brings the passages earlier, as it does for `contemplation`.
    public var haste: Float

    /// Candidates tried for one scene before the farthest of them is taken anyway, so a batch
    /// that has filled its space still goes on.
    static let patience = 64

    private let sequence: Sobol

    public init(batchSeed: UInt64, spacing: Float = FreeDraw.defaultSpacing, haste: Float = 0) {
        self.batchSeed = batchSeed
        self.spacing = spacing
        self.haste = haste
        sequence = Sobol(dimensions: Axis.allCases.count, seed: batchSeed)
    }

    /// Which scenes a run of places takes: any, those of exactly two galaxies, or the others.
    public enum Pairing: Sendable, Hashable {
        case any, pairs, others

        public func takes(galaxies: Int) -> Bool {
            switch self {
            case .any: true
            case .pairs: galaxies == 2
            case .others: galaxies != 2
            }
        }
    }

    /// The scene at a place in the batch, ready to run: among the scenes `pairing` takes, the
    /// one at `index`.
    public func scene(at index: Int, particleCount: Int, taking pairing: Pairing = .any) -> SceneConfig {
        var scene = drafts(index + 1, particleCount: particleCount, taking: pairing)[index]
        var finish = SeededGenerator(seed: scene.seed ^ 0x4649_4E49_5348_4544)
        scene.finishGenerated(using: &finish)
        return scene
    }

    /// The batch's first scenes as drawn, before anything is placed: what `signature` reads.
    /// The points `pairing` does not take are passed over as if they were not in the sequence,
    /// so each kind keeps the spacing and the patience of a batch of its own.
    public func drafts(_ count: Int, particleCount: Int, taking pairing: Pairing = .any) -> [SceneConfig] {
        var kept: [SceneConfig] = []
        var signatures: [[Float]] = []
        var point = 1
        while kept.count < count {
            var best: (scene: SceneConfig, signature: [Float], gap: Float)?
            var tried = 0
            while tried < Self.patience {
                let candidate = draft(point: point, particleCount: particleCount)
                point += 1
                // The hole is decided by the candidate's own stream, so its count is known
                // before the choice.
                if pairing != .any,
                    !pairing.takes(galaxies: (Self.withBlackHole(candidate) ?? candidate).galaxyCount)
                {
                    continue
                }
                tried += 1
                let signature = candidate.signature
                let gap = signatures.map { Self.distance($0, signature) }.min() ?? .infinity
                if best == nil || gap > best!.gap { best = (candidate, signature, gap) }
                if gap >= spacing { break }
            }
            guard var chosen = best else { break }
            // After the choice, so the scenes around it are the ones the batch always drew.
            if let hole = Self.withBlackHole(chosen.scene) { chosen.scene = hole }
            chosen.scene.draw?.index = kept.count
            kept.append(chosen.scene)
            signatures.append(chosen.signature)
        }
        return kept
    }

    public static func distance(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).reduce(Float(0)) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }.squareRoot()
    }

    /// The coordinates of the sequence, one per parameter it decides.
    enum Axis: Int, CaseIterable {
        case count, primaryFamily, primarySize, primaryArms, primaryPitch, primaryBulge
        case primaryThickness, secondaryFamily, massRatio, secondaryArms, secondaryPitch
        case secondaryBulge, secondaryThickness, pericentre, approach, primaryInclination
        case secondaryInclination, primarySpin, secondarySpin, pericentreTime
    }

    /// Shares of each galaxy count from one to five. Pairs are where most of the variety is;
    /// one disk alone has the fewest ways to differ and fills its corner first.
    static let countShares: [Float] = [0.1, 0.4, 0.25, 0.15, 0.1]
    static let primaryShares: [(GalaxyFamily, Float)] = [
        (.spiral, 0.55), (.disk, 0.2), (.elliptical, 0.25),
    ]
    static let solitaryShares: [(GalaxyFamily, Float)] = [(.spiral, 0.7), (.disk, 0.3)]
    static let companionShares: [(GalaxyFamily, Float)] = [
        (.spiral, 0.4), (.disk, 0.15), (.elliptical, 0.1), (.dwarf, 0.2), (.globular, 0.15),
    ]
    static let armShares: [(Int, Float)] = [(2, 0.4), (3, 0.25), (4, 0.2), (5, 0.15)]
    static let names = ["First", "Second", "Third", "Fourth", "Fifth"]

    func draft(point: Int, particleCount: Int) -> SceneConfig {
        let u = sequence.point(point)
        func at(_ axis: Axis) -> Float { u[axis.rawValue] }
        var mixer = SeededGenerator(seed: batchSeed ^ (UInt64(point) &* 0x9E37_79B9_7F4A_7C15))
        let seed = mixer.next()
        var stream = SeededGenerator(seed: seed)
        var looks = SeededGenerator(seed: SceneConfig.lookSeed(for: seed))
        let palette = SceneConfig.Palette.all[Int(looks.next() % UInt64(SceneConfig.Palette.all.count))]

        let count = Self.pick(at(.count), Self.countShares.enumerated().map { ($0.offset + 1, $0.element) })
        // An elliptical alone is a smooth ball with nothing happening to it.
        var families = [
            Self.pick(at(.primaryFamily), count == 1 ? Self.solitaryShares : Self.primaryShares)
        ]
        var galaxies = [
            Self.galaxy(
                families[0], size: at(.primarySize), arms: at(.primaryArms), pitch: at(.primaryPitch),
                bulge: at(.primaryBulge), thickness: at(.primaryThickness), stream: &stream)
        ]
        let window = SceneConfig.contemplationWindow(haste: haste)
        let span = window.upperBound - window.lowerBound
        var encounters: [Encounter] = []
        // As the placement will weigh them: a companion takes its mass from its primary's.
        var masses = [galaxies[0].potential.mass]
        for index in 1..<max(count, 1) {
            let first = index == 1
            let family = Self.pick(first ? at(.secondaryFamily) : stream.uniform(), Self.companionShares)
            families.append(family)
            galaxies.append(
                Self.galaxy(
                    family, size: stream.uniform(),
                    arms: first ? at(.secondaryArms) : stream.uniform(),
                    pitch: first ? at(.secondaryPitch) : stream.uniform(),
                    bulge: first ? at(.secondaryBulge) : stream.uniform(),
                    thickness: first ? at(.secondaryThickness) : stream.uniform(), stream: &stream))
            // A later galaxy now and then passes an earlier companion instead of the first, so
            // a group is not always a hub with spokes.
            var primary = 0
            if !first, stream.uniform() < 0.3 {
                let earlier = Int(stream.next() % UInt64(index - 1)) + 1
                if [.spiral, .disk, .elliptical].contains(families[earlier]) { primary = earlier }
            }
            let minor = family == .dwarf || family == .globular
            // Drawn in the order they always were, so the stream gives every later galaxy and
            // disk the numbers it did.
            let later =
                first
                ? 0 : 0.15 + 0.7 * (Float(index - 1) + stream.uniform(in: 0.2...0.8)) / Float(count - 1)
            let pericentre = first ? at(.pericentre) : stream.uniform()
            let approach = first ? at(.approach) : stream.uniform()
            let ratio = Self.logarithmic(
                first ? at(.massRatio) : stream.uniform(), in: Self.massRatios(family))
            masses.append(masses[primary] * ratio)
            let orbit = Self.orbit(
                approach: approach, pericentre: pericentre, in: minor ? 1.5...20 : 2...30,
                totalMass: masses[primary] + masses[index])
            // A captured pair passes early, so the clip has room for it to come back.
            var along = later
            if first {
                along = orbit.captured ? 0.02 + 0.2 * at(.pericentreTime) : 0.15 + 0.45 * at(.pericentreTime)
            }
            var meeting = Encounter(
                primary: primary, secondary: index,
                pericentre: orbit.pericentre,
                eccentricity: orbit.eccentricity,
                massRatio: ratio,
                pericentreTime: window.lowerBound + along * span,
                primaryDisk: Encounter.Disk(
                    inclination: (first ? at(.primaryInclination) : stream.uniform()) * .pi / 2,
                    argument: stream.uniform(in: 0...(2 * .pi)),
                    spin: (first ? at(.primarySpin) : stream.uniform()) < 0.65 ? .prograde : .retrograde),
                secondaryDisk: Encounter.Disk(
                    inclination: (first ? at(.secondaryInclination) : stream.uniform()) * .pi / 2,
                    argument: stream.uniform(in: 0...(2 * .pi)),
                    spin: (first ? at(.secondarySpin) : stream.uniform()) < 0.65 ? .prograde : .retrograde))
            // Where the orbit lies in the scene is a matter of viewpoint, not of shape.
            meeting.planeTilt = stream.uniform(in: -0.7...0.7)
            meeting.planeTurn = stream.uniform(in: 0...(2 * .pi))
            meeting.pericentreAngle = stream.uniform(in: 0...(2 * .pi))
            encounters.append(meeting)
        }
        for index in galaxies.indices {
            galaxies[index].name = Self.names[index]
            galaxies[index].color = index % 2 == 0 ? palette.primary : palette.secondary
            // Shared out again by mass once the encounters are placed.
            galaxies[index].particleCount =
                index == 0
                ? particleCount - particleCount / count * (count - 1) : particleCount / count
        }
        var scene = SceneConfig(name: "Free", galaxies: galaxies, centerSoftening: 1.2)
        scene.encounters = encounters
        scene.seed = seed
        scene.draw = SceneDraw(
            generator: Self.generator, batchSeed: batchSeed, index: 0, point: point,
            families: families)
        return scene
    }

    /// Share of free scenes whose first companion is a black hole instead.
    public static let blackHoleShare: Float = 0.04

    /// The scene with its first companion swapped for a black hole, for `blackHoleShare` of
    /// the scenes that have one to swap, decided by a stream of the scene's own so every other
    /// scene of a batch stays as it was. The passage is drawn again over the hole's ranges:
    /// fly-bys mostly, a bound orbit one time in five.
    static func withBlackHole(_ scene: SceneConfig) -> SceneConfig? {
        guard scene.galaxies.count >= 2, let first = scene.encounters.first, first.secondary == 1,
            !scene.encounters.contains(where: { $0.primary == 1 })
        else { return nil }
        var draws = SeededGenerator(seed: scene.seed ^ 0x424C_4143_4B48_4F4C)
        guard draws.uniform() < blackHoleShare else { return nil }
        var hole = scene
        let companion = hole.galaxies[1]
        hole.galaxies[1] = galaxy(
            .blackHole, size: 0, arms: 0, pitch: 0, bulge: 0, thickness: 0, stream: &draws)
        hole.galaxies[1].name = companion.name
        hole.galaxies[1].color = companion.color
        hole.galaxies[1].particleCount = 1
        hole.galaxies[0].particleCount += companion.particleCount - 1
        var meeting = first
        meeting.massRatio = logarithmic(draws.uniform(), in: massRatios(.blackHole))
        meeting.pericentre = logarithmic(draws.uniform(), in: 0.5...20)
        meeting.eccentricity =
            draws.uniform() < 0.2 ? draws.uniform(in: 0.7...0.95) : draws.uniform(in: 1...1.6)
        meeting.secondaryDisk = Encounter.Disk()
        hole.encounters[0] = meeting
        hole.draw?.families[1] = .blackHole
        return hole
    }

    /// How fast a companion comes in, drawn for itself rather than as an eccentricity, which
    /// gave one pass in two over 300 km/s far out and one in five bound (#252): two in five are
    /// captured on a bound orbit and come back round, three in ten fall in from rest or nearly
    /// and, held by the live halos, come back too, and the rest pass fast and close.
    static let capturedShare: Float = 0.4
    static let slowShare: Float = 0.3
    /// Where a captured companion swings out to, in kpc, by Kepler. The placement widens an
    /// orbit that cannot fall in for as long as its pericentre waits.
    static let capturedApocentres: ClosedRange<Float> = 25...60
    /// How fast a companion that is not captured would be far away, in km/s: a pair or a group
    /// meets at a few hundred, the intruder of Stephan's Quintet at 900.
    static let slowSpeeds: ClosedRange<Float> = 0...120
    static let fastSpeeds: ClosedRange<Float> = 120...900
    /// Pericentre times speed of a fast pass at most, in kpc km/s: 30 kpc at 150 km/s, 5 kpc at
    /// 900. A fast pass far out barely touches either disk.
    static let fastReach: Float = 4_500

    struct Orbit: Equatable {
        var pericentre: Float
        var eccentricity: Float
        var captured: Bool
    }

    /// A companion's orbit from two coordinates in [0, 1): where its pericentre lies in `range`,
    /// and its approach. The eccentricity is what the placement reads, its energy over the pair
    /// at pericentre being (e - 1) M / 2q.
    static func orbit(
        approach u: Float, pericentre p: Float, in range: ClosedRange<Float>, totalMass: Float
    ) -> Orbit {
        if u < capturedShare {
            let q = logarithmic(p, in: range)
            let apocentre = max(logarithmic(u / capturedShare, in: capturedApocentres), 1.5 * q)
            return Orbit(pericentre: q, eccentricity: (apocentre - q) / (apocentre + q), captured: true)
        }
        let fast = u >= capturedShare + slowShare
        let speed =
            fast
            ? logarithmic((u - capturedShare - slowShare) / (1 - capturedShare - slowShare), in: fastSpeeds)
            : slowSpeeds.at((u - capturedShare) / slowShare)
        let upper =
            fast ? min(range.upperBound, max(fastReach / speed, 2 * range.lowerBound)) : range.upperBound
        let q = logarithmic(p, in: range.lowerBound...upper)
        let v = speed / Float(Physics.kilometersPerSecondPerVelocityUnit)
        return Orbit(pericentre: q, eccentricity: 1 + q * v * v / totalMass, captured: false)
    }

    /// Where an orbit sits on the approach as `orbit` lays it out, from 0 for the tightest
    /// capture to 1 for the fastest pass.
    static func approach(pericentre q: Float, eccentricity e: Float, totalMass: Float) -> Float {
        func clamped(_ x: Float) -> Float { min(max(x, 0), 1) }
        if e < 1 {
            let apocentre = q * (1 + e) / max(1 - e, 1e-6)
            let swing = capturedApocentres
            return capturedShare
                * clamped(log(apocentre / swing.lowerBound) / log(swing.upperBound / swing.lowerBound))
        }
        let speed = ((e - 1) * totalMass / q).squareRoot() * Float(Physics.kilometersPerSecondPerVelocityUnit)
        if speed < slowSpeeds.upperBound { return capturedShare + slowShare * speed / slowSpeeds.upperBound }
        return capturedShare + slowShare + (1 - capturedShare - slowShare)
            * clamped(log(speed / fastSpeeds.lowerBound) / log(fastSpeeds.upperBound / fastSpeeds.lowerBound))
    }

    /// The range of mass ratios a companion of a family is drawn from, against the galaxy it
    /// passes.
    static func massRatios(_ family: GalaxyFamily) -> ClosedRange<Float> {
        switch family {
        case .spiral, .disk: 0.2...1
        case .elliptical: 0.25...1
        case .dwarf: 0.03...0.2
        case .globular: 0.08...0.3
        // A 10^9 to 10^11 solar mass hole against a 10^11 to 10^12 host. Past a tenth it is
        // more a massive intruder than any black hole known, kept for what the disk does.
        case .blackHole: 0.01...0.3
        }
    }

    /// One galaxy of a family. `size`, `arms`, `pitch`, `bulge` and `thickness` are positions
    /// in [0, 1) within that family's own range, so the same coordinate means a large spiral
    /// or a large elliptical. The ranges are each family's plausible span, taken wide.
    static func galaxy(
        _ family: GalaxyFamily, size: Float, arms: Float, pitch: Float, bulge: Float,
        thickness: Float, stream: inout SeededGenerator
    ) -> GalaxyConfig {
        switch family {
        case .spiral:
            let scale = 2.6 + 3.6 * size
            let armCount = pick(arms, armShares)
            var galaxy = GalaxyConfig(
                name: "", particleCount: 0, kind: .spiral,
                potential: GalaxyPotential(
                    profile: .hernquist, mass: (32 + 38 * size) * stream.uniform(in: 0.9...1.1),
                    scaleRadius: scale * stream.uniform(in: 0.9...1.7)),
                diskScaleLength: scale,
                diskTruncation: stream.uniform(in: 3.4...5.6),
                diskThickness: scale * (0.025 + 0.11 * thickness),
                armCount: armCount,
                // Fewer arms carry more contrast; a five-armed flocculent disk wants less.
                armStrength: stream.uniform(in: 0.6...1.0) * (armCount <= 2 ? 1 : 0.75),
                // From an Sa wound tight to an Sc thrown wide open, eleven to forty degrees.
                armPitch: 0.2 + 0.5 * pitch,
                dustFraction: stream.uniform(in: DiskResponse.drawnDust),
                starFormingFraction: stream.uniform(in: 0.008...0.045),
                // Past a fifth of the stars a bulge reads as a swarm of yellow points at any
                // distance worth watching from.
                bulgeExtent: (0.07 + 0.1 * bulge) * stream.uniform(in: 0.8...1.2),
                bulgeFraction: 0.2 * bulge,
                bulgeFlattening: stream.uniform(in: 0.45...0.95),
                // The old disk of a real spiral carries no clumps and a wave of 0.15 to 0.2;
                // the knots and the painted contrast are the young population's. With the
                // streaming the disk holds that wave, and its response keeps it growing arms of
                // its own (docs/notes/lumpy-arms.md).
                clumpiness: stream.uniform(in: 0.02...0.08),
                youngClumpiness: stream.uniform(in: 0.4...0.6),
                armMassContrast: stream.uniform(in: 0.3...0.45),
                armIrregularity: stream.uniform(in: 0.3...0.78),
                // Three to five arms are the disk's own: drawn at Q 1.25 to 1.45, a small, soft
                // or thick disk faded to a smooth one, so its response is drawn instead and Q
                // solved for it, here and among the scene's galaxies in `finishGenerated`, then
                // at every count it runs at. Two arms ride the painted wave the streaming holds
                // and keep the draw of Q unless the disk is small: a stronger response barred
                // them, a weaker one faded them (#181). A large one keeps the response it gives
                // at the reference count, 1.90 at least, at every count (#249).
                toomreQ: stream.uniform(
                    in: armCount <= 2 ? DiskResponse.twoArmedToomreQ : DiskResponse.drawnRange),
                inclination: stream.uniform(in: -1.2...1.2),
                positionAngle: stream.uniform(in: 0...(2 * .pi)),
                spin: stream.uniform() < 0.5 ? .prograde : .retrograde)
            if armCount > 2 {
                galaxy.effectiveToomreQ = galaxy.toomreQ
                galaxy.toomreQ = DiskResponse.toomreQ(
                    effective: galaxy.toomreQ, of: galaxy,
                    softening: DiskResponse.referenceSoftening([galaxy]))
            }
            return galaxy
        case .disk:
            // A lenticular: no arms, little dust and no young stars, a heavier bulge and a
            // hotter, thicker disk.
            let scale = 2.4 + 3 * size
            return GalaxyConfig(
                name: "", particleCount: 0, kind: .disk,
                potential: GalaxyPotential(
                    profile: .hernquist, mass: (36 + 34 * size) * stream.uniform(in: 0.9...1.1),
                    scaleRadius: scale * stream.uniform(in: 0.9...1.5)),
                diskScaleLength: scale,
                diskTruncation: stream.uniform(in: 3.4...5.0),
                diskThickness: scale * (0.06 + 0.12 * thickness),
                armStrength: 0,
                dustFraction: stream.uniform(in: 0.02...0.08),
                starFormingFraction: stream.uniform(in: 0...0.004),
                bulgeExtent: (0.12 + 0.14 * bulge) * stream.uniform(in: 0.8...1.2),
                bulgeFraction: 0.1 + 0.32 * bulge,
                bulgeFlattening: stream.uniform(in: 0.5...0.9),
                clumpiness: stream.uniform(in: 0.02...0.06),
                youngClumpiness: stream.uniform(in: 0.3...0.5),
                toomreQ: stream.uniform(in: 1.4...2.0),
                inclination: stream.uniform(in: -1.2...1.2),
                positionAngle: stream.uniform(in: 0...(2 * .pi)),
                spin: stream.uniform() < 0.5 ? .prograde : .retrograde)
        case .elliptical:
            // A Hernquist sphere is a de Vaucouleurs profile to within the noise, which is
            // what an elliptical is. Cut at five to seven scale radii: further out the envelope
            // is a haze across the whole frame.
            let radius = 1.6 + 2.8 * size
            var galaxy = GalaxyConfig(
                name: "", particleCount: 0, kind: .globular,
                potential: GalaxyPotential(
                    profile: .hernquist, mass: (40 + 40 * size) * stream.uniform(in: 0.9...1.1),
                    scaleRadius: radius),
                diskScaleLength: radius,
                diskTruncation: stream.uniform(in: 5...7))
            galaxy.dustFraction = stream.uniform(in: 0...0.02)
            galaxy.starFormingFraction = 0
            return galaxy
        case .dwarf:
            // Small, puffy, irregular and still forming stars, held by more dark matter than a
            // large disk for its stars.
            let scale = 1 + 1.4 * size
            return GalaxyConfig(
                name: "", particleCount: 0, kind: .disk,
                potential: GalaxyPotential(
                    profile: .hernquist, mass: (4 + 10 * size) * stream.uniform(in: 0.9...1.1),
                    scaleRadius: scale * stream.uniform(in: 1.2...2.2)),
                diskScaleLength: scale,
                diskTruncation: stream.uniform(in: 3.2...4.5),
                diskThickness: scale * (0.12 + 0.18 * thickness),
                armStrength: 0,
                dustFraction: stream.uniform(in: 0.06...0.2),
                starFormingFraction: stream.uniform(in: 0.03...0.07),
                bulgeExtent: 0.1,
                bulgeFraction: 0.04 * bulge,
                // A dwarf is young and clumpy through and through.
                clumpiness: stream.uniform(in: 0.1...0.2),
                youngClumpiness: stream.uniform(in: 0.6...0.8),
                diskMassFraction: stream.uniform(in: 0.1...0.18),
                toomreQ: stream.uniform(in: 1.4...1.9),
                inclination: stream.uniform(in: -1.2...1.2),
                positionAngle: stream.uniform(in: 0...(2 * .pi)),
                spin: stream.uniform() < 0.5 ? .prograde : .retrograde)
        case .blackHole:
            // Weighed and sized by the encounter's mass ratio, the softening with it.
            return .blackHole(mass: 1, softening: GalaxyConfig.blackHoleSoftening(mass: 1))
        case .globular:
            // Small and dense: it punches through a disk rather than orbiting it.
            var galaxy = GalaxyConfig(
                name: "", particleCount: 0, kind: .globular,
                potential: GalaxyPotential(
                    profile: .plummer, mass: (6 + 10 * size) * stream.uniform(in: 0.9...1.1),
                    scaleRadius: 1 + 1.2 * size),
                diskScaleLength: 1.4 + size)
            galaxy.dustFraction = 0.04
            return galaxy
        }
    }

    /// The choice whose cumulative share first passes `u`.
    static func pick<Value>(_ u: Float, _ shares: [(Value, Float)]) -> Value {
        let total = shares.reduce(0) { $0 + $1.1 }
        var running: Float = 0
        for (value, share) in shares {
            running += share / total
            if u < running { return value }
        }
        return shares[shares.count - 1].0
    }

    static func logarithmic(_ u: Float, in range: ClosedRange<Float>) -> Float {
        range.lowerBound * pow(range.upperBound / range.lowerBound, u)
    }
}

extension ClosedRange where Bound == Float {
    fileprivate func at(_ u: Float) -> Float { lowerBound + u * (upperBound - lowerBound) }
}

extension SceneConfig {
    /// The galaxies as a batch counts them, for its pairs and `--galaxies`: a globular or a
    /// dwarf companion is one, a black hole is none.
    public var galaxyCount: Int { galaxies.filter { $0.kind != .blackHole }.count }

    /// Where a scene sits among the scenes the generators draw, as coordinates running over
    /// about [0, 1]: how many galaxies, what the first two are, and the geometry of the first
    /// encounter. Two scenes close here look alike. Nothing about how they are drawn, lit or
    /// framed is in it.
    public var signature: [Float] {
        let companion = encounters.first.map { galaxies[$0.secondary] }
        return [Float(galaxies.count - 1) / 4 * 1.5]
            + Self.signature(of: galaxies.first) + Self.signature(of: companion)
            + Self.signature(of: encounters.first, galaxies: galaxies)
    }

    private static func signature(of galaxy: GalaxyConfig?) -> [Float] {
        guard let galaxy else { return [Float](repeating: 0, count: 8) }
        let spiral = galaxy.kind == .spiral
        let rotating = galaxy.kind.isRotating
        let compact =
            galaxy.kind == .blackHole
            || galaxy.kind == .globular && galaxy.potential.profile == .plummer
        return [
            spiral ? 0.5 : 0, galaxy.kind == .disk ? 0.5 : 0, galaxy.kind == .globular ? 0.5 : 0,
            compact ? 0.5 : 0,
            spiral ? Float(galaxy.armCount - 2) / 3 : 0,
            spiral ? (galaxy.armPitch - 0.2) / 0.5 : 0,
            rotating ? galaxy.bulgeFraction / 0.42 : 0,
            rotating ? galaxy.diskThickness / max(galaxy.diskScaleLength, 0.1) / 0.3 : 0,
        ]
    }

    private static func signature(of encounter: Encounter?, galaxies: [GalaxyConfig]) -> [Float] {
        guard let encounter else { return [Float](repeating: 0, count: 7) }
        func attitude(_ disk: Encounter.Disk, _ index: Int) -> [Float] {
            guard galaxies[index].kind.isRotating else { return [0, 0] }
            return [disk.inclination / (.pi / 2), disk.spin == .retrograde ? 0.5 : 0]
        }
        // The pair as the placement weighs it, the companion taking its mass from the primary.
        let mass = galaxies[encounter.primary].potential.mass * (1 + encounter.massRatio)
        return [
            log(min(max(encounter.massRatio, 0.03), 1) / 0.03) / log(1 / 0.03),
            log(min(max(encounter.pericentre, 1.5), 30) / 1.5) / log(20),
            FreeDraw.approach(
                pericentre: encounter.pericentre, eccentricity: encounter.eccentricity, totalMass: mass),
        ]
            + attitude(encounter.primaryDisk, encounter.primary)
            + attitude(encounter.secondaryDisk, encounter.secondary)
    }
}
