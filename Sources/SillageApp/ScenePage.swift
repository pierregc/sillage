import AppKit
import SillageCore
import SillageRender
import SwiftUI

/// One scene in the detail area: every version in one player, the five steps with the next one
/// to take, what can be redone, and the technical details folded at the bottom.
struct ScenePage: View {
    @ObservedObject var model: LibraryModel
    let scene: LibraryScene
    /// Drawn offscreen by the checks, which cannot draw a scroll view or a menu.
    var snapshot = false
    @State private var still: NSImage?
    @State private var detailsShown = false

    private var entry: SceneRatings.Entry? { model.entries[scene.id] }
    private var facts: ScenePageFacts? { model.facts?.id == scene.id ? model.facts : nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if snapshot {
                content
                Spacer(minLength: 0)
            } else {
                ScrollView { content }
            }
            Divider()
            footer
        }
        .environment(\.offscreen, snapshot)
        .task(id: ThumbnailCache.shared.key(scene)) {
            still = ThumbnailCache.shared.cached(scene)
            if let image = await ThumbnailCache.shared.load(scene) { still = image }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            player
            StageTracker(model: model, scene: scene, entry: entry, facts: facts)
            technicalDetails
        }
        .padding(20)
        .frame(maxWidth: 1240)
        .frame(maxWidth: .infinity)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                model.close()
            } label: {
                Label("Bibliothèque", systemImage: "chevron.left")
            }
            .help("Revient à la grille (échap)")
            VStack(alignment: .leading, spacing: 2) {
                Text(scene.name).font(.title2.bold().monospacedDigit())
                Text(subtitle).font(.caption.monospacedDigit()).foregroundStyle(Palette.secondary)
            }
            Spacer()
            if snapshot {
                Label("Refaire", systemImage: "arrow.counterclockwise").foregroundStyle(Palette.secondary)
            } else {
                RedoMenu(model: model, scene: scene, entry: entry, facts: facts)
            }
            HStack(spacing: 4) {
                Button {
                    model.moveOpened(-1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .help("La scène d'avant (←)")
                Button {
                    model.moveOpened(1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .help("La scène suivante (→)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var subtitle: String {
        var parts = [scene.batch]
        if let at = model.visible.firstIndex(where: { $0.id == scene.id }) {
            parts.append("\(at + 1) sur \(model.visible.count) · \(model.query.collection.title)")
        } else {
            parts.append("n'est plus dans \(model.query.collection.title)")
        }
        return parts.joined(separator: " · ")
    }

    private var player: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                Color.black
                if let still = still ?? ThumbnailCache.shared.cached(scene) {
                    Image(nsImage: still).resizable().aspectRatio(contentMode: .fit)
                }
                if model.playing == scene.id, !snapshot { PlayerView(player: model.player) }
                ChoiceBadge(entry: entry).padding(10)
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxHeight: 520)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .frame(maxWidth: .infinity)
            VersionPicker(model: model, scene: scene)
        }
    }

    private var technicalDetails: some View {
        DisclosureGroup("Détails techniques", isExpanded: $detailsShown) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                row("Graine", scene.seed ?? "inconnue")
                row("Index", scene.index.map(String.init) ?? "inconnu")
                row("Lot", scene.batch)
                GridRow {
                    Text("Dossier").foregroundStyle(Palette.secondary)
                    HStack(spacing: 10) {
                        Text(location.path)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                        Button("Montrer dans le Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([location])
                        }
                        .controlSize(.small)
                    }
                }
            }
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The scene's folder, or its video in a flat batch.
    private var location: URL { scene.folder?.url ?? scene.video ?? scene.batchURL }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(Palette.secondary)
            Text(value).font(.callout.monospacedDigit()).textSelection(.enabled)
        }
    }

    private var footer: some View {
        HStack {
            Text(
                "← → scène précédente, suivante · Y oui · N non · 0 à 9 la note, 1 puis 0 pour 10 · ⌫ effacer · échap la grille"
            )
            .font(.caption)
            .foregroundStyle(Palette.secondary)
            Spacer()
            if let failure = model.failure {
                Text(failure).font(.caption).foregroundStyle(Palette.warning)
            } else if model.copied != nil {
                Text("Commande copiée, à coller dans le Terminal")
                    .font(.caption)
                    .foregroundStyle(Color(red: 0.45, green: 0.85, blue: 0.55))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

/// Aperçu, Haute résolution, then one entry per video. One decoder: picking one replaces
/// whatever played.
struct VersionPicker: View {
    @ObservedObject var model: LibraryModel
    let scene: LibraryScene
    @Environment(\.offscreen) private var offscreen

    var body: some View {
        let versions = scene.versions
        HStack(spacing: 10) {
            if versions.count > 1, offscreen {
                Text(versions.map(\.title).joined(separator: " · ")).font(.callout)
            } else if versions.count > 1 {
                Picker("Version", selection: selection) {
                    ForEach(versions) { Text($0.title).tag(Optional($0.url)) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            } else if let only = versions.first {
                Text(only.title).font(.callout).foregroundStyle(Palette.secondary)
            } else {
                Text("Aucune vidéo").font(.callout).foregroundStyle(Palette.secondary)
            }
            Spacer()
            if let url = model.playingURL, model.playing == scene.id {
                Button("Montrer le fichier") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .controlSize(.small)
                    .help(url.lastPathComponent)
            }
        }
    }

    private var selection: Binding<URL?> {
        Binding(
            get: { model.version ?? scene.defaultVersion?.url },
            set: { model.version = $0 })
    }
}

extension SceneVersion {
    var title: String {
        switch kind {
        case .preview: "Aperçu"
        case .highResolution: "Haute résolution"
        case .video(let name): "Vidéo \(name)"
        }
    }
}

/// The five steps side by side: what each one did, the next one highlighted with its button,
/// the later ones dimmed.
struct StageTracker: View {
    @ObservedObject var model: LibraryModel
    let scene: LibraryScene
    let entry: SceneRatings.Entry?
    let facts: ScenePageFacts?

    var body: some View {
        let states = SceneStep.states(scene, entry: entry)
        HStack(alignment: .top, spacing: 8) {
            ForEach(SceneStep.allCases, id: \.self) { step in
                StageColumn(step: step, state: states[step] ?? .later) {
                    content(step, states[step] ?? .later)
                }
            }
        }
    }

    @ViewBuilder
    private func content(_ step: SceneStep, _ state: SceneStep.State) -> some View {
        switch step {
        case .exploration: exploration
        case .choice: choice
        case .highResolution: highResolution(state)
        case .style: style(state)
        case .export: export(state)
        }
    }

    private var exploration: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let score = scene.score { fact(String(format: "score %.2f", score)) }
            if let galaxies = scene.galaxies { fact(galaxies == 1 ? "1 galaxie" : "\(galaxies) galaxies") }
            fact(scene.archetype ?? "libre")
            if let story = facts?.story {
                fact(
                    String(
                        format: "%.0f Myr, de %.0f à %.0f", story.endMyr - story.startMyr, story.startMyr,
                        story.endMyr))
            }
        }
    }

    private var choice: some View {
        VStack(alignment: .leading, spacing: 6) {
            fact(choiceSummary)
            ChoiceButtons(entry: entry) { model.choose($0, for: scene.id) }
            RatingGrid(entry: entry) { model.rate($0, for: scene.id) }
        }
    }

    private var choiceSummary: String {
        var parts: [String] = []
        switch entry?.choice {
        case .yes: parts.append("Oui")
        case .no: parts.append("Non")
        case nil:
            if let picked = entry?.picked {
                parts.append(String(format: "Choisie par le score (%.2f)", picked.score))
            }
        }
        if let rating = entry?.rating { parts.append("note \(rating)") }
        return parts.isEmpty ? "Pas encore décidée" : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func highResolution(_ state: SceneStep.State) -> some View {
        switch state {
        case .done:
            VStack(alignment: .leading, spacing: 3) {
                if let hires = facts?.hires {
                    fact("\(Format.particles(hires.particles)) particules")
                    if let seconds = hires.seconds { fact("\(Format.duration(seconds)) de calcul") }
                } else if let hires = scene.hires {
                    fact("\(Format.particles(hires.particles)) particules")
                }
                if let date = facts?.hiresDate { fact(Format.date(date)) }
            }
        case .next:
            if scene.hiresActive {
                fact("Dans la file d'attente")
            } else {
                HiresOffer(model: model, scene: scene, facts: facts)
            }
        case .later:
            later(scene.folder == nil ? "Pas de dossier de scène" : "Après le choix")
        }
    }

    @ViewBuilder
    private func style(_ state: SceneStep.State) -> some View {
        switch state {
        case .done:
            VStack(alignment: .leading, spacing: 6) {
                fact(facts.map { $0.rawStyle ? "Style brut" : $0.styleName ?? "Style" } ?? "Style choisi")
                if let palette = facts?.palette, !palette.isEmpty { Swatches(colours: palette) }
            }
        case .next:
            Button("Choisir le style") { model.tune(scene) }
                .buttonStyle(.borderedProminent)
                .help("Ouvre la prise haute résolution avec son style dans l'Atelier")
        case .later:
            later("Après la haute résolution")
        }
    }

    @ViewBuilder
    private func export(_ state: SceneStep.State) -> some View {
        switch state {
        case .done:
            VStack(alignment: .leading, spacing: 3) {
                let videos = scene.videos
                fact(videos.count == 1 ? "1 vidéo" : "\(videos.count) vidéos")
                ForEach(videos, id: \.self) { url in
                    Button(url.deletingPathExtension().lastPathComponent) { model.version = url }
                        .buttonStyle(.plain)
                        .font(.callout)
                        .foregroundStyle(Color.accentColor)
                        .help("La lire")
                }
            }
        case .next:
            ExportOffer(model: model, scene: scene)
        case .later:
            later("Après le style")
        }
    }

    private func fact(_ text: String) -> some View {
        Text(text).font(.callout.monospacedDigit()).fixedSize(horizontal: false, vertical: true)
    }

    private func later(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(Palette.secondary)
    }
}

struct StageColumn<Content: View>: View {
    let step: SceneStep
    let state: SceneStep.State
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .foregroundStyle(
                        state == .done ? Color(red: 0.45, green: 0.85, blue: 0.55) : Palette.label)
                Text(step.title).font(.headline)
            }
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(state == .next ? Color.accentColor.opacity(0.16) : Palette.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    state == .next ? Color.accentColor : Color(white: 0.24),
                    lineWidth: state == .next ? 2 : 1)
        )
        .opacity(state == .later ? 0.5 : 1)
    }

    private var symbol: String {
        switch state {
        case .done: "checkmark.circle.fill"
        case .next: "arrow.right.circle.fill"
        case .later: "circle"
        }
    }
}

extension SceneStep {
    var title: String {
        switch self {
        case .exploration: "Exploration"
        case .choice: "Choix"
        case .highResolution: "Haute résolution"
        case .style: "Style"
        case .export: "Export"
        }
    }
}

/// Calculer waits for the queue's sheet (#106); until then, the command line to copy, at the
/// size picked, with what it costs.
struct HiresOffer: View {
    @ObservedObject var model: LibraryModel
    let scene: LibraryScene
    let facts: ScenePageFacts?
    @State private var particles = 2_000_000
    @Environment(\.offscreen) private var offscreen

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button("Calculer") {}
                .buttonStyle(.borderedProminent)
                .disabled(true)
                .help("Disponible avec la file d'attente")
            if let folder = scene.folder {
                if offscreen {
                    Text(facts?.hiresCosts.first { $0.particles == particles }?.label ?? "")
                        .font(.callout)
                } else {
                    Picker("Taille", selection: $particles) {
                        ForEach(facts?.hiresCosts ?? [], id: \.particles) { cost in
                            Text(cost.label).tag(cost.particles)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                CopyCommand(model: model, command: StageCommand.hires(folder, particles: particles))
            }
        }
    }
}

/// Exporter… waits for #106 too; until then, the command for the preset picked.
struct ExportOffer: View {
    @ObservedObject var model: LibraryModel
    let scene: LibraryScene
    @State private var preset = "1080p"
    @Environment(\.offscreen) private var offscreen

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button("Exporter…") {}
                .buttonStyle(.borderedProminent)
                .disabled(true)
                .help("Disponible avec la file d'attente")
            if let folder = scene.folder {
                if offscreen {
                    Text(preset).font(.callout)
                } else {
                    Picker("Format", selection: $preset) {
                        ForEach(VideoPreset.all.map(\.name), id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                CopyCommand(
                    model: model,
                    command: StageCommand.export(folder, preset: preset, existing: scene.exports))
            }
        }
    }
}

/// A command line, cut short, and the button that copies it whole.
struct CopyCommand: View {
    let model: LibraryModel
    let command: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(command)
                .font(.caption2.monospaced())
                .foregroundStyle(Palette.secondary)
                .lineLimit(2)
                .truncationMode(.head)
                .help(command)
            Button("Copier la commande") { model.copy(command) }
                .controlSize(.small)
        }
    }
}

/// The 0 to 10 rating in two rows, to fit a step's column.
struct RatingGrid: View {
    let entry: SceneRatings.Entry?
    let rate: (Int) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 6), spacing: 3) {
            ForEach(Array(SceneRatings.ratingRange), id: \.self) { value in
                let lit = entry?.rating == value
                Button {
                    rate(value)
                } label: {
                    Text("\(value)")
                        .font(.caption.monospacedDigit().weight(lit ? .bold : .regular))
                        .frame(maxWidth: .infinity, minHeight: 20)
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

/// The style's galaxy colours, linear sRGB as the look file keeps them.
struct Swatches: View {
    let colours: [SIMD3<Float>]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(colours.enumerated()), id: \.offset) { _, colour in
                Circle()
                    .fill(
                        Color(
                            .sRGBLinear, red: Double(colour.x), green: Double(colour.y),
                            blue: Double(colour.z))
                    )
                    .frame(width: 16, height: 16)
                    .overlay(Circle().strokeBorder(Color(white: 0.3), lineWidth: 1))
            }
        }
    }
}

/// Every step already done, redone on its own. What the app cannot run yet copies its
/// command line instead.
struct RedoMenu: View {
    @ObservedObject var model: LibraryModel
    let scene: LibraryScene
    let entry: SceneRatings.Entry?
    let facts: ScenePageFacts?

    var body: some View {
        let states = SceneStep.states(scene, entry: entry)
        let done = { (step: SceneStep) in states[step] == .done }
        Menu {
            if done(.choice) {
                Button("Effacer le choix et la note") { model.clear(scene.id) }
            }
            if done(.highResolution), let folder = scene.folder {
                Menu("Recalculer en haute résolution (copier la commande)") {
                    ForEach(facts?.hiresCosts ?? [], id: \.particles) { cost in
                        Button(cost.label) {
                            model.copy(StageCommand.hires(folder, particles: cost.particles))
                        }
                    }
                }
            }
            if done(.style) {
                Button("Choisir le style à nouveau") { model.tune(scene) }
                if facts?.rawStyle == false {
                    Button("Revenir au style brut") { model.restoreRawLook(scene) }
                        .help("Le style actuel reste dans looks/")
                }
            }
            if done(.export), let folder = scene.folder {
                Menu("Exporter dans un autre format (copier la commande)") {
                    ForEach(VideoPreset.all.map(\.name), id: \.self) { preset in
                        Button(preset) {
                            model.copy(StageCommand.export(folder, preset: preset, existing: scene.exports))
                        }
                    }
                }
                Menu("Exporter avec un autre style (copier la commande)") {
                    let looks = facts?.otherLooks ?? []
                    if looks.isEmpty {
                        Text("Aucun autre style pour cette scène")
                    }
                    ForEach(looks, id: \.name) { look in
                        Button(look.name == StageCommand.rawLookName ? "Style brut" : look.name) {
                            model.copy(
                                StageCommand.export(
                                    folder, preset: "1080p", look: look, existing: scene.exports))
                        }
                    }
                }
            }
        } label: {
            Label("Refaire", systemImage: "arrow.counterclockwise")
        }
        .fixedSize()
        .disabled(!SceneStep.allCases.dropFirst().contains(where: done))
    }
}

/// What the page reads beyond the scan, off the main actor when a scene opens.
struct ScenePageFacts: Sendable, Equatable {
    struct HiresCost: Sendable, Equatable {
        var particles: Int
        var seconds: Double?

        var label: String {
            "\(Format.particles(particles))" + (seconds.map { ", environ \(Format.duration($0))" } ?? "")
        }
    }

    /// A look the scene can be exported with besides its own: one of `looks/`, or the raw one.
    struct OtherLook: Sendable, Equatable {
        var name: String
        var file: URL
    }

    var id: String
    var story: Story.Span?
    var hires: SceneFolder.Hires?
    var hiresDate: Date?
    var styleName: String?
    var palette: [SIMD3<Float>] = []
    var rawStyle = false
    var otherLooks: [OtherLook] = []
    var hiresCosts: [HiresCost] = []

    /// The sizes offered, measured on this Mac (#19): about 30 min at 1 M, 85 min at 2 M, 4 h
    /// at 5 M and 8 h at 10 M for a 700 Myr story, and from the cost model once it has runs.
    static let hiresSizes = [1_000_000, 2_000_000, 5_000_000, 10_000_000]
    static let measuredSeconds: [Int: Double] = [
        1_000_000: 1_800, 2_000_000: 5_100, 5_000_000: 14_400, 10_000_000: 28_800,
    ]

    nonisolated static func read(_ scene: LibraryScene) -> ScenePageFacts {
        var facts = ScenePageFacts(id: scene.id)
        guard let folder = scene.folder else { return facts }
        let manager = FileManager.default
        facts.story = (try? folder.storedClip())?.story
        facts.hires = folder.storedHires()
        facts.hiresDate =
            (try? manager.attributesOfItem(atPath: folder.hires.path))?[.modificationDate] as? Date
        if let data = try? Data(contentsOf: folder.look), let look = try? LookFile.decoded(from: data) {
            facts.styleName = look.name
            facts.palette = look.palette.map(\.colour)
        }
        facts.rawStyle = folder.hasRawLook
        let names = ((try? manager.contentsOfDirectory(atPath: folder.looks.path)) ?? [])
            .filter { $0.hasSuffix(".look.json") }.sorted()
        facts.otherLooks = names.map {
            OtherLook(
                name: String($0.dropLast(".look.json".count)), file: folder.looks.appendingPathComponent($0))
        }
        if manager.fileExists(atPath: folder.rawLook.path), !facts.rawStyle {
            facts.otherLooks.insert(OtherLook(name: StageCommand.rawLookName, file: folder.rawLook), at: 0)
        }
        let maximum = SceneFolder.maximumParticles()
        let costs = CostModel.current(library: folder.batch.deletingLastPathComponent())
        facts.hiresCosts = hiresSizes.filter { $0 <= maximum }.map {
            HiresCost(
                particles: $0,
                seconds: (try? costs.hiresSeconds(folder, particles: $0)) ?? measuredSeconds[$0])
        }
        return facts
    }
}

/// The command lines for what the app cannot run yet, through `scripts/dev.sh`.
enum StageCommand {
    static let rawLookName = "raw"

    static func hires(_ folder: SceneFolder, particles: Int) -> String {
        [script(near: folder), "hires", quoted(folder.url.path), "--particles", String(particles)]
            .joined(separator: " ")
    }

    /// Never over a video already there: a second export of a preset, or one with another
    /// look, goes to a file of its own.
    static func export(
        _ folder: SceneFolder, preset: String, look: ScenePageFacts.OtherLook? = nil,
        existing: [URL]
    ) -> String {
        var parts = [script(near: folder), "export", quoted(folder.url.path), "--preset", preset]
        let standard = folder.export(preset: preset)
        let taken = Set(existing.map(\.lastPathComponent))
        var out = standard
        if let look {
            parts += ["--look", look.name == rawLookName ? quoted(look.file.path) : quoted(look.name)]
            out = named("\(preset)-\(look.name)", like: standard)
        }
        var suffix = 2
        let base = out.deletingPathExtension().lastPathComponent
        while taken.contains(out.lastPathComponent) {
            out = named("\(base)-\(suffix)", like: standard)
            suffix += 1
        }
        if out != standard { parts += ["--out", quoted(out.path)] }
        return parts.joined(separator: " ")
    }

    private static func named(_ name: String, like url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("\(name).\(url.pathExtension)")
    }

    /// The repository's script, found above the library or the application, so the command
    /// runs from any folder.
    static func script(near folder: SceneFolder) -> String {
        for start in [folder.url, Bundle.main.bundleURL] {
            var url = start
            for _ in 0..<8 {
                url = url.deletingLastPathComponent()
                let script = url.appendingPathComponent("scripts/dev.sh")
                if FileManager.default.fileExists(atPath: script.path) { return quoted(script.path) }
            }
        }
        return "./scripts/dev.sh"
    }

    static func quoted(_ text: String) -> String {
        let plain = text.allSatisfy { $0.isLetter || $0.isNumber || "/._-+@:".contains($0) }
        return plain ? text : "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}

enum Format {
    static func particles(_ count: Int) -> String {
        if count >= 1_000_000 {
            let millions = Double(count) / 1_000_000
            return millions == millions.rounded()
                ? "\(Int(millions)) M"
                : String(format: "%.1f M", millions).replacingOccurrences(of: ".", with: ",")
        }
        return count >= 1_000 ? "\(count / 1_000) k" : "\(count)"
    }

    static func duration(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return "moins d'une minute" }
        if minutes < 60 { return "\(minutes) min" }
        let (hours, rest) = (minutes / 60, minutes % 60)
        return rest == 0 ? "\(hours) h" : "\(hours) h \(String(format: "%02d", rest))"
    }

    static func date(_ date: Date) -> String {
        date.formatted(
            .dateTime.day().month(.abbreviated).year().hour().minute()
                .locale(Locale(identifier: "fr_FR")))
    }
}

private struct OffscreenKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Drawn by `ImageRenderer`, which shows players, pickers and menus as blanks.
    var offscreen: Bool {
        get { self[OffscreenKey.self] }
        set { self[OffscreenKey.self] = newValue }
    }
}
