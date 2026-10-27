import SillageRender
import SwiftUI

enum SidebarItem: Hashable {
    case library(LibraryCollection)
    case queue
    case nights
    case workshop

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

    func openTake(_ model: SimulationModel) {
        if TakeFiles.open(model) { selection = .workshop }
    }

    func tune(_ model: SimulationModel, _ scene: LibraryScene) {
        guard scene.take != nil else { return }
        model.tune(scene)
        selection = .workshop
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
            }
        }
        // A run started anywhere, from a menu included, is watched in the workshop.
        .onChange(of: model.stage) { _, stage in
            if stage == .running, !model.contemplating { navigation.selection = .workshop }
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
            }
            Section("Nuits") {
                Label("Nuits", systemImage: "moon.stars")
                    .tag(SidebarItem.nights)
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
