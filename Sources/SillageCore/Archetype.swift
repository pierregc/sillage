import Foundation

/// A known interacting system as a starting point: the galaxies it is made of and the geometry
/// of their encounters, each drawn from ranges of its own, narrow enough that the scene reads
/// as what it is named after and wide enough that no two come out alike. Physics only, as for
/// `FreeDraw`.
public enum Archetype: String, Codable, Sendable, CaseIterable {
    /// NGC 4038/9. Two comparable spirals, both prograde and steeply inclined, on a bound orbit
    /// that brings them back together while their two long tails cross.
    case antennae
    /// NGC 4676. Two comparable early-type disks just after a close prograde passage, one near
    /// the orbital plane and one steep, each trailing a long straight tail.
    case mice
    /// The Cartwheel. A compact companion dropped through a disk along its axis, near the
    /// centre and fast, so the disk answers with a ring running outwards.
    case ring
    /// UGC 10214. A small dense intruder on a prograde pass near the plane of a large spiral,
    /// which throws out one long tail.
    case tadpole
    /// NGC 4650A. A dwarf torn apart on a polar orbit round a lenticular, its stars wound into a
    /// ring across the host's poles.
    case polarRing = "polar-ring"
    /// A large spiral swallowing a satellite a few per cent to a fifth of its mass.
    case minorMerger = "minor-merger"
    /// Stephan's Quintet. Four or five galaxies close together, passing the largest in turn,
    /// and an intruder arriving fast later in the clip.
    case compactGroup = "compact-group"

    /// Coordinates of the sequence an archetype draws its first parameters from.
    static let dimensions = 10

    /// The archetype's scene number `occurrence` in batch `batchSeed`, ready to run. Nothing
    /// else goes into it, so it is the same scene wherever the batch puts it.
    public func scene(
        batchSeed: UInt64, occurrence: Int, particleCount: Int, haste: Float = 0
    ) -> SceneConfig {
        var scene = draft(
            batchSeed: batchSeed, occurrence: occurrence, particleCount: particleCount,
            haste: haste)
        var finish = SeededGenerator(seed: scene.seed ^ 0x4649_4E49_5348_4544)
        scene.finishGenerated(using: &finish)
        return scene
    }

    /// Shifts the batch seed so each archetype runs a sequence of its own, spreading its scenes
    /// over its own ranges. Taken from the name rather than the order, so adding an archetype
    /// leaves the others' scenes where they were.
    var salt: UInt64 {
        rawValue.utf8.reduce(0xCBF2_9CE4_8422_2325) { ($0 ^ UInt64($1)) &* 0x100_0000_01B3 }
    }

    func draft(batchSeed: UInt64, occurrence: Int, particleCount: Int, haste: Float) -> SceneConfig {
        let sequenceSeed = batchSeed ^ salt
        let point = occurrence + 1
        var mixer = SeededGenerator(seed: sequenceSeed ^ (UInt64(point) &* 0x9E37_79B9_7F4A_7C15))
        let seed = mixer.next()
        var looks = SeededGenerator(seed: SceneConfig.lookSeed(for: seed))
        let palette = SceneConfig.Palette.all[Int(looks.next() % UInt64(SceneConfig.Palette.all.count))]
        var draft = Draft(
            draws: Draws(
                point: Sobol(dimensions: Self.dimensions, seed: sequenceSeed).point(point),
                seed: seed),
            window: SceneConfig.contemplationWindow(haste: haste))
        shape(&draft)

        var galaxies = draft.galaxies
        let count = galaxies.count
        for index in galaxies.indices {
            galaxies[index].name = FreeDraw.names[index]
            galaxies[index].color = index % 2 == 0 ? palette.primary : palette.secondary
            // Shared out again by mass once the encounters are placed.
            galaxies[index].particleCount =
                index == 0
                ? particleCount - particleCount / count * (count - 1) : particleCount / count
        }
        var scene = SceneConfig(name: "Archétype", galaxies: galaxies, centerSoftening: 1.2)
        scene.encounters = draft.encounters
        scene.seed = seed
        scene.draw = SceneDraw(
            generator: rawValue, batchSeed: batchSeed, index: occurrence, point: point,
            families: draft.families)
        return scene
    }

    /// The galaxies and their encounters. What sets the archetype apart is drawn first, from
    /// the sequence; what only shades it comes after, from the stream.
    private func shape(_ d: inout Draft) {
        switch self {
        case .antennae:
            // Toomre & Toomre 1972 and Barnes 1988: equal disks inclined about sixty degrees,
            // both prograde, falling back within a few hundred megayears.
            let pericentre = d.draws.uniform(in: 5...11)
            let eccentricity = d.draws.uniform(in: 0.8...1)
            let ratio = d.draws.uniform(in: 0.7...1)
            let tilts = (d.draws.uniform(in: 0.6...1.25), d.draws.uniform(in: 0.6...1.25))
            let along = d.draws.uniform(in: 0.08...0.25)
            let sizes = (d.draws.uniform(in: 0.5...1), d.draws.uniform(in: 0.45...0.95))
            let bulges = (d.draws.uniform(in: 0...0.4), d.draws.uniform(in: 0...0.4))
            d.add(.spiral, size: sizes.0, bulge: bulges.0, thickness: d.draws.uniform(in: 0...0.4))
            d.add(.spiral, size: sizes.1, bulge: bulges.1, thickness: d.draws.uniform(in: 0...0.4))
            d.meet(
                0, 1, pericentre: pericentre, eccentricity: eccentricity, massRatio: ratio,
                along: along, primaryDisk: d.disk(tilts.0), secondaryDisk: d.disk(tilts.1))

        case .mice:
            // Seen soon after the first passage, so the tails are long and still straight.
            let pericentre = d.draws.uniform(in: 7...14)
            let eccentricity = d.draws.uniform(in: 0.95...1.1)
            let ratio = d.draws.uniform(in: 0.6...1)
            let flat = d.draws.uniform(in: 0...0.45)
            let steep = d.draws.uniform(in: 0.8...1.4)
            let along = d.draws.uniform(in: 0.25...0.45)
            let sizes = (d.draws.uniform(in: 0.4...0.9), d.draws.uniform(in: 0.4...0.9))
            let bulges = (d.draws.uniform(in: 0.4...1), d.draws.uniform(in: 0.3...0.9))
            let lenticular = d.draws.uniform() < 0.4
            d.add(
                lenticular ? .disk : .spiral, size: sizes.0, bulge: bulges.0,
                thickness: d.draws.uniform(in: 0...0.5))
            d.add(.spiral, size: sizes.1, bulge: bulges.1, thickness: d.draws.uniform(in: 0...0.5))
            d.meet(
                0, 1, pericentre: pericentre, eccentricity: eccentricity, massRatio: ratio,
                along: along, primaryDisk: d.disk(flat), secondaryDisk: d.disk(steep))

        case .ring:
            // Lynds & Toomre 1976. The disk's axis lies along the companion's path at
            // pericentre, which is where it crosses the disk, so the hit is square on; a
            // close pass through an extended potential runs nearly straight. A little off
            // the axis and off the centre still makes a ring, only lopsided.
            let pericentre = d.draws.logarithmic(in: 0.4...3)
            let ratio = d.draws.uniform(in: 0.15...0.45)
            let eccentricity = d.draws.uniform(in: 1...1.2)
            let along = d.draws.uniform(in: 0.2...0.4)
            let offAxis = d.draws.uniform(in: 0...0.3)
            let size = d.draws.uniform(in: 0.4...1)
            let compact = d.draws.uniform() < 0.65
            let lenticular = d.draws.uniform() < 0.35
            let side: Float = d.draws.uniform() < 0.5 ? 0 : .pi
            let skew = d.draws.uniform(in: -0.2...0.2)
            d.add(
                lenticular ? .disk : .spiral, size: size, bulge: d.draws.uniform(in: 0...0.35),
                thickness: d.draws.uniform(in: 0...0.5))
            d.add(
                compact ? .globular : .elliptical, size: d.draws.uniform(in: 0...0.35),
                bulge: 0, thickness: 0)
            d.meet(
                0, 1, pericentre: pericentre, eccentricity: eccentricity, massRatio: ratio,
                along: along,
                primaryDisk: Encounter.Disk(
                    inclination: .pi / 2 - offAxis, argument: side + skew,
                    spin: d.draws.stream.uniform() < 0.5 ? .prograde : .retrograde),
                secondaryDisk: d.disk(0))

        case .tadpole:
            let pericentre = d.draws.uniform(in: 8...16)
            let ratio = d.draws.logarithmic(in: 0.06...0.2)
            let eccentricity = d.draws.uniform(in: 1.1...1.35)
            let tilt = d.draws.uniform(in: 0...0.5)
            let along = d.draws.uniform(in: 0.15...0.35)
            let size = d.draws.uniform(in: 0.5...1)
            let compact = d.draws.uniform() < 0.7
            d.add(
                .spiral, size: size, bulge: d.draws.uniform(in: 0...0.4),
                thickness: d.draws.uniform(in: 0...0.4))
            d.add(
                compact ? .globular : .dwarf, size: d.draws.uniform(in: 0...0.6), bulge: 0,
                thickness: d.draws.uniform())
            d.meet(
                0, 1, pericentre: pericentre, eccentricity: eccentricity, massRatio: ratio,
                along: along, primaryDisk: d.disk(tilt), secondaryDisk: d.disk(d.draws.uniform() * .pi / 2))

        case .polarRing:
            // Reshetnikov & Sotnikova 1997, Bournaud & Combes 2003: a satellite torn apart on a
            // polar orbit. The host's axis lies in the orbital plane and the satellite's disk
            // turns with the orbit in that plane, the passage that strips a disk hardest, so
            // its stars spread along the orbit and close into a ring across the host's poles.
            // Heavy enough that the ring holds enough stars to be seen.
            let pericentre = d.draws.uniform(in: 8...14)
            let eccentricity = Self.eccentricity(pericentre, apocentre: d.draws.uniform(in: 25...45))
            let ratio = d.draws.uniform(in: 0.2...0.4)
            let offPolar = d.draws.uniform(in: 0...0.2)
            let along = d.draws.uniform(in: 0.02...0.1)
            let size = d.draws.uniform(in: 0.4...0.9)
            let bulge = d.draws.uniform(in: 0.3...0.9)
            let tilt = d.draws.uniform(in: 0...0.3)
            d.add(.disk, size: size, bulge: bulge, thickness: d.draws.uniform(in: 0...0.5))
            d.add(.dwarf, size: d.draws.uniform(in: 0.5...1), bulge: 0, thickness: d.draws.uniform())
            // Looser than a free dwarf, so it comes apart rather than losing only its edge.
            d.galaxies[1].potential.scaleRadius *= 1.5
            d.galaxies[1].diskScaleLength *= 1.3
            d.galaxies[1].diskThickness *= 1.3
            d.meet(
                0, 1, pericentre: pericentre, eccentricity: eccentricity, massRatio: ratio,
                along: along, primaryDisk: d.disk(.pi / 2 - offPolar), secondaryDisk: d.disk(tilt))

        case .minorMerger:
            let pericentre = d.draws.uniform(in: 4...12)
            let eccentricity = Self.eccentricity(pericentre, apocentre: d.draws.uniform(in: 30...55))
            let ratio = d.draws.logarithmic(in: 0.05...0.2)
            let tilt = d.draws.uniform(in: 0...1.2)
            let along = d.draws.uniform(in: 0.02...0.12)
            let size = d.draws.uniform(in: 0.5...1)
            let satellite = FreeDraw.pick(
                d.draws.uniform(), [(GalaxyFamily.dwarf, Float(0.5)), (.globular, 0.25), (.spiral, 0.25)])
            d.add(
                .spiral, size: size, bulge: d.draws.uniform(in: 0...0.5),
                thickness: d.draws.uniform(in: 0...0.4))
            d.add(
                satellite, size: d.draws.uniform(in: 0...0.3), bulge: d.draws.uniform(),
                thickness: d.draws.uniform())
            let spin: Spin = d.draws.stream.uniform() < 0.7 ? .prograde : .retrograde
            d.meet(
                0, 1, pericentre: pericentre, eccentricity: eccentricity, massRatio: ratio,
                along: along, primaryDisk: d.disk(tilt, spin: spin),
                secondaryDisk: d.disk(d.draws.uniform() * .pi / 2))

        case .compactGroup:
            // The members pass the largest galaxy wide and one after another early in the clip,
            // so the group gathers and stays a group rather than one merger, and the intruder
            // arrives fast and later. The passages are placed latest first: a galaxy
            // stepped back from its pericentre then only meets the largest one before any
            // other passage has thrown it about, which is what kept them from being placed.
            let count = d.draws.uniform() < 0.5 ? 4 : 5
            let elliptical = d.draws.uniform() < 0.4
            let size = d.draws.uniform(in: 0.6...1)
            let pericentre = d.draws.uniform(in: 12...25)
            let eccentricity = d.draws.uniform(in: 1.05...1.25)
            let ratio = d.draws.uniform(in: 0.25...0.6)
            let first = d.draws.uniform(in: 0.05...0.2)
            let intruder = (
                pericentre: d.draws.uniform(in: 8...16), eccentricity: d.draws.uniform(in: 1.3...1.6),
                along: d.draws.uniform(in: 0.5...0.7)
            )
            d.add(
                elliptical ? .elliptical : .spiral, size: size, bulge: d.draws.uniform(in: 0...0.6),
                thickness: d.draws.uniform(in: 0...0.5))
            for index in 1..<count {
                let family: GalaxyFamily =
                    index == count - 1
                    ? .spiral
                    : FreeDraw.pick(
                        d.draws.uniform(),
                        [(.spiral, 0.45), (.elliptical, 0.25), (.disk, 0.2), (.dwarf, 0.1)])
                d.add(
                    family, size: d.draws.uniform(in: 0.2...0.8), bulge: d.draws.uniform(in: 0...0.6),
                    thickness: d.draws.uniform(in: 0...0.5))
            }
            for index in stride(from: count - 1, through: 1, by: -1) {
                let last = index == count - 1
                let member = (
                    pericentre: index == 1 ? pericentre : d.draws.uniform(in: 15...30),
                    eccentricity: index == 1 ? eccentricity : d.draws.uniform(in: 1.05...1.25),
                    massRatio: index == 1 ? ratio : d.draws.uniform(in: 0.25...0.6),
                    along: first + 0.25 * Float(index - 1) / Float(max(count - 2, 1))
                )
                d.meet(
                    0, index, pericentre: last ? intruder.pericentre : member.pericentre,
                    eccentricity: last ? intruder.eccentricity : member.eccentricity,
                    massRatio: d.families[index] == .dwarf
                        ? d.draws.logarithmic(in: 0.05...0.2) : member.massRatio,
                    along: last ? intruder.along : member.along,
                    primaryDisk: d.disk(d.draws.uniform() * .pi / 2, spin: d.draws.spin()),
                    secondaryDisk: d.disk(d.draws.uniform() * .pi / 2, spin: d.draws.spin()))
            }
        }
    }

    /// A bound orbit set by how far out it swings rather than by its eccentricity. Far enough
    /// that it is still falling in when the clip opens, which a first passage has to be, and
    /// near enough that the satellite does not swing out of the frame.
    private static func eccentricity(_ pericentre: Float, apocentre: Float) -> Float {
        (apocentre - pericentre) / (apocentre + pericentre)
    }
}

/// The numbers one scene is drawn from: the sequence's coordinates first, so the parameters
/// drawn first spread evenly over a batch, then a stream seeded by the scene.
struct Draws {
    private let point: [Float]
    private var used = 0
    var stream: SeededGenerator

    init(point: [Float], seed: UInt64) {
        self.point = point
        stream = SeededGenerator(seed: seed)
    }

    mutating func uniform() -> Float {
        defer { used += 1 }
        return used < point.count ? point[used] : stream.uniform()
    }

    mutating func uniform(in range: ClosedRange<Float>) -> Float {
        range.lowerBound + uniform() * (range.upperBound - range.lowerBound)
    }

    mutating func logarithmic(in range: ClosedRange<Float>) -> Float {
        FreeDraw.logarithmic(uniform(), in: range)
    }

    /// Prograde more often than not, as the free draws have it.
    mutating func spin() -> Spin { uniform() < 0.65 ? .prograde : .retrograde }
}

/// A scene as it is being drawn.
private struct Draft {
    var draws: Draws
    let window: ClosedRange<Float>
    var families: [GalaxyFamily] = []
    var galaxies: [GalaxyConfig] = []
    var encounters: [Encounter] = []

    init(draws: Draws, window: ClosedRange<Float>) {
        self.draws = draws
        self.window = window
    }

    /// A galaxy of a family, at positions in [0, 1) within that family's ranges.
    mutating func add(_ family: GalaxyFamily, size: Float, bulge: Float, thickness: Float) {
        let arms = draws.stream.uniform()
        let pitch = draws.stream.uniform()
        families.append(family)
        galaxies.append(
            FreeDraw.galaxy(
                family, size: size, arms: arms, pitch: pitch, bulge: bulge, thickness: thickness,
                stream: &draws.stream))
    }

    /// A disk's attitude against its orbit, its line of nodes anywhere.
    mutating func disk(_ inclination: Float, spin: Spin = .prograde) -> Encounter.Disk {
        Encounter.Disk(
            inclination: inclination, argument: draws.stream.uniform(in: 0...(2 * .pi)), spin: spin)
    }

    /// An encounter whose pericentre falls `along` the window, its orbital plane anywhere:
    /// where the orbit lies in the scene is a matter of viewpoint, not of shape.
    mutating func meet(
        _ primary: Int, _ secondary: Int, pericentre: Float, eccentricity: Float, massRatio: Float,
        along: Float, primaryDisk: Encounter.Disk, secondaryDisk: Encounter.Disk
    ) {
        var meeting = Encounter(
            primary: primary, secondary: secondary, pericentre: pericentre,
            eccentricity: eccentricity, massRatio: massRatio,
            pericentreTime: window.lowerBound + along * (window.upperBound - window.lowerBound),
            primaryDisk: primaryDisk, secondaryDisk: secondaryDisk)
        meeting.planeTilt = draws.stream.uniform(in: -0.7...0.7)
        meeting.planeTurn = draws.stream.uniform(in: 0...(2 * .pi))
        meeting.pericentreAngle = draws.stream.uniform(in: 0...(2 * .pi))
        encounters.append(meeting)
    }
}

/// A batch as the generators draw it: archetypes and free draws mixed in a set proportion.
///
/// Which places are archetypes follows from the share alone, so every stretch of a batch holds
/// its share, and the archetypes come round in a shuffled order, each once a round. The free
/// places take `FreeDraw`'s scenes in order, so a batch with no archetypes is the free one.
public struct BatchDraw: Sendable {
    /// One scene in four: each archetype once in every 28 scenes.
    public static let defaultArchetypeShare: Float = 0.25

    public var free: FreeDraw
    public var archetypeShare: Float

    public enum Place: Equatable, Sendable {
        /// The free draw at this place among the free ones.
        case free(Int)
        case archetype(Archetype, occurrence: Int)
    }

    public init(
        batchSeed: UInt64, archetypeShare: Float = BatchDraw.defaultArchetypeShare,
        spacing: Float = FreeDraw.defaultSpacing, haste: Float = 0
    ) {
        free = FreeDraw(batchSeed: batchSeed, spacing: spacing, haste: haste)
        self.archetypeShare = min(max(archetypeShare, 0), 1)
    }

    /// Archetypes among the first `count` places.
    private func archetypes(before count: Int) -> Int {
        Int((Double(count) * Double(archetypeShare)).rounded(.down))
    }

    public func place(_ index: Int) -> Place {
        let before = archetypes(before: index)
        guard archetypes(before: index + 1) > before else { return .free(index - before) }
        let all = Archetype.allCases
        let round = before / all.count
        // Fisher-Yates by hand: the standard shuffle is free to change between releases.
        var order = all
        var generator = SeededGenerator(seed: free.batchSeed ^ 0x4152_4348_4554_5950 ^ UInt64(round))
        for index in stride(from: order.count - 1, to: 0, by: -1) {
            order.swapAt(index, Int(generator.next() % UInt64(index + 1)))
        }
        return .archetype(order[before % all.count], occurrence: round)
    }

    /// The scene at a place in the batch, ready to run.
    public func scene(at index: Int, particleCount: Int) -> SceneConfig {
        var scene: SceneConfig
        switch place(index) {
        case .free(let index):
            scene = free.scene(at: index, particleCount: particleCount)
        case .archetype(let archetype, let occurrence):
            scene = archetype.scene(
                batchSeed: free.batchSeed, occurrence: occurrence, particleCount: particleCount,
                haste: free.haste)
        }
        scene.draw?.index = index
        return scene
    }
}
