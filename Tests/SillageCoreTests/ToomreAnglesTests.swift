import Foundation
import Testing

@testable import SillageCore

#if canImport(simd)
    import simd
#endif

/// Toomre and Toomre's disk angles (i, w), as Karl et al. 2010 and Privon et al. 2013 give them,
/// against `Encounter.Disk` (#523). Each disk's angles are read against its own companion: z along
/// the orbit's angular momentum, x towards the companion at pericentre, w counted in the orbit
/// plane from a node to the pericentre along the motion. From the descending node, the reading
/// `references/antennae/tools/make_scene.py` writes by default, the spin is
/// (-sin i sin w, -sin i cos w, cos i); from the ascending node, its half turn about z. Sillage
/// counts both disks' arguments from the line that runs from the primary to the secondary at
/// pericentre: from the descending node a = -w for the primary and 180 - w for the secondary,
/// from the ascending node 180 - w and -w.
@Suite("Toomre and Toomre's angles")
struct ToomreAnglesTests {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func degrees(_ value: Double) -> Float { Float(value * .pi / 180) }

    /// The spin a disk takes in the scene, which is the orbit's frame when the plane is not
    /// tilted: its axis times the sign of its spin.
    static func spin(_ galaxy: GalaxyConfig) -> SIMD3<Float> {
        galaxy.orientation.columns.2 * galaxy.spin.sign
    }

    static func placed(primary: Encounter.Disk, secondary: Encounter.Disk) throws -> SceneConfig {
        var scene = SceneConfig.merger(particleCount: 20_000)
        scene.solver = .restricted
        scene.encounters = [
            Encounter(
                pericentre: 10, eccentricity: 1, massRatio: 1, pericentreTime: 150,
                primaryDisk: primary, secondaryDisk: secondary)
        ]
        try scene.placeEncounters()
        return scene
    }

    static func expectClose(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ what: String) {
        #expect(simd_length(a - b) < 1e-4, "\(what): \(a) against \(b)")
    }

    /// The vectors worked out by hand from the definition, one case per question: where w is
    /// counted from, which way it turns, and which side the companion lies on for each disk. At
    /// pericentre the secondary is at +x from the primary and moves along +y.
    @Test func handWorkedSpins() throws {
        let h = Float(3).squareRoot() / 2  // sin 60
        // Descending, w = 0: the pericentre at the node where the companion goes down through the
        // disk. The primary's companion, at +x moving along +y, goes down: the spin leans to -y.
        // The secondary's, at -x moving along -y, goes down: its spin leans to +y.
        var scene = try Self.placed(
            primary: Encounter.Disk(inclination: Self.degrees(60), argument: 0),
            secondary: Encounter.Disk(inclination: Self.degrees(60), argument: Self.degrees(180)))
        Self.expectClose(Self.spin(scene.galaxies[0]), SIMD3(0, -h, 0.5), "primary, descending, w = 0")
        Self.expectClose(Self.spin(scene.galaxies[1]), SIMD3(0, h, 0.5), "secondary, descending, w = 0")

        // Descending, w = 90: a quarter turn past that node the companion is at its lowest under the
        // disk, so the spin leans away from it: -x for the primary, +x for the secondary.
        scene = try Self.placed(
            primary: Encounter.Disk(inclination: Self.degrees(60), argument: Self.degrees(270)),
            secondary: Encounter.Disk(inclination: Self.degrees(60), argument: Self.degrees(90)))
        Self.expectClose(Self.spin(scene.galaxies[0]), SIMD3(-h, 0, 0.5), "primary, descending, w = 90")
        Self.expectClose(Self.spin(scene.galaxies[1]), SIMD3(h, 0, 0.5), "secondary, descending, w = 90")

        // Ascending, w = 90: the companion at its highest over the disk, the spin leaning towards
        // it: +x for the primary, -x for the secondary. Sillage's arguments 90 and 270.
        scene = try Self.placed(
            primary: Encounter.Disk(inclination: Self.degrees(60), argument: Self.degrees(90)),
            secondary: Encounter.Disk(inclination: Self.degrees(60), argument: Self.degrees(270)))
        Self.expectClose(Self.spin(scene.galaxies[0]), SIMD3(h, 0, 0.5), "primary, ascending, w = 90")
        Self.expectClose(Self.spin(scene.galaxies[1]), SIMD3(-h, 0, 0.5), "secondary, ascending, w = 90")
    }

    /// Prograde at 60 degrees: the disk turns with the orbit, its spin half along the orbit's
    /// angular momentum, and its stars carry that spin.
    @Test func progradeAtSixtyDegreesTurnsWithTheOrbit() throws {
        let scene = try Self.placed(
            primary: Encounter.Disk(inclination: Self.degrees(60), argument: Self.degrees(150)),
            secondary: Encounter.Disk(inclination: Self.degrees(60), argument: Self.degrees(300)))
        let centres = scene.galaxies
        // The relative orbit's angular momentum, from where the centres start.
        let r = centres[1].position - centres[0].position
        let v = centres[1].velocity - centres[0].velocity
        let orbit = simd_normalize(simd_cross(r, v))
        Self.expectClose(orbit, SIMD3(0, 0, 1), "the orbit turns about +z")

        for (index, galaxy) in scene.galaxies.enumerated() {
            var config = galaxy
            config.particleCount = 4000
            config.haloParticleRatio = 0
            var system = ParticleSystem()
            var generator = SeededGenerator(seed: 11)
            DiskSampler.sample(config, galaxyIndex: 0, into: &system, using: &generator)
            var momentum = SIMD3<Float>.zero
            for k in 0..<system.count where system.component[k] == ParticleComponent.star.rawValue {
                let p = system.positions[k] - config.position
                let u = system.velocities[k] - config.velocity
                momentum += simd_cross(p, u)
            }
            let axis = simd_normalize(momentum)
            #expect(simd_dot(axis, Self.spin(galaxy)) > 0.99, "galaxy \(index): stars turn about \(axis)")
            #expect(abs(simd_dot(axis, orbit) - 0.5) < 0.02, "galaxy \(index): cos 60 along the orbit")
        }
    }

    /// The two scenes on file carry the papers' angles: the spins they give are the ones worked
    /// out from (i, w) above, and the ones `view.json` lists.
    @Test func antennaeScenesCarryThePapersSpins() throws {
        // (i, w) for NGC 4038 and NGC 4039.
        let papers: [(String, [(Double, Double)])] = [
            ("karl", [(60, 30), (60, 60)]),
            ("privon", [(65, 345), (70, 95)]),
        ]
        for (model, angles) in papers {
            let folder = Self.root.appendingPathComponent("references/antennae/\(model)")
            let file = try SceneFile.decoded(
                from: Data(contentsOf: folder.appendingPathComponent("scene.json")))
            var scene = file.scene(particleCount: 20_000)
            try scene.placeEncounters()
            let view =
                try JSONSerialization.jsonObject(
                    with: Data(contentsOf: folder.appendingPathComponent("view.json"))) as? [String: Any]
            let listed = view?["spins"] as? [String: [Double]] ?? [:]
            for (index, (i, w)) in angles.enumerated() {
                let si = sin(i * .pi / 180)
                let ci = cos(i * .pi / 180)
                let sw = sin(w * .pi / 180)
                let cw = cos(w * .pi / 180)
                // The descending reading the files are written in.
                let side: Double = index == 0 ? -1 : 1
                let expected = SIMD3<Float>(Float(side * si * sw), Float(side * si * cw), Float(ci))
                Self.expectClose(Self.spin(scene.galaxies[index]), expected, "\(model) galaxy \(index)")
                let name = scene.galaxies[index].name
                let written = listed[name] ?? []
                #expect(written.count == 3, "\(model): view.json lists \(name)'s spin")
                if written.count == 3 {
                    Self.expectClose(
                        SIMD3(Float(written[0]), Float(written[1]), Float(written[2])), expected,
                        "\(model) \(name) in view.json")
                }
                #expect(scene.galaxies[index].spin == .prograde)
            }
            #expect(scene.encounters.first?.massRatio == 1)
        }
    }
}
