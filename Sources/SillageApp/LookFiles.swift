import AppKit
import SillageRender
import SwiftUI
import UniformTypeIdentifiers

/// The open and save panels for a look file.
enum LookFiles {
    private static var contentType: UTType { .json }

    @MainActor
    static func open(_ model: SimulationModel) {
        let panel = NSOpenPanel()
        panel.title = "Ouvrir un style"
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
        panel.title = "Enregistrer le style"
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
}

/// File menu entries for takes and look files, so either can be opened over the other. In the
/// style editor ⌘S makes the style the scene's.
struct LookCommands: View {
    @ObservedObject var model: SimulationModel
    @ObservedObject var navigation: AppNavigation

    var body: some View {
        Divider()
        Button("Ouvrir une prise…") { navigation.openTake(model) }
            .keyboardShortcut("o", modifiers: .command)
        Button("Ouvrir un style…") { LookFiles.open(model) }
            .keyboardShortcut("o", modifiers: [.command, .shift])
        if let style = navigation.editingStyle {
            PromoteCommand(session: style)
        } else {
            Button("Enregistrer le style") { LookFiles.save(model) }
                .keyboardShortcut("s", modifiers: .command)
        }
        Button("Enregistrer le style sous…") { LookFiles.saveAs(model) }
            .keyboardShortcut("s", modifiers: [.command, .shift])
    }
}

struct PromoteCommand: View {
    @ObservedObject var session: StyleSession

    var body: some View {
        Button("Utiliser pour la scène") { session.promote() }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(session.scene.folder == nil || !session.isOpen)
    }
}
