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
    static func open(_ model: SimulationModel) {
        let panel = NSOpenPanel()
        panel.title = "Ouvrir une prise"
        panel.allowedContentTypes = [contentType]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.openTake(from: url)
    }
}
