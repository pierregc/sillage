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

    /// Picks where a run will write itself once it reaches its finish, so a big scene can be
    /// started and left.
    @MainActor
    static func saveWhenFinished(_ model: SimulationModel) {
        let panel = NSSavePanel()
        panel.title = "Sauvegarder quand fini"
        panel.allowedContentTypes = [contentType]
        panel.nameFieldStringValue = "\(model.scene.name).\(RecordingFile.fileExtension)"
        panel.message =
            "La course s'arrêtera au temps choisi et écrira la prise ici, sans rien demander."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.saveWhenFinished(to: url)
    }

    @MainActor
    /// False when the panel was cancelled.
    @discardableResult
    static func open(_ model: SimulationModel) -> Bool {
        let panel = NSOpenPanel()
        panel.title = "Ouvrir une prise"
        panel.allowedContentTypes = [contentType]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        model.openTake(from: url)
        return true
    }
}
