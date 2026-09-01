import AppKit
import Metal
import MetalKit
import SillageCore
import SillageRender
import simd

/// Editing the scene before it is run. Nothing here touches a solver: the draft is committed
/// to `scene` only when the run starts.
extension SimulationModel {
    func loadPreset(_ preset: SceneConfig) {
        // The exploration speed is how the user wants to watch, not part of the scene, so a
        // preset must not quietly undo it.
        let speed = draft.timeStepScale
        draft = preset
        draft.timeStepScale = speed
    }

    /// Softening and time step follow from the particle count and the disk size, so anything
    /// that changes either has to retune them before the preview is rebuilt.
    func commitDraftChange() {
        draft.retune()
        rebuildPreview()
    }

    func addGalaxy() {
        let share = max(draft.totalParticleCount / max(draft.galaxies.count, 1), 100_000)
        draft.galaxies.append(
            GalaxyConfig(
                name: "Galaxie \(draft.galaxies.count + 1)",
                particleCount: share,
                kind: .spiral,
                potential: GalaxyPotential(profile: .hernquist, mass: 30, scaleRadius: 4),
                diskScaleLength: 3,
                diskTruncation: 5,
                position: SIMD3<Float>(0, 60, 0),
                velocity: SIMD3<Float>(-0.5, 0, 0)))
    }

    func removeGalaxy(at index: Int) {
        guard draft.galaxies.count > 1, draft.galaxies.indices.contains(index) else { return }
        draft.galaxies.remove(at: index)
    }

    /// Scales every galaxy's share of the draft so the preset's own ratio is preserved.
    func setTotalParticles(_ total: Int) {
        let current = draft.totalParticleCount
        guard current > 0, total > 0 else { return }
        let ratio = Double(total) / Double(current)
        for index in draft.galaxies.indices {
            draft.galaxies[index].particleCount =
                max(Int(Double(draft.galaxies[index].particleCount) * ratio), 1)
        }
        draft.galaxies[0].particleCount += total - draft.totalParticleCount
    }

    /// Rough simulation cost per frame on this GPU, measured at about 0.18 ms per million
    /// particles per step for the restricted solver and about 110 ms for Barnes-Hut, which
    /// also scales a little worse than linearly. Shown in the setup screen so the particle
    /// count can be chosen knowing what it costs.
    var estimatedStepMilliseconds: Double {
        let millions = Double(draft.simulatedParticleCount) / 1_000_000
        let perStep = draft.solver == .barnesHut ? 110 * pow(millions, 1.15) : 0.18 * millions
        return perStep * Double(stepsPerFrame)
    }

    /// What the draft would advance at, before it is run. The measured rate replaces this
    /// as soon as there is one.
    var estimatedMegayearsPerSecond: Double {
        let perStep = estimatedStepMilliseconds / Double(max(stepsPerFrame, 1))
        guard perStep > 0 else { return 0 }
        return Double(draft.timeStep) * Physics.megayearsPerTimeUnit * (1000 / perStep)
    }
}
