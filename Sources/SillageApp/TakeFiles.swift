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
        panel.title = "Save the take"
        panel.allowedContentTypes = [contentType]
        panel.nameFieldStringValue =
            "\(model.scene.name).\(RecordingFile.fileExtension)"
        panel.message =
            "Everything that decides the image (exposure, colour, instrument, camera) stays adjustable on playback."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.saveTake(to: url)
    }

    /// Picks where a run will write itself once it reaches its finish, so a big scene can be
    /// started and left.
    @MainActor
    static func saveWhenFinished(_ model: SimulationModel) {
        let panel = NSSavePanel()
        panel.title = "Save when finished"
        panel.allowedContentTypes = [contentType]
        panel.nameFieldStringValue = "\(model.scene.name).\(RecordingFile.fileExtension)"
        panel.message =
            "The run will stop at the chosen time and write the take here without asking."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.saveWhenFinished(to: url)
    }

    @MainActor
    /// False when the panel was cancelled.
    @discardableResult
    static func open(_ model: SimulationModel) -> Bool {
        let panel = NSOpenPanel()
        panel.title = "Open a take"
        panel.allowedContentTypes = [contentType]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        model.openTake(from: url)
        return true
    }
}
