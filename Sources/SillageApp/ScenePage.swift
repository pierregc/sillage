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
            ExportList(model: model, files: facts?.exports ?? [])
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
                Label("Library", systemImage: "chevron.left")
            }
            .help("Back to the grid (esc)")
            VStack(alignment: .leading, spacing: 2) {
                Text(scene.name).font(.title2.bold().monospacedDigit())
                Text(subtitle).font(.caption.monospacedDigit()).foregroundStyle(Palette.secondary)
            }
            Spacer()
            if snapshot {
                Label("Redo", systemImage: "arrow.counterclockwise").foregroundStyle(Palette.secondary)
            } else {
                RedoMenu(model: model, scene: scene, entry: entry, facts: facts)
            }
            HStack(spacing: 4) {
                Button {
                    model.moveOpened(-1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .help("Previous scene (←)")
                Button {
                    model.moveOpened(1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .help("Next scene (→)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var subtitle: String {
        var parts = [scene.batch]
        if let at = model.visible.firstIndex(where: { $0.id == scene.id }) {
            parts.append("\(at + 1) of \(model.visible.count) · \(model.query.collection.title)")
        } else {
            parts.append("no longer in \(model.query.collection.title)")
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
                if let image = shownImage {
                    ExportedImage(url: image).background(Color.black)
                } else if model.playing == scene.id, !snapshot {
                    PlayerView(player: model.player)
                }
                ChoiceBadge(entry: entry).padding(10)
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxHeight: 520)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .frame(maxWidth: .infinity)
            VersionPicker(model: model, scene: scene)
        }
    }

    /// An animated WebP or GIF picked in the export list, which AVPlayer does not play.
    private var shownImage: URL? {
        guard let url = model.version, ExportedFile.imageExtensions.contains(url.pathExtension.lowercased()),
            scene.exports.contains(url)
        else { return nil }
        return url
    }

    private var isNight: Bool {
        FileManager.default.fileExists(atPath: scene.batchURL.appendingPathComponent("night.json").path)
    }

    private var technicalDetails: some View {
        DisclosureGroup("Technical details", isExpanded: $detailsShown) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                row("Seed", scene.seed ?? "unknown")
                row("Index", scene.index.map(String.init) ?? "unknown")
                row(isNight ? "Night" : "Batch", scene.batch)
                GridRow {
                    Text("Folder").foregroundStyle(Palette.secondary)
                    HStack(spacing: 10) {
                        Text(location.path)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                        Button("Show in Finder") {
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
                "← → previous, next scene · Y yes · N no · 0 to 9 rating, 1 then 0 for 10 · ⌫ clear · esc grid"
            )
            .font(.caption)
            .foregroundStyle(Palette.secondary)
            Spacer()
            if let failure = model.failure {
                Text(failure).font(.caption).foregroundStyle(Palette.warning)
            } else if model.copied != nil {
                Text(model.copiedNote)
                    .font(.caption)
                    .foregroundStyle(Color(red: 0.45, green: 0.85, blue: 0.55))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

/// Preview, High resolution, then one entry per video. One decoder: picking one replaces
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
                Text("No video").font(.callout).foregroundStyle(Palette.secondary)
            }
            Spacer()
            if let url = model.playingURL, model.playing == scene.id {
                Button("Show the file") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
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
        case .preview: "Preview"
        case .highResolution: "High resolution"
        case .video(let name): "Video \(name)"
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
    @Environment(\.queue) private var queue
    @State private var exporting = false

    var body: some View {
        let states = SceneStep.states(scene, entry: entry)
        HStack(alignment: .top, spacing: 8) {
            ForEach(SceneStep.allCases, id: \.self) { step in
                StageColumn(step: step, state: states[step] ?? .later) {
                    content(step, states[step] ?? .later)
                }
            }
        }
        .sheet(isPresented: $exporting) {
            if let queue, let folder = scene.folder {
                ExportSheet(queue: queue, folders: [folder], looks: facts?.otherLooks ?? []) {
                    exporting = false
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
            if let galaxies = scene.galaxies { fact(galaxies == 1 ? "1 galaxy" : "\(galaxies) galaxies") }
            fact(scene.archetype ?? "free")
            if let story = facts?.story {
                fact(
                    String(
                        format: "%.0f Myr, from %.0f to %.0f", story.endMyr - story.startMyr, story.startMyr,
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
        case .yes: parts.append("Kept")
        case .no: parts.append("Discarded")
        case nil:
            if let picked = entry?.picked {
                parts.append(String(format: "Kept by score (%.2f)", picked.score))
            }
        }
        if let rating = entry?.rating { parts.append("rating \(rating)") }
        return parts.isEmpty ? "Not decided yet" : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func highResolution(_ state: SceneStep.State) -> some View {
        switch state {
        case .done:
            VStack(alignment: .leading, spacing: 3) {
                if let hires = facts?.hires {
                    fact(Format.particles(hires.particles, massive: hires.massive))
                    if let seconds = hires.seconds { fact("\(Format.duration(seconds)) of computing") }
                } else if let hires = scene.hires {
                    fact(Format.particles(hires.particles, massive: hires.massive))
                }
                if let date = facts?.hiresDate { fact(Format.date(date)) }
            }
        case .next:
            if let queue, let folder = scene.folder {
                if queue.queue.unfinished(at: folder).contains(where: { $0.kind == .hires }) {
                    StageJobLines(queue: queue, folder: folder, kind: .hires)
                } else {
                    HiresForm(queue: queue, folders: [folder])
                }
            }
        case .later:
            later(scene.folder == nil ? "No scene folder" : "After the choice")
        }
        if state == .done, let queue, let folder = scene.folder {
            StageJobLines(queue: queue, folder: folder, kind: .hires)
        }
    }

    @ViewBuilder
    private func style(_ state: SceneStep.State) -> some View {
        switch state {
        case .done:
            VStack(alignment: .leading, spacing: 6) {
                fact(facts.map { $0.rawStyle ? "Raw style" : $0.styleName ?? "Style" } ?? "Style chosen")
                if let palette = facts?.palette, !palette.isEmpty { Swatches(colours: palette) }
            }
        case .next:
            Button("Choose style") { model.tune(scene) }
                .buttonStyle(.borderedProminent)
                .help("Opens the style editor on the high resolution")
        case .later:
            later("After high resolution")
        }
    }

    @ViewBuilder
    private func export(_ state: SceneStep.State) -> some View {
        switch state {
        case .done:
            VStack(alignment: .leading, spacing: 6) {
                let files = scene.exports.filter {
                    LibraryScene.videoExtensions.contains($0.pathExtension.lowercased())
                        || ExportedFile.imageExtensions.contains($0.pathExtension.lowercased())
                }
                fact(files.count == 1 ? "1 file" : "\(files.count) files")
                Text("Listed below").font(.caption).foregroundStyle(Palette.secondary)
                exportButton(prominent: false)
            }
        case .next:
            exportButton(prominent: true)
        case .later:
            later("After the style")
        }
        if state != .later, let queue, let folder = scene.folder {
            StageJobLines(queue: queue, folder: folder, kind: .export)
        }
    }

    @ViewBuilder
    private func exportButton(prominent: Bool) -> some View {
        if queue != nil, scene.folder != nil {
            if prominent {
                Button("Export…") { exporting = true }.buttonStyle(.borderedProminent)
            } else {
                Button("Export…") { exporting = true }.controlSize(.small)
            }
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
        case .exploration: "Preview"
        case .choice: "Choice"
        case .highResolution: "High resolution"
        case .style: "Style"
        case .export: "Videos"
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

/// Every step already done, redone on its own: nothing else is.
struct RedoMenu: View {
    @ObservedObject var model: LibraryModel
    let scene: LibraryScene
    let entry: SceneRatings.Entry?
    let facts: ScenePageFacts?
    @Environment(\.queue) private var queue
    @State private var sheet: Sheet?

    enum Sheet: Identifiable {
        case hires, export
        var id: Self { self }
    }

    var body: some View {
        let states = SceneStep.states(scene, entry: entry)
        let done = { (step: SceneStep) in states[step] == .done }
        Menu {
            if done(.choice) {
                Button("Clear the choice and rating") { model.clear(scene.id) }
            }
            if done(.highResolution), queue != nil, scene.folder != nil {
                Button("Recompute in high resolution…") { sheet = .hires }
                    .help("The videos stay until a new export replaces them")
            }
            if done(.style) {
                Button("Choose the style again") { model.tune(scene) }
                if facts?.rawStyle == false {
                    Button("Revert to raw style") { model.restoreRawLook(scene) }
                        .help("The current style stays in the scene's folder")
                }
            }
            if done(.export), queue != nil, scene.folder != nil {
                Button("Export in another format or style…") { sheet = .export }
                    .help("Writes a new file and keeps the others")
            }
        } label: {
            Label("Redo", systemImage: "arrow.counterclockwise")
        }
        .fixedSize()
        .disabled(!SceneStep.allCases.dropFirst().contains(where: done))
        .sheet(item: $sheet) { which in
            if let queue, let folder = scene.folder {
                switch which {
                case .hires:
                    HiresSheet(queue: queue, folders: [folder]) { sheet = nil }
                case .export:
                    ExportSheet(queue: queue, folders: [folder], looks: facts?.otherLooks ?? []) {
                        sheet = nil
                    }
                }
            }
        }
    }
}

/// What the page reads beyond the scan, off the main actor when a scene opens.
struct ScenePageFacts: Sendable, Equatable {
    var id: String
    var story: Story.Span?
    var hires: SceneFolder.Hires?
    var hiresDate: Date?
    var styleName: String?
    var palette: [SIMD3<Float>] = []
    var rawStyle = false
    var otherLooks: [StageLook] = []
    /// The videos and animations of `exports/`, newest first.
    var exports: [ExportedFile] = []

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
            StageLook(
                name: String($0.dropLast(".look.json".count)), file: folder.looks.appendingPathComponent($0))
        }
        if manager.fileExists(atPath: folder.rawLook.path), !facts.rawStyle {
            facts.otherLooks.insert(StageLook(name: StageLook.rawName, file: folder.rawLook), at: 0)
        }
        return facts
    }
}

enum Format {
    static func particles(_ count: Int) -> String { StageJobs.particles(count) }

    /// A hires: "8 M particles (2 M massive)", "2 M particles".
    static func particles(_ count: Int, massive: Int?) -> String {
        let traced = massive.flatMap { $0 < count ? $0 : nil }
        return "\(particles(count)) particles" + (traced.map { " (\(particles($0)) massive)" } ?? "")
    }

    static func duration(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return "under a minute" }
        if minutes < 60 { return "\(minutes) min" }
        let (hours, rest) = (minutes / 60, minutes % 60)
        return rest == 0 ? "\(hours) h" : "\(hours) h \(String(format: "%02d", rest)) min"
    }

    /// "about 12 min", "under a minute".
    static func about(_ seconds: Double) -> String {
        seconds < 60 ? duration(seconds) : "about " + duration(seconds)
    }

    static func date(_ date: Date) -> String {
        date.formatted(
            .dateTime.day().month(.abbreviated).year().hour().minute()
                .locale(Locale(identifier: "en_GB")))
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

/// An animated WebP or GIF, which the player cannot show: drawn as an image that animates
/// where AppKit can, and as a still offscreen.
struct ExportedImage: View {
    let url: URL
    @Environment(\.offscreen) private var offscreen

    var body: some View {
        if offscreen {
            Image(nsImage: NSImage(contentsOf: url) ?? NSImage()).resizable().aspectRatio(contentMode: .fit)
        } else {
            AnimatedImageView(url: url)
        }
    }
}

struct AnimatedImageView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.animates = true
        view.imageScaling = .scaleProportionallyUpOrDown
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        view.image = NSImage(contentsOf: url)
    }
}

/// Every video and animation of `exports/` with what it is and what can be done with it.
/// There is no share sheet: Show in Finder and Copy path work wherever the
/// file goes next.
struct ExportList: View {
    @ObservedObject var model: LibraryModel
    let files: [ExportedFile]

    var body: some View {
        if !files.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(files.count == 1 ? "Exported video" : "Exported videos").font(.headline)
                ForEach(files) { file in
                    ExportRow(model: model, file: file)
                    if file.id != files.last?.id { Divider() }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Palette.card))
        }
    }
}

struct ExportRow: View {
    @ObservedObject var model: LibraryModel
    let file: ExportedFile
    @Environment(\.offscreen) private var offscreen

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(file.url.lastPathComponent).font(.callout.monospaced())
                Text(details).font(.caption.monospacedDigit()).foregroundStyle(Palette.secondary)
            }
            Spacer(minLength: 12)
            if offscreen {
                Text(
                    "Play · Show in Finder · Copy path"
                        + (file.caption == nil ? "" : " · Copy caption")
                )
                .font(.caption).foregroundStyle(Palette.secondary)
            } else {
                Button("Play") { model.version = file.url }
                    .help(file.isImage ? "Shows it in the player" : "Plays it in the player")
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([file.url])
                }
                Button("Copy path") { model.copy(file.url.path, note: "Path copied") }
                if let caption = file.caption {
                    Button("Copy caption") { model.copyCaption(caption) }
                }
            }
        }
        .controlSize(.small)
    }

    /// Preset, style, codec, size on screen, duration, weight, date.
    var details: String { Self.details(file) }

    static func details(_ file: ExportedFile) -> String {
        var parts: [String] = []
        parts.append(file.preset.map { "Preset \($0)" } ?? "Custom preset")
        if let style = file.style { parts.append("Style \(style)") }
        if !file.codec.isEmpty { parts.append(file.codec) }
        if let size = file.size { parts.append(size) }
        if let seconds = file.seconds { parts.append(String(format: "%.1f s", seconds)) }
        parts.append(String(format: "%.1f MB", Double(file.bytes) / 1_000_000))
        parts.append(Format.date(file.date))
        return parts.joined(separator: " · ")
    }
}
