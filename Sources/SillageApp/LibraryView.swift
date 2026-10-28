import AVFoundation
import AppKit
import SillageRender
import SwiftUI

/// One collection of the library, picked in the sidebar: its scenes chosen and rated in one
/// click or one key.
struct LibraryView: View {
    @ObservedObject var model: LibraryModel
    let collection: LibraryCollection
    /// Shows another collection of the sidebar.
    let open: (LibraryCollection) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if let triage = model.triage {
                TriageView(model: model, triage: triage) { open(.chosen) }
            } else {
                // The grid stays under the page, hidden, so escape finds it scrolled where it was.
                ZStack {
                    browser
                        .opacity(model.opened == nil ? 1 : 0)
                        .allowsHitTesting(model.opened == nil)
                        .accessibilityHidden(model.opened != nil)
                    if let scene = model.scene(model.opened) {
                        ScenePage(model: model, scene: scene)
                    }
                }
            }
        }
        .panelSurface()
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(phases: .down) { press in
            guard let key = Self.key(press) else { return .ignored }
            return model.handle(key) ? .handled : .ignored
        }
        .onAppear {
            focused = true
            model.query.collection = collection
            model.show(true)
        }
        .onDisappear { model.show(false) }
        .onChange(of: collection) { _, collection in
            model.endTriage()
            model.close()
            model.query.collection = collection
        }
        .onChange(of: model.selection) { if !model.isSearching { focused = true } }
        .onChange(of: model.gridFocusRequests) { focused = true }
    }

    private var browser: some View {
        VStack(spacing: 0) {
            LibraryHeader(model: model, collection: collection)
            Divider()
            if model.visible.isEmpty {
                emptyState
            } else {
                grid
            }
            Divider()
            footer
        }
    }

    private static func key(_ press: KeyPress) -> LibraryModel.Key? {
        guard press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return nil }
        switch press.key {
        case .leftArrow: return .left
        case .rightArrow: return .right
        case .upArrow: return .up
        case .downArrow: return .down
        case .space, .return: return .open
        case .escape: return .close
        case .delete, .deleteForward: return .clear
        default: break
        }
        switch press.characters.lowercased() {
        case "y", "o": return .yes
        case "n": return .no
        case let text where text.count == 1 && text.first?.isASCII == true:
            return text.first?.wholeNumberValue.map { .digit($0) }
        default: return nil
        }
    }

    private var grid: some View {
        GeometryReader { geometry in
            let columns = max(1, Int((geometry.size.width - 24) / (LibraryCard.width + 12)))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columns),
                        spacing: 12
                    ) {
                        ForEach(model.visible) { scene in
                            LibraryCard(
                                model: model, scene: scene, entry: model.entries[scene.id],
                                selected: model.selection == scene.id,
                                playing: model.playing == scene.id && model.opened == nil,
                                ready: model.playable.contains(scene.id)
                            )
                            .id(scene.id)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: model.selection) { _, selection in
                    guard let selection else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(selection) }
                }
            }
            .onAppear { model.columns = columns }
            .onChange(of: columns) { _, columns in model.columns = columns }
        }
    }

    private var emptyState: some View {
        let nothingHere = model.scenes.isEmpty
        let nothingInCollection = (model.counts[collection] ?? 0) == 0
        return VStack(spacing: 10) {
            Text(
                nothingHere || nothingInCollection
                    ? collection.emptyTitle : "Aucune scène ne passe ces filtres"
            )
            .font(.title3)
            Text(
                model.root.map {
                    nothingHere
                        ? "Les scènes apparaissent dès qu'elles arrivent dans \($0.path)."
                        : nothingInCollection
                            ? collection.emptyDetail : "Changer les filtres en haut de la fenêtre."
                } ?? "Choisir le dossier library."
            )
            .foregroundStyle(Palette.secondary)
            if model.root == nil || nothingHere {
                Button("Choisir un dossier…") { model.pickRoot() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Text(
                "← → ↑ ↓ naviguer · Y oui · N non · 0 à 9 la note · ⌫ effacer · espace ouvrir la scène"
            )
            .font(.caption)
            .foregroundStyle(Palette.secondary)
            Spacer()
            if let failure = model.failure {
                Text(failure).font(.caption).foregroundStyle(Palette.warning)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

/// The collection's name, the one button that moves it on, and the sort, filters and search
/// that narrow it.
struct LibraryHeader: View {
    @ObservedObject var model: LibraryModel
    let collection: LibraryCollection

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(collection.title).font(.title2.bold())
                Text(summary).font(.caption.monospacedDigit()).foregroundStyle(Palette.secondary)
            }
            Spacer(minLength: 12)
            LibraryPrimaryButton(model: model, collection: collection)
            Picker("Trier par", selection: $model.query.order) {
                Text("Score").tag(LibraryQuery.Order.score)
                Text("Note").tag(LibraryQuery.Order.rating)
                Text("Récentes").tag(LibraryQuery.Order.newest)
            }
            .fixedSize()
            LibraryFilters(model: model)
            LibrarySearchField(model: model)
            Button("Dossier…") { model.pickRoot() }
                .help(model.root?.path ?? "Aucun dossier choisi")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var summary: String {
        let shown = model.visible.count
        let total = model.counts[collection] ?? 0
        let place = model.root?.lastPathComponent ?? "aucun dossier"
        return (shown == total ? "\(total) scènes" : "\(shown) sur \(total) scènes") + " · \(place)"
    }
}

/// The one thing to do next with the collection, which is the stage's own step. Calculer and
/// Exporter act on every scene listed, through the same form and sheet as the scene page.
struct LibraryPrimaryButton: View {
    @ObservedObject var model: LibraryModel
    let collection: LibraryCollection
    @Environment(\.queue) private var queue
    @State private var computing = false
    @State private var exporting = false

    var body: some View {
        switch collection {
        case .toSort:
            button("Trier", "Une scène à la fois, au clavier") { model.startTriage() }
        case .chosen:
            if let queue {
                button(
                    "Calculer en haute résolution (\(folders.count))",
                    "Une haute résolution pour chaque scène listée", count: folders.count
                ) { computing = true }
                .popover(isPresented: $computing, arrowEdge: .bottom) {
                    HiresForm(queue: queue, folders: folders) { computing = false }
                        .padding(16)
                        .frame(width: 340, alignment: .leading)
                }
            }
        case .toStyle:
            button("Choisir le style de la suivante", "Ouvre l'éditeur de style sur sa haute résolution") {
                model.chooseStyleOfNext()
            }
        case .ready:
            if let queue {
                button(
                    "Exporter (\(folders.count))", "Les mêmes vidéos pour chaque scène listée",
                    count: folders.count
                ) { exporting = true }
                .sheet(isPresented: $exporting) {
                    ExportSheet(queue: queue, folders: folders) { exporting = false }
                }
            }
        case .exported:
            button("Montrer les vidéos", "Les montre dans le Finder") { model.revealExports() }
        case .highResolution, .all:
            EmptyView()
        }
    }

    /// The scenes listed that have a folder to compute from.
    var folders: [SceneFolder] { model.visible.compactMap(\.folder) }

    private func button(
        _ title: String, _ help: String, count: Int? = nil, _ action: @escaping () -> Void
    ) -> some View {
        Button(title, action: action)
            .buttonStyle(.borderedProminent)
            .disabled((count ?? model.visible.count) == 0)
            .help(help)
    }
}

/// The triage view: one scene large and looping, decided from the keyboard. It lists the scenes
/// as they were when it opened, so the scene just decided does not slip away under the hand.
struct TriageView: View {
    @ObservedObject var model: LibraryModel
    let triage: LibraryModel.Triage
    /// Goes to Choisies, once nothing is left to sort.
    let showChosen: () -> Void
    @State private var still: NSImage?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if triage.finished {
                    finished
                } else if let scene = model.scene(triage.current) {
                    content(scene)
                } else {
                    Color.clear
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
    }

    private var header: some View {
        let progress = model.triageProgress ?? (0, 0)
        return HStack(spacing: 12) {
            Text("Trier").font(.title2.bold())
            Text("\(progress.0) / \(progress.1) triées")
                .font(.title3.monospacedDigit())
                .foregroundStyle(Palette.secondary)
            GeometryReader { bar in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(white: 0.2))
                    Capsule().fill(Color.accentColor)
                        .frame(width: bar.size.width * Double(progress.0) / Double(max(progress.1, 1)))
                }
            }
            .frame(width: 240, height: 6)
            Spacer()
            Button("Quitter") { model.endTriage() }
                .help("Revient à la grille (échap)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func content(_ scene: LibraryScene) -> some View {
        let entry = model.entries[scene.id]
        return VStack(spacing: 14) {
            ZStack(alignment: .topLeading) {
                Color.black
                if let still { Image(nsImage: still).resizable().aspectRatio(contentMode: .fit) }
                if model.playing == scene.id { PlayerView(player: model.player) }
                ChoiceBadge(entry: entry).padding(10)
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .frame(maxWidth: 1180)
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(scene.name).font(.title2.monospacedDigit())
                Text(details(scene)).foregroundStyle(Palette.secondary)
                Spacer()
            }
            .frame(maxWidth: 1180)
            HStack(spacing: 16) {
                Button {
                    model.handle(.left)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .help("La scène d'avant (←)")
                ChoiceButtons(entry: entry) { model.handle($0 == .yes ? .yes : .no) }
                    .frame(width: 220)
                RatingButtons(entry: entry) { model.rate($0, for: scene.id) }
                    .frame(width: 380)
                Button {
                    model.handle(.right)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .help("La scène suivante (→)")
            }
        }
        .padding(20)
        .task(id: ThumbnailCache.shared.key(scene)) {
            still = ThumbnailCache.shared.cached(scene)
            if let image = await ThumbnailCache.shared.load(scene) { still = image }
        }
    }

    private func details(_ scene: LibraryScene) -> String {
        var parts = [scene.archetype ?? "libre"]
        if let galaxies = scene.galaxies {
            parts.append(galaxies == 1 ? "1 galaxie" : "\(galaxies) galaxies")
        }
        if let score = scene.score { parts.append(String(format: "score %.2f", score)) }
        return parts.joined(separator: " · ")
    }

    private var finished: some View {
        let entries = triage.order.compactMap { model.entries[$0]?.choice }
        let kept = entries.filter { $0 == .yes }.count
        return VStack(spacing: 12) {
            Text(LibraryCollection.toSort.emptyTitle).font(.title)
            Text("\(kept) choisies, \(entries.count - kept) écartées.")
                .foregroundStyle(Palette.secondary)
            Button("Aller aux Choisies", action: showChosen)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }

    private var footer: some View {
        HStack {
            Text(
                "Y oui · N non · 0 à 9 la note, 1 puis 0 pour 10 · ← → scène précédente, suivante · ⌫ effacer · échap quitter"
            )
            .font(.caption)
            .foregroundStyle(Palette.secondary)
            Spacer()
            if let failure = model.failure {
                Text(failure).font(.caption).foregroundStyle(Palette.warning)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

/// Archetype, number of galaxies and rating, which narrow whatever the collection lists.
struct LibraryFilters: View {
    @ObservedObject var model: LibraryModel

    var body: some View {
        Menu {
            Picker("Archétype", selection: $model.query.archetype) {
                Text("Tous").tag(String?.none)
                ForEach(model.archetypes, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            Picker("Galaxies", selection: $model.query.galaxies) {
                Text("Toutes").tag(Int?.none)
                ForEach(model.galaxyCounts, id: \.self) { Text("\($0)").tag(Int?.some($0)) }
            }
            Picker("Note", selection: $model.query.rating) {
                Text("Toutes").tag(LibraryQuery.Rating.any)
                Text("Non notées").tag(LibraryQuery.Rating.unrated)
                ForEach(1...10, id: \.self) { floor in
                    Text("≥ \(floor)").tag(LibraryQuery.Rating.atLeast(floor))
                }
            }
            Divider()
            Button("Tout afficher") {
                model.query.archetype = nil
                model.query.galaxies = nil
                model.query.rating = .any
            }
            .disabled(active == 0)
        } label: {
            Label(
                active == 0 ? "Filtres" : "Filtres (\(active))",
                systemImage: "line.3.horizontal.decrease.circle")
        }
        .fixedSize()
    }

    private var active: Int {
        [
            model.query.archetype != nil, model.query.galaxies != nil, model.query.rating != .any,
        ].filter { $0 }.count
    }
}

/// Filters the scenes on a part of their name. The grid keeps the keys unless this holds the
/// focus, and gets them back on return or escape.
struct LibrarySearchField: View {
    @ObservedObject var model: LibraryModel
    @FocusState private var focus: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(Palette.secondary)
            TextField("Nom de la scène", text: $model.query.search)
                .textFieldStyle(.plain)
                .focused($focus)
                .onSubmit { leave() }
                .onExitCommand { leave() }
            if !model.query.search.isEmpty {
                Button {
                    model.query.search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(width: 170)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.2)))
        .onChange(of: focus) { _, focus in model.isSearching = focus }
    }

    private func leave() {
        focus = false
        model.isSearching = false
        model.gridFocusRequests += 1
    }
}

struct LibraryCard: View {
    static let width: CGFloat = 300

    let model: LibraryModel
    let scene: LibraryScene
    let entry: SceneRatings.Entry?
    let selected: Bool
    let playing: Bool
    let ready: Bool
    @State private var still: NSImage?

    init(
        model: LibraryModel, scene: LibraryScene, entry: SceneRatings.Entry?, selected: Bool,
        playing: Bool, ready: Bool
    ) {
        self.model = model
        self.scene = scene
        self.entry = entry
        self.selected = selected
        self.playing = playing
        self.ready = ready
        _still = State(initialValue: ThumbnailCache.shared.cached(scene))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            preview
            HStack(spacing: 6) {
                Text(scene.name).font(.callout.monospacedDigit()).lineLimit(1)
                Spacer(minLength: 4)
                if scene.take != nil { Pill(text: "HD", tint: Color.accentColor) }
                Pill(text: scene.stage.pillTitle, tint: Color(white: 0.5))
            }
            HStack(spacing: 6) {
                Text(summary).font(.caption.monospacedDigit()).foregroundStyle(Palette.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let videos = Self.videoCount(scene) {
                    Label("\(videos)", systemImage: "film").font(.caption.monospacedDigit())
                        .foregroundStyle(Palette.secondary)
                        .help("Vidéos")
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.card))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(selected ? Color.accentColor : Color(white: 0.24), lineWidth: selected ? 2 : 1)
        )
        .task(id: ThumbnailCache.shared.key(scene)) {
            if let image = await ThumbnailCache.shared.load(scene) { still = image }
        }
    }

    private var preview: some View {
        ZStack(alignment: .topTrailing) {
            Color.black
            if let still {
                Image(nsImage: still).resizable().aspectRatio(contentMode: .fit)
            }
            if playing {
                PlayerView(player: model.player)
            }
            if !ready {
                Text(scene.video == nil ? "sans vidéo" : "en cours")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.black.opacity(0.6)))
                    .padding(6)
            }
            ChoiceBadge(entry: entry, showsRating: false).padding(6)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onHover { model.hover(scene.id, inside: $0) }
        .onTapGesture { model.open(scene.id) }
    }

    /// The rating if there is one, else the score.
    private var summary: String {
        if let rating = entry?.rating { return "note \(rating)" }
        if let score = scene.score { return String(format: "score %.2f", score) }
        return " "
    }

    static func videoCount(_ scene: LibraryScene) -> Int? {
        scene.exports.isEmpty ? nil : scene.exports.count
    }
}

struct Pill: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.25)))
            .foregroundStyle(Palette.label)
            .lineLimit(1)
    }
}

extension SceneStage {
    var pillTitle: String {
        switch self {
        case .toSort: "À trier"
        case .discarded: "Écartée"
        case .chosen: "Choisie"
        case .highResolution: "Haute résolution"
        case .toStyle: "Style à choisir"
        case .ready: "Prête"
        case .exported: "Exportée"
        }
    }
}

/// Yes and no, side by side. Clicking the one already lit takes it back.
struct ChoiceButtons: View {
    let entry: SceneRatings.Entry?
    let choose: (SceneRatings.Choice) -> Void

    var body: some View {
        HStack(spacing: 6) {
            button("Oui", .yes, Color(red: 0.25, green: 0.62, blue: 0.38))
            button("Non", .no, Color(red: 0.70, green: 0.30, blue: 0.27))
        }
    }

    private func button(_ title: String, _ choice: SceneRatings.Choice, _ tint: Color) -> some View {
        let lit = entry?.choice == choice
        return Button {
            choose(choice)
        } label: {
            Text(title)
                .font(.callout.weight(lit ? .semibold : .regular))
                .frame(maxWidth: .infinity, minHeight: 24)
                .background(RoundedRectangle(cornerRadius: 5).fill(lit ? tint : Color(white: 0.2)))
                .foregroundStyle(lit ? Color.white : Palette.label)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Eleven buttons, 0 to 10. Clicking the lit one takes the rating back.
struct RatingButtons: View {
    let entry: SceneRatings.Entry?
    let rate: (Int) -> Void

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(SceneRatings.ratingRange), id: \.self) { value in
                let lit = entry?.rating == value
                Button {
                    rate(value)
                } label: {
                    Text("\(value)")
                        .font(.caption.monospacedDigit().weight(lit ? .bold : .regular))
                        .frame(maxWidth: .infinity, minHeight: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(lit ? Color.accentColor : Color(white: 0.2))
                        )
                        .foregroundStyle(lit ? Color.white : Palette.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct ChoiceBadge: View {
    let entry: SceneRatings.Entry?
    var showsRating = true

    var body: some View {
        HStack(spacing: 4) {
            if let choice = entry?.choice {
                Text(choice == .yes ? "Choisie" : "Écartée")
                    .foregroundStyle(
                        choice == .yes
                            ? Color(red: 0.45, green: 0.85, blue: 0.55)
                            : Color(red: 0.95, green: 0.5, blue: 0.45))
            }
            if entry?.choice == nil, entry?.picked != nil {
                Text("Choisie par le score").foregroundStyle(Color(red: 0.55, green: 0.75, blue: 0.95))
            }
            if showsRating, let rating = entry?.rating { Text("\(rating)") }
        }
        .font(.caption.weight(.semibold).monospacedDigit())
        .padding(.horizontal, entry?.isEmpty == false ? 6 : 0)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.black.opacity(entry?.isEmpty == false ? 0.6 : 0)))
    }
}

/// The one player, shown wherever its scene is: in its card, or enlarged.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }

    static func dismantleNSView(_ view: PlayerLayerView, coordinator: ()) {
        view.playerLayer.player = nil
    }
}

final class PlayerLayerView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}

/// The menu item and its shortcut: selects the library, reopening the window if it was closed.
struct LibraryCommand: View {
    @ObservedObject var navigation: AppNavigation
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Bibliothèque") {
            navigation.showLibrary()
            openWindow(id: AppNavigation.windowID)
        }
        .keyboardShortcut("l", modifiers: .command)
    }
}
