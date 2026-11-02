// Prints the softening and time step sillage-render derives for --scene FILE --particles N
// [--halo R], following main.swift: the file's ratio unless a halo is given, then
// file.scene(particleCount:), which retunes both from the counts.
import Foundation
import SillageCore

let args = CommandLine.arguments
let path = args[1]
let particles = Int(args[2])!
let halo = args.count > 3 ? Float(args[3]) : nil
var file = try SceneFile.decoded(from: Data(contentsOf: URL(fileURLWithPath: path)))
let placedFor = file.galaxies.map(\.haloParticleRatio)
if let halo {
    for index in file.galaxies.indices where file.galaxies[index].kind != .blackHole {
        file.galaxies[index].haloParticleRatio = halo
    }
}
var scene = file.scene(particleCount: particles)
if !scene.encounters.isEmpty, placedFor != file.galaxies.map(\.haloParticleRatio) {
    scene.placeEncountersGivingWay()
}
print(String(format: "visible %d halo %d simulated %d softening %.5f kpc timeStep %.6f units = %.5f Myr (scale %.2f)",
    scene.totalParticleCount, scene.simulatedParticleCount - scene.totalParticleCount,
    scene.simulatedParticleCount, scene.softening, scene.timeStep,
    Double(scene.timeStep) * Physics.megayearsPerTimeUnit, scene.timeStepScale))
