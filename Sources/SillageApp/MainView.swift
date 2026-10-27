import SillageRender
import SwiftUI

enum SidebarItem: Hashable {
    case library(LibraryCollection)
    case queue
    /// A night's page, by its folder name.
    case night(String)
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

    /// A night launched shows its page.
    func nightLaunched(_ batch: String?) {
        showsNightSheet = false
        if let batch { selection = .night(batch) }
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
    /// Watched by the sidebar and the night page, not here: the sheet below would be rebuilt.
    let nights: NightsModel

    var body: some View {
        Group {
            if model.contemplating {
                ContemplationView(model: model)
            } else {
                NavigationSplitView {
                    Sidebar(
                        model: model, library: library, queue: queue, nights: nights,
                        navigation: navigation
                    )
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
                        launched: { navigation.nightLaunched($0) })
                }
            }
        }
        // The night sheet opens on a plan already sized.
        .onAppear {
            let library = queue.store.library
            Task.detached(priority: .utility) { NightSheetPlanner.shared(library: library).warm() }
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
        case .night(let id):
            NightPageView(
                id: id, nights: nights, queue: queue, library: library,
                openScene: { scene in
                    navigation.selection = .library(.all)
                    library.open(scene)
                },
                sort: { batch in
                    library.startTriage(batch: batch)
                    navigation.selection = .library(.toSort)
                })
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
    @ObservedObject var nights: NightsModel
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
                ForEach(nights.items) { item in
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.day)
                            Text(item.summary).font(.caption).foregroundStyle(Palette.secondary)
                        }
                    } icon: {
                        Image(systemName: item.live ? "moon.stars.fill" : "moon")
                    }
                    .tag(SidebarItem.night(item.id))
                }
                if nights.items.isEmpty {
                    Text("Aucune nuit encore").font(.callout).foregroundStyle(Palette.secondary)
                }
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
