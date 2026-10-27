import SillageRender
import SwiftUI

enum SidebarItem: Hashable {
    case library(LibraryCollection)
    case queue
    case nights
    case workshop
    /// The style editor, on the scene `AppNavigation.style` holds.
    case style

    var isLibrary: Bool {
        if case .library = self { return true }
        return false
    }
}

/// Which part of the window is showing. Shared with the menu commands, which have no view of
/// their own to hold it.
@MainActor
final class AppNavigation: ObservableObject {
    static let windowID = "main"

    @Published var selection: SidebarItem = AppNavigation.initial
    /// The style being chosen. It stays while other parts show, so the sidebar can come back
    /// to it, and goes when the editor is left.
    @Published private(set) var style: StyleSession?
    /// Where leaving the editor goes back to: the collection it was opened from.
    private var styleReturn: SidebarItem = .library(.all)
    /// The new night sheet, opened from the sidebar and the toolbar.
    @Published var showsNightSheet = false

    /// Selects the library, on the collection it was showing if it already is.
    func showLibrary() {
        if !selection.isLibrary { selection = .library(.all) }
    }

    /// The window checks drive the workshop, so they open on it.
    static var initial: SidebarItem {
        let workshopChecks: Set = [
            "--verify", "--cinema", "--presets", "--responsive", "--qa", "--soak",
        ]
        return CommandLine.arguments.contains(where: workshopChecks.contains) ? .workshop : .library(.all)
    }

    func newNight() { showsNightSheet = true }

    /// A night launched shows the nights, where its page will be (#108).
    func nightLaunched() {
        showsNightSheet = false
        selection = .nights
    }

    func openTake(_ model: SimulationModel) {
        if TakeFiles.open(model) { selection = .workshop }
    }

    /// Opens the style editor on a scene's take. The same scene still open there is shown as
    /// it was left, edits included.
    func tune(_ model: SimulationModel, _ scene: LibraryScene) {
        guard scene.take != nil else { return }
        if case .library = selection { styleReturn = selection }
        if style?.scene.id != scene.id || style?.isOpen != true {
            let session = StyleSession(scene: scene, model: model)
            style = session
            // Already on the canvas: its saved style is put back rather than the take read again.
            if scene.folder != nil, session.isOpen, let saved = session.saved {
                model.adopt(saved, from: scene.folder?.look)
            } else {
                model.tune(scene)
            }
        }
        selection = .style
    }

    /// The style editor, when it is the part showing.
    var editingStyle: StyleSession? { selection == .style ? style : nil }

    /// Back to the scene's page, in the collection the editor was opened from.
    func leaveStyle(_ library: LibraryModel) {
        guard let style else { return }
        selection = styleReturn
        library.open(style.scene.id)
        self.style = nil
    }
}

/// The one window: library, nights and workshop in a sidebar, the chosen one beside it.
struct MainView: View {
    @ObservedObject var model: SimulationModel
    @ObservedObject var library: LibraryModel
    @ObservedObject var navigation: AppNavigation
    @ObservedObject var queue: QueueModel

    var body: some View {
        Group {
            if model.contemplating {
                ContemplationView(model: model)
            } else {
                NavigationSplitView {
                    Sidebar(model: model, library: library, queue: queue, navigation: navigation)
                        .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 280)
                } detail: {
                    detail
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            navigation.newNight()
                        } label: {
                            Label("Nouvelle nuit", systemImage: "moon.stars")
                        }
                        .help("Préparer une nuit de calcul")
                    }
                }
                .sheet(isPresented: $navigation.showsNightSheet) {
                    NightSheetView(
                        model: NightSheetModel(library: queue.store.library), queue: queue,
                        dismiss: { navigation.showsNightSheet = false },
                        launched: { navigation.nightLaunched() })
                }
            }
        }
        .environment(\.queue, queue)
        // The night sheet opens on a plan already sized.
        .onAppear {
            let library = queue.store.library
            Task.detached(priority: .utility) { NightSheetPlanner.shared(library: library).warm() }
        }
        // A run started anywhere, from a menu included, is watched in the workshop. A take
        // opened for its style stays in the editor.
        .onChange(of: model.stage) { _, stage in
            if stage == .running, model.mode == .running, !model.contemplating {
                navigation.selection = .workshop
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch navigation.selection {
        case .library(let collection):
            LibraryView(model: library, collection: collection) { navigation.selection = .library($0) }
        case .queue: QueueView(queue: queue)
        case .nights: NightsView()
        case .workshop:
            // Leaving the workshop drops the canvas and nothing else: the run keeps stepping
            // on its own queue, as with "Afficher pendant le calcul" off.
            switch model.stage {
            case .setup: SetupView(model: model)
            case .running: RunningView(model: model)
            }
        case .style:
            if let style = navigation.style {
                StyleEditor(
                    session: style, leave: { navigation.leaveStyle(library) },
                    reopen: { navigation.tune(model, style.scene) })
            } else {
                Color.clear.panelSurface()
            }
        }
    }
}

struct Sidebar: View {
    @ObservedObject var model: SimulationModel
    @ObservedObject var library: LibraryModel
    @ObservedObject var queue: QueueModel
    @ObservedObject var navigation: AppNavigation

    var body: some View {
        let counts = library.counts
        List(selection: selection) {
            Section {
                Label("File d'attente", systemImage: "list.bullet.rectangle")
                    .badge(queue.status.waitingCount)
                    .tag(SidebarItem.queue)
            }
            Section("Bibliothèque") {
                ForEach(LibraryCollection.allCases, id: \.self) { collection in
                    Label(collection.title, systemImage: collection.symbol)
                        .badge(counts[collection] ?? 0)
                        .tag(SidebarItem.library(collection))
                }
                if let style = navigation.style {
                    Label("Style de \(style.scene.name)", systemImage: "paintpalette")
                        .tag(SidebarItem.style)
                }
            }
            Section("Nuits") {
                Label("Nuits", systemImage: "moon.stars")
                    .tag(SidebarItem.nights)
                Button {
                    navigation.newNight()
                } label: {
                    Label("Nouvelle nuit", systemImage: "plus.circle")
                }
            }
            Section("Atelier") {
                Label("Nouvelle collision", systemImage: "circle.circle")
                    .tag(SidebarItem.workshop)
                Button {
                    navigation.openTake(model)
                } label: {
                    Label("Ouvrir une prise…", systemImage: "film")
                }
                contemplation("Contemplation lente", .slow, "Plein écran, cinq minutes par scène")
                contemplation("Contemplation rapide", .brisk, "Plein écran, une minute par scène")
            }
        }
        .listStyle(.sidebar)
        .buttonStyle(.plain)
        // The counts are the sidebar's, so the folder is read whatever part is showing.
        .onAppear { library.watch() }
        .safeAreaInset(edge: .top, spacing: 0) {
            SidebarStatus(
                model: model, queue: queue, openQueue: { navigation.selection = .queue },
                openWorkshop: { navigation.selection = .workshop })
        }
    }

    /// The list clears its selection on some clicks; the window always shows something.
    private var selection: Binding<SidebarItem?> {
        Binding(
            get: { navigation.selection },
            set: { if let item = $0 { navigation.selection = item } })
    }

    /// Contemplation replaces the scene, so it waits until the run in the workshop is closed.
    /// It leaves the selection alone: escape lands back on whatever was showing.
    private func contemplation(
        _ title: String, _ pace: SimulationModel.Pace, _ help: String
    ) -> some View {
        Button {
            model.startContemplation(pace: pace)
        } label: {
            Label(title, systemImage: pace == .slow ? "sparkles" : "hare")
        }
        .disabled(model.stage == .running)
        .help(model.stage == .running ? "Revenir d'abord à « Modifier la scène »" : help)
    }
}

/// Filled by the night pages (#108).
struct NightsView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "moon.stars")
                .font(.system(size: 34))
                .foregroundStyle(Palette.secondary)
            Text("Les nuits apparaîtront ici").font(.title3)
            Text("Chaque nuit de calcul, ses scènes et ses vidéos.")
                .foregroundStyle(Palette.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .panelSurface()
    }
}
