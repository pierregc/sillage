/// Light tracers (#187): a sample drawn at the count that is wanted on screen, of which only a
/// share carries the mass. The rest follow the same orbits in the field of the massive ones,
/// since in a collisionless system a massless particle drawn from the same distribution moves
/// as a massive one does, and they do not shrink the softening or the step.
extension ParticleSystem {
    /// A run drawn at `drawn` whose mass `massive` carries, the same scene at fewer particles
    /// (#211): the visible particles sampled at the drawn count, the dark matter at the massive
    /// one, then split. Drawn at the drawn count, three quarters of the halo of an 8 M run from
    /// 2 M were sampled only to be thrown away.
    public static func lightTracers(drawn: SceneConfig, massive: SceneConfig) -> (
        system: ParticleSystem, tracers: Int
    ) {
        RestrictedSolver.sampleParticles(
            for: drawn, haloCounts: massive.galaxies.map(\.haloParticleCount)
        ).splittingLightTracers(massive: massive.totalParticleCount, seed: massive.seed)
    }

    /// Keeps about `massive` of the visible particles as the massive set, and makes every other
    /// visible particle a massless tracer. The dark matter is all kept: it is drawn at the
    /// massive count (`lightTracers(drawn:massive:)`). Laid out tracers first,
    /// `[tracers | massive visible | massive halo]`, so the tree can be built over everything
    /// after them while the visible ones stay one run.
    ///
    /// The kept particles of each galaxy carry all of its visible mass between them. Black holes
    /// are always kept, with their own mass. Which particles are kept depends on the seed and
    /// the index only.
    public func splittingLightTracers(massive: Int, seed: UInt64) -> (
        system: ParticleSystem, tracers: Int
    ) {
        let visible = visibleCount > 0 ? visibleCount : count
        let share = min(max(Double(massive) / Double(max(visible, 1)), 0), 1)
        let hole = ParticleComponent.hole.rawValue
        let halo = ParticleComponent.halo.rawValue
        var tracers: [Int] = []
        var keptVisible: [Int] = []
        var keptHalo: [Int] = []
        tracers.reserveCapacity(Int(Double(visible) * (1 - share)) + 1024)
        for index in 0..<count {
            let kind = index < component.count ? component[index] : 0
            let kept = kind == hole || kind == halo || Self.unit(index, seed) < share
            if kind == halo {
                if kept { keptHalo.append(index) }
            } else if kept {
                keptVisible.append(index)
            } else {
                tracers.append(index)
            }
        }

        // What each galaxy's kept particles must weigh: all of its visible mass.
        let galaxies = Int(galaxyIndex.max() ?? 0) + 1
        var total = [Double](repeating: 0, count: galaxies * 2)
        var held = total
        for index in 0..<count where index < mass.count && component[index] != hole {
            let slot = Int(galaxyIndex[index]) * 2 + (component[index] == halo ? 1 : 0)
            total[slot] += Double(mass[index])
        }
        for index in keptVisible + keptHalo where component[index] != hole {
            let slot = Int(galaxyIndex[index]) * 2 + (component[index] == halo ? 1 : 0)
            held[slot] += Double(mass[index])
        }

        let order = tracers + keptVisible + keptHalo
        var split = ParticleSystem(capacity: order.count)
        for (place, index) in order.enumerated() {
            var weight: Float = 0
            if place >= tracers.count, index < mass.count {
                if component[index] == hole {
                    weight = mass[index]
                } else {
                    let slot = Int(galaxyIndex[index]) * 2 + (component[index] == halo ? 1 : 0)
                    weight = held[slot] > 0 ? Float(Double(mass[index]) * total[slot] / held[slot]) : 0
                }
            }
            split.append(
                position: positions[index], velocity: velocities[index], galaxy: galaxyIndex[index],
                radius: birthRadius[index], population: population[index],
                luminosity: luminosity[index], formation: formation[index],
                component: ParticleComponent(rawValue: component[index]) ?? .star, mass: weight,
                kernelScale: kernelScale[index])
        }
        split.setVisibleCount(tracers.count + keptVisible.count)
        return (split, tracers.count)
    }

    /// Samples `drawn` and splits it exactly as `lightTracers(drawn:massive:)` does, but hands
    /// the tracers to `emit` in chunks of `chunk` as they are drawn and keeps only the massive
    /// set, `[massive visible | massive halo]` (#238). The drawn count is never held as full
    /// particles: at 64 bytes each that copy alone was 6.4 GB at 100 M.
    public static func streamingLightTracers(
        drawn: SceneConfig, massive: SceneConfig, chunk: Int = 1 << 20,
        emit: (LightTracerChunk) -> Void
    ) -> (massive: ParticleSystem, tracers: Int) {
        let visible = drawnVisibleCount(drawn)
        let haloCounts = massive.galaxies.map(\.haloParticleCount)
        let slots = max(drawn.galaxies.count, 1) * 2
        return withoutActuallyEscaping(emit) { emit in
            var split = LightTracerSplit(
                share: min(max(Double(massive.totalParticleCount) / Double(max(visible, 1)), 0), 1),
                seed: massive.seed, chunkSize: max(chunk, 1), emit: emit,
                kept: ParticleSystem(capacity: massive.totalParticleCount + 1024),
                halo: ParticleSystem(capacity: haloCounts.reduce(0, +)),
                total: [Double](repeating: 0, count: slots),
                held: [Double](repeating: 0, count: slots))
            var generator = SeededGenerator(seed: drawn.seed)
            let selfGravitating = drawn.solver == .barnesHut
            for (index, galaxy) in drawn.galaxies.enumerated() {
                DiskSampler.sample(
                    galaxy, galaxyIndex: UInt32(index), selfGravitating: selfGravitating,
                    haloCount: index < haloCounts.count ? haloCounts[index] : nil,
                    into: &split, using: &generator)
            }
            split.flush()
            return (split.massiveSet(), split.tracers)
        }
    }

    /// Every particle `streamingLightTracers` hands on or keeps, tracers and massive alike.
    public static func lightTracerTotal(drawn: SceneConfig, massive: SceneConfig) -> Int {
        guard drawn.solver == .barnesHut else { return drawnVisibleCount(drawn) }
        let halo = drawn.galaxies.indices.reduce(0) { sum, index in
            drawn.galaxies[index].haloParticleCount > 0 && index < massive.galaxies.count
                ? sum + massive.galaxies[index].haloParticleCount : sum
        }
        return drawnVisibleCount(drawn) + halo
    }

    /// What the sampler draws visible: a black hole is one particle whatever its count says.
    static func drawnVisibleCount(_ scene: SceneConfig) -> Int {
        scene.galaxies.reduce(0) { $0 + ($1.kind == .blackHole ? 1 : max($1.particleCount, 0)) }
    }

    /// Appends every particle of `other`, in order.
    public mutating func append(contentsOf other: ParticleSystem) {
        positions += other.positions
        velocities += other.velocities
        galaxyIndex += other.galaxyIndex
        birthRadius += other.birthRadius
        population += other.population
        luminosity += other.luminosity
        formation += other.formation
        component += other.component
        mass += other.mass
        kernelScale += other.kernelScale
    }

    /// The particles `range` of this system, as a system of their own.
    public func slice(_ range: Range<Int>) -> ParticleSystem {
        var part = ParticleSystem(capacity: range.count)
        for index in range {
            part.append(
                position: positions[index], velocity: velocities[index], galaxy: galaxyIndex[index],
                radius: birthRadius[index], population: population[index],
                luminosity: luminosity[index], formation: formation[index],
                component: ParticleComponent(rawValue: component[index]) ?? .star,
                mass: index < mass.count ? mass[index] : 0, kernelScale: kernelScale[index])
        }
        part.setVisibleCount(min(max(visibleCount - range.lowerBound, 0), range.count))
        return part
    }

    /// A uniform number in [0, 1) from an index and a seed.
    static func unit(_ index: Int, _ seed: UInt64) -> Double {
        var z = seed &+ UInt64(truncatingIfNeeded: index) &* 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) * 0x1p-53
    }
}

/// A light tracer's attributes in 32 bits (#238): its galaxy, what it is, how wide its kernel
/// is drawn, its light and its birth radius. With its position, its velocity and when its
/// stars formed, that is all a tracer holds. The light is kept in log steps of 5.6 %, the
/// radius in steps of 0.1 %.
public struct TracerWord: Hashable, Sendable {
    public var bits: UInt32

    /// Galaxies a run with light tracers may hold, black holes included.
    public static let galaxyLimit = 16
    /// The kernel scales the sampler draws, by class.
    public static let kernelScales: [Float] = [1, 0.75, 0.9, 2.2, 1.35]
    static let light = (floor: Float(-12), octaves: Float(20), codes: UInt32(255))
    static let radius = (floor: Float(-12), octaves: Float(24), codes: UInt32(16_383))

    public init(bits: UInt32) { self.bits = bits }

    public init(
        galaxy: UInt32, component: UInt32, kernelScale: Float, luminosity: Float,
        birthRadius: Float
    ) {
        let scales = Self.kernelScales
        let kernel = scales.indices.min { abs(scales[$0] - kernelScale) < abs(scales[$1] - kernelScale) } ?? 0
        bits =
            (galaxy & 15) | (component & 7) << 4 | UInt32(kernel) << 7
            | Self.code(luminosity, Self.light) << 10 | Self.code(birthRadius, Self.radius) << 18
    }

    public var galaxy: UInt32 { bits & 15 }
    public var component: UInt32 { (bits >> 4) & 7 }
    public var kernelScale: Float {
        let kernel = Int((bits >> 7) & 7)
        return kernel < Self.kernelScales.count ? Self.kernelScales[kernel] : 1
    }
    public var luminosity: Float { Self.value((bits >> 10) & 255, Self.light) }
    public var birthRadius: Float { Self.value(bits >> 18, Self.radius) }

    /// 0 for nothing, then `codes` log steps from 2^floor over `octaves`.
    static func code(_ value: Float, _ scale: (floor: Float, octaves: Float, codes: UInt32)) -> UInt32 {
        guard value > 0, value.isFinite else { return 0 }
        let at = ((log2(value) - scale.floor) * Float(scale.codes - 1) / scale.octaves).rounded()
        return UInt32(min(max(at, 0), Float(scale.codes - 1))) + 1
    }

    static func value(_ code: UInt32, _ scale: (floor: Float, octaves: Float, codes: UInt32)) -> Float {
        code == 0 ? 0 : exp2(Float(code - 1) * scale.octaves / Float(scale.codes - 1) + scale.floor)
    }
}

/// Light tracers as the solver lays them out (#238), a chunk at a time: the position with the
/// formation time in w, then the velocity as bit patterns with the `TracerWord` in w.
public struct LightTracerChunk: Sendable {
    public var states: [SIMD4<Float>] = []
    public var motions: [SIMD4<UInt32>] = []

    public init() {}

    public var count: Int { states.count }

    public mutating func append(
        position: SIMD3<Float>, velocity: SIMD3<Float>, formation: Float, word: TracerWord
    ) {
        states.append(SIMD4<Float>(position, formation))
        motions.append(
            SIMD4<UInt32>(
                velocity.x.bitPattern, velocity.y.bitPattern, velocity.z.bitPattern, word.bits))
    }

    public mutating func removeAll() {
        states.removeAll(keepingCapacity: true)
        motions.removeAll(keepingCapacity: true)
    }
}

/// `splittingLightTracers` made while the sampler draws: the same particles kept, the same
/// sums in the same order, so the same massive set to the bit.
struct LightTracerSplit: ParticleSink {
    let share: Double
    let seed: UInt64
    let chunkSize: Int
    let emit: (LightTracerChunk) -> Void
    var kept: ParticleSystem
    var halo: ParticleSystem
    /// Each galaxy's visible and dark mass, all of it, then what the kept particles hold.
    var total: [Double]
    var held: [Double]
    var visible = 0
    var tracers = 0
    var chunk = LightTracerChunk()

    init(
        share: Double, seed: UInt64, chunkSize: Int, emit: @escaping (LightTracerChunk) -> Void,
        kept: ParticleSystem, halo: ParticleSystem, total: [Double], held: [Double]
    ) {
        self.share = share
        self.seed = seed
        self.chunkSize = chunkSize
        self.emit = emit
        self.kept = kept
        self.halo = halo
        self.total = total
        self.held = held
    }

    mutating func append(
        position: SIMD3<Float>, velocity: SIMD3<Float>, galaxy: UInt32, radius: Float,
        population: Float, luminosity: Float, formation: Float, component: ParticleComponent,
        mass: Float, kernelScale: Float
    ) {
        let dark = component == .halo
        let slot = Int(galaxy) * 2 + (dark ? 1 : 0)
        if slot >= total.count {
            total += [Double](repeating: 0, count: slot + 2 - total.count)
            held += [Double](repeating: 0, count: slot + 2 - held.count)
        }
        if component != .hole { total[slot] += Double(mass) }
        if dark {
            held[slot] += Double(mass)
            halo.append(
                position: position, velocity: velocity, galaxy: galaxy, radius: radius,
                population: population, luminosity: luminosity, formation: formation,
                component: component, mass: mass, kernelScale: kernelScale)
            return
        }
        let index = visible
        visible += 1
        if component == .hole || ParticleSystem.unit(index, seed) < share {
            if component != .hole { held[slot] += Double(mass) }
            kept.append(
                position: position, velocity: velocity, galaxy: galaxy, radius: radius,
                population: population, luminosity: luminosity, formation: formation,
                component: component, mass: mass, kernelScale: kernelScale)
            return
        }
        chunk.append(
            position: position, velocity: velocity, formation: formation,
            word: TracerWord(
                galaxy: galaxy, component: component.rawValue, kernelScale: kernelScale,
                luminosity: luminosity, birthRadius: radius))
        tracers += 1
        if chunk.count >= chunkSize { flush() }
    }

    mutating func flush() {
        guard chunk.count > 0 else { return }
        emit(chunk)
        chunk.removeAll()
    }

    /// The kept particles, visible then dark, each galaxy's carrying all of its mass.
    func massiveSet() -> ParticleSystem {
        var massive = kept
        massive.reserveCapacity(kept.count + halo.count)
        massive.append(contentsOf: halo)
        massive.setVisibleCount(kept.count)
        let hole = ParticleComponent.hole.rawValue
        let dark = ParticleComponent.halo.rawValue
        for index in 0..<massive.count where massive.component[index] != hole {
            let slot = Int(massive.galaxyIndex[index]) * 2 + (massive.component[index] == dark ? 1 : 0)
            massive.mass[index] =
                held[slot] > 0 ? Float(Double(massive.mass[index]) * total[slot] / held[slot]) : 0
        }
        return massive
    }
}
