import Foundation
import SillageCore
import SillageRender

/// The curves a solver check compares between engines (#274): one line a sampled step, from
/// what any solver gives of its massive particles. No Metal here, so both engines write the
/// same numbers.
public enum SolverCurves {
    static let perGalaxy = [
        "cx", "cy", "cz", "thickness", "coherence", "disruption", "torn", "ax", "ay", "az",
    ]

    public static func header(galaxies: Int) -> String {
        var columns = ["step", "time"]
        for galaxy in 0..<galaxies { columns += perGalaxy.map { "\($0)_\(galaxy)" } }
        columns += ["px", "py", "pz", "mx", "my", "mz", "formed"]
        return columns.joined(separator: ",") + "\n"
    }

    /// `particles` laid out `[visible | halo]` as the solver holds them now; `sampled` is the
    /// formation time each was sampled with.
    public static func line(
        step: Int, time: Float, particles: ParticleSystem, sampled: [Float],
        centers: [SIMD3<Float>], disks: [DiskState]
    ) -> String {
        func f(_ value: Float) -> String { String(format: "%.9g", Double(value)) }
        func d(_ value: Double) -> String { String(format: "%.17g", value) }
        var fields = ["\(step)", f(time)]
        for galaxy in centers.indices {
            let centre = centers[galaxy]
            let disk = galaxy < disks.count ? disks[galaxy] : DiskState(axis: .zero)
            fields += [
                f(centre.x), f(centre.y), f(centre.z), f(disk.thickness), f(disk.coherence),
                f(disk.disruption), f(disk.torn), f(disk.axis.x), f(disk.axis.y), f(disk.axis.z),
            ]
        }
        // Summed in double, in index order, a component at a time.
        var momentum = (0.0, 0.0, 0.0)
        var moment = (0.0, 0.0, 0.0)
        var total = 0.0
        for index in 0..<particles.count {
            let mass = Double(particles.mass[index])
            let velocity = particles.velocities[index]
            let position = particles.positions[index]
            momentum.0 += mass * Double(velocity.x)
            momentum.1 += mass * Double(velocity.y)
            momentum.2 += mass * Double(velocity.z)
            moment.0 += mass * Double(position.x)
            moment.1 += mass * Double(position.y)
            moment.2 += mass * Double(position.z)
            total += mass
        }
        let scale = total > 0 ? 1 / total : 0
        fields += [d(momentum.0), d(momentum.1), d(momentum.2)]
        fields += [d(moment.0 * scale), d(moment.1 * scale), d(moment.2 * scale)]
        var formed = 0
        for index in 0..<min(particles.visibleCount, sampled.count)
        where particles.formation[index].bitPattern != sampled[index].bitPattern {
            formed += 1
        }
        fields.append("\(formed)")
        return fields.joined(separator: ",") + "\n"
    }

    /// The visible particles counted on the xy grid at each of `instants` sampled steps.
    public static func maps(instants: Int, extent: Float = 80) -> DensityMap {
        DensityMap(frames: instants, count: instants, extent: extent)
    }
}
