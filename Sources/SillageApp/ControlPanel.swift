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
            HStack {
                Button(model.isPlaying ? "Pause" : "Lecture") { model.isPlaying.toggle() }
                    .keyboardShortcut(.space, modifiers: [])
                Button("Relancer") { model.restart() }
                    .disabled(model.mode == .recording)
            }
            .buttonStyle(.bordered)

            Button("Modifier la scène") { model.returnToSetup() }
                .buttonStyle(.bordered)

            Stepper("Pas par image : \(model.stepsPerFrame)", value: $model.stepsPerFrame, in: 1...64)
                .font(.caption)
                .disabled(model.mode == .playback)

            Text(String(format: "t = %.0f Myr", model.elapsedMyr))
                .font(.callout.monospacedDigit())
            Text(
                String(
                    format: "%.1f ms/image · %@ particules", model.frameMilliseconds,
                    model.particleCount >= 1_000_000
                        ? String(format: "%.1f M", Double(model.particleCount) / 1_000_000)
                        : "\(model.particleCount / 1000) k")
            )
            .font(.caption.monospacedDigit())
            .foregroundStyle(Palette.secondary)

            if let failure = model.failure {
                Text(failure).font(.caption).foregroundStyle(Palette.warning)
            }
        }
    }

    /// Recording and playback. Self-gravity costs hundreds of milliseconds a step, so the
    /// only way to watch it without touching the physics is to stop making the display wait
    /// for it.
    @ViewBuilder
    private var capture: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Prise").font(.headline)

            switch model.mode {
            case .live:
                Text(
                    "Enregistre la suite du calcul en mémoire, puis rejoue à la fréquence de l'écran."
                )
                .font(.caption)
                .foregroundStyle(Palette.secondary)
                Stepper("Images : \(model.targetFrames)", value: $model.targetFrames, in: 30...3000, step: 30)
                    .font(.caption)
                Text(String(format: "environ %.1f Go en mémoire", model.projectedGigabytes))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(model.projectedGigabytes > 12 ? Palette.warning : Palette.secondary)
                Button("Enregistrer") { model.startRecording() }
                    .buttonStyle(.borderedProminent)

            case .recording:
                ProgressView(
                    value: Double(model.recordedFrames), total: Double(max(model.targetFrames, 1)))
                Text(
                    String(
                        format: "%d / %d images · %.0f Mo", model.recordedFrames,
                        model.targetFrames, model.recordingMegabytes)
                )
                .font(.caption.monospacedDigit())
                Button("Arrêter et rejouer") { model.stopRecording() }
                    .buttonStyle(.bordered)

            case .playback:
                Text(
                    String(
                        format: "%d images · %.0f Mo", model.recordedFrames,
                        model.recordingMegabytes)
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(Palette.secondary)
                Slider(
                    value: $model.playbackPosition,
                    in: 0...Double(max(model.recordedFrames - 1, 1)))
                ParameterSlider(
                    title: "Vitesse (images/s)", value: $model.playbackSpeed, range: 1...120,
                    format: "%.0f")
                Button("Nouvelle prise") { model.discardRecording() }
                    .buttonStyle(.bordered)
            }
        }
    }

    private var rendering: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Rendu").font(.headline)
            ParameterSlider(
                title: "Luminosité", value: $model.brightness, range: 0.02...2.0, format: "%.2f")
            ParameterSlider(
                title: "Étirement logarithmique", value: $model.stretch, range: 0...60,
                format: "%.0f")
            ParameterSlider(title: "Saturation", value: $model.saturation, range: 0...3)
            ParameterSlider(title: "Halo lumineux", value: $model.bloom, range: 0...2)
            ParameterSlider(
                title: "Opacité des poussières", value: $model.dustStrength, range: 0...0.8,
                format: "%.3f")
            ParameterSlider(title: "Taille des points", value: $model.pointSize, range: 0.8...6)
            ParameterSlider(title: "Exposition", value: $model.exposure, range: 0.1...4)
            ParameterSlider(
                title: "Lissage (taille du noyau)", value: $model.smoothingScale,
                range: 0.4...3.0)
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
                title: "Distance (kpc)", value: $model.camera.distance, range: 20...1200,
                format: "%.0f")
            ParameterSlider(
                title: "Élévation (rad)", value: $model.camera.elevation,
                range: -OrbitCamera.elevationLimit...OrbitCamera.elevationLimit)
            Button("Recadrer") { model.frameCamera() }
                .buttonStyle(.bordered)
        }
    }
}
