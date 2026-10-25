import AppKit
import SillageCore
import SillageRender
import SwiftUI
import UniformTypeIdentifiers

/// The parts of a look file the `Regard` sliders do not reach: the file itself, the colour of
/// each galaxy, what owns buffers, and the camera plan.
struct LookFilePanel: View {
    @ObservedObject var model: SimulationModel
    /// Held here while a slider is dragged and handed over on release, because each of these
    /// builds a new renderer.
    @State private var starCount: Float?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            file
            Divider()
            galaxies
            Divider()
            buffers
            Divider()
            plan
        }
    }

    private var file: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Fichier de look").font(.headline)
            TextField("Nom", text: $model.lookFile.name)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
            Text(model.lookURL.map(LookFiles.shortPath) ?? "Pas encore enregistré")
                .font(.caption2)
                .foregroundStyle(Palette.secondary)
                .lineLimit(2)
            catalogue
            HStack {
                Button("Ouvrir…") { LookFiles.open(model) }
                Button("Enregistrer") { LookFiles.save(model) }
                Button("Sous…") { LookFiles.saveAs(model) }
            }
            .buttonStyle(.bordered)
            if model.sceneFolder != nil {
                Button("En faire le look de la scène") { model.promoteLook() }
                    .buttonStyle(.bordered)
                Text(
                    "Écrit look.json dans le dossier de la scène ; le premier look remplacé reste dans look-raw.json."
                )
                .font(.caption2)
                .foregroundStyle(Palette.secondary)
            }
        }
    }

    /// The looks of the scene's `looks/` folder, which the look grid fills with the whole
    /// catalogue: one click to try one over the picture.
    @ViewBuilder private var catalogue: some View {
        let files = LookFiles.catalogue(of: model.sceneFolder)
        if !files.isEmpty {
            Menu("Catalogue (\(files.count))") {
                ForEach(files, id: \.self) { url in
                    Button(String(url.lastPathComponent.dropLast(10))) { model.openLook(from: url) }
                }
            }
            .font(.caption)
        }
    }

    private var galaxies: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Galaxies").font(.headline)
            ForEach(model.scene.galaxies.indices, id: \.self) { index in
                ColorPicker(
                    "Galaxie \(index + 1)",
                    selection: Binding(
                        get: { LookFiles.color(model.colour(ofGalaxy: index)) },
                        set: { model.setColour(LookFiles.simd($0), ofGalaxy: index) }),
                    supportsOpacity: false
                )
                .font(.caption)
            }
            if !model.lookFile.palette.isEmpty {
                Button("Couleurs de la scène") { model.lookFile.palette = [] }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            ParameterSlider(
                title: "Force des bras (fichier)", value: $model.lookFile.armStrength, range: 0...2)
        }
    }

    private var buffers: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Rendu").font(.headline)
            Text("Ces réglages reconstruisent le rendu, au relâché.")
                .font(.caption2)
                .foregroundStyle(Palette.secondary)
            ParameterSlider(
                title: "Étoiles de champ",
                value: Binding(
                    get: { starCount ?? Float(model.lookFile.starCount) },
                    set: { starCount = $0.rounded() }),
                range: 0...60_000, format: "%.0f",
                onCommit: {
                    if let starCount { model.lookFile.starCount = Int(starCount) }
                    starCount = nil
                })
            Stepper(
                "Niveaux du halo : \(model.lookFile.bloomLevels)",
                value: $model.lookFile.bloomLevels, in: 1...8
            )
            .font(.caption)
            Text("Suréchantillonnage").font(.caption)
            Picker("", selection: $model.supersample) {
                ForEach(1...4, id: \.self) { Text("\($0)×").tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Toggle("Points bruts", isOn: $model.lookFile.plain)
                .font(.caption)
        }
    }

    private var plan: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Plan de caméra").font(.headline)
            Picker("", selection: $model.lookFile.camera.mode) {
                Text("Fixe").tag(LookFile.CameraPlan.Mode.fixed)
                Text("Auto").tag(LookFile.CameraPlan.Mode.auto)
                Text("Réalisateur").tag(LookFile.CameraPlan.Mode.director)
                Text("Immergé").tag(LookFile.CameraPlan.Mode.immersed)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            Toggle("Voir à travers le plan", isOn: $model.followsPlan)
                .font(.caption)
                .disabled(model.mode != .playback)
            Text(planCaption)
                .font(.caption2)
                .foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ParameterSlider(
                title: "Élévation (rad)", value: $model.lookFile.camera.elevation, range: -1.5...1.5)
            EndSlider(
                title: "Élévation de fin", start: model.lookFile.camera.elevation,
                end: $model.lookFile.camera.elevationEnd, range: -1.5...1.5)
            ParameterSlider(
                title: "Azimut (rad)", value: $model.lookFile.camera.azimuth, range: -6.3...6.3)
            EndSlider(
                title: "Azimut de fin", start: model.lookFile.camera.azimuth,
                end: $model.lookFile.camera.azimuthEnd, range: -12.6...12.6)
            ParameterSlider(title: "Zoom", value: $model.lookFile.camera.zoom, range: 0.2...5)
            ParameterSlider(
                title: "Part des particules cadrées", value: $model.lookFile.camera.percentile,
                range: 0.5...1, format: "%.3f")
            ParameterSlider(
                title: "Rayon cadré (kpc, 0 = mesuré)", value: $model.lookFile.camera.radius,
                range: 0...300, format: "%.0f")
        }
    }

    private var planCaption: String {
        switch model.lookFile.camera.mode {
        case .fixed:
            "Cadré une fois sur la première image, des angles de départ à ceux de fin."
        case .auto:
            "Suit les galaxies. L'aperçu cadre chaque image à neuf ; le rendu lisse d'une image à l'autre."
        case .director, .immersed:
            "Le réalisateur choisit ses plans en jouant la prise : rien à prévisualiser image par image, la caméra reste à la main."
        }
    }
}

/// An end angle that may be absent, in which case the camera holds its start.
private struct EndSlider: View {
    let title: String
    let start: Float
    @Binding var end: Float?
    let range: ClosedRange<Float>

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(
                title,
                isOn: Binding(
                    get: { end != nil },
                    set: { end = $0 ? start : nil })
            )
            .font(.caption)
            if end != nil {
                ParameterSlider(
                    title: "", value: Binding(get: { end ?? start }, set: { end = $0 }),
                    range: range)
            }
        }
    }
}

/// The open and save panels for a look file.
enum LookFiles {
    private static var contentType: UTType { .json }

    @MainActor
    static func open(_ model: SimulationModel) {
        let panel = NSOpenPanel()
        panel.title = "Ouvrir un look"
        panel.allowedContentTypes = [contentType]
        panel.directoryURL =
            model.lookURL?.deletingLastPathComponent() ?? model.sceneFolder?.looks
            ?? model.sceneFolder?.url
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.openLook(from: url)
    }

    /// Over the file it came from, or asks where if it came from nowhere.
    @MainActor
    static func save(_ model: SimulationModel) {
        guard let url = model.lookURL else { return saveAs(model) }
        model.saveLook(to: url)
    }

    @MainActor
    static func saveAs(_ model: SimulationModel) {
        let panel = NSSavePanel()
        panel.title = "Enregistrer le look"
        panel.allowedContentTypes = [contentType]
        panel.nameFieldStringValue = "\(model.lookFile.name).look.json"
        panel.directoryURL =
            model.sceneFolder?.looks ?? model.lookURL?.deletingLastPathComponent()
        if let looks = model.sceneFolder?.looks {
            try? FileManager.default.createDirectory(at: looks, withIntermediateDirectories: true)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.saveLook(to: url)
    }

    /// `looks/*.look.json` of a scene, by name.
    static func catalogue(of folder: SceneFolder?) -> [URL] {
        guard let looks = folder?.looks,
            let names = try? FileManager.default.contentsOfDirectory(atPath: looks.path)
        else { return [] }
        return names.filter { $0.hasSuffix(".look.json") }.sorted()
            .map { looks.appendingPathComponent($0) }
    }

    static func shortPath(_ url: URL) -> String {
        url.deletingLastPathComponent().lastPathComponent + "/" + url.lastPathComponent
    }

    static func color(_ value: SIMD3<Float>) -> Color {
        Color(.sRGB, red: Double(value.x), green: Double(value.y), blue: Double(value.z))
    }

    static func simd(_ color: Color) -> SIMD3<Float> {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return SIMD3(1, 1, 1) }
        return SIMD3(
            Float(rgb.redComponent), Float(rgb.greenComponent), Float(rgb.blueComponent))
    }
}

/// File menu entries for takes and look files, so either can be opened over the other.
struct LookCommands: View {
    @ObservedObject var model: SimulationModel

    var body: some View {
        Divider()
        Button("Ouvrir une prise…") { TakeFiles.open(model) }
            .keyboardShortcut("o", modifiers: .command)
        Button("Ouvrir un look…") { LookFiles.open(model) }
            .keyboardShortcut("o", modifiers: [.command, .shift])
        Button("Enregistrer le look") { LookFiles.save(model) }
            .keyboardShortcut("s", modifiers: .command)
        Button("Enregistrer le look sous…") { LookFiles.saveAs(model) }
            .keyboardShortcut("s", modifiers: [.command, .shift])
    }
}
