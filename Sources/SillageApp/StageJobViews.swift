import AppKit
import SillageRender
import SwiftUI

private struct QueueKey: EnvironmentKey {
    static let defaultValue: QueueModel? = nil
}

extension EnvironmentValues {
    /// The queue the stage buttons add to. Absent, as in the snapshots of other panels, they
    /// are not offered.
    var queue: QueueModel? {
        get { self[QueueKey.self] }
        set { self[QueueKey.self] = newValue }
    }
}

/// What the forms read once, off the main actor: the cost model, what every scene's hires takes
/// at each size Auto may pick, and what each `exports/` holds.
struct StageQuotes: Sendable, Equatable {
    var cost: CostModel
    /// Particles to the seconds all the scenes would take together, when each can be told.
    var hires: [Int: Double] = [:]
    var maximum: Int
    var exports: [String: ExportFolderState] = [:]

    var sizes: [Int] { StageJobs.hiresSizes.filter { $0 <= maximum } }

    nonisolated static func read(_ folders: [SceneFolder], library: URL) -> StageQuotes {
        let cost = CostModel.current(library: library)
        let maximum = SceneFolder.maximumParticles()
        var quotes = StageQuotes(cost: cost, maximum: maximum)
        var sizes = Set(stride(from: StageJobs.hiresSizes[0], through: maximum, by: StageJobs.autoStep))
        sizes.formUnion(StageJobs.hiresSizes.filter { $0 <= maximum })
        sizes.insert(maximum)
        for size in sizes {
            let each = folders.map { StageJobs.hiresSeconds($0, particles: size, cost: cost) }
            if !each.contains(where: { $0 == nil }) {
                quotes.hires[size] = each.compactMap { $0 }.reduce(0, +)
            }
        }
        for folder in folders { quotes.exports[folder.url.path] = ExportFolderState.read(folder) }
        return quotes
    }
}

/// Calculer: a size, Auto by default, what it will take and when it will be ready behind the
/// queue, and the button that queues one hires job a scene.
struct HiresForm: View {
    @ObservedObject var queue: QueueModel
    let folders: [SceneFolder]
    /// Once the jobs are queued.
    var queued: () -> Void = {}
    /// 0 is Auto.
    @State private var size = 0
    /// Read when the form appears; the checks give it.
    @State var quotes: StageQuotes?
    @Environment(\.offscreen) private var offscreen

    var body: some View {
        let jobs = planned
        let forecast = StageForecast(jobs: jobs, status: queue.status, now: Date())
        VStack(alignment: .leading, spacing: 6) {
            if offscreen {
                Text("Taille : \(label(size))").font(.callout)
            } else {
                Picker("Taille", selection: $size) {
                    Text(label(0)).tag(0)
                    ForEach(quotes?.sizes ?? StageJobs.hiresSizes, id: \.self) { Text(label($0)).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            Text(quotes == nil ? "Estimation de la durée…" : forecast.summary)
                .font(.caption.monospacedDigit())
                .foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(folders.count == 1 ? "Calculer" : "Calculer (\(forecast.jobs.count))") {
                if queue.submit(jobs) > 0 { queued() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(quotes == nil || forecast.jobs.isEmpty)
            .help("Ajoute le calcul à la file d'attente")
        }
        .task(id: folders.map(\.url)) {
            let (folders, library) = (folders, queue.store.library)
            let read = await Task.detached { StageQuotes.read(folders, library: library) }.value
            if read != quotes { quotes = read }
        }
    }

    var particles: Int { size == 0 ? auto : size }

    private var auto: Int {
        guard let quotes else { return SceneFolder.maximumParticles() }
        return StageJobs.autoParticles(
            seconds: { quotes.hires[$0] }, start: queue.status.freeAt ?? Date(), now: Date(),
            maximum: quotes.maximum)
    }

    private var planned: [PlannedJob] {
        guard let quotes else { return [] }
        return folders.map {
            StageJobs.hires($0, particles: particles, cost: quotes.cost, queue: queue.queue)
        }
    }

    /// "Auto · 5 M, environ 4 h", "2 M, environ 1 h 25".
    private func label(_ size: Int) -> String {
        let particles = size == 0 ? auto : size
        var text = StageJobs.particles(particles)
        if let seconds = quotes?.hires[particles] { text += ", " + Format.about(seconds) }
        return size == 0 ? "Auto · " + text : text
    }
}

/// Exporter…: preset cards to tick, Avancé, and what each job takes and when all is ready. Each
/// ticked card is one job a scene.
struct ExportSheet: View {
    @ObservedObject var queue: QueueModel
    let folders: [SceneFolder]
    /// The styles a single scene can be exported with besides its own.
    var looks: [StageLook] = []
    var close: () -> Void
    @State var ticked: Set<ExportChoice> = [.hd]
    @State private var settings = ExportSettings()
    @State private var advanced = false
    @State private var start = ""
    @State private var duration = ""
    @State private var fps = ""
    /// Read when the sheet appears; the checks give it.
    @State var quotes: StageQuotes?
    @Environment(\.offscreen) private var offscreen

    var body: some View {
        let jobs = planned
        let forecast = StageForecast(jobs: jobs, status: queue.status, now: Date())
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Exporter").font(.title2.bold())
                Text(subject).font(.callout).foregroundStyle(Palette.secondary)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                ForEach(ExportChoice.allCases) { card($0) }
            }
            advancedSection
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(forecast.jobs.prefix(Self.linesShown).enumerated()), id: \.element.id) {
                    index, job in
                    Text(line(job, forecast.line(index)))
                        .font(.caption.monospacedDigit())
                }
                if forecast.jobs.count > Self.linesShown {
                    Text("et \(forecast.jobs.count - Self.linesShown) autres")
                        .font(.caption).foregroundStyle(Palette.secondary)
                }
                Text(quotes == nil ? "Estimation des durées…" : forecast.summary)
                    .font(.callout.monospacedDigit())
            }
            HStack {
                if let failure = queue.failure {
                    Text(failure).font(.caption).foregroundStyle(Palette.warning)
                }
                Spacer()
                Button("Annuler", action: close).keyboardShortcut(.cancelAction)
                Button(forecast.jobs.count == 1 ? "Exporter" : "Exporter (\(forecast.jobs.count))") {
                    if queue.submit(jobs) > 0 { close() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(quotes == nil || forecast.jobs.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 760)
        .task(id: folders.map(\.url)) {
            let (folders, library) = (folders, queue.store.library)
            let read = await Task.detached { StageQuotes.read(folders, library: library) }.value
            if read != quotes { quotes = read }
        }
    }

    static let linesShown = 8

    private var subject: String {
        folders.count == 1 ? folders[0].sceneID : "\(folders.count) scènes"
    }

    private func card(_ choice: ExportChoice) -> some View {
        let on = ticked.contains(choice)
        let seconds = quotes.map { quotes in
            folders.compactMap { folder in
                StageJobs.export(
                    choice, settings, folder: folder, state: quotes.exports[folder.url.path] ?? .init(),
                    cost: quotes.cost, queue: queue.queue
                ).seconds
            }.reduce(0, +)
        }
        return Button {
            if on { ticked.remove(choice) } else { ticked.insert(choice) }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: on ? "checkmark.square.fill" : "square")
                        .foregroundStyle(on ? Color.accentColor : Palette.secondary)
                    Text(choice.title).font(.headline)
                }
                Text(choice.detail).font(.caption).foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(seconds.map(Format.about) ?? " ")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Palette.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(on ? Color.accentColor.opacity(0.16) : Palette.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(on ? Color.accentColor : Color(white: 0.24), lineWidth: on ? 2 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var advancedSection: some View {
        if offscreen {
            Text(advancedSummary).font(.callout).foregroundStyle(Palette.secondary)
        } else {
            DisclosureGroup("Avancé", isExpanded: $advanced) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("Codec").foregroundStyle(Palette.secondary)
                        Picker("Codec", selection: $settings.codec) {
                            Text("HEVC").tag(VideoCodec.hevc)
                            Text("H.264").tag(VideoCodec.h264)
                            Text("ProRes").tag(VideoCodec.prores)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                    GridRow {
                        Text("Début").foregroundStyle(Palette.secondary)
                        field("0 s", $start) { settings.start = $0 }
                    }
                    GridRow {
                        Text("Durée").foregroundStyle(Palette.secondary)
                        field("toute la prise", $duration) { settings.duration = $0 }
                    }
                    GridRow {
                        Text("Images par seconde").foregroundStyle(Palette.secondary)
                        field("celles de la prise", $fps) { settings.framesPerSecond = $0.map { Int($0) } }
                    }
                    if !looks.isEmpty {
                        GridRow {
                            Text("Style").foregroundStyle(Palette.secondary)
                            Picker("Style", selection: $settings.look) {
                                Text("Celui de la scène").tag(StageLook?.none)
                                ForEach(looks, id: \.self) { look in
                                    Text(look.name == StageLook.rawName ? "Style brut" : look.name)
                                        .tag(Optional(look))
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                    }
                }
                .padding(.top, 6)
            }
        }
    }

    /// Offscreen, Avancé as one line.
    private var advancedSummary: String {
        var parts = ["Avancé : \(settings.codec.title)"]
        if let start = settings.start { parts.append("début \(start) s") }
        if let duration = settings.duration { parts.append("durée \(duration) s") }
        if let fps = settings.framesPerSecond { parts.append("\(fps) images/s") }
        if let look = settings.look { parts.append("style \(look.name)") }
        return parts.joined(separator: " · ")
    }

    /// A number in seconds or frames; empty is the stage's own default.
    private func field(_ prompt: String, _ text: Binding<String>, set: @escaping (Double?) -> Void)
        -> some View
    {
        TextField(prompt, text: text)
            .frame(width: 140)
            .onChange(of: text.wrappedValue) { _, value in
                let number = Double(value.replacingOccurrences(of: ",", with: "."))
                set(number.flatMap { $0 >= 0 ? $0 : nil })
            }
    }

    var planned: [PlannedJob] {
        guard let quotes else { return [] }
        return folders.flatMap { folder in
            ExportChoice.allCases.filter(ticked.contains).map {
                StageJobs.export(
                    $0, settings, folder: folder, state: quotes.exports[folder.url.path] ?? .init(),
                    cost: quotes.cost, queue: queue.queue)
            }
        }
    }

    /// "scene-0023 · 4K · 4k.mp4 · environ 12 min · prêt vers 23 h 40".
    private func line(_ job: PlannedJob, _ timing: String) -> String {
        var parts: [String] = []
        if folders.count > 1 { parts.append(job.folder.url.lastPathComponent) }
        parts.append(job.title)
        if let output = job.output {
            parts.append(output.lastPathComponent + (job.replaces ? " (remplace l'ancien)" : ""))
        }
        parts.append(timing)
        return parts.joined(separator: " · ")
    }
}

extension VideoCodec {
    var title: String {
        switch self {
        case .hevc: "HEVC"
        case .h264: "H.264"
        case .prores: "ProRes"
        }
    }
}

/// The jobs of one stage of a scene while they wait or run: what, how far, when, and Annuler.
struct StageJobLines: View {
    @ObservedObject var queue: QueueModel
    let folder: SceneFolder
    let kind: QueueJob.Kind

    var body: some View {
        let jobs = queue.queue.unfinished(at: folder).filter { $0.kind == kind }
        if !jobs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(jobs) { job in line(job) }
            }
        }
    }

    private func line(_ job: QueueJob) -> some View {
        let row = queue.row(job.id)
        let running = job.state == .running
        return VStack(alignment: .leading, spacing: 3) {
            Text((running ? "En cours · " : "En attente · ") + StageJobs.title(of: job))
                .font(.callout.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            if running {
                ProgressBar(value: row?.progress ?? 0)
                if let detail = row?.detail { caption(detail) }
            }
            if let timing = row?.timing { caption(timing) }
            Button(job.stopping == true ? "Annulation…" : "Annuler") {
                queue.attempt { try queue.cancel(job.id) }
            }
            .controlSize(.small)
            .disabled(job.stopping == true)
            .help(running ? "Arrête le calcul et le retire de la file" : "Le retire de la file d'attente")
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption.monospacedDigit()).foregroundStyle(Palette.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Drawn by hand: `ImageRenderer` shows a ProgressView as a blank.
struct ProgressBar: View {
    let value: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(white: 0.25))
                Capsule().fill(Color.accentColor)
                    .frame(width: geometry.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: 5)
    }
}

/// The hires form in a sheet of its own, for Refaire.
struct HiresSheet: View {
    @ObservedObject var queue: QueueModel
    let folders: [SceneFolder]
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recalculer en haute résolution").font(.title2.bold())
            Text("Les vidéos restent jusqu'à ce qu'un nouvel export les remplace.")
                .font(.callout).foregroundStyle(Palette.secondary)
            HiresForm(queue: queue, folders: folders, queued: close)
            HStack {
                Spacer()
                Button("Fermer", action: close).keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
