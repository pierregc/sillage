import SillageRender
import SwiftUI

/// The sidebar's entry for the queue, and what a click on the status line opens: what runs
/// with its progress and end, then what waits in order with when it should start and end, then
/// the last ten finished or failed. The words come from `QueueStatus`, the formatter
/// `sillage-render status` prints with.
struct QueueView: View {
    @ObservedObject var queue: QueueModel

    var body: some View {
        let status = queue.status
        VStack(alignment: .leading, spacing: 0) {
            header(status)
            Divider()
            if status.running == nil, status.waiting.isEmpty, status.finished.isEmpty {
                empty
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if let running = status.running {
                            section("En cours") { RunningRow(row: running, paused: status.isPaused) }
                        }
                        if !status.waiting.isEmpty {
                            section("En attente") {
                                ForEach(Array(status.waiting.enumerated()), id: \.element.id) {
                                    position, row in
                                    WaitingRow(row: row, first: position == 0, queue: queue)
                                }
                            }
                        }
                        if !status.finished.isEmpty {
                            section("Terminés") {
                                ForEach(status.finished) { FinishedRow(row: $0) }
                            }
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .panelSurface()
    }

    private func header(_ status: QueueStatus) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("File d'attente").font(.title2.weight(.semibold))
                Text(status.statusLine).foregroundStyle(Palette.secondary)
                if let failure = queue.failure {
                    Text(failure).font(.callout).foregroundStyle(Palette.warning)
                }
            }
            Spacer()
            if status.isPaused || status.running != nil || !status.waiting.isEmpty {
                Button(status.isPaused ? "Reprendre" : "Mettre en pause") {
                    queue.attempt { status.isPaused ? try queue.resume() : try queue.pause() }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 34))
                .foregroundStyle(Palette.secondary)
            Text(queue.status.headline).font(.title3)
            Text("Les calculs lancés depuis l'app ou la ligne de commande apparaîtront ici.")
                .foregroundStyle(Palette.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func section<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.caption.weight(.semibold))
                .foregroundStyle(Palette.secondary)
            content()
        }
    }
}

private struct RunningRow: View {
    let row: QueueStatus.Row
    let paused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(row.title).font(.headline)
                Text(row.subject).foregroundStyle(Palette.secondary)
                Spacer()
                if let timing = row.timing {
                    Text(timing).font(.callout.monospacedDigit()).foregroundStyle(Palette.secondary)
                }
            }
            if let progress = row.progress {
                ProgressView(value: progress)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            HStack {
                Text(paused ? "En pause" : (row.detail ?? "En cours"))
                if let progress = row.progress, !paused {
                    Text(String(format: "%.0f %%", progress * 100)).monospacedDigit()
                }
                Spacer()
                if let options = row.options {
                    Text(options).font(.caption).foregroundStyle(Palette.secondary)
                }
            }
            .font(.callout)
            .foregroundStyle(Palette.secondary)
        }
        .padding(14)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct WaitingRow: View {
    let row: QueueStatus.Row
    let first: Bool
    @ObservedObject var queue: QueueModel

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(row.title)
                    Text(row.subject).foregroundStyle(Palette.secondary)
                }
                if let timing = row.timing {
                    Text(timing).font(.callout.monospacedDigit()).foregroundStyle(Palette.secondary)
                }
            }
            Spacer()
            if let id = row.job {
                if !first {
                    Button {
                        queue.attempt { try queue.moveFirst(id) }
                    } label: {
                        Image(systemName: "arrow.up.to.line")
                    }
                    .help("Passer en premier")
                }
                Button {
                    queue.attempt { try queue.cancel(id) }
                } label: {
                    Image(systemName: "xmark")
                }
                .help("Annuler")
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct FinishedRow: View {
    let row: QueueStatus.Row

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(row.outcome == .failed ? Palette.warning : Palette.secondary)
                .frame(width: 18)
            Text(row.title)
            Text(row.subject).foregroundStyle(Palette.secondary)
            Spacer()
            if let timing = row.timing {
                Text(timing).font(.callout).foregroundStyle(Palette.secondary).lineLimit(2)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(.horizontal, 14)
    }

    private var symbol: String {
        switch row.outcome {
        case .failed: "exclamationmark.triangle"
        case .cancelled: "xmark.circle"
        default: "checkmark.circle"
        }
    }
}

/// The top of the sidebar, on every screen: whether the Mac is computing, what, and until
/// when, with how many jobs wait. A click opens the queue. A run in the workshop, which is not
/// the queue's, is told below it while another part is showing.
struct SidebarStatus: View {
    @ObservedObject var model: SimulationModel
    @ObservedObject var queue: QueueModel
    let openQueue: () -> Void
    let openWorkshop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: openQueue) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle().fill(color).frame(width: 8, height: 8)
                    Text(queue.status.statusLine)
                        .font(.callout)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .help("Ouvrir la file d'attente")

            if model.stage == .running, !model.contemplating {
                Button(action: openWorkshop) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(workshopTitle).font(.callout)
                        Text(String(format: "%.0f Myr", model.elapsedMyr))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Palette.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
                .help("Afficher dans l'Atelier")
            }
        }
    }

    private var color: Color {
        let status = queue.status
        if status.isStuck || status.isPaused { return Palette.warning }
        return status.isBusy ? .green : Palette.secondary
    }

    private var workshopTitle: String {
        if model.mode == .playback { return "Prise ouverte dans l'Atelier" }
        return model.isPlaying ? "Simulation en cours" : "Simulation en pause"
    }
}
