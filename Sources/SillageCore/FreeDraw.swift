import Foundation

/// What a galaxy was drawn as. Finer than `GalaxyKind`, which says how its stars are laid
/// down: an elliptical and a globular are both spheroids, a dwarf is a small disk.
public enum GalaxyFamily: String, Codable, Sendable, CaseIterable {
    case spiral, disk, elliptical, dwarf, globular
}

/// How a scene was drawn, kept in its scene file.
public struct SceneDraw: Codable, Sendable, Equatable {
    /// `free` for `FreeDraw`.
    public var generator: String
    public var batchSeed: UInt64
    /// Place in the batch, from zero.
    public var index: Int
    /// The point of the batch's sequence the scene came from. The points skipped between two
    /// scenes were too close to one already drawn.
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
/// encounter. What only shades it comes from a stream seeded by the point: dust, clumps, the
/// orbital plane, and every galaxy past the second. A candidate too close to a scene already
/// in the batch, by `SceneConfig.signature`, is passed over.
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

    /// The scene at a place in the batch, ready to run.
    public func scene(at index: Int, particleCount: Int) -> SceneConfig {
        var scene = drafts(index + 1, particleCount: particleCount)[index]
        var finish = SeededGenerator(seed: scene.seed ^ 0x4649_4E49_5348_4544)
        scene.finishGenerated(using: &finish)
        return scene
    }

    /// The batch's first scenes as drawn, before anything is placed: what `signature` reads.
    public func drafts(_ count: Int, particleCount: Int) -> [SceneConfig] {
        var kept: [SceneConfig] = []
        var signatures: [[Float]] = []
        var point = 1
        while kept.count < count {
            var best: (scene: SceneConfig, signature: [Float], gap: Float)?
            for _ in 0..<Self.patience {
                let candidate = draft(point: point, particleCount: particleCount)
                point += 1
                let signature = candidate.signature
                let gap = signatures.map { Self.distance($0, signature) }.min() ?? .infinity
                if best == nil || gap > best!.gap { best = (candidate, signature, gap) }
                if gap >= spacing { break }
            }
            guard var chosen = best else { break }
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
        case secondaryBulge, secondaryThickness, pericentre, eccentricity, primaryInclination
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
    static let names = ["Première", "Deuxième", "Troisième", "Quatrième", "Cinquième"]

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
            let along =
                first
                ? 0.15 + 0.45 * at(.pericentreTime)
                : 0.15 + 0.7 * (Float(index - 1) + stream.uniform(in: 0.2...0.8)) / Float(count - 1)
            var meeting = Encounter(
                primary: primary, secondary: index,
                pericentre: Self.logarithmic(
                    first ? at(.pericentre) : stream.uniform(), in: minor ? 1.5...20 : 2...30),
                eccentricity: (minor ? 0.8...2.2 : 0.7...1.6).at(
                    first ? at(.eccentricity) : stream.uniform()),
                massRatio: Self.logarithmic(
                    first ? at(.massRatio) : stream.uniform(), in: Self.massRatios(family)),
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
        var scene = SceneConfig(name: "Libre", galaxies: galaxies, centerSoftening: 1.2)
        scene.encounters = encounters
        scene.seed = seed
        scene.draw = SceneDraw(
            generator: Self.generator, batchSeed: batchSeed, index: 0, point: point,
            families: families)
        return scene
    }

    /// The range of mass ratios a companion of a family is drawn from, against the galaxy it
    /// passes.
    static func massRatios(_ family: GalaxyFamily) -> ClosedRange<Float> {
        switch family {
        case .spiral, .disk: 0.2...1
        case .elliptical: 0.25...1
        case .dwarf: 0.03...0.2
        case .globular: 0.08...0.3
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
            return GalaxyConfig(
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
                dustFraction: stream.uniform(in: 0.14...0.38),
                starFormingFraction: stream.uniform(in: 0.008...0.045),
                // Past a fifth of the stars a bulge reads as a swarm of yellow points at any
                // distance worth watching from.
                bulgeExtent: (0.07 + 0.1 * bulge) * stream.uniform(in: 0.8...1.2),
                bulgeFraction: 0.2 * bulge,
                bulgeFlattening: stream.uniform(in: 0.45...0.95),
                clumpiness: stream.uniform(in: 0.18...0.44),
                armIrregularity: stream.uniform(in: 0.3...0.78),
                toomreQ: stream.uniform(in: 1.25...1.7),
                inclination: stream.uniform(in: -1.2...1.2),
                positionAngle: stream.uniform(in: 0...(2 * .pi)),
                spin: stream.uniform() < 0.5 ? .prograde : .retrograde)
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
                clumpiness: stream.uniform(in: 0.06...0.16),
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
                clumpiness: stream.uniform(in: 0.3...0.5),
                diskMassFraction: stream.uniform(in: 0.1...0.18),
                toomreQ: stream.uniform(in: 1.4...1.9),
                inclination: stream.uniform(in: -1.2...1.2),
                positionAngle: stream.uniform(in: 0...(2 * .pi)),
                spin: stream.uniform() < 0.5 ? .prograde : .retrograde)
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
        let compact = galaxy.kind == .globular && galaxy.potential.profile == .plummer
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
        return [
            log(min(max(encounter.massRatio, 0.03), 1) / 0.03) / log(1 / 0.03),
            log(min(max(encounter.pericentre, 1.5), 30) / 1.5) / log(20),
            (min(max(encounter.eccentricity, 0.7), 2.2) - 0.7) / 1.5,
        ]
            + attitude(encounter.primaryDisk, encounter.primary)
            + attitude(encounter.secondaryDisk, encounter.secondary)
    }
}
