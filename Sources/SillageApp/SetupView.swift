import SillageCore
import SillageRender
import SwiftUI

struct SetupView: View {
    @ObservedObject var model: SimulationModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                ScrollView {
                    SetupContent(model: model).padding(18)
                }
                .frame(width: 430)
                Divider()
                ZStack(alignment: .bottomLeading) {
                    PreviewCanvas(model: model).background(Palette.canvas)
                    previewCaption
                }
                .frame(minWidth: 420)
            }
            Divider()
            footer
        }
        .panelSurface()
        .onAppear { model.rebuildPreview() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Sillage").font(.largeTitle.bold())
                Text("Réglage de la collision").foregroundStyle(Palette.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    /// The preview never steps, so it is honest about what it shows.
    private var previewCaption: some View {
        Text(
            "Conditions initiales, figées · \(model.previewParticleCount / 1000) k affichées · glisser pour tourner"
        )
        .font(.caption)
        .foregroundStyle(Palette.secondary)
        .padding(10)
    }

    private var footer: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(
                    "\(model.draft.galaxies.count) galaxies · \(formatted(model.draft.totalParticleCount)) visibles"
                        + (model.draft.hasLiveHalos
                            ? " · \(formatted(model.draft.simulatedParticleCount - model.draft.totalParticleCount)) de halo"
                            : "")
                )
                .font(.callout.monospacedDigit())
                Text(costLabel)
                    .font(.caption)
                    .foregroundStyle(
                        model.estimatedMegayearsPerSecond < 0.3
                            ? Palette.warning : Palette.secondary)
            }
            Button("Ouvrir une prise…") { TakeFiles.open(model) }
                .buttonStyle(.bordered)
            Menu("Contemplation") {
                Button("Lente — 5 min par scène") { model.startContemplation(pace: .slow) }
                Button("Rapide — 1 min par scène") { model.startContemplation(pace: .brisk) }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Plein écran, sans réglages: des scènes générées et filmées d'elles-mêmes")
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Button("Lancer la simulation") { model.start() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.draft.galaxies.isEmpty)
                Text("la prise s'enregistre dès le lancement")
                    .font(.caption2)
                    .foregroundStyle(Palette.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    /// Nothing waits for the physics any more, so the honest number is not milliseconds a
    /// frame but how long the machine takes to reach the moment worth looking at. A close
    /// encounter plays out over roughly 500 Myr.
    private var costLabel: String {
        let rate = model.estimatedMegayearsPerSecond
        guard rate > 0 else { return "" }
        let seconds = 500 / rate
        let reach =
            seconds < 90
            ? String(format: "%.0f s", seconds)
            : (seconds < 5400
                ? String(format: "%.0f min", seconds / 60)
                : String(format: "%.1f h", seconds / 3600))
        return String(
            format: "environ %.1f Myr par seconde · une rencontre de 500 Myr en %@", rate, reach)
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
                model.commitDraftChange()
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
                presetButton("Rencontre", .encounter(particleCount: total))
                presetButton("Fusion", .merger(particleCount: total))
                presetButton("Passage rapproché", .flyby(particleCount: total))
                presetButton("Disque isolé", .isolatedDisk(particleCount: total))
            }
        }
    }

    /// Loading the preset already showing changes nothing visible, so the current one is
    /// marked: otherwise the button reads as dead.
    private func presetButton(_ title: String, _ scene: SceneConfig) -> some View {
        Button(title) { load(scene) }
            .buttonStyle(.bordered)
            .tint(model.draft.name == scene.name ? Palette.label : Palette.secondary)
    }

    private func load(_ scene: SceneConfig) {
        model.loadPreset(scene)
        model.commitDraftChange()
    }

    private var global: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Gravité").font(.headline)

            Picker("", selection: solverBinding) {
                Text("Auto-gravitante").tag(SolverKind.barnesHut)
                Text("Particules-tests").tag(SolverKind.restricted)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(
                model.draft.solver == .barnesHut
                    ? "Les particules s'attirent entre elles, halo compris. C'est la friction contre le halo qui fait fusionner les galaxies. Lent, mais la prise s'enregistre toute seule : laisse tourner, puis rejoue."
                    : "Particules-tests dans des potentiels rigides. Cent fois plus rapide, donne les queues de marée, mais rien ne fusionne."
            )
            .font(.caption)
            .foregroundStyle(Palette.secondary)

            HStack {
                Text("Graine aléatoire").font(.caption)
                Spacer()
                TextField(
                    "graine",
                    value: Binding(
                        get: { model.draft.seed },
                        set: {
                            model.draft.seed = $0
                            model.commitDraftChange()
                        }),
                    format: .number
                )
                .frame(width: 90)
                .textFieldStyle(.roundedBorder)
            }

            // Softening follows from the particle count and the disk size; there is no useful
            // way to pick it by hand, so it is shown rather than offered. The step is derived
            // the same way, but how much accuracy a run needs is the user's call, so that one
            // is a multiplier on the derived value rather than a number to guess at.
            ParameterSlider(
                title: "Vitesse d'exploration", value: speedBinding, range: 1...32,
                format: "%.0f×", onCommit: { model.commitDraftChange() })

            Text(
                String(
                    format: "adoucissement %.3f kpc · pas %.4f (%.2f Myr) · %.1f Myr par seconde",
                    model.draft.softening, model.draft.timeStep,
                    Double(model.draft.timeStep) * Physics.megayearsPerTimeUnit,
                    model.estimatedMegayearsPerSecond)
            )
            .font(.caption.monospacedDigit())
            .foregroundStyle(Palette.secondary)

            Text(
                model.draft.timeStepScale > 16
                    ? "Au-delà de 16× la structure commence à s'écarter : bon pour cadrer une rencontre, pas pour une prise."
                    : "Multiplie le pas calé automatiquement. Jusqu'à 16×, un disque isolé garde son profil à 0,3 % près."
            )
            .font(.caption2)
            .foregroundStyle(model.draft.timeStepScale > 16 ? Palette.warning : Palette.secondary)
        }
    }

    private var speedBinding: Binding<Float> {
        Binding(
            get: { model.draft.timeStepScale },
            set: { model.draft.timeStepScale = $0 })
    }

    /// Switching model retunes the step and the softening, which differ by orders of magnitude
    /// between tracers in a rigid potential and a self-gravitating disk.
    private var solverBinding: Binding<SolverKind> {
        Binding(
            get: { model.draft.solver },
            set: { kind in
                model.draft.solver = kind
                model.commitDraftChange()
            })
    }
}

struct GalaxyCard: View {
    @ObservedObject var model: SimulationModel
    let index: Int

    private var commit: () -> Void { { model.commitDraftChange() } }

    /// A preset can shrink the list while this card is still on screen, and SwiftUI evaluates
    /// the body once more with the stale index before dropping the view. Subscripting the
    /// draft unguarded there is what used to kill the app on "Disque isolé".
    var body: some View {
        if model.draft.galaxies.indices.contains(index) {
            card
        }
    }

    private var card: some View {
        let galaxy = $model.draft.galaxies[index]
        let kind = model.draft.galaxies[index].kind
        return Card {
            Group {
                HStack {
                    TextField("nom", text: galaxy.name)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                    Spacer()
                    Button(role: .destructive) {
                        model.removeGalaxy(at: index)
                        model.commitDraftChange()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(model.draft.galaxies.count <= 1)
                }

                Picker("", selection: galaxy.kind) {
                    ForEach(GalaxyKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: kind) { model.commitDraftChange() }

                particleCountRow(galaxy)

                Group {
                    ParameterSlider(
                        title: "Masse (10¹⁰ M☉)", value: galaxy.potential.mass, range: 5...200,
                        format: "%.0f", onCommit: commit)
                    ParameterSlider(
                        title: "Rayon du disque (kpc)", value: sizeBinding, range: 1...14,
                        format: "%.1f", onCommit: commit)
                    if kind != .globular {
                        ParameterSlider(
                            title: "Épaisseur (kpc)", value: galaxy.diskThickness, range: 0.05...2,
                            onCommit: commit)
                    }
                }

                if kind != .globular {
                    Divider()
                    Text("Bulbe").font(.caption.bold())
                    ParameterSlider(
                        title: "Part des étoiles", value: galaxy.bulgeFraction, range: 0...0.6,
                        onCommit: commit)
                    ParameterSlider(
                        title: "Rayon (longueurs de disque)", value: galaxy.bulgeExtent,
                        range: 0.05...0.6, onCommit: commit)
                    ParameterSlider(
                        title: "Aplatissement", value: galaxy.bulgeFlattening, range: 0.3...1,
                        onCommit: commit)
                    Text("Sphéroïde de Hernquist soutenu par la dispersion. À 0 la galaxie est un disque nu.")
                        .font(.caption2)
                        .foregroundStyle(Palette.secondary)
                }

                if kind != .globular {
                    Group {
                        ParameterSlider(
                            title: "Inclinaison (rad)", value: galaxy.inclination,
                            range: -1.57...1.57, onCommit: commit)
                        ParameterSlider(
                            title: "Orientation (rad)", value: galaxy.positionAngle,
                            range: 0...6.28, onCommit: commit)
                        Picker("", selection: galaxy.spin) {
                            Text("Prograde").tag(Spin.prograde)
                            Text("Rétrograde").tag(Spin.retrograde)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .onChange(of: model.draft.galaxies[index].spin) { commit() }
                    }
                }

                if kind == .spiral {
                    Stepper(
                        "Bras : \(model.draft.galaxies[index].armCount)", value: galaxy.armCount,
                        in: 1...6
                    )
                    .font(.caption)
                    .onChange(of: model.draft.galaxies[index].armCount) { commit() }
                    ParameterSlider(
                        title: "Contraste des bras", value: galaxy.armStrength, range: 0...0.95,
                        onCommit: commit)
                }

                if model.draft.solver == .barnesHut {
                    Divider()
                    Text("Auto-gravité").font(.caption.bold())
                    ParameterSlider(
                        title: "Dissipation du disque (Myr)", value: galaxy.dissipationTime,
                        range: 0...1500, format: "%.0f", onCommit: commit)
                    Text(
                        "Un disque d'étoiles seules ne peut que chauffer : ses bras s'éteignent en un milliard d'années. Le gaz d'une vraie galaxie dissipe ce désordre. 0 coupe l'effet."
                    )
                    .font(.caption2)
                    .foregroundStyle(Palette.secondary)
                    ParameterSlider(
                        title: "Halo simulé, particules par étoile",
                        value: galaxy.haloParticleRatio, range: 0...4, onCommit: commit)
                    ParameterSlider(
                        title: "Part de masse dans le disque", value: galaxy.diskMassFraction,
                        range: 0.05...1.0, onCommit: commit)
                    ParameterSlider(
                        title: "Stabilité du disque (Toomre Q)", value: galaxy.toomreQ,
                        range: 0.4...2.5, onCommit: commit)
                    Text("Sous 1 le disque se fragmente et chauffe. 1,2 à 1,6 est la zone sûre.")
                        .font(.caption2)
                        .foregroundStyle(Palette.secondary)
                }

                VectorEditor(
                    title: "Position (kpc)", value: galaxy.position, range: -150...150,
                    onCommit: commit)
                VectorEditor(
                    title: "Vitesse (207 km/s par unité)", value: galaxy.velocity, range: -3...3,
                    onCommit: commit)
            }
        }
    }

    /// The halo's scale radius has no meaning of its own next to the disk radius, so it
    /// follows it at the ratio a real galaxy shows rather than being a separate control.
    private var sizeBinding: Binding<Float> {
        Binding(
            get: { exists ? model.draft.galaxies[index].diskScaleLength : 1 },
            set: { value in
                guard exists else { return }
                model.draft.galaxies[index].diskScaleLength = value
                model.draft.galaxies[index].potential.scaleRadius = value * 1.25
            })
    }

    /// A slider can still be mid-drag when a preset drops the galaxy under it.
    private var exists: Bool { model.draft.galaxies.indices.contains(index) }

    @ViewBuilder
    private func particleCountRow(_ galaxy: Binding<GalaxyConfig>) -> some View {
        let count = Binding<Float>(
            get: { exists ? Float(model.draft.galaxies[index].particleCount) : 50_000 },
            set: {
                guard exists else { return }
                model.draft.galaxies[index].particleCount = Int($0)
            })
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text("Étoiles affichées").font(.caption)
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
            Slider(value: count, in: 50_000...8_000_000) { editing in
                if !editing { model.commitDraftChange() }
            }
        }
    }
}
