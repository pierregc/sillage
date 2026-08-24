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
                Button("Rejouer") { model.restart() }
            }
            .buttonStyle(.bordered)

            Button("Modifier la scène") { model.returnToSetup() }
                .buttonStyle(.bordered)

            Stepper("Pas par image : \(model.stepsPerFrame)", value: $model.stepsPerFrame, in: 1...64)
                .font(.caption)

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

    private var rendering: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Rendu").font(.headline)
            ParameterSlider(
                title: "Luminosité", value: $model.brightness, range: 0.005...0.4, format: "%.3f")
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
