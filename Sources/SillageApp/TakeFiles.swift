import AppKit
import SillageRender
import UniformTypeIdentifiers

/// The open and save panels for a captured run.
enum TakeFiles {
    private static var contentType: UTType {
        UTType(filenameExtension: RecordingFile.fileExtension) ?? .data
    }

    @MainActor
    static func save(_ model: SimulationModel) {
        let panel = NSSavePanel()
        panel.title = "Enregistrer la prise"
        panel.allowedContentTypes = [contentType]
        panel.nameFieldStringValue =
            "\(model.scene.name).\(RecordingFile.fileExtension)"
        panel.message =
            "Tout ce qui décide de l'image — exposition, couleur, instrument, caméra — reste réglable à la relecture."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.saveTake(to: url)
    }

    @MainActor
    static func exportVideo(_ model: SimulationModel) {
        let panel = NSSavePanel()
        panel.title = "Exporter la vidéo"
        panel.allowedContentTypes = [.quickTimeMovie]
        panel.nameFieldStringValue = "\(model.scene.name).mov"
        panel.message =
            "Les images sont rendues à cette taille, pas capturées à l'écran : rien n'est perdu."

        // The size is part of the export, so it is asked for here rather than guessed.
        let sizes = ["1280 x 720", "1920 x 1080", "2560 x 1440", "3840 x 2160"]
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 200, height: 25))
        picker.addItems(withTitles: sizes)
        picker.selectItem(at: 1)
        let label = NSTextField(labelWithString: "Définition")
        let row = NSStackView(views: [label, picker])
        row.spacing = 8
        row.frame = NSRect(x: 0, y: 0, width: 300, height: 30)
        panel.accessoryView = row

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let chosen = sizes[picker.indexOfSelectedItem]
            .split(separator: "x").map { Int($0.trimmingCharacters(in: .whitespaces)) ?? 1920 }
        model.exportVideo(
            to: url, width: chosen[0], height: chosen[1],
            framesPerSecond: Int(model.playbackSpeed.rounded()))
    }

    @MainActor
    static func open(_ model: SimulationModel) {
        let panel = NSOpenPanel()
        panel.title = "Ouvrir une prise"
        panel.allowedContentTypes = [contentType]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.openTake(from: url)
    }
}
