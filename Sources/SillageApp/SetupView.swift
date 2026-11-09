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
                Text("Collision setup").foregroundStyle(Palette.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    /// The preview never steps, so it is honest about what it shows.
    private var previewCaption: some View {
        Text(
            "Initial conditions, frozen · \(model.previewParticleCount / 1000) k shown · drag to rotate"
        )
        .font(.caption)
        .foregroundStyle(Palette.secondary)
        .padding(10)
    }

    private var footer: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(
                    "\(model.draft.galaxies.count) galaxies · \(formatted(model.draft.totalParticleCount)) visible"
                        + (model.draft.hasLiveHalos
                            ? " · \(formatted(model.draft.simulatedParticleCount - model.draft.totalParticleCount)) in halos"
                            : "")
                )
                .font(.callout.monospacedDigit())
                Text(costLabel)
                    .font(.caption)
                    .foregroundStyle(
                        model.estimatedMegayearsPerSecond < 0.3
                            ? Palette.warning : Palette.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Button("Launch simulation") { model.start() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.draft.galaxies.isEmpty)
                Text("the take records from launch")
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
            format: "about %.1f Myr per second · a 500 Myr encounter in %@", rate, reach)
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
                Label("Add a galaxy", systemImage: "plus.circle")
            }
            .buttonStyle(.bordered)
        }
    }

    private var total: Int { max(model.draft.totalParticleCount, 100_000) }

    private var presets: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Start from a preset").font(.headline)
            HStack {
                presetButton("Encounter", .encounter(particleCount: total))
                presetButton("Merger", .merger(particleCount: total))
                presetButton("Close flyby", .flyby(particleCount: total))
                presetButton("Isolated disk", .isolatedDisk(particleCount: total))
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
            Text("Gravity").font(.headline)

            Picker("", selection: solverBinding) {
                Text("Self-gravitating").tag(SolverKind.barnesHut)
                Text("Test particles").tag(SolverKind.restricted)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(
                model.draft.solver == .barnesHut
                    ? "The particles attract one another, halo included. Friction against the halo is what makes galaxies merge. Slow, but the take records itself: let it run, then replay."
                    : "Test particles in rigid potentials. A hundred times faster, gives the tidal tails, but nothing merges."
            )
            .font(.caption)
            .foregroundStyle(Palette.secondary)

            HStack {
                Text("Random seed").font(.caption)
                Spacer()
                TextField(
                    "seed",
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
                title: "Time warp", value: speedBinding, range: 1...32,
                format: "%.0f×", onCommit: { model.commitDraftChange() })

            Text(
                String(
                    format: "softening %.3f kpc · step %.4f (%.2f Myr) · %.1f Myr per second",
                    model.draft.softening, model.draft.timeStep,
                    Double(model.draft.timeStep) * Physics.megayearsPerTimeUnit,
                    model.estimatedMegayearsPerSecond)
            )
            .font(.caption.monospacedDigit())
            .foregroundStyle(Palette.secondary)

            Text(
                model.draft.timeStepScale > 16
                    ? "Beyond 16× the structure starts to drift: fine for framing an encounter, not for a take."
                    : "Multiplies the automatically set step. Up to 16×, an isolated disk keeps its profile within 0.3%."
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
    /// draft unguarded there is what used to kill the app on "Isolated disk".
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
                    TextField("name", text: galaxy.name)
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
                    ForEach(GalaxyKind.allCases.filter { $0 != .blackHole }, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: kind) { model.commitDraftChange() }

                particleCountRow(galaxy)

                Group {
                    ParameterSlider(
                        title: "Mass (10¹⁰ M☉)", value: galaxy.potential.mass, range: 5...200,
                        format: "%.0f", onCommit: commit)
                    ParameterSlider(
                        title: "Disk radius (kpc)", value: sizeBinding, range: 1...14,
                        format: "%.1f", onCommit: commit)
                    if kind != .globular {
                        ParameterSlider(
                            title: "Thickness (kpc)", value: galaxy.diskThickness, range: 0.05...2,
                            onCommit: commit)
                    }
                }

                if kind != .globular {
                    Divider()
                    Text("Bulge").font(.caption.bold())
                    ParameterSlider(
                        title: "Share of stars", value: galaxy.bulgeFraction, range: 0...0.6,
                        onCommit: commit)
                    ParameterSlider(
                        title: "Radius (disk scale lengths)", value: galaxy.bulgeExtent,
                        range: 0.05...0.6, onCommit: commit)
                    ParameterSlider(
                        title: "Flattening", value: galaxy.bulgeFlattening, range: 0.3...1,
                        onCommit: commit)
                    Text("Dispersion-supported Hernquist spheroid. At 0 the galaxy is a bare disk.")
                        .font(.caption2)
                        .foregroundStyle(Palette.secondary)
                }

                if kind != .globular {
                    Group {
                        ParameterSlider(
                            title: "Inclination (rad)", value: galaxy.inclination,
                            range: -1.57...1.57, onCommit: commit)
                        ParameterSlider(
                            title: "Position angle (rad)", value: galaxy.positionAngle,
                            range: 0...6.28, onCommit: commit)
                        Picker("", selection: galaxy.spin) {
                            Text("Prograde").tag(Spin.prograde)
                            Text("Retrograde").tag(Spin.retrograde)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .onChange(of: model.draft.galaxies[index].spin) { commit() }
                    }
                }

                if kind == .spiral {
                    Stepper(
                        "Arms: \(model.draft.galaxies[index].armCount)", value: galaxy.armCount,
                        in: 1...6
                    )
                    .font(.caption)
                    .onChange(of: model.draft.galaxies[index].armCount) { commit() }
                    ParameterSlider(
                        title: "Arm contrast", value: galaxy.armStrength, range: 0...0.95,
                        onCommit: commit)
                }

                if model.draft.solver == .barnesHut {
                    Divider()
                    Text("Self-gravity").font(.caption.bold())
                    ParameterSlider(
                        title: "Disk dissipation (Myr)", value: galaxy.dissipationTime,
                        range: 0...1500, format: "%.0f", onCommit: commit)
                    Text(
                        "A disk of stars alone can only heat up: its arms fade within a billion years. The gas of a real galaxy dissipates that disorder. 0 turns the effect off."
                    )
                    .font(.caption2)
                    .foregroundStyle(Palette.secondary)
                    ParameterSlider(
                        title: "Live halo, particles per star",
                        value: galaxy.haloParticleRatio, range: 0...4, onCommit: commit)
                    ParameterSlider(
                        title: "Disk mass fraction", value: galaxy.diskMassFraction,
                        range: 0.05...1.0, onCommit: commit)
                    ParameterSlider(
                        title: "Disk stability (Toomre Q)", value: galaxy.toomreQ,
                        range: 0.4...2.5, onCommit: commit)
                    Text("Below 1 the disk fragments and heats up. 1.2 to 1.6 is the safe range.")
                        .font(.caption2)
                        .foregroundStyle(Palette.secondary)
                }

                VectorEditor(
                    title: "Position (kpc)", value: galaxy.position, range: -150...150,
                    onCommit: commit)
                VectorEditor(
                    title: "Velocity (207 km/s per unit)", value: galaxy.velocity, range: -3...3,
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
                Text("Stars shown").font(.caption)
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
