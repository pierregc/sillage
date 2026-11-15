import Foundation
import SillageCore

#if canImport(simd)
    import simd
#endif

/// What the star formation rule reads on the leaves of one tree, summed over them (#306): each
/// leaf's density, the convergence of its flow against its free-fall rate, and the rate the two
/// give the gas it holds that has not formed yet. Read on the CPU from the buffers the next
/// step's pass reads, the way the kernel reads them, so it moves nothing.
public struct StarFormationLeaves: Sendable {
    /// Bins of the convergence, `-div v / sqrt(G rho)`, between these edges.
    public static let convergenceEdges: [Float] = [-100, -45, -15, -5, 0, 5, 15, 45, 100, 300, 1000]

    public var leaves = 0
    /// Leaves above the density threshold, and those of them whose flow could be read.
    public var dense = 0
    public var measured = 0
    /// Gas not formed yet, in every leaf and in the dense ones. Every star that forms takes one
    /// out for good, so its fall between two readings counts the stars formed in between.
    public var gas = 0
    public var denseGas = 0
    /// Stars a time unit the dense leaves' gas is expected to form: the density term alone, what
    /// the compression adds, and what the draws give once the chance saturates.
    public var densityRate = 0.0
    public var compressionRate = 0.0
    public var drawnRate = 0.0
    /// The gas in measured leaves, and its sums of the free-fall rate and of the convergence
    /// squared, in free-fall rates.
    public var measuredGas = 0
    public var gasFreeFall = 0.0
    public var gasConvergenceSquared = 0.0
    /// Per convergence bin, over the measured leaves holding gas: leaves, gas, and the
    /// compression term.
    public var binLeaves: [Int]
    public var binGas: [Int]
    public var binCompressionRate: [Double]

    public init() {
        binLeaves = [Int](repeating: 0, count: Self.convergenceEdges.count + 1)
        binGas = binLeaves
        binCompressionRate = binLeaves.map { _ in 0 }
    }

    mutating func add(_ other: StarFormationLeaves) {
        leaves += other.leaves
        dense += other.dense
        measured += other.measured
        gas += other.gas
        denseGas += other.denseGas
        densityRate += other.densityRate
        compressionRate += other.compressionRate
        drawnRate += other.drawnRate
        measuredGas += other.measuredGas
        gasFreeFall += other.gasFreeFall
        gasConvergenceSquared += other.gasConvergenceSquared
        for index in binLeaves.indices {
            binLeaves[index] += other.binLeaves[index]
            binGas[index] += other.binGas[index]
            binCompressionRate[index] += other.binCompressionRate[index]
        }
    }

    /// Reads every leaf of `nodes` as `massiveFormStars` does. The particle arrays are the
    /// massive ones, indexed as `order` indexes them.
    public static func read(
        nodes: UnsafeBufferPointer<BHNode>, order: UnsafeBufferPointer<UInt32>,
        positions: UnsafeBufferPointer<SIMD3<Float>>, velocities: UnsafeBufferPointer<SIMD3<Float>>,
        mass: UnsafeBufferPointer<Float>, component: UnsafeBufferPointer<UInt32>,
        formation: UnsafeBufferPointer<Float>, params: StarFormationGPU
    ) -> StarFormationLeaves {
        let chunks = 64
        let per = (nodes.count + chunks - 1) / chunks
        var partials = [StarFormationLeaves](repeating: StarFormationLeaves(), count: chunks)
        partials.withUnsafeMutableBufferPointer { partials in
            concurrentPerform(iterations: chunks) { chunk in
                var sum = StarFormationLeaves()
                for node in nodes[min(chunk * per, nodes.count)..<min((chunk + 1) * per, nodes.count)]
                where node.isLeaf && node.particleCount > 0 && node.particleStart < order.count {
                    let start = node.particleStart
                    let slots = UnsafeBufferPointer(
                        rebasing: order[start..<min(start + node.particleCount, order.count)])
                    sum.leaf(
                        width: max(node.packed.x, 1e-12).squareRoot(), slots: slots, positions: positions,
                        velocities: velocities, mass: mass, component: component, formation: formation,
                        params: params)
                }
                partials[chunk] = sum
            }
        }
        var total = StarFormationLeaves()
        for partial in partials { total.add(partial) }
        return total
    }

    private mutating func leaf(
        width: Float, slots: UnsafeBufferPointer<UInt32>, positions: UnsafeBufferPointer<SIMD3<Float>>,
        velocities: UnsafeBufferPointer<SIMD3<Float>>, mass: UnsafeBufferPointer<Float>,
        component: UnsafeBufferPointer<UInt32>, formation: UnsafeBufferPointer<Float>,
        params s: StarFormationGPU
    ) {
        leaves += 1
        var baryons: Float = 0
        var unformed = 0
        var count = 0
        var meanPosition = SIMD3<Float>.zero
        var meanVelocity = SIMD3<Float>.zero
        for slot in slots {
            let i = Int(slot)
            guard component[i] != 3 else { continue }
            baryons += mass[i]
            if component[i] == 2 && formation[i] >= 1e8 { unformed += 1 }
            meanPosition += positions[i]
            meanVelocity += velocities[i]
            count += 1
        }
        gas += unformed
        let density = baryons / (width * width * width)
        guard density >= s.threshold else { return }
        dense += 1
        denseGas += unformed
        let base = Double(
            s.efficiency * (32 * s.gravitationalConstant * density / (3 * Float.pi)).squareRoot())
        let freeFall = (s.gravitationalConstant * density).squareRoot()
        var compression: Float = 0
        if count >= 4 && freeFall > 1e-12 {
            meanPosition /= Float(count)
            meanVelocity /= Float(count)
            var flux: Float = 0
            var spread: Float = 0
            for slot in slots where component[Int(slot)] != 3 {
                let dr = positions[Int(slot)] - meanPosition
                flux += simd_dot(velocities[Int(slot)] - meanVelocity, dr)
                spread += simd_dot(dr, dr)
            }
            if spread > 1e-12 {
                let convergence = -3 * flux / spread / freeFall
                compression = max(convergence - s.compressionFloor, 0)
                measured += 1
                if unformed > 0 {
                    var index = 0
                    while index < Self.convergenceEdges.count && convergence >= Self.convergenceEdges[index] {
                        index += 1
                    }
                    measuredGas += unformed
                    gasFreeFall += Double(unformed) * Double(freeFall)
                    gasConvergenceSquared += Double(unformed) * Double(convergence * convergence)
                    binLeaves[index] += 1
                    binGas[index] += unformed
                    binCompressionRate[index] +=
                        Double(unformed) * base * Double(s.compressionBoost * compression)
                }
            }
        }
        let rate = base * Double(1 + s.compressionBoost * compression)
        densityRate += Double(unformed) * base
        compressionRate += Double(unformed) * base * Double(s.compressionBoost * compression)
        drawnRate += Double(unformed) * (1 - exp(-rate * Double(s.timeStep))) / Double(s.timeStep)
    }

    /// The columns of `csvLine`.
    public static var csvHeader: String {
        let bins = 0..<(convergenceEdges.count + 1)
        let fixed = [
            "frame", "time_myr", "step_myr", "leaves", "dense", "measured", "gas", "dense_gas",
            "density_rate", "compression_rate", "drawn_rate", "measured_gas", "gas_free_fall",
            "gas_convergence_sq",
        ]
        return (fixed + ["bl", "bg", "bc"].flatMap { name in bins.map { "\(name)\($0)" } })
            .joined(separator: ",")
    }

    /// One line of `csvHeader`; the rates are stars a megayear.
    public func csvLine(frame: Int, timeMyr: Double, stepMyr: Double) -> String {
        let perMyr = 1 / Physics.megayearsPerTimeUnit
        func g(_ value: Double) -> String { String(format: "%.6g", value) }
        let fields =
            [
                String(frame), String(format: "%.3f", timeMyr), String(format: "%.5f", stepMyr),
                String(leaves), String(dense), String(measured), String(gas), String(denseGas),
                g(densityRate * perMyr), g(compressionRate * perMyr), g(drawnRate * perMyr),
                String(measuredGas), g(gasFreeFall), g(gasConvergenceSquared),
            ] + binLeaves.map(String.init) + binGas.map(String.init)
            + binCompressionRate.map { g($0 * perMyr) }
        return fields.joined(separator: ",")
    }
}
