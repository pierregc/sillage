import SillageCore
import SillageRender
import SwiftUI

struct ControlPanel: View {
    @ObservedObject var model: SimulationModel

    private static let counts = [
        500_000, 1_000_000, 2_000_000, 3_000_000, 5_000_000, 8_000_000, 12_000_000, 20_000_000,
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                transport
                Divider()
                simulation
                Divider()
                rendering
                Divider()
                galaxies
            }
            .padding(12)
        }
        .frame(width: 300)
    }

    private var transport: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button(model.isPlaying ? "Pause" : "Lecture") { model.isPlaying.toggle() }
                Button("Relancer") { model.restart() }
                Button("Recadrer") { model.frameCamera() }
            }
            .buttonStyle(.bordered)

            Text(String(format: "t = %.0f Myr", model.elapsedMyr))
                .font(.caption.monospacedDigit())
            Text(
                String(
                    format: "%.1f ms/frame  ·  %d particules", model.frameMilliseconds, model.particleCount)
            )
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            if let failure = model.failure {
                Text(failure).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var simulation: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Simulation").font(.headline)

            Picker("Scène", selection: presetBinding) {
                Text("Fusion").tag("merger")
                Text("Passage").tag("flyby")
                Text("Disque isolé").tag("disk")
            }
            .pickerStyle(.segmented)

            Picker("Particules", selection: countBinding) {
                ForEach(Self.counts, id: \.self) { count in
                    Text(count >= 1_000_000 ? "\(count / 1_000_000) M" : "\(count / 1000) k").tag(count)
                }
            }

            Stepper("Pas par image : \(model.stepsPerFrame)", value: $model.stepsPerFrame, in: 1...64)
                .font(.caption)

            ParameterSlider(
                title: "Pas de temps", value: $model.scene.timeStep, range: 0.002...0.05,
                format: "%.3f")
        }
    }

    private var rendering: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Rendu").font(.headline)
            ParameterSlider(title: "Luminosité", value: $model.brightness, range: 0.005...0.4, format: "%.3f")
            ParameterSlider(title: "Étirement log", value: $model.stretch, range: 0...60, format: "%.0f")
            ParameterSlider(title: "Saturation", value: $model.saturation, range: 0...3)
            ParameterSlider(title: "Bloom", value: $model.bloom, range: 0...2)
            ParameterSlider(title: "Taille des points", value: $model.pointSize, range: 0.8...6)
            ParameterSlider(title: "Exposition", value: $model.exposure, range: 0.1...4)
            Picker("Suréchantillonnage", selection: $model.supersample) {
                Text("1×").tag(1)
                Text("2×").tag(2)
            }
            .pickerStyle(.segmented)
        }
    }

    private var galaxies: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Galaxies").font(.headline)
            ForEach(model.scene.galaxies.indices, id: \.self) { index in
                DisclosureGroup(model.scene.galaxies[index].name) {
                    galaxyEditor(index)
                }
                .font(.callout)
            }
        }
    }

    @ViewBuilder
    private func galaxyEditor(_ index: Int) -> some View {
        let galaxy = $model.scene.galaxies[index]
        VStack(alignment: .leading, spacing: 6) {
            Picker("Profil", selection: galaxy.potential.profile) {
                Text("Plummer").tag(PotentialProfile.plummer)
                Text("Hernquist").tag(PotentialProfile.hernquist)
            }
            .pickerStyle(.segmented)
            .onChange(of: model.scene.galaxies[index].potential.profile) { model.restart() }

            Picker("Rotation", selection: galaxy.spin) {
                Text("Prograde").tag(Spin.prograde)
                Text("Rétrograde").tag(Spin.retrograde)
            }
            .pickerStyle(.segmented)
            .onChange(of: model.scene.galaxies[index].spin) { model.restart() }

            ParameterSlider(
                title: "Masse", value: galaxy.potential.mass, range: 1...200, format: "%.0f",
                onCommit: model.restart)
            ParameterSlider(
                title: "Rayon d'échelle", value: galaxy.potential.scaleRadius, range: 0.5...20,
                format: "%.1f", onCommit: model.restart)
            ParameterSlider(
                title: "Longueur de disque", value: galaxy.diskScaleLength, range: 0.5...15, format: "%.1f",
                onCommit: model.restart)
            ParameterSlider(
                title: "Troncature", value: galaxy.diskTruncation, range: 1...8, format: "%.1f",
                onCommit: model.restart)
            ParameterSlider(
                title: "Épaisseur", value: galaxy.diskThickness, range: 0...3, onCommit: model.restart)
            ParameterSlider(
                title: "Dispersion", value: galaxy.velocityDispersion, range: 0...0.5, onCommit: model.restart
            )
            ParameterSlider(
                title: "Inclinaison", value: galaxy.inclination, range: -1.57...1.57, onCommit: model.restart)
            ParameterSlider(
                title: "Angle de position", value: galaxy.positionAngle, range: 0...6.28,
                onCommit: model.restart)
            VectorEditor(
                title: "Position (kpc)", value: galaxy.position, range: -150...150, onCommit: model.restart)
            VectorEditor(title: "Vitesse", value: galaxy.velocity, range: -3...3, onCommit: model.restart)
        }
        .padding(.leading, 6)
    }

    private var presetBinding: Binding<String> {
        Binding(
            get: {
                model.scene.name.lowercased().contains("fly")
                    ? "flyby"
                    : model.scene.name.lowercased().contains("isolated") ? "disk" : "merger"
            },
            set: { name in
                let total = model.scene.totalParticleCount
                switch name {
                case "flyby": model.scene = .flyby(particleCount: total)
                case "disk": model.scene = .isolatedDisk(particleCount: total)
                default: model.scene = .merger(particleCount: total)
                }
                model.restart()
                model.frameCamera()
            })
    }

    private var countBinding: Binding<Int> {
        Binding(
            get: {
                Self.counts.min(by: { abs($0 - model.particleCount) < abs($1 - model.particleCount) })
                    ?? 3_000_000
            },
            set: { model.setTotalParticles($0) })
    }
}
