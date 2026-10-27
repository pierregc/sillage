import AppKit
import SillageRender
import SwiftUI

/// One night: where it stands in its five phases, the job running and when it will be ready,
/// the scenes as they arrive, the errors with their logs, and the buttons that steer it. Once
/// it is over the page opens on the morning summary. All of it comes from the night's files.
struct NightPageView: View {
    let id: String
    @ObservedObject var nights: NightsModel
    @ObservedObject var queue: QueueModel
    @ObservedObject var library: LibraryModel
    let openScene: (String) -> Void
    let sort: (String) -> Void
    /// Drawn offscreen by the checks, which cannot draw a scroll view.
    var snapshot = false
    @State private var confirmingStop = false

    var body: some View {
        Group {
            if let page = nights.page, page.id == id {
                VStack(spacing: 0) {
                    header(page)
                    Divider()
                    if snapshot {
                        content(page)
                        Spacer(minLength: 0)
                    } else {
                        ScrollView { content(page) }
                    }
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "moon").font(.system(size: 34)).foregroundStyle(Palette.secondary)
                    Text("Cette nuit n'est pas dans la bibliothèque").font(.title3)
                    Text("Son dossier a été déplacé ou supprimé.").foregroundStyle(Palette.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .panelSurface()
        .task(id: id) { if !snapshot { nights.select(id) } }
        .onDisappear { if !snapshot { nights.select(nil) } }
    }

    // MARK: Header

    private func header(_ page: NightPage) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(page.title).font(.title2.weight(.semibold))
                HStack(spacing: 8) {
                    Circle().fill(color(page)).frame(width: 8, height: 8)
                    Text(page.status).foregroundStyle(Palette.secondary)
                    if let delivery = page.delivery {
                        Text("·").foregroundStyle(Palette.secondary)
                        Text(delivery).foregroundStyle(Palette.secondary)
                    }
                }
                .font(.callout)
                if let failure = queue.failure {
                    Text(failure).font(.callout).foregroundStyle(Palette.warning)
                }
            }
            Spacer()
            if let job = page.controls.queuedJob, !page.live {
                Button("Annuler la nuit") { queue.attempt { try queue.cancel(job) } }
            }
            sortButton(page)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private func color(_ page: NightPage) -> Color {
        if page.stuck || page.state == .paused || page.state == .failed { return Palette.warning }
        return page.live ? .green : Palette.secondary
    }

    /// Opens the triage view on the scenes of this night still to sort.
    private func sortButton(_ page: NightPage) -> some View {
        let waiting = library.scenes.filter { $0.batch == page.id && $0.stage == .toSort }.count
        return Button(waiting > 0 ? "Trier (\(waiting))" : "Trier") { sort(page.id) }
            .buttonStyle(.borderedProminent)
            .disabled(waiting == 0)
            .help(waiting == 0 ? "Aucune scène de cette nuit à trier" : "Une scène à la fois, au clavier")
    }

    // MARK: Content

    private func content(_ page: NightPage) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            if page.live { running(page) }
            phases(page)
            if let report = page.report, !page.live { summary(report) }
            if !page.problems.isEmpty { problems(page) }
            scenes(page)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Running

    private func running(_ page: NightPage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("En ce moment").font(.caption.weight(.semibold)).foregroundStyle(Palette.secondary)
                Spacer()
            }
            Text(page.current?.line ?? "").font(.headline.monospacedDigit())
            Meter(fraction: page.current?.progress, tint: .accentColor)
            controls(page)
        }
        .padding(14)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 10))
    }

    private func controls(_ page: NightPage) -> some View {
        let controls = page.controls
        return HStack(spacing: 8) {
            Button(controls.isPaused ? "Reprendre" : "Pause") {
                queue.attempt { controls.isPaused ? try queue.resume() : try queue.pause() }
            }
            Button(controls.stopAfterAsked ? "Arrêt demandé" : "Arrêter après cette étape") {
                if let job = controls.job { queue.attempt { try queue.stopAfterStep(job) } }
            }
            .disabled(controls.job == nil || controls.stopAfterAsked)
            .help("La nuit s'arrête dès que l'étape en cours est finie")
            Button("Arrêter maintenant") { confirmingStop = true }
                .disabled(controls.job == nil || controls.stoppingNow)
                .help("Abandonne le calcul en cours")
                .confirmationDialog(
                    "Arrêter la nuit maintenant ?", isPresented: $confirmingStop,
                    titleVisibility: .visible
                ) {
                    Button("Arrêter maintenant", role: .destructive) {
                        if let job = controls.job { queue.attempt { try queue.cancel(job) } }
                    }
                    Button("Annuler", role: .cancel) {}
                } message: {
                    Text("Le calcul en cours est abandonné. Ce qui est déjà calculé est gardé.")
                }
            Button("Passer cette scène") {
                guard let job = controls.job else { return }
                queue.attempt { try queue.skip(job) }
                nights.skipWasAsked(for: page.current?.scene)
            }
            .disabled(
                !controls.canSkip || controls.job == nil
                    || (page.current?.scene != nil && nights.skipAsked == page.current?.scene)
            )
            .help("La scène en cours est laissée de côté, la nuit passe à la suivante")
            Spacer()
        }
        .controlSize(.small)
    }

    // MARK: Phases

    private func phases(_ page: NightPage) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(page.phases) { PhaseCell(bar: $0) }
        }
    }

    // MARK: Summary

    private func summary(_ report: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Résumé du matin").font(.caption.weight(.semibold)).foregroundStyle(Palette.secondary)
            ForEach(Array(ReportLine.parse(report).enumerated()), id: \.offset) { _, line in
                switch line {
                case .heading(let text):
                    Text(text).font(.callout.weight(.semibold)).padding(.top, 6)
                case .item(let label, let value):
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(label).foregroundStyle(Palette.secondary)
                            .frame(width: label.count > 24 ? 220 : 150, alignment: .leading)
                        Text(value).textSelection(.enabled)
                        Spacer(minLength: 0)
                    }
                    .font(.callout.monospacedDigit())
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Problems

    private func problems(_ page: NightPage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Erreurs").font(.caption.weight(.semibold)).foregroundStyle(Palette.secondary)
            ForEach(page.problems) { problem in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(Palette.warning)
                    Text(problem.text).font(.callout)
                    Spacer()
                    if let url = problem.logURL {
                        let exists = FileManager.default.fileExists(atPath: url.path)
                        Button("Journal") { NSWorkspace.shared.open(url) }
                            .controlSize(.small)
                            .disabled(!exists)
                            .help(problem.log ?? url.path)
                    }
                }
            }
        }
    }

    // MARK: Scenes

    private func scenes(_ page: NightPage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(page.scenes.isEmpty ? "Scènes" : "Scènes · \(page.scenes.count)")
                .font(.caption.weight(.semibold)).foregroundStyle(Palette.secondary)
            if page.scenes.isEmpty {
                Text(page.live ? "Les scènes apparaissent ici dès qu'elles sont explorées." : "Aucune scène.")
                    .foregroundStyle(Palette.secondary)
            } else if snapshot {
                let shown = Array(page.scenes.prefix(8))
                Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                    ForEach(0..<(shown.count + 3) / 4, id: \.self) { row in
                        GridRow {
                            ForEach(shown[row * 4..<min(row * 4 + 4, shown.count)]) { card in
                                NightSceneCard(card: card, scene: library.scene("\(page.id)/\(card.name)"))
                                    .frame(width: 220)
                            }
                        }
                    }
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)], spacing: 12) {
                    ForEach(page.scenes) { card in
                        NightSceneCard(card: card, scene: library.scene("\(page.id)/\(card.name)"))
                            .onTapGesture { openScene("\(page.id)/\(card.name)") }
                    }
                }
            }
        }
    }
}

/// A thin bar, drawn by hand: the system's linear progress view is a blank in a picture.
struct Meter: View {
    /// Nil for a job that cannot say how far it is.
    let fraction: Double?
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(white: 0.24))
                Capsule().fill(tint)
                    .frame(width: proxy.size.width * CGFloat(min(max(fraction ?? 0.04, 0), 1)))
                    .opacity(fraction == nil ? 0.4 : 1)
            }
        }
        .frame(height: 6)
    }
}

private struct PhaseCell: View {
    let bar: NightPage.PhaseBar

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(bar.title).font(.callout.weight(.semibold)).lineLimit(1)
            }
            Text(bar.counts.isEmpty ? "–" : bar.counts).font(.title3.monospacedDigit())
            Meter(fraction: bar.state == .left && bar.fraction == 0 ? 0 : bar.fraction, tint: tint)
            Text(bar.detail.isEmpty ? " " : bar.detail).font(.caption).foregroundStyle(Palette.secondary)
                .lineLimit(1)
            Text(bar.time.isEmpty ? " " : bar.time).font(.caption.monospacedDigit())
                .foregroundStyle(Palette.secondary).lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(bar.state == .current ? Color.accentColor : .clear, lineWidth: 1.5))
    }

    private var symbol: String {
        switch bar.state {
        case .done: "checkmark.circle.fill"
        case .current: "circle.dotted"
        case .waiting: "circle"
        case .left: "minus.circle"
        }
    }

    private var tint: Color {
        switch bar.state {
        case .done: Color(red: 0.35, green: 0.68, blue: 0.45)
        case .current: .accentColor
        case .waiting, .left: Palette.secondary
        }
    }
}

struct NightSceneCard: View {
    let card: NightPage.SceneCard
    let scene: LibraryScene?
    @State private var still: NSImage?

    init(card: NightPage.SceneCard, scene: LibraryScene?) {
        self.card = card
        self.scene = scene
        _still = State(initialValue: scene.flatMap { ThumbnailCache.shared.cached($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Color.black
                if let still { Image(nsImage: still).resizable().aspectRatio(contentMode: .fit) }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            HStack(spacing: 6) {
                Text(card.name).font(.callout.monospacedDigit()).lineLimit(1)
                Spacer(minLength: 4)
                if card.videos > 0 {
                    Label("\(card.videos)", systemImage: "film").font(.caption.monospacedDigit())
                        .foregroundStyle(Palette.secondary)
                        .help("Vidéos")
                }
                Pill(text: card.stage, tint: card.current ? .accentColor : Color(white: 0.5))
            }
            Text(card.detail.isEmpty ? " " : card.detail).font(.caption.monospacedDigit())
                .foregroundStyle(Palette.secondary).lineLimit(1)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.card))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    card.current ? Color.accentColor : Color(white: 0.24),
                    lineWidth: card.current ? 2 : 1)
        )
        .contentShape(Rectangle())
        .task(id: scene.map { ThumbnailCache.shared.key($0) }) {
            guard let scene else { return }
            if let image = await ThumbnailCache.shared.load(scene) { still = image }
        }
    }
}

/// The lines of `report.md` as the page shows them: headings, and `- label : value` items.
enum ReportLine: Equatable {
    case heading(String)
    case item(label: String, value: String)

    static func parse(_ text: String) -> [ReportLine] {
        var lines: [ReportLine] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            if line.hasPrefix("# ") { continue }
            if line.hasPrefix("## ") {
                lines.append(.heading(String(line.dropFirst(3))))
            } else if line.hasPrefix("- ") {
                let body = String(line.dropFirst(2))
                if let split = body.range(of: " : ") {
                    lines.append(
                        .item(
                            label: String(body[..<split.lowerBound]), value: String(body[split.upperBound...])
                        ))
                } else {
                    lines.append(.item(label: "", value: body))
                }
            }
        }
        return lines
    }
}
