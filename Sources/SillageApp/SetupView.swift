import SillageCore
import SwiftUI

struct SetupView: View {
    @ObservedObject var model: SimulationModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                SetupContent(model: model)
                    .padding(20)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
            }
            Divider()
            footer
        }
        .panelSurface()
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Sillage").font(.largeTitle.bold())
                Text("Réglage de la collision").foregroundStyle(Palette.secondary)
            }
            Spacer()
        }
        .padding(20)
    }

    private var footer: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(
                    "\(model.draft.galaxies.count) galaxies · \(formatted(model.draft.totalParticleCount)) particules"
                )
                .font(.callout.monospacedDigit())
                Text(costLabel)
                    .font(.caption)
                    .foregroundStyle(
                        model.estimatedStepMilliseconds > 8 ? Palette.warning : Palette.secondary)
            }
            Spacer()
            Button("Lancer la simulation") { model.start() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(model.draft.galaxies.isEmpty)
        }
        .padding(20)
    }

    private var costLabel: String {
        let ms = model.estimatedStepMilliseconds
        let verdict = ms > 8 ? "au-delà du temps réel, la lecture ralentira" : "temps réel"
        return String(format: "environ %.1f ms de calcul par image · %@", ms, verdict)
    }

    private func formatted(_ value: Int) -> String {
        value >= 1_000_000
            ? String(format: "%.1f M", Double(value) / 1_000_000)
            : "\(value / 1000) k"
    }
}

/// Split out from the scroll view so it can be rendered offscreen for inspection.
struct SetupContent: View {
    @ObservedObject var model: SimulationModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            presets
            global
            ForEach(model.draft.galaxies.indices, id: \.self) { index in
                GalaxyCard(model: model, index: index)
            }
            Button {
                model.addGalaxy()
            } label: {
                Label("Ajouter une galaxie", systemImage: "plus.circle")
            }
            .buttonStyle(.bordered)
        }
    }

    private var total: Int { max(model.draft.totalParticleCount, 100_000) }

    private var presets: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Partir d'un préréglage").font(.headline)
            HStack {
                Button("Fusion") { model.loadPreset(.merger(particleCount: total)) }
                Button("Passage rapproché") { model.loadPreset(.flyby(particleCount: total)) }
                Button("Disque isolé") { model.loadPreset(.isolatedDisk(particleCount: total)) }
            }
            .buttonStyle(.bordered)
        }
    }

    private var global: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Simulation").font(.headline)
            HStack {
                Text("Graine aléatoire").font(.caption)
                Spacer()
                TextField(
                    "graine",
                    value: Binding(get: { model.draft.seed }, set: { model.draft.seed = $0 }),
                    format: .number
                )
                .frame(width: 90)
                .textFieldStyle(.roundedBorder)
            }
            ParameterSlider(
                title: "Pas de temps (4,71 Myr par unité)", value: $model.draft.timeStep,
                range: 0.002...0.05, format: "%.3f")
        }
    }
}

struct GalaxyCard: View {
    @ObservedObject var model: SimulationModel
    let index: Int

    var body: some View {
        let galaxy = $model.draft.galaxies[index]
        Card {
            Group {
                HStack {
                    TextField("nom", text: galaxy.name)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                    Spacer()
                    Button(role: .destructive) {
                        model.removeGalaxy(at: index)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(model.draft.galaxies.count <= 1)
                }

                Picker("Type", selection: galaxy.kind) {
                    ForEach(GalaxyKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Profil de masse", selection: galaxy.potential.profile) {
                    Text("Plummer").tag(PotentialProfile.plummer)
                    Text("Hernquist").tag(PotentialProfile.hernquist)
                }
                .pickerStyle(.segmented)

                particleCountRow(galaxy)

                Group {
                    ParameterSlider(
                        title: "Masse (10¹⁰ M☉)", value: galaxy.potential.mass, range: 1...200,
                        format: "%.0f")
                    ParameterSlider(
                        title: "Rayon d'échelle (kpc)", value: galaxy.potential.scaleRadius,
                        range: 0.5...20, format: "%.1f")
                    ParameterSlider(
                        title: "Taille (kpc)", value: galaxy.diskScaleLength, range: 0.5...15,
                        format: "%.1f")
                    ParameterSlider(
                        title: "Étendue (en tailles)", value: galaxy.diskTruncation, range: 1...8,
                        format: "%.1f")
                }

                if model.draft.galaxies[index].kind != .globular {
                    Group {
                        ParameterSlider(
                            title: "Épaisseur (kpc)", value: galaxy.diskThickness, range: 0...3)
                        ParameterSlider(
                            title: "Dispersion des vitesses", value: galaxy.velocityDispersion,
                            range: 0...0.5)
                        ParameterSlider(
                            title: "Inclinaison (rad)", value: galaxy.inclination,
                            range: -1.57...1.57)
                        ParameterSlider(
                            title: "Angle de position (rad)", value: galaxy.positionAngle,
                            range: 0...6.28)
                        Picker("Rotation", selection: galaxy.spin) {
                            Text("Prograde").tag(Spin.prograde)
                            Text("Rétrograde").tag(Spin.retrograde)
                        }
                        .pickerStyle(.segmented)
                    }
                }

                if model.draft.galaxies[index].kind == .spiral {
                    Stepper(
                        "Bras : \(model.draft.galaxies[index].armCount)", value: galaxy.armCount,
                        in: 1...8
                    )
                    .font(.caption)
                    ParameterSlider(
                        title: "Contraste des bras", value: galaxy.armStrength, range: 0...0.95)
                    ParameterSlider(
                        title: "Enroulement (rad)", value: galaxy.armPitch, range: 0.08...0.9)
                }

                VectorEditor(title: "Position (kpc)", value: galaxy.position, range: -150...150)
                VectorEditor(title: "Vitesse (207 km/s par unité)", value: galaxy.velocity, range: -3...3)
            }
        }
    }

    @ViewBuilder
    private func particleCountRow(_ galaxy: Binding<GalaxyConfig>) -> some View {
        let count = Binding<Float>(
            get: { Float(model.draft.galaxies[index].particleCount) },
            set: { model.draft.galaxies[index].particleCount = Int($0) })
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text("Particules").font(.caption)
                Spacer()
                Text(
                    model.draft.galaxies[index].particleCount >= 1_000_000
                        ? String(
                            format: "%.2f M",
                            Double(model.draft.galaxies[index].particleCount) / 1_000_000)
                        : "\(model.draft.galaxies[index].particleCount / 1000) k"
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(Palette.secondary)
            }
            Slider(value: count, in: 50_000...10_000_000)
        }
    }
}
