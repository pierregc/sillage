import Foundation
import SillageCore

#if canImport(simd)
    import simd
#endif

/// The CPU side of a Barnes-Hut solver (#274), which the Metal and the CUDA engines share: what
/// the solver knows of its particles besides the buffers its kernels step, the centres and the
/// disk frames it works out from their positions, the parameters it hands each pass, its
/// counters, and what a checkpoint keeps of them. It reads the positions through a pointer the
/// engine gives it: Metal's unified memory, or CUDA's copy of them in pinned host memory.
///
/// Moved out of `MetalBarnesHutSolver` as it was; `BarnesHutStep` runs a step over it.
public final class BarnesHutHost {
    public let scene: SceneConfig
    public internal(set) var time: Float = 0
    /// The scene's step, unless a step schedule changed it between two steps (#307).
    public internal(set) var timeStep: Float

    /// Opening angle. Smaller is more accurate and slower; 0.5 to 0.7 is the usual range.
    public var openingAngle: Float
    /// Force softening in kpc, which should sit near the mean interparticle separation.
    public var softening: Float

    public var lastDriftMilliseconds = 0.0
    public var lastTreeMilliseconds = 0.0
    public internal(set) var lastForceMilliseconds = 0.0

    /// Masses never change, so they are read once. A black hole's is here and not in the
    /// buffer the tree is built from.
    public let particleMass: [Float]
    /// Black holes, pulled outside the tree; empty in a scene without one.
    public let holes: [HoleGPU]
    public static let holeLimit = 4
    /// The massive particles as sampled, less what the buffers hold: positions, velocities and
    /// formation times.
    public let template: ParticleSystem
    /// Everything the position buffer holds, tracers included.
    public let count: Int
    /// Light tracers (#187): the first `tracerCount` particles carry no mass and stay out of
    /// the tree. They are drawn, kicked, drifted and cooled like the rest, in the field of the
    /// massive ones, so the softening and the step stay those of the massive count. Since
    /// #238 they hold a position and a velocity and nothing else: 32 bytes each.
    public let tracerCount: Int
    /// The particles the tree is built over, after the tracers, and the visible ones of them.
    public let massive: Int
    public let massiveVisible: Int
    /// The opening angle of the tracers' walk alone. Their force error does not feed back.
    public var tracerOpeningAngle: Float
    /// Tracers sorted together into their walk order, a chunk at a time.
    public let sortChunk: Int
    var stepsSinceTracerSort = 0
    /// Steps since the walk order was last sorted, for `walkDump` (#271).
    public internal(set) var tracerOrderAge = 0
    /// The disks this step's tracer pass cooled towards, for `walkDump` (#271).
    public internal(set) var lastCoolingDisks: [DiskCoolingGPU]?
    public let galaxyOf: [UInt32]
    public let componentOf: [UInt32]
    public let liveHalos: Bool
    /// Whether any galaxy's disk is cooled: the dissipation pass, and the disk frames it follows.
    public let dissipates: Bool
    /// The last build gathered the particles into Morton order, so the force pass need not.
    var gathered = false
    var stepsSinceTree = 0
    /// Only ever used to vary the per-step random draw in the star formation pass.
    var stepsSinceFormation = 0
    var haloCenters: [SIMD3<Float>]
    /// Where a rigid analytic halo sits: the centre of mass of the galaxy's visible particles.
    /// Not the nucleus the rest follows: a rigid halo on the nucleus pulls on its own lopsided
    /// stars with nothing pulling back, and the galaxy pushes itself along (review of #179).
    public internal(set) var massCenters: [SIMD3<Float>]
    var galaxyMotion: [SIMD3<Float>]
    var diskStates: [DiskState]
    let centersLock = NSLock()

    /// Written on whichever queue is stepping and read by the renderer on the main thread,
    /// so the array is handed over under a lock rather than copied out from under the write.
    public var centers: [SIMD3<Float>] {
        centersLock.lock()
        defer { centersLock.unlock() }
        return haloCenters
    }

    /// The axis each disk is currently turning about, and how much of its material still
    /// turns that way. Both are measured from the particles rather than taken from the setup,
    /// and both are what decides whether the disk is still cooled. Exposed because a run that
    /// wrongly keeps cooling a wrecked disk looks perfectly healthy from anywhere else.
    public var diskFrames: [DiskState] {
        centersLock.lock()
        defer { centersLock.unlock() }
        return diskStates
    }

    /// Over `particles`, the massive ones laid out `[visible | halo]`, with `tracers` light
    /// tracers in front of them in the engine's buffers.
    public init(scene: SceneConfig, massive particles: ParticleSystem, tracers: Int) {
        self.scene = scene
        self.timeStep = scene.timeStep
        self.tracerCount = tracers
        self.massive = max(particles.count, 1)
        self.count = tracers + max(particles.count, 1)
        self.massiveVisible = particles.visibleCount > 0 ? particles.visibleCount : particles.count
        self.tracerOpeningAngle = scene.openingAngle
        self.openingAngle = scene.openingAngle
        self.softening = scene.softening
        self.galaxyOf = particles.galaxyIndex
        self.componentOf = particles.component
        self.liveHalos = scene.hasLiveHalos
        self.dissipates = scene.galaxies.contains { $0.dissipationTime > 0 }
        self.haloCenters = scene.galaxies.map(\.position)
        self.massCenters = scene.galaxies.map(\.position)
        self.galaxyMotion = scene.galaxies.map(\.velocity)
        self.diskStates = DiskState.natal(scene)
        var masses = particles.mass
        if masses.count != massive {
            masses = [Float](repeating: 0, count: massive)
        }
        self.particleMass = masses
        // Never softer than the stars, whatever the scene says.
        var holes: [HoleGPU] = []
        for index in particles.component.indices
        where particles.component[index] == ParticleComponent.hole.rawValue
            && holes.count < Self.holeLimit && index < masses.count
        {
            let galaxy = Int(particles.galaxyIndex[index])
            let own =
                scene.galaxies.indices.contains(galaxy) ? scene.galaxies[galaxy].potential.scaleRadius : 0
            let length = max(own, scene.softening)
            holes.append(
                HoleGPU(
                    massG: SIMD4<Float>(0, 0, 0, masses[index] * Physics.gravitationalConstant),
                    shape: SIMD4<Float>(length * length, Float(bitPattern: UInt32(index)), 0, 0)))
        }
        self.holes = holes
        var stripped = particles
        stripped.positions = []
        stripped.velocities = []
        // Read back from the buffer the solver writes, not from the sample it started with.
        stripped.formation = []
        self.template = stripped
        self.sortChunk = min(max(Self.tracerSortChunk, 1), max(tracers, 1))
    }

    /// The masses the tree is built over: a black hole pulls outside it, and weighs nothing there.
    public var treeMass: [Float] {
        var treeMass = particleMass
        for hole in holes { treeMass[Int(hole.shape.y.bitPattern)] = 0 }
        return treeMass
    }

    public func formationParams(nodeCount: Int) -> StarFormationGPU {
        StarFormationGPU(
            efficiency: StarFormation.efficiency,
            threshold: StarFormation.thresholdDensity,
            timeStep: timeStep,
            time: time,
            gravitationalConstant: Physics.gravitationalConstant,
            compressionBoost: StarFormation.compressionBoost,
            compressionFloor: StarFormation.compressionFloor,
            seed: UInt32(truncatingIfNeeded: stepsSinceFormation),
            nodeCount: UInt32(nodeCount))
    }

    /// This step's star formation draw over a tree of `nodeCount` nodes, a new one each call;
    /// nil without a tree.
    public func drawFormation(nodeCount: Int) -> StarFormationGPU? {
        guard nodeCount > 0 else { return nil }
        stepsSinceFormation &+= 1
        return formationParams(nodeCount: nodeCount)
    }

    /// What each disk is cooled towards this step, for the massive pass and the tracers' alike;
    /// nil when nothing is cooled.
    public func coolingDisks() -> [DiskCoolingGPU]? {
        guard dissipates else { return nil }
        let elapsed = timeStep * Float(Physics.megayearsPerTimeUnit)
        centersLock.lock()
        let frames = (haloCenters, galaxyMotion, diskStates)
        centersLock.unlock()
        let disks = scene.galaxies.enumerated().map { index, galaxy -> DiskCoolingGPU in
            let centre = index < frames.0.count ? frames.0[index] : galaxy.position
            let motion = index < frames.1.count ? frames.1[index] : galaxy.velocity
            let state = index < frames.2.count ? frames.2[index] : DiskState.natal(galaxy)
            let axis = state.axis
            // The share of the gap to circular closed this step, from the time constant,
            // taken away again by whatever is stopping this from being a quiet disk: a
            // companion close enough to be tearing at it now, and the memory of one that
            // already has.
            let disturbed = Self.smoothstep(
                Self.tidalFloor, Self.tidalCeiling, tidalStress(on: index, centers: frames.0))
            let wrecked = state.disruption
            let quiet = max((1 - disturbed) * (1 - wrecked), 0)
            let damping =
                galaxy.dissipationTime > 0 && galaxy.kind.isRotating
                ? quiet * (1 - exp(-elapsed / galaxy.dissipationTime)) : 0
            let edge = max(galaxy.diskScaleLength, 0.1)
            // The floor the disk cools to, taken from the equilibrium it was sampled in so it
            // holds the Toomre parameter the galaxy asked for rather than a number picked by
            // hand. Read at two scale lengths and carried as a fraction of the circular
            // speed, which is close enough to constant across an exponential disk.
            let equilibrium = DiskEquilibrium(config: galaxy, selfGravitating: true)
            let reference = edge * 2
            let circular = max(equilibrium.circularSpeed(atRadius: reference), 1e-6)
            // The floor applies to the whole peculiar velocity, so it has to be the whole
            // equilibrium dispersion. Flooring the three-dimensional motion at the radial
            // component alone leaves the radial part below what Toomre asks and the disk
            // fragments anyway, which is what the first attempt did.
            let radial = equilibrium.radialDispersion(atRadius: reference)
            let azimuthal = equilibrium.azimuthalDispersion(atRadius: reference)
            let vertical = equilibrium.verticalDispersion(atRadius: reference)
            let dispersion =
                (radial * radial + azimuthal * azimuthal + vertical * vertical).squareRoot()
            let floorFraction = min(dispersion / circular, 0.5)
            return DiskCoolingGPU(
                center: SIMD4<Float>(centre.x, centre.y, centre.z, floorFraction),
                motion: SIMD4<Float>(motion.x, motion.y, motion.z, damping),
                axis: SIMD4<Float>(axis.x, axis.y, axis.z, 0),
                // Generous on purpose. Halo and bulge are already excluded by component, so
                // the only thing these limits keep out is material genuinely thrown clear —
                // a tidal tail, not a disk star that has been heated. Cutting in at a few
                // scale heights did the opposite: it stopped cooling the stars that had
                // picked up the most motion, and the disk heated almost as fast as with no
                // dissipation at all.
                reach: SIMD4<Float>(edge * 5, edge * 9, edge, edge * 2))
        }
        if disks.isEmpty { return nil }
        // Permanent once every disk is wrecked, which is where a merger ends up.
        if disks.allSatisfy({ $0.motion.w <= 0 }) { return nil }
        return disks
    }

    public var params: BHParams { params(over: massive) }

    public func params(over particles: Int) -> BHParams {
        BHParams(
            particleCount: UInt32(particles),
            // With a live halo the dark matter is already in the tree; adding the analytic
            // potential on top would double its mass, and a rigid potential that follows the
            // disk does work on the system, which is why the old one leaked energy.
            haloCount: liveHalos ? 0 : UInt32(scene.galaxies.count),
            timeStep: timeStep,
            openingAngleSquared: openingAngle * openingAngle,
            softeningSquared: softening * softening,
            gravitationalConstant: Physics.gravitationalConstant)
    }

    // Deliberately mutable: the tests and the measurement probes set these to sweep them, and
    // nothing else ever writes one. Strict concurrency has no way to know that, so it is said
    // here rather than by making them lets that the tests could not move.
    //
    /// Particles per piece of the force pass, each committed on its own. A whole large scene
    /// in one kernel keeps the GPU to itself long enough that the pointer stutters, and frames
    /// only get in between command buffers.
    nonisolated(unsafe) public static var forceChunk = 1_000_000

    /// Particles a leaf may hold before it splits. Bigger leaves mean far fewer nodes and a
    /// cheaper build at the cost of more direct summation in the force pass. That trade only
    /// became worth taking once leaves started respecting the opening criterion, since a
    /// distant leaf now costs one evaluation whatever it holds.
    nonisolated(unsafe) public static var leafCapacity = 16

    /// How deep the tree may go. A merged core subdivides to the ceiling, one dispatch a level.
    /// Twenty is right when accuracy matters; thirteen puts the smallest cell at a few tens of
    /// parsecs, far below any softening length used here.
    nonisolated(unsafe) public static var maximumTreeDepth = 20

    /// Steps a tree is reused for. The build is most of what a step costs, and what decides
    /// whether motion looks continuous is how *often* positions change, not how far they move
    /// each time: a few large steps a second make the galaxies jump while the starfield, which
    /// only follows the camera, glides. Reusing the tree buys the step rate that fixes that,
    /// and costs nothing at these step sizes — a particle crosses a fraction of a leaf cell
    /// in the interval, which is well inside what the opening angle already approximates.
    nonisolated(unsafe) public static var treeReuse = 1

    /// Whether an accepted cell adds its quadrupole to its monopole, which is what lets the
    /// opening angle be 0.9 rather than 0.7 for the same force error. The default for new
    /// solvers; the monopole stays for measuring against.
    nonisolated(unsafe) public static var quadrupole = true

    /// Particles a galaxy contributes to its own disk frame. The axis and the coherence are
    /// mass-weighted sums over a hundred thousand-odd stars; fifty thousand of them give the
    /// same answer, and this runs on every tree rebuild.
    nonisolated(unsafe) public static var frameSample = 50_000

    /// Where a companion stops leaving the disk alone, as the disk's radius over its tidal
    /// radius. Below the floor the disk sits well inside the tidal radius and its gas is
    /// undisturbed; past the ceiling the companion is cutting into the disk itself.
    nonisolated(unsafe) public static var tidalFloor: Float = 0.7
    nonisolated(unsafe) public static var tidalCeiling: Float = 1.4

    /// Steps between two sorts of the tracers' walk order. Sorting is what keeps the lanes of a
    /// SIMD group walking alike; in between, the walk slows as the order ages. Ten was the
    /// cheapest of 1, 10, 25, 50 and 100 at 8 M (#238).
    nonisolated(unsafe) public static var tracerSortInterval = 10
    /// Tracers sorted together. Each chunk is sorted on its own, so the sort's own buffers
    /// stay this size however many tracers there are.
    nonisolated(unsafe) public static var tracerSortChunk = 1 << 22

    /// Each halo rides on the centre of mass of its own galaxy's particles, and so does the
    /// frame the dissipation pass cools towards: cooling in the wrong frame would drag two
    /// galaxies to a halt instead of letting them orbit.
    ///
    /// Summed in fixed blocks on every core, in double precision. The single running float sum
    /// this replaced was not exact enough to be worth matching: by the time a galaxy's total
    /// mass is tens of thousands of times one particle's, every addition rounds the same way,
    /// and at sixty thousand particles a galaxy the centre came out scaled by 1.0008, 23 pc off
    /// at 30 kpc. Fixed blocks added in order also make the answer the same on any machine.
    public func updateHaloCenters(
        positions: UnsafeBufferPointer<SIMD3<Float>>, velocities: UnsafeBufferPointer<SIMD3<Float>>?
    ) {
        let galaxies = scene.galaxies.count
        guard galaxies > 0 else { return }
        let limit = min(massive, galaxyOf.count)
        let block = 65_536
        // Over the massive particles alone, so a run with tracers sums them in the order the same
        // run without them does, to the bit (#239).
        let blocks = (limit + block - 1) / block
        // Six sums a galaxy a block: position and velocity weighted by mass, then the mass,
        // over every visible particle and again over the nucleus alone.
        var partial = [SIMD3<Double>](repeating: .zero, count: blocks * galaxies * 6)
        let halo = ParticleComponent.halo.rawValue
        let outskirt = ParticleComponent.outskirt.rawValue
        // The nucleus: the disk material and the bulge inside one and a half scale lengths of
        // where the centre was. The centre of mass of every visible particle, which this used
        // to be, sat 0.3 to 5 kpc off it once the outskirts went lopsided, and the camera and
        // the cooling followed that (docs/notes/lumpy-arms.md). Real galaxies are centred on
        // their bulge to a few pixels whatever their outskirts do.
        centersLock.lock()
        let previous = haloCenters
        centersLock.unlock()
        let reach = scene.galaxies.map { galaxy -> Float in
            galaxy.kind == .blackHole ? 0 : max(galaxy.diskScaleLength * 1.5, 0.5)
        }
        galaxyOf.withUnsafeBufferPointer { galaxyOf in
            componentOf.withUnsafeBufferPointer { componentOf in
                particleMass.withUnsafeBufferPointer { mass in
                    partial.withUnsafeMutableBufferPointer { partial in
                        concurrentPerform(iterations: blocks) { index in
                            var weighted = [SIMD3<Double>](repeating: .zero, count: galaxies)
                            var drift = weighted
                            var totals = [Double](repeating: 0, count: galaxies)
                            var innerWeighted = weighted
                            var innerDrift = weighted
                            var innerTotals = totals
                            let lower = index * block
                            let upper = min((index + 1) * block, limit)
                            for particle in lower..<max(lower, upper) {
                                let galaxy = Int(galaxyOf[particle])
                                guard galaxy < galaxies else { continue }
                                // Halo particles outnumber the disk, so including them would
                                // put the centre at the halo's centroid rather than at the
                                // visible galaxy's.
                                let kind = particle < componentOf.count ? componentOf[particle] : halo
                                if kind == halo { continue }
                                let m = Double(max(mass[particle], 1e-20))
                                let position = positions[particle]
                                weighted[galaxy] += SIMD3<Double>(position) * m
                                if let velocities {
                                    drift[galaxy] += SIMD3<Double>(velocities[particle]) * m
                                }
                                totals[galaxy] += m
                                let offset = position - previous[galaxy]
                                let inside = simd_length_squared(offset) < reach[galaxy] * reach[galaxy]
                                if kind != outskirt, inside {
                                    innerWeighted[galaxy] += SIMD3<Double>(position) * m
                                    if let velocities {
                                        innerDrift[galaxy] += SIMD3<Double>(velocities[particle]) * m
                                    }
                                    innerTotals[galaxy] += m
                                }
                            }
                            for galaxy in 0..<galaxies {
                                let base = (index * galaxies + galaxy) * 6
                                partial[base] = weighted[galaxy]
                                partial[base + 1] = drift[galaxy]
                                partial[base + 2] = SIMD3<Double>(repeating: totals[galaxy])
                                partial[base + 3] = innerWeighted[galaxy]
                                partial[base + 4] = innerDrift[galaxy]
                                partial[base + 5] = SIMD3<Double>(repeating: innerTotals[galaxy])
                            }
                        }
                    }
                }
            }
        }
        var weighted = [SIMD3<Double>](repeating: .zero, count: galaxies)
        var drift = weighted
        var totals = [Double](repeating: 0, count: galaxies)
        var innerWeighted = weighted
        var innerDrift = weighted
        var innerTotals = totals
        for index in 0..<blocks {
            for galaxy in 0..<galaxies {
                let base = (index * galaxies + galaxy) * 6
                weighted[galaxy] += partial[base]
                drift[galaxy] += partial[base + 1]
                totals[galaxy] += partial[base + 2].x
                innerWeighted[galaxy] += partial[base + 3]
                innerDrift[galaxy] += partial[base + 4]
                innerTotals[galaxy] += partial[base + 5].x
            }
        }
        var updated = centers
        var masses = massCenters
        for galaxy in updated.indices where totals[galaxy] > 0 {
            masses[galaxy] = SIMD3<Float>(weighted[galaxy] / totals[galaxy])
            // The nucleus when there still is one; a galaxy torn apart, or a black hole, is
            // wherever its mass is.
            let nucleus = innerTotals[galaxy] > 0.01 * totals[galaxy]
            let sum = nucleus ? innerWeighted[galaxy] : weighted[galaxy]
            let motion = nucleus ? innerDrift[galaxy] : drift[galaxy]
            let mass = nucleus ? innerTotals[galaxy] : totals[galaxy]
            updated[galaxy] = SIMD3<Float>(sum / mass)
            if velocities != nil {
                galaxyMotion[galaxy] = SIMD3<Float>(motion / mass)
            }
        }
        centersLock.lock()
        haloCenters = updated
        massCenters = masses
        centersLock.unlock()
    }

    /// The plane each disk is actually turning in, and how much of it still turns that way.
    ///
    /// Cooling towards the orientation the galaxy was *set up* with is a spring back to the
    /// natal plane: a disk thrown out of it by an encounter gets pulled back into it, and
    /// re-thins, which is the one thing a collisionless system cannot do. Measured on a run
    /// of three galaxies, the inclined one heated from 0.24 kpc thick to 11.7 through
    /// pericentre and was back to 1.04 four hundred megayears later, still within five degrees
    /// of the plane it was born in and eighty-three from the remnant it was supposed to have
    /// joined. The axis is now the mass-weighted angular momentum of the galaxy's own disk
    /// material about its own moving centre, so it tumbles, precesses and warps with the disk
    /// instead of holding it.
    ///
    /// `coherence` is |sum m l| / sum m |l|: one where every star turns the same way, near
    /// zero for a spheroid whose angular momenta cancel. It is what says a disk has stopped
    /// being a disk.
    ///
    /// Fifty thousand particles a galaxy answer both questions. Walking millions of them on
    /// every tree rebuild would cost more than the cooling it feeds.
    public func updateDiskFrames(
        positions: UnsafeBufferPointer<SIMD3<Float>>, velocities: UnsafeBufferPointer<SIMD3<Float>>
    ) {
        let galaxies = scene.galaxies.count
        guard galaxies > 0 else { return }
        let mass = particleMass
        var angular = [SIMD3<Double>](repeating: .zero, count: galaxies)
        var scalar = [Double](repeating: 0, count: galaxies)
        var height = [Double](repeating: 0, count: galaxies)
        var across = [Double](repeating: 0, count: galaxies)
        centersLock.lock()
        let plane = diskStates.map(\.axis)
        centersLock.unlock()
        var layers = scene.galaxies.enumerated().map { index, galaxy in
            DiskLayer(
                axis: plane[index], scaleLength: galaxy.diskScaleLength,
                edge: galaxy.diskScaleLength * galaxy.diskTruncation)
        }
        let limit = min(massive, min(galaxyOf.count, componentOf.count))
        let step = max(limit / (Self.frameSample * galaxies), 1)
        for index in Swift.stride(from: 0, to: limit, by: step) {
            let kind = componentOf[index]
            // The same material the cooling touches, so the frame is the frame of the thing
            // being cooled: no dark matter, no bulge, which has no plane to speak of, and no
            // thick halo either. The cooling excludes everything from `halo` upward and this
            // has to say the same thing — when the thick component was added to one and not
            // the other, a spheroid reaching past thirty kiloparsecs and turning at a third of
            // the circular speed was being counted as disk, and the ordered-rotation fraction
            // it is measured by came out of a mixture of two populations.
            if kind >= ParticleComponent.halo.rawValue { continue }
            let galaxy = Int(galaxyOf[index])
            guard galaxy < galaxies else { continue }
            let offset = SIMD3<Double>(positions[index] - haloCenters[galaxy])
            let motion = SIMD3<Double>(velocities[index] - galaxyMotion[galaxy])
            let weight = Double(max(mass[index], 1e-20))
            angular[galaxy] += simd_cross(offset, motion) * weight
            // Against m|r||v| rather than m|r x v|. The cross product is already blind to
            // radial motion, so normalising by its own magnitude asks only whether the
            // angular momenta point the same way and answers yes for a swarm of plunging
            // radial orbits. What is wanted is whether the material is rotationally
            // supported, and this is the ratio that says so.
            scalar[galaxy] += simd_length(offset) * simd_length(motion) * weight
            let z = simd_dot(offset, SIMD3<Double>(plane[galaxy]))
            height[galaxy] += z * z * weight
            across[galaxy] += simd_length_squared(offset) * weight
            layers[galaxy].add(positions[index] - haloCenters[galaxy])
        }

        // The same particles again, now that each ring's plane is known.
        let fits = layers.map { $0.fitted() }
        centersLock.lock()
        let cut = (0..<galaxies).map { diskStates[$0].layerHeight(spread: fits[$0].spread) }
        centersLock.unlock()
        var held = [Double](repeating: 0, count: galaxies)
        var material = [Double](repeating: 0, count: galaxies)
        for index in Swift.stride(from: 0, to: limit, by: step)
        where componentOf[index] < ParticleComponent.halo.rawValue {
            let galaxy = Int(galaxyOf[index])
            guard galaxy < galaxies else { continue }
            material[galaxy] += 1
            if let standing = fits[galaxy].height(of: positions[index] - haloCenters[galaxy]),
                abs(standing) < cut[galaxy]
            {
                held[galaxy] += 1
            }
        }

        centersLock.lock()
        for galaxy in 0..<galaxies {
            // A globular has no ordered rotation to lose and is never cooled, so leaving its
            // state alone keeps the reading worth looking at rather than pinned at one.
            guard scene.galaxies[galaxy].kind.isRotating else { continue }
            diskStates[galaxy].fold(
                momentum: angular[galaxy], scalar: scalar[galaxy],
                height: height[galaxy], across: across[galaxy])
            if material[galaxy] > 0 {
                diskStates[galaxy].foldLayer(
                    spread: fits[galaxy].spread, held: Float(held[galaxy] / material[galaxy]))
            }
        }
        centersLock.unlock()
    }

    /// How hard the nearest companion is working on a disk, as the disk's own radius over its
    /// tidal radius in that companion's field: r_t = d (M / 3 M_companion)^(1/3).
    ///
    /// Cooling stands in for gas sitting in a quiet cold layer and forming stars on circular
    /// orbits. During an encounter that gas is being shocked, driven inward and burned, so
    /// the stand-in has no business running: this is what takes the cooling off *while* the
    /// galaxies are passing through each other, which is when the disk is meant to be
    /// destroyed and when holding it together does the most damage. It comes back on if the
    /// two separate again without wrecking each other, which is what a distant fly-by is.
    ///
    /// Scale-free, so a small satellite passing close does not switch off a large disk's
    /// cooling the way an equal-mass companion does.
    private func tidalStress(on index: Int, centers: [SIMD3<Float>]) -> Float {
        let galaxy = scene.galaxies[index]
        // Three scale lengths holds about four fifths of an exponential disk's mass, so it is
        // the radius at which "the disk is inside its tidal radius" means the disk.
        let radius = max(galaxy.diskScaleLength * 3, 0.1)
        let mass = max(galaxy.potential.mass, 1e-6)
        var worst: Float = 0
        for other in scene.galaxies.indices where other != index {
            let companion = max(scene.galaxies[other].potential.mass, 1e-6)
            let separation = max(simd_distance(centers[index], centers[other]), 1e-3)
            let tidalRadius = separation * cbrt(mass / (3 * companion))
            worst = max(worst, radius / max(tidalRadius, 1e-3))
        }
        return worst
    }

    private static func smoothstep(_ low: Float, _ high: Float, _ x: Float) -> Float {
        guard high > low else { return x < low ? 0 : 1 }
        let t = min(max((x - low) / (high - low), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// The analytic halos the force pass adds, one a galaxy, at the current centres.
    public var haloList: [HaloGPU] {
        var list = scene.galaxies.enumerated().map { index, galaxy -> HaloGPU in
            let center = index < massCenters.count ? massCenters[index] : galaxy.position
            let haloMass =
                galaxy.potential.mass * (1 - galaxy.diskMassFraction)
                * Physics.gravitationalConstant
            let point = SIMD4<Float>(center.x, center.y, center.z, 0)
            return HaloGPU(
                centerBefore: point, centerAfter: point,
                shape: SIMD4<Float>(
                    haloMass, galaxy.potential.scaleRadius,
                    galaxy.potential.profile == .plummer ? 0 : 1, 0))
        }
        if list.isEmpty { list = [HaloGPU(centerBefore: .zero, centerAfter: .zero, shape: .zero)] }
        return list
    }

    public func tracerStepParams(mode: UInt32, disks: [DiskCoolingGPU]?) -> TracerStepGPU {
        let base = params
        return TracerStepGPU(
            tracerCount: UInt32(tracerCount), haloCount: base.haloCount,
            timeStep: base.timeStep, openingAngleSquared: tracerOpeningAngle * tracerOpeningAngle,
            softeningSquared: base.softeningSquared,
            gravitationalConstant: base.gravitationalConstant, sortChunk: UInt32(sortChunk),
            holeCount: UInt32(holes.count), diskCount: UInt32(disks?.count ?? 0), mode: mode)
    }

    /// Total momentum. With live halos nothing external acts on the system, so this must be
    /// constant; a rigid halo that follows the disk makes it drift. Tracers weigh nothing.
    public func momentum(velocities: UnsafeBufferPointer<SIMD3<Float>>) -> SIMD3<Float> {
        var total = SIMD3<Float>.zero
        for index in 0..<min(massive, particleMass.count) {
            total += velocities[index] * particleMass[index]
        }
        return total
    }

    // MARK: - Checkpoint

    /// What a checkpoint keeps besides the particles' buffers (#240).
    public var state: SolverState {
        centersLock.lock()
        defer { centersLock.unlock() }
        return SolverState(
            count: count, tracers: tracerCount, time: time, stepsSinceTree: stepsSinceTree,
            stepsSinceFormation: stepsSinceFormation, haloCenters: haloCenters,
            massCenters: massCenters, galaxyMotion: galaxyMotion, diskStates: diskStates)
    }

    /// Refuses the state of another run, before anything of it is read.
    public func accepts(_ state: SolverState) throws {
        guard state.count == count, state.tracers == tracerCount else {
            throw RunCheckpointError.otherRun(
                "\(state.count) particles, \(state.tracers) tracers against \(count), \(tracerCount)")
        }
    }

    /// Takes a checkpoint's counters, centres and disks, once its buffers are read back.
    public func take(_ state: SolverState) {
        time = state.time
        stepsSinceTree = state.stepsSinceTree
        stepsSinceFormation = state.stepsSinceFormation
        centersLock.lock()
        haloCenters = state.haloCenters
        massCenters = state.massCenters
        galaxyMotion = state.galaxyMotion
        diskStates = state.diskStates
        centersLock.unlock()
    }
}
