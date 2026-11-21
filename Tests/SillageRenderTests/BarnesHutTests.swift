import Foundation
import Testing

@testable import SillageCore
@testable import SillageRender

#if canImport(simd)
    import simd
#endif

@Suite("Barnes-Hut")
struct BarnesHutTests {
    func cluster(count: Int, seed: UInt64 = 3) -> (
        positions: [SIMD3<Float>], mass: [Float]
    ) {
        var generator = SeededGenerator(seed: seed)
        var positions: [SIMD3<Float>] = []
        var mass: [Float] = []
        for _ in 0..<count {
            positions.append(
                SIMD3<Float>(generator.normal(), generator.normal(), generator.normal() * 0.3) * 7)
            mass.append(0.002)
        }
        return (positions, mass)
    }

    @Test func treeConservesMassAndCentreOfMass() {
        let (positions, mass) = cluster(count: 5_000)
        let tree = BarnesHutTree()
        tree.build(positions: positions, mass: mass)

        let total = mass.reduce(0, +)
        #expect(abs(tree.nodes[0].comMass.w - total) / total < 1e-4)

        var reference = SIMD3<Float>.zero
        for index in positions.indices { reference += positions[index] * mass[index] }
        reference /= total
        let root = tree.nodes[0].comMass
        #expect(simd_length(SIMD3<Float>(root.x, root.y, root.z) - reference) < 1e-3)

        #expect(Set(tree.order).count == positions.count)
        var inLeaves = 0
        for node in tree.nodes where node.isLeaf { inLeaves += node.particleCount }
        #expect(inLeaves == positions.count)
    }

    @Test func mortonCodesInterleaveConsistently() {
        #expect(BarnesHutTree.morton(0, 0, 0) == 0)
        #expect(BarnesHutTree.morton(1, 0, 0) == 4)
        #expect(BarnesHutTree.morton(0, 1, 0) == 2)
        #expect(BarnesHutTree.morton(0, 0, 1) == 1)
        // The digit at depth 0 is the top bit of each axis, which is bit 20 of 21.
        let top: UInt32 = 1 << 20
        #expect(BarnesHutTree.octant(BarnesHutTree.morton(top, 0, top), depth: 0) == 5)
        // And the deepest digit the code can still separate is at the far end.
        #expect(BarnesHutTree.octant(BarnesHutTree.morton(1, 1, 0), depth: 20) == 6)
    }

    /// The root folds every level, so it checks the shift as much as the leaves check the sums.
    @Test func quadrupolesAreTheSecondMomentAboutEachCentre() {
        let (positions, mass) = cluster(count: 5_000)
        let tree = BarnesHutTree()
        tree.computesQuadrupoles = true
        tree.build(positions: positions, mass: mass)
        #expect(tree.quadrupoles.count == tree.nodes.count * 2)

        func moments(_ members: [Int], about centre: SIMD4<Float>) -> [Double] {
            var sums = [Double](repeating: 0, count: 6)
            let c = SIMD3<Double>(Double(centre.x), Double(centre.y), Double(centre.z))
            for particle in members {
                let d = SIMD3<Double>(positions[particle]) - c
                let m = Double(mass[particle])
                sums[0] += m * d.x * d.x
                sums[1] += m * d.y * d.y
                sums[2] += m * d.z * d.z
                sums[3] += m * d.x * d.y
                sums[4] += m * d.x * d.z
                sums[5] += m * d.y * d.z
            }
            return sums
        }
        func stored(_ index: Int) -> [Double] {
            let a = tree.quadrupoles[2 * index]
            let b = tree.quadrupoles[2 * index + 1]
            return [a.x, a.y, a.z, a.w, b.x, b.y].map(Double.init)
        }
        func worst(_ index: Int, _ members: [Int]) -> Double {
            let reference = moments(members, about: tree.nodes[index].comMass)
            let scale = max(reference[0] + reference[1] + reference[2], 1e-30)
            return zip(stored(index), reference).map { abs($0 - $1) / scale }.max() ?? 0
        }

        #expect(worst(0, Array(positions.indices)) < 1e-4)
        var leaves = 0
        for index in tree.nodes.indices where tree.nodes[index].isLeaf {
            let node = tree.nodes[index]
            guard node.particleCount > 1 else { continue }
            let members = (node.particleStart..<(node.particleStart + node.particleCount)).map {
                Int(tree.order[$0])
            }
            #expect(worst(index, members) < 1e-3)
            leaves += 1
        }
        #expect(leaves > 100)
    }

    /// The equilibrium model is what makes level 2 usable, so it is checked directly rather
    /// than through a dynamical run: watching a disk heat up takes several orbits, which does
    /// not belong in a fast test suite. The measured behaviour over an orbit is in docs/reference.md.
    @Test(arguments: [Float(0.8), 1.4, 2.0])
    func equilibriumRealisesTheRequestedToomreQ(target: Float) {
        var galaxy = SceneConfig.isolatedDisk(particleCount: 1).galaxies[0]
        galaxy.toomreQ = target
        galaxy.diskMassFraction = 0.5
        let equilibrium = DiskEquilibrium(config: galaxy)

        for radius in [Float(2), 4, 8, 14] {
            let sigma = equilibrium.radialDispersion(atRadius: radius)
            let realised = equilibrium.toomreQ(atRadius: radius, radialDispersion: sigma)
            #expect(abs(realised - target) / target < 1e-3)
            // The epicyclic ratio fixes the anisotropy; it is never a free choice.
            let azimuthal = equilibrium.azimuthalDispersion(atRadius: radius)
            #expect(azimuthal > 0 && azimuthal < sigma)
            // Pressure support makes the mean rotation lag the circular speed.
            #expect(
                equilibrium.streamingSpeed(atRadius: radius)
                    <= equilibrium.circularSpeed(atRadius: radius) + 1e-4)
        }
    }

    @Test func sampledDiskCarriesTheDispersionTheEquilibriumAsks() {
        var scene = SceneConfig.isolatedDisk(particleCount: 60_000)
        scene.solver = .barnesHut
        scene.galaxies[0].toomreQ = 1.4
        scene.galaxies[0].diskMassFraction = 0.6
        // The bulge is held up by the Jeans equation rather than by Q, so leaving it in would
        // only dilute the one thing this measures.
        scene.galaxies[0].bulgeFraction = 0
        let hot = RestrictedSolver.sampleParticles(for: scene)

        scene.galaxies[0].toomreQ = 0.4
        let cold = RestrictedSolver.sampleParticles(for: scene)

        func radialDispersion(_ system: ParticleSystem) -> Float {
            var total: Float = 0
            var samples = 0
            // The thin disk alone. The thick component carries an isotropic dispersion that
            // tracks the circular speed and has nothing to do with Toomre's Q, so counting it
            // in mixes a population that does not answer the question into the answer: it
            // pulled a hot disk and a cold one to within a per cent of each other.
            for index in 0..<system.count
            where system.component[index] == ParticleComponent.star.rawValue {
                let p = system.positions[index]
                let radius = max(sqrt(p.x * p.x + p.y * p.y), 1e-3)
                let outward = SIMD2<Float>(p.x / radius, p.y / radius)
                let v = system.velocities[index]
                let radial = v.x * outward.x + v.y * outward.y
                total += radial * radial
                samples += 1
            }
            return sqrt(total / Float(max(samples, 1)))
        }
        #expect(radialDispersion(hot) > 2 * radialDispersion(cold))
    }

    /// The rotation curve has to describe the mass the sampler lays down, not the sphere the
    /// galaxy was written as. Freeman's disk is the piece that was missing.
    @Test func theRotationCurveCountsTheDiskItselfNotJustTheSphere() {
        var galaxy = SceneConfig.isolatedDisk(particleCount: 10_000).galaxies[0]
        galaxy.bulgeFraction = 0
        let live = DiskEquilibrium(config: galaxy, selfGravitating: true)
        let tracer = DiskEquilibrium(config: galaxy, selfGravitating: false)
        for radius in [Float(3), 6, 10] {
            // The disk and the truncated halo both pull harder in the plane than the sphere.
            #expect(live.circularSpeed(atRadius: radius) > tracer.circularSpeed(atRadius: radius))
        }

        // Freeman's curve for a disk on its own peaks near 2.15 scale lengths, which is what
        // separates a real disk term from any monotonic stand-in for one.
        func diskSpeed(_ radius: Float) -> Float {
            DiskEquilibrium.exponentialDiskSpeedSquared(mass: 10, scaleLength: 4, radius: radius)
        }
        let peak = stride(from: Float(0.4), through: 30, by: 0.05).max { diskSpeed($0) < diskSpeed($1) }
        #expect(abs((peak ?? 0) / 4 - 2.15) < 0.1)
    }

    @Test func selfGravitatingSamplingAssignsMass() {
        var scene = SceneConfig.merger(particleCount: 2_000)
        scene.solver = .barnesHut
        let particles = RestrictedSolver.sampleParticles(for: scene)
        #expect(particles.mass.allSatisfy { $0 > 0 })

        // The disk carries its share and the live halo carries the rest, so a galaxy's
        // particles must add up to the mass its potential claims.
        let galaxy = scene.galaxies[0]
        func mass(of kind: ParticleComponent?) -> Float {
            var total: Float = 0
            for index in 0..<particles.count where particles.galaxyIndex[index] == 0 {
                if let kind, particles.component[index] != kind.rawValue { continue }
                if kind == nil, particles.component[index] == ParticleComponent.halo.rawValue {
                    continue
                }
                total += particles.mass[index]
            }
            return total
        }
        let disk = mass(of: nil)
        let halo = mass(of: .halo)
        #expect(abs(disk - galaxy.potential.mass * galaxy.diskMassFraction) / disk < 1e-3)
        #expect(
            abs(halo - galaxy.potential.mass * (1 - galaxy.diskMassFraction)) / halo < 1e-3)
        #expect(abs(disk + halo - galaxy.potential.mass) / galaxy.potential.mass < 1e-3)
        #expect(particles.count > scene.totalParticleCount)

        var restricted = scene
        restricted.solver = .restricted
        #expect(RestrictedSolver.sampleParticles(for: restricted).mass.allSatisfy { $0 == 0 })
    }

    @Test func haloParticlesAreSampledAndCarryNoLight() {
        var scene = SceneConfig.merger(particleCount: 5_000)
        scene.solver = .barnesHut
        let particles = RestrictedSolver.sampleParticles(for: scene)
        #expect(particles.count == scene.simulatedParticleCount)
        #expect(particles.count > scene.totalParticleCount)

        var halos = 0
        for index in 0..<particles.count
        where particles.component[index] == ParticleComponent.halo.rawValue {
            halos += 1
            #expect(particles.luminosity[index] == 0)
            #expect(particles.mass[index] > 0)
        }
        #expect(halos == scene.galaxies.reduce(0) { $0 + $1.haloParticleCount })
        #expect(!ParticleComponent.halo.isVisible)

        // Level 1 has no live halo: its tracers are massless in a rigid potential.
        var restricted = scene
        restricted.solver = .restricted
        let tracers = RestrictedSolver.sampleParticles(for: restricted)
        #expect(tracers.count == restricted.totalParticleCount)
    }

    @Test func nodeStaysSmall() {
        // Thirty-two bytes rather than forty-eight: the node array is the hottest thing the
        // force kernel reads, so its size is its speed.
        #expect(MemoryLayout<BHNode>.stride == 32)
    }

    /// A node has to be able to say where its particles are, at any size of run.
    ///
    /// The ranges used to go through `Float(start)`, and a float counts exactly only up to
    /// 16 777 216. Past that a leaf start rounds to an even index, the last leaf in the tree
    /// reads one slot beyond `order`, and whatever the allocator left there becomes a
    /// particle number — an unchecked subscript in a release build, so a wild address rather
    /// than a message. Eighteen million simulated particles is an ordinary large run here:
    /// seven million visible with live halos is already past it.
    @Test func aNodeAddressesMoreParticlesThanAFloatCanCount() {
        let past = 18_000_003
        #expect(Int(Float(past)) != past, "otherwise this test tests nothing")

        var node = BHNode()
        node.range = Int32(past)
        node.signedCount = Int32(-31)
        #expect(node.particleStart == past)
        #expect(node.particleCount == 31)
        #expect(node.isLeaf)

        node.range = Int32(past + 1)
        node.signedCount = 5
        #expect(node.childOffset == past + 1)
        #expect(node.childCount == 5)
        #expect(!node.isLeaf)

        // And the whole 32-bit range round-trips, since the count of a leaf sitting on the
        // depth ceiling is bounded by the run and not by the leaf capacity.
        for value in [Int32.min + 1, -1, 0, 1, Int32.max] {
            node.range = value
            #expect(node.range == value)
        }
    }

    /// A stable sort has exactly one answer, so the parallel one is checked against what defines
    /// it: codes in order, each the code of the particle it names, every particle named once, and
    /// equal codes in particle order. That is the serial sort's output, bit for bit.
    @Test(arguments: ["random", "clustered", "beyond a float"])
    func theParallelSortIsTheStableOne(set: String) {
        var generator = SeededGenerator(seed: 11)
        var codes: [UInt64]
        switch set {
        case "random":
            codes = (0..<300_000).map { _ in generator.next() >> 1 }
        case "clustered":
            // Two dense clumps quantised onto the grid, so many particles share a code.
            codes = (0..<300_000).map { index in
                let centre: Float = index % 3 == 0 ? 600_000 : 1_400_000
                func axis() -> UInt32 { UInt32(max(centre + generator.normal() * 2_000, 0)) }
                return BarnesHutTree.morton(axis(), axis(), axis())
            }
        default:
            codes = (0..<17_500_000).map { _ in generator.next() >> 38 }
        }

        let tree = BarnesHutTree()
        tree.sort(codes: codes)
        let order = tree.order
        let sorted = tree.sortedCodes
        #expect(order.count == codes.count && sorted.count == codes.count)

        var named = [Bool](repeating: false, count: codes.count)
        var wrong = 0
        for position in order.indices {
            let particle = Int(order[position])
            if named[particle] || codes[particle] != sorted[position] { wrong += 1 }
            named[particle] = true
            guard position > 0 else { continue }
            let previous = sorted[position - 1]
            if previous > sorted[position]
                || (previous == sorted[position] && order[position - 1] > order[position])
            {
                wrong += 1
            }
        }
        #expect(wrong == 0)
    }

    /// The serial split and fold the parallel ones replaced, kept as the definition of the tree.
    func serialNodes(
        _ tree: BarnesHutTree, positions: [SIMD3<Float>], mass: [Float]
    ) -> [BHNode] {
        var lower = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var upper = -lower
        for position in positions {
            lower = simd_min(lower, position)
            upper = simd_max(upper, position)
        }
        let half = max((upper - lower).max() * 0.5, 1e-3) * 1.001
        let codes = tree.sortedCodes
        var nodes: [BHNode] = []
        var parents: [Int] = []
        func make(_ half: Float, _ start: Int, _ count: Int, _ parent: Int, _ digit: UInt32) -> Int {
            var node = BHNode()
            node.packed.x = (half * 2) * (half * 2)
            node.range = Int32(start)
            node.signedCount = Int32(-count)
            node.digit = digit
            nodes.append(node)
            parents.append(parent)
            return nodes.count - 1
        }
        var stack = [
            (
                start: 0, count: codes.count, depth: 0, half: half,
                node: make(half, 0, codes.count, -1, 63 << 3)
            )
        ]
        while let work = stack.popLast() {
            if work.count <= tree.leafCapacity || work.depth >= tree.maximumDepth { continue }
            let limit = work.start + work.count
            var offsets = [Int](repeating: limit, count: 9)
            offsets[0] = work.start
            var digit = 0
            for position in work.start..<limit {
                let value = BarnesHutTree.octant(codes[position], depth: work.depth)
                while digit < value {
                    digit += 1
                    offsets[digit] = position
                }
            }
            var first = -1
            var children: Int32 = 0
            for octant in 0..<8 where offsets[octant + 1] > offsets[octant] {
                let size = offsets[octant + 1] - offsets[octant]
                let digit = UInt32(60 - 3 * work.depth) << 3 | UInt32(octant)
                let index = make(work.half * 0.5, offsets[octant], size, work.node, digit)
                if first < 0 { first = index }
                children += 1
                stack.append((offsets[octant], size, work.depth + 1, work.half * 0.5, index))
            }
            nodes[work.node].range = Int32(first)
            nodes[work.node].signedCount = children
        }
        for index in nodes.indices where nodes[index].isLeaf {
            var sum = SIMD4<Float>.zero
            var weighted = SIMD3<Float>.zero
            for position in nodes[index]
                .particleStart..<(nodes[index].particleStart + nodes[index].particleCount)
            {
                let particle = Int(tree.order[position])
                weighted += positions[particle] * mass[particle]
                sum.w += mass[particle]
            }
            nodes[index].comMass = SIMD4<Float>(weighted.x, weighted.y, weighted.z, sum.w)
        }
        for index in stride(from: nodes.count - 1, through: 1, by: -1) {
            nodes[parents[index]].comMass += nodes[index].comMass
        }
        for index in nodes.indices where nodes[index].comMass.w > 0 {
            let inverse = 1 / nodes[index].comMass.w
            nodes[index].comMass.x *= inverse
            nodes[index].comMass.y *= inverse
            nodes[index].comMass.z *= inverse
        }
        return nodes
    }

    /// However the top levels are cut into subtrees, the node array has to come out the serial
    /// one to the bit: the force shader reads its layout, and the sums depend on their order.
    @Test(arguments: ["disk", "merged core"])
    func theParallelSplitIsTheSerialOne(set: String) {
        var generator = SeededGenerator(seed: 5)
        let sample = cluster(count: 200_000, seed: 5)
        var positions = sample.positions
        let mass = sample.mass
        if set == "merged core" {
            // A tight core under a wide envelope, so cells reach the depth ceiling still full.
            positions = positions.indices.map { index in
                let direction = SIMD3<Float>(generator.normal(), generator.normal(), generator.normal())
                return direction * (index % 10 == 0 ? 400 : 0.002)
            }
        }
        for subtreeParticles in [nil, 1, 64, 5_000, Int.max] {
            let tree = BarnesHutTree()
            tree.subtreeParticles = subtreeParticles
            tree.build(positions: positions, mass: mass)
            let reference = serialNodes(tree, positions: positions, mass: mass)
            #expect(tree.nodes.count == reference.count)
            var different = 0
            for (node, expected) in zip(tree.nodes, reference) {
                let bits = { (value: SIMD4<Float>) in (0..<4).map { value[$0].bitPattern } }
                if bits(node.comMass) != bits(expected.comMass) || bits(node.packed) != bits(expected.packed)
                {
                    different += 1
                }
            }
            #expect(different == 0, "\(set), subtrees of \(subtreeParticles ?? -1)")
        }
        if set == "merged core" {
            let tree = BarnesHutTree()
            tree.build(positions: positions, mass: mass)
            #expect(
                tree.nodes.contains { $0.particleCount > tree.leafCapacity },
                "otherwise the cap is not reached")
        }
    }
}
