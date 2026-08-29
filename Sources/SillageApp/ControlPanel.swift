import SillageCore
import SillageRender
import SwiftUI

/// Live controls for the running simulation. Everything here applies immediately: the scene
/// itself is edited on the setup screen, not while it runs.
struct ControlPanel: View {
    @ObservedObject var model: SimulationModel

    var body: some View {
        ScrollView {
            ControlPanelContent(model: model).padding(14)
        }
        .frame(width: 290)
        .panelSurface()
    }
}

/// Split out from the scroll view so it can be rendered offscreen for inspection.
struct ControlPanelContent: View {
    @ObservedObject var model: SimulationModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            transport
            Divider()
            capture
            Divider()
            rendering
            Divider()
            view
        }
    }

    private var transport: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.mode == .playback ? "Relecture" : "Simulation en cours")
                .font(.headline)
            HStack {
                Button(model.isPlaying ? "Pause" : "Lecture") { model.isPlaying.toggle() }
                    .keyboardShortcut(.space, modifiers: [])
                Button("Relancer") { model.restart() }
            }
            .buttonStyle(.bordered)

            Button("Modifier la scène") { model.returnToSetup() }
                .buttonStyle(.bordered)

            HStack(alignment: .firstTextBaseline) {
                Text(String(format: "t = %.0f Myr", model.elapsedMyr))
                    .font(.callout.monospacedDigit())
                Spacer()
                if model.mode == .running {
                    Text(String(format: "%.1f Myr/s", model.megayearsPerSecond))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Palette.secondary)
                }
            }
            Text(
                String(
                    format: "%@ particules · %.1f ms par image affichée",
                    model.particleCount >= 1_000_000
                        ? String(format: "%.1f M", Double(model.particleCount) / 1_000_000)
                        : "\(model.particleCount / 1000) k",
                    model.frameMilliseconds)
            )
            .font(.caption.monospacedDigit())
            .foregroundStyle(Palette.secondary)

            if let activity = model.fileActivity {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(activity).font(.caption)
                }
            }

            if let failure = model.failure {
                Text(failure).font(.caption).foregroundStyle(Palette.warning)
            }
        }
    }

    /// Capture and playback. A run records itself from the moment it starts: self-gravity
    /// costs hundreds of milliseconds a step, so a scene that has already been computed once
    /// should never have to be computed again just to be watched.
    @ViewBuilder
    private var capture: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Prise").font(.headline)

            switch model.mode {
            case .running:
                Text(
                    String(
                        format: "%d images · %.0f Myr · %.0f Mo", model.capturedFrames,
                        model.capturedMyr, model.capturedMegabytes)
                )
                .font(.caption.monospacedDigit())
                ProgressView(value: model.captureFraction)

                if model.captureIsFull {
                    Text(
                        "Budget atteint : la prise s'éclaircit et garde une image sur \(model.captureStride). Toute la durée est conservée."
                    )
                    .font(.caption2)
                    .foregroundStyle(Palette.warning)
                }

                HStack {
                    Button("Arrêter et rejouer") { model.stopAndReplay() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canReplay)
                    Button("Ouvrir…") { TakeFiles.open(model) }
                        .buttonStyle(.bordered)
                }

                ParameterSlider(
                    title: "Budget mémoire (Go)",
                    value: Binding(
                        get: { Float(model.memoryBudgetGigabytes) },
                        set: { model.memoryBudgetGigabytes = Double($0) }),
                    range: 0.5...24, format: "%.1f")

                Toggle("Afficher pendant le calcul", isOn: $model.showCanvasWhileRunning)
                    .font(.caption)
                Text(
                    "Dessiner quelques millions de particules prend une vraie part du même GPU que le calcul."
                )
                .font(.caption2)
                .foregroundStyle(Palette.secondary)

                Divider()
                Text("Fin de course").font(.caption.bold())
                ParameterSlider(
                    title: "Arrêter à (Myr)",
                    value: Binding(
                        get: { Float(model.stopAtMyr) },
                        set: { model.stopAtMyr = Double($0) }),
                    range: 0...8000, format: "%.0f")
                Text(
                    model.stopAtMyr > 0
                        ? "La course s'arrêtera d'elle-même et passera en relecture."
                        : "À 0, la course ne s'arrête jamais toute seule."
                )
                .font(.caption2)
                .foregroundStyle(Palette.secondary)

                if let destination = model.finishDestination {
                    HStack {
                        Text("Sera écrite dans \(destination.lastPathComponent)")
                            .font(.caption2)
                            .foregroundStyle(Palette.secondary)
                            .lineLimit(1)
                        Spacer()
                        Button("Annuler") { model.cancelSaveWhenFinished() }
                            .buttonStyle(.borderless)
                            .font(.caption2)
                    }
                } else {
                    Button("Sauvegarder quand fini…") { TakeFiles.saveWhenFinished(model) }
                        .buttonStyle(.bordered)
                }

                Toggle("Quitter quand c'est fini", isOn: $model.quitWhenFinished)
                    .font(.caption)
                    .disabled(model.stopAtMyr <= 0)

                Divider()
                Stepper(
                    "Pas simulés par image : \(model.stepsPerFrame)",
                    value: $model.stepsPerFrame, in: 1...64
                )
                .font(.caption)
                Text("Plus haut, la prise couvre plus de temps pour la même mémoire.")
                    .font(.caption2)
                    .foregroundStyle(Palette.secondary)

            case .playback:
                if model.reachedFinish {
                    Text("Course terminée au temps demandé.")
                        .font(.caption)
                        .foregroundStyle(Palette.label)
                }
                Text(
                    String(
                        format: "%d images · %.0f Myr · %.0f Mo", model.capturedFrames,
                        model.capturedMyr, model.capturedMegabytes)
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(Palette.secondary)
                Slider(
                    value: $model.playbackPosition,
                    in: 0...Double(max(model.capturedFrames - 1, 1)))
                ParameterSlider(
                    title: "Vitesse (images/s)", value: $model.playbackSpeed, range: 1...120,
                    format: "%.0f")
                HStack {
                    Button("Enregistrer…") { TakeFiles.save(model) }
                    Button("Ouvrir…") { TakeFiles.open(model) }
                    Button("Vidéo…") { TakeFiles.exportVideo(model) }
                }
                .buttonStyle(.bordered)
                .disabled(model.fileActivity != nil)

                if model.isOpenedTake {
                    Text(
                        "Prise ouverte depuis un fichier. Tous les réglages d'image restent vifs ; relancer la recalculerait depuis sa scène."
                    )
                    .font(.caption2)
                    .foregroundStyle(Palette.secondary)
                } else {
                    HStack {
                        Button("Reprendre le calcul") { model.resumeRunning() }
                        Button("Nouvelle prise") { model.restartCapture() }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    /// Split the way the two halves of the picture are: what light the galaxy sends, and
    /// what the telescope does with it. Ten sliders in one column say nothing about which
    /// knob to reach for.
    private var rendering: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Lumière").font(.headline)
            ParameterSlider(
                title: "Luminosité", value: $model.brightness, range: 0.02...2.0, format: "%.2f")
            ParameterSlider(
                title: "Étirement logarithmique", value: $model.stretch, range: 0...60,
                format: "%.0f")
            ParameterSlider(title: "Saturation", value: $model.saturation, range: 0...3)
            ParameterSlider(title: "Teinte par galaxie", value: $model.galaxyTint, range: 0...1)
            Text(
                "0 : chaque étoile a la couleur de sa population. 1 : chaque galaxie garde la sienne, ce qui rend lisibles les étoiles qu'elle perd."
            )
            .font(.caption2)
            .foregroundStyle(Palette.secondary)
            ParameterSlider(
                title: "Opacité des poussières", value: $model.dustStrength, range: 0...0.8,
                format: "%.3f")

            Divider()
            Text("Instrument").font(.headline)
            ParameterSlider(
                title: "Lissage des étoiles", value: $model.smoothingScale,
                range: 0.4...5.0)
            ParameterSlider(title: "Halo lumineux", value: $model.bloom, range: 0...2)
            ParameterSlider(
                title: "Aigrettes de diffraction", value: $model.spikeIntensity, range: 0...1.5)
            ParameterSlider(
                title: "Fond de ciel", value: $model.skyLevel, range: 0...0.01, format: "%.4f")
            ParameterSlider(
                title: "Bruit de détecteur", value: $model.noiseLevel, range: 0...0.01,
                format: "%.4f")
            Picker("Suréchantillonnage", selection: $model.supersample) {
                Text("1×").tag(1)
                Text("2×").tag(2)
            }
            .pickerStyle(.segmented)
        }
    }

    private var view: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Caméra").font(.headline)
            Text("Glisser pour tourner, molette pour zoomer")
                .font(.caption)
                .foregroundStyle(Palette.secondary)
            ParameterSlider(
                title: "Distance (kpc)", value: $model.camera.distance,
                range: OrbitCamera.nearest...OrbitCamera.furthest, format: "%.0f")
            ParameterSlider(
                title: "Élévation (rad)", value: $model.camera.elevation,
                range: -OrbitCamera.elevationLimit...OrbitCamera.elevationLimit)
            Button("Recadrer") { model.frameCamera() }
                .buttonStyle(.bordered)
        }
    }
}
