import AVFoundation
import AppKit
import SillageRender
import SwiftUI

/// The library: every scene of every batch, chosen and rated in one click or one key.
struct LibraryView: View {
    @ObservedObject var model: LibraryModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            LibraryHeader(model: model)
            Divider()
            ZStack {
                if model.visible.isEmpty {
                    emptyState
                } else {
                    grid
                }
                if let id = model.enlarged, let scene = model.scene(id) {
                    LibraryEnlarged(model: model, scene: scene)
                }
            }
            Divider()
            footer
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
            model.watch()
        }
        .onDisappear { model.stop() }
        .onChange(of: model.selection) { focused = true }
    }

    private static func key(_ press: KeyPress) -> LibraryModel.Key? {
        guard press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return nil }
        switch press.key {
        case .leftArrow: return .left
        case .rightArrow: return .right
        case .upArrow: return .up
        case .downArrow: return .down
        case .space, .return: return .enlarge
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
                                playing: model.playing == scene.id && model.enlarged == nil,
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
        VStack(spacing: 10) {
            Text(model.scenes.isEmpty ? "Aucune scène ici" : "Aucune scène ne passe ces filtres")
                .font(.title3)
            Text(
                model.root.map {
                    model.scenes.isEmpty
                        ? "Les scènes apparaissent dès qu'elles arrivent dans \($0.path)."
                        : "Changer les filtres en haut de la fenêtre."
                } ?? "Choisir le dossier library."
            )
            .foregroundStyle(Palette.secondary)
            if model.root == nil || model.scenes.isEmpty {
                Button("Choisir un dossier…") { model.pickRoot() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Text(
                "← → ↑ ↓ naviguer · Y oui · N non · 0 à 9 la note, 1 puis 0 pour 10 · ⌫ effacer · espace agrandir · échap fermer"
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

struct LibraryHeader: View {
    @ObservedObject var model: LibraryModel

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Bibliothèque").font(.title2.bold())
                Text(summary).font(.caption.monospacedDigit()).foregroundStyle(Palette.secondary)
            }
            Spacer()
            Picker("Ordre", selection: $model.query.order) {
                Text("Lot").tag(LibraryQuery.Order.batch)
                Text("Note").tag(LibraryQuery.Order.rating)
                Text("Score").tag(LibraryQuery.Order.score)
                Text("Récentes").tag(LibraryQuery.Order.newest)
            }
            .fixedSize()
            Picker("Choix", selection: $model.query.choice) {
                Text("Tous").tag(LibraryQuery.Choice.all)
                Text("Oui").tag(LibraryQuery.Choice.yes)
                Text("Non").tag(LibraryQuery.Choice.no)
                Text("À trier").tag(LibraryQuery.Choice.undecided)
            }
            .fixedSize()
            Picker("Note", selection: $model.query.rating) {
                Text("Toutes").tag(LibraryQuery.Rating.any)
                Text("Non notées").tag(LibraryQuery.Rating.unrated)
                ForEach(1...10, id: \.self) { floor in
                    Text("≥ \(floor)").tag(LibraryQuery.Rating.atLeast(floor))
                }
            }
            .fixedSize()
            Picker("Lot", selection: $model.query.batch) {
                Text("Tous").tag(String?.none)
                ForEach(model.batches, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .fixedSize()
            Picker("Archétype", selection: $model.query.archetype) {
                Text("Tous").tag(String?.none)
                ForEach(model.archetypes, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .fixedSize()
            Button("Dossier…") { model.pickRoot() }
                .help(model.root?.path ?? "Aucun dossier choisi")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var summary: String {
        let shown = model.visible.count
        let total = model.scenes.count
        let yes = model.entries.values.filter { $0.choice == .yes }.count
        let rated = model.entries.values.filter { $0.rating != nil }.count
        let place = model.root?.lastPathComponent ?? "aucun dossier"
        return (shown == total ? "\(total) scènes" : "\(shown) sur \(total) scènes")
            + " · \(yes) oui · \(rated) notées · \(place)"
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
                Text(scene.name).font(.callout.monospacedDigit())
                Spacer(minLength: 4)
                Text(details).font(.caption).foregroundStyle(Palette.secondary).lineLimit(1)
                TuneButton(model: model, scene: scene)
            }
            ChoiceButtons(entry: entry) { model.choose($0, for: scene.id) }
            RatingButtons(entry: entry) { model.rate($0, for: scene.id) }
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
            ChoiceBadge(entry: entry).padding(6).frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onHover { model.hover(scene.id, inside: $0) }
        .onTapGesture {
            model.selection = scene.id
            model.enlarged = scene.id
        }
    }

    private var details: String {
        var parts: [String] = []
        if let archetype = scene.archetype { parts.append(archetype) }
        if let tempo = scene.tempo { parts.append(tempo) }
        if let galaxies = scene.galaxies { parts.append("\(galaxies) gal.") }
        if let score = scene.score { parts.append(String(format: "score %.2f", score)) }
        if parts.isEmpty { parts.append(scene.batch) }
        return parts.joined(separator: " · ")
    }
}

struct LibraryEnlarged: View {
    @ObservedObject var model: LibraryModel
    let scene: LibraryScene

    var body: some View {
        ZStack {
            Color.black.opacity(0.85)
                .onTapGesture { model.enlarged = nil }
            VStack(spacing: 12) {
                ZStack {
                    Color.black
                    if let still = ThumbnailCache.shared.cached(scene) {
                        Image(nsImage: still).resizable().aspectRatio(contentMode: .fit)
                    }
                    if model.playing == scene.id { PlayerView(player: model.player) }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: 1280)
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(scene.name).font(.title3.monospacedDigit())
                        Text(
                            [scene.batch, scene.archetype, scene.tempo, scene.seed.map { "graine \($0)" }]
                                .compactMap { $0 }.joined(separator: " · ")
                        )
                        .font(.caption)
                        .foregroundStyle(Palette.secondary)
                    }
                    Spacer()
                    TuneButton(model: model, scene: scene)
                    ChoiceButtons(entry: model.entries[scene.id]) { model.choose($0, for: scene.id) }
                        .frame(width: 180)
                    RatingButtons(entry: model.entries[scene.id]) { model.rate($0, for: scene.id) }
                        .frame(width: 330)
                }
                .frame(maxWidth: 1280)
            }
            .padding(24)
        }
    }
}

/// Opens the scene's high resolution take with its look, in the main window, for tuning.
/// Only there once `hires` has written a take.
struct TuneButton: View {
    let model: LibraryModel
    let scene: LibraryScene

    var body: some View {
        if scene.take != nil {
            Button("Régler le look") { model.tune(scene) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Ouvre la prise haute résolution avec le look de la scène")
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

    var body: some View {
        HStack(spacing: 4) {
            if let choice = entry?.choice {
                Text(choice == .yes ? "oui" : "non")
                    .foregroundStyle(
                        choice == .yes
                            ? Color(red: 0.45, green: 0.85, blue: 0.55)
                            : Color(red: 0.95, green: 0.5, blue: 0.45))
            }
            if let rating = entry?.rating { Text("\(rating)") }
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
            navigation.selection = .library
            openWindow(id: AppNavigation.windowID)
        }
        .keyboardShortcut("l", modifiers: .command)
    }
}
