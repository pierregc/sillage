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
                        format: "%d images · %.0f Myr · %.1f Go", model.capturedFrames,
                        model.capturedMyr, Double(model.capturedBytes) / 1_073_741_824)
                )
                .font(.caption.monospacedDigit())
                ProgressView(value: model.captureFraction)

                if let why = model.captureSpillFailure {
                    Text("Débord sur disque impossible, la prise continue en mémoire. \(why)")
                        .font(.caption2)
                        .foregroundStyle(Palette.warning)
                } else if model.captureSpilling {
                    Text(
                        String(
                            format:
                                "Budget mémoire atteint : la prise continue sur disque (%.1f Go). Aucune image n'est perdue.",
                            Double(model.captureDiskBytes) / 1_073_741_824)
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
                Text(
                    "Ce que la prise garde en mémoire. Au-delà elle continue sur disque, sans jamais perdre d'image."
                )
                .font(.caption2)
                .foregroundStyle(Palette.secondary)

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

    private var lookBinding: Binding<String> {
        Binding(
            get: { model.lookName },
            set: { id in
                guard let named = RenderLook.catalogue.first(where: { $0.id == id }) else { return }
                model.adopt(named)
            })
    }

    private var lookDescription: String {
        switch model.lookName {
        case "dream": "Noyaux larges et floraison généreuse: le disque devient nuage."
        case "gloss": "Noyaux serrés, longues aigrettes: un champ d'éclats individuels."
        case "ink": "Ciel presque noir, couleur retenue. Pour les plans larges."
        case "ember": "Chaud et lourd, la poussière fait l'essentiel du dessin."
        default: "Ce que l'instrument enregistrerait vraiment."
        }
    }

    /// Split the way the two halves of the picture are: what light the galaxy sends, and
    /// what the telescope does with it. Ten sliders in one column say nothing about which
    /// knob to reach for.
    private var rendering: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Regard").font(.headline)
            // A whole look in one press, from the honest telescope to the frankly invented.
            // The sliders below stay live afterwards: a look is a place to start, not a mode.
            Picker("", selection: lookBinding) {
                ForEach(RenderLook.catalogue) { named in
                    Text(named.name).tag(named.id)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            Text(lookDescription)
                .font(.caption)
                .foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider().padding(.vertical, 2)
            Text("Lumière").font(.headline)
            ParameterSlider(
                title: "Luminosité", value: $model.look.brightness, range: 0.02...2.0, format: "%.2f")
            ParameterSlider(
                title: "Étirement logarithmique", value: $model.look.stretch, range: 0...60,
                format: "%.0f")
            ParameterSlider(title: "Saturation", value: $model.look.saturation, range: 0...3)
            ParameterSlider(title: "Teinte par galaxie", value: $model.look.galaxyTint, range: 0...1)
            Text(
                "0 : chaque étoile a la couleur de sa population. 1 : chaque galaxie garde la sienne, ce qui rend lisibles les étoiles qu'elle perd."
            )
            .font(.caption2)
            .foregroundStyle(Palette.secondary)
            ParameterSlider(
                title: "Opacité des poussières", value: $model.look.dustStrength, range: 0...1.2,
                format: "%.3f")
            ParameterSlider(
                title: "Force des bras peints", value: $model.look.armPersistence, range: 0...2)
            Text(
                "Au-dessus de 1 les bras sont une invention franche, ce que les looks les plus doux assument."
            )
            .font(.caption2)
            .foregroundStyle(Palette.secondary)

            Divider()
            Text("Instrument").font(.headline)
            ParameterSlider(
                title: "Lissage des étoiles", value: $model.look.smoothingScale,
                range: 0.4...5.0)
            // How wide a splat is allowed to be. The floor is the one that matters and it was
            // reachable only from a preset: a star drawn thinner than a pixel crosses pixel
            // boundaries as it moves and twinkles on its own, whatever the detector noise is
            // set to. Measured on a take played slowly with the noise off, the worst
            // frame-to-frame jump on a single pixel falls from 81 levels at 1.1 px to 16 at
            // 3.5.
            ParameterSlider(
                title: "Noyau minimal (px)", value: $model.look.minimumKernel, range: 0.5...6)
            ParameterSlider(
                title: "Noyau maximal (px)", value: $model.look.maximumKernel, range: 4...160,
                format: "%.0f")
            ParameterSlider(title: "Halo lumineux", value: $model.look.bloomIntensity, range: 0...2)
            ParameterSlider(
                title: "Aigrettes de diffraction", value: $model.look.spikeIntensity, range: 0...1.5)
            // What makes a bright star sparkle is these three together, and only the first of
            // them had a control: the number of arms and how far they reach were reachable
            // only from a preset.
            ParameterSlider(
                title: "Branches des aigrettes", value: $model.spikeArms, range: 0...8,
                format: "%.0f")
            ParameterSlider(
                title: "Longueur des aigrettes", value: $model.look.spikeLength, range: 0...200,
                format: "%.0f")
            ParameterSlider(
                title: "Taille des étoiles de champ", value: $model.look.starSize, range: 0.2...4)
            ParameterSlider(
                title: "Seuil du halo", value: $model.look.bloomThreshold, range: 0.05...1.5)
            ParameterSlider(
                title: "Douceur du seuil", value: $model.look.bloomSoftKnee, range: 0...1)
            ParameterSlider(
                title: "Point blanc", value: $model.look.whitePoint, range: 1...20, format: "%.1f")
            ParameterSlider(
                title: "Fond de ciel", value: $model.look.skyLevel, range: 0...0.006,
                format: "%.4f")
            // Named for what it does rather than for what it is. Every look sits between
            // 0.0008 and 0.0022, so a range up to 0.01 put the whole useful part of it in the
            // first sixth of the track: it read as a control that did nothing until it
            // suddenly did everything, and zero was three pixels wide.
            ParameterSlider(
                title: "Scintillement (bruit du capteur)", value: $model.look.noiseLevel,
                range: 0...0.004, format: "%.4f")
            Text(
                "À zéro, deux images d'une scène arrêtée sont identiques au bit près : c'est ce bruit-là qui fait clignoter tout le fond. Pour les étoiles qui scintillent en bougeant, c'est le noyau minimal."
            )
            .font(.caption2)
            .foregroundStyle(Palette.secondary)
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
            Picker("", selection: flightBinding) {
                Text("Orbite").tag(false)
                Text("Vol libre").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if model.isFlying {
                Text("Glisser pour regarder, molette pour la vitesse")
                    .font(.caption)
                    .foregroundStyle(Palette.secondary)
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                    GridRow {
                        Text("W S").monospaced()
                        Text("avancer, reculer")
                    }
                    GridRow {
                        Text("A D").monospaced()
                        Text("gauche, droite")
                    }
                    GridRow {
                        Text("␣ C").monospaced()
                        Text("monter, descendre")
                    }
                    GridRow {
                        Text("← →").monospaced()
                        Text("pivoter")
                    }
                    GridRow {
                        Text("↑ ↓").monospaced()
                        Text("lever, baisser les yeux")
                    }
                    GridRow {
                        Text("⇧ ⌃").monospaced()
                        Text("plus vite, moins vite")
                    }
                    GridRow {
                        Text("F").monospaced()
                        Text("revenir en orbite")
                    }
                }
                .font(.caption)
                .foregroundStyle(Palette.secondary)
                // Not bound to the rig: it moves on every frame, and a binding would rebuild
                // this panel sixty times a second.
                Text(String(format: "vitesse %.0f kpc/s", model.flight.speed))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Palette.secondary)
            } else {
                Text("Glisser pour tourner, molette pour zoomer · F pour voler")
                    .font(.caption)
                    .foregroundStyle(Palette.secondary)
                ParameterSlider(
                    title: "Distance (kpc)", value: $model.camera.distance,
                    range: OrbitCamera.nearest...OrbitCamera.furthest, format: "%.0f")
                ParameterSlider(
                    title: "Élévation (rad)", value: $model.camera.elevation,
                    range: -OrbitCamera.elevationLimit...OrbitCamera.elevationLimit)
            }
            ParameterSlider(
                title: "Ouverture de l'objectif", value: $model.look.fieldOfView, range: 0.2...1.4)
            Button(model.isFlying ? "Revenir sur la scène" : "Recadrer") {
                if model.isFlying { model.toggleFlight() }
                model.frameCamera()
            }
            .buttonStyle(.bordered)
        }
    }

    private var flightBinding: Binding<Bool> {
        Binding(
            get: { model.isFlying },
            set: { wanted in if wanted != model.isFlying { model.toggleFlight() } })
    }
}
