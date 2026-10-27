import SillageRender
import SwiftUI

/// The sheet's state: the settings, and the plan they make, planned again off the main actor
/// a moment after every change. The batch's draws are sized once when the sheet opens, so the
/// plan that follows a change comes within half a second.
@MainActor
final class NightSheetModel: ObservableObject {
    @Published var sheet: NightSheet {
        didSet { if sheet != oldValue { replan() } }
    }
    @Published private(set) var plan: NightSheetPlan?
    @Published private(set) var launching = false
    @Published var failure: String?
    /// When the last plan was asked for and when it came, for the check.
    private(set) var lastLatency: TimeInterval?

    let library: URL
    private let planner: NightSheetPlanner
    private let debounce: Duration
    private var generation = 0
    private var task: Task<Void, Never>?

    nonisolated static let debounce = Duration.milliseconds(60)

    init(
        library: URL, planner: NightSheetPlanner? = nil, debounce: Duration = NightSheetModel.debounce
    ) {
        self.library = library
        self.planner = planner ?? NightSheetPlanner.shared(library: library)
        self.debounce = debounce
        sheet = NightSheet.last(library: library)
        replan(immediately: true)
    }

    func replan(immediately: Bool = false) {
        generation += 1
        let mine = generation
        let sheet = sheet
        let planner = planner
        let wait = immediately ? Duration.zero : debounce
        let asked = Date()
        task?.cancel()
        task = Task {
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            let plan = await Task.detached(priority: .userInitiated) {
                planner.plan(sheet, now: Date())
            }.value
            guard mine == generation else { return }
            self.plan = plan
            lastLatency = Date().timeIntervalSince(asked)
        }
    }

    /// Adds the night to the queue with `submit`.
    func launch(_ submit: (NightSheet) throws -> Void) -> Bool {
        launching = true
        defer { launching = false }
        do {
            try submit(sheet)
            failure = nil
            return true
        } catch {
            failure = "\(error)"
            return false
        }
    }
}

/// "Nouvelle nuit": the time the night must be done by, the plan under it, and four settings
/// behind one disclosure.
struct NightSheetView: View {
    @StateObject private var model: NightSheetModel
    @ObservedObject var queue: QueueModel
    let dismiss: () -> Void
    let launched: () -> Void
    /// `ImageRenderer` draws pickers and fields as blanks, so a picture of the sheet has them
    /// as text and the disclosure open.
    var snapshot = false
    @State private var customising = false

    init(
        model: NightSheetModel, queue: QueueModel, snapshot: Bool = false,
        dismiss: @escaping () -> Void = {}, launched: @escaping () -> Void = {}
    ) {
        _model = StateObject(wrappedValue: model)
        self.queue = queue
        self.snapshot = snapshot
        self.dismiss = dismiss
        self.launched = launched
        _customising = State(initialValue: snapshot)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Nouvelle nuit").font(.title2.weight(.semibold))
            timeControl
            planCard
            customise
            footer
        }
        .padding(24)
        .frame(width: 560)
        .background(Palette.panel)
        // The plan counts down to the delivery as the evening goes.
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            model.replan(immediately: true)
        }
    }

    // MARK: Time

    private var timeControl: some View {
        HStack(spacing: 14) {
            if snapshot {
                Text(model.sheet.timing == .deliver ? "Prêt à" : "Pendant")
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Palette.card, in: RoundedRectangle(cornerRadius: 6))
            } else {
                Picker("", selection: $model.sheet.timing) {
                    Text("Prêt à").tag(NightSheet.Timing.deliver)
                    Text("Pendant").tag(NightSheet.Timing.hours)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 190)
            }
            if model.sheet.timing == .deliver {
                if snapshot {
                    Text(Self.clock(model.sheet.deliverMinutes)).font(.title3.monospacedDigit())
                } else {
                    DatePicker(
                        "", selection: deliveryTime, displayedComponents: .hourAndMinute
                    )
                    .labelsHidden()
                }
            } else if snapshot {
                Text(Self.hours(model.sheet.hours)).font(.title3.monospacedDigit())
            } else {
                Stepper(
                    value: $model.sheet.hours, in: NightSheet.hoursRange, step: 0.5
                ) {
                    Text(Self.hours(model.sheet.hours)).font(.title3.monospacedDigit())
                }
            }
            Spacer()
        }
    }

    /// The delivery as a date on any day, of which only the clock is read.
    private var deliveryTime: Binding<Date> {
        Binding(
            get: {
                let minutes = model.sheet.deliverMinutes
                return Calendar.current.date(
                    bySettingHour: minutes / 60 % 24, minute: minutes % 60, second: 0, of: Date())
                    ?? Date()
            },
            set: {
                let parts = Calendar.current.dateComponents([.hour, .minute], from: $0)
                model.sheet.deliverMinutes = (parts.hour ?? 7) * 60 + (parts.minute ?? 0)
            })
    }

    static func clock(_ minutes: Int) -> String {
        String(format: "%d h %02d", minutes / 60 % 24, minutes % 60)
    }

    /// "8 h", "6 h 30".
    static func hours(_ hours: Double) -> String {
        let minutes = Int((hours * 60).rounded())
        return minutes % 60 == 0
            ? "\(minutes / 60) h" : String(format: "%d h %02d", minutes / 60, minutes % 60)
    }

    // MARK: Plan

    private var planCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let plan = model.plan {
                ForEach(Array(plan.lines.enumerated()), id: \.offset) { _, line in
                    PlanRow(line: line)
                    Divider()
                }
                if plan.lines.isEmpty {
                    Text("Rien à calculer.").foregroundStyle(Palette.secondary).padding(14)
                    Divider()
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(plan.delivery).font(.headline)
                    Text(plan.margin).font(.callout).foregroundStyle(Palette.secondary)
                }
                .padding(14)
                if !plan.warnings.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(plan.warnings.enumerated()), id: \.offset) { _, warning in
                            Label(warning.text, systemImage: "exclamationmark.triangle")
                                .font(.callout)
                                .foregroundStyle(Palette.warning)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(14)
                }
            } else {
                HStack(spacing: 10) {
                    if !snapshot { ProgressView().controlSize(.small) }
                    Text("Calcul du plan…").foregroundStyle(Palette.secondary)
                }
                .padding(14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Settings

    private var customise: some View {
        DisclosureGroup(
            isExpanded: $customising,
            content: {
                VStack(alignment: .leading, spacing: 12) {
                    row("Scènes en haute résolution") {
                        if snapshot {
                            Text(model.sheet.hiresScenes.map(String.init) ?? "Auto")
                        } else {
                            Picker("", selection: hiresScenes) {
                                Text("Auto").tag(0)
                                ForEach(Array(NightSheet.hiresChoices), id: \.self) {
                                    Text("\($0)").tag($0)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(width: 190)
                        }
                    }
                    .disabled(model.sheet.exploreOnly)
                    row("Monde de couleurs") {
                        if snapshot {
                            Text(Self.worldName(model.sheet.world))
                        } else {
                            Picker("", selection: world) {
                                Text("Auto").tag("")
                                Text("Télescope").tag("telescope")
                                Text("Libre").tag("free")
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(width: 230)
                        }
                    }
                    row("Formats") {
                        HStack(spacing: 16) {
                            checkbox("4K", $model.sheet.fourK)
                            checkbox("Vertical", $model.sheet.vertical)
                        }
                    }
                    .disabled(model.sheet.exploreOnly)
                    checkbox("Exploration seulement", $model.sheet.exploreOnly)
                    Text("Tout le reste est laissé en Auto.")
                        .font(.caption).foregroundStyle(Palette.secondary)
                }
                .padding(.top, 10)
            },
            label: {
                Text(model.sheet.customised ? "Personnaliser · modifié" : "Personnaliser")
            })
    }

    @ViewBuilder
    private func checkbox(_ title: String, _ isOn: Binding<Bool>) -> some View {
        if snapshot {
            Label(title, systemImage: isOn.wrappedValue ? "checkmark.square.fill" : "square")
        } else {
            Toggle(title, isOn: isOn).toggleStyle(.checkbox)
        }
    }

    private var hiresScenes: Binding<Int> {
        Binding(
            get: { model.sheet.hiresScenes ?? 0 },
            set: { model.sheet.hiresScenes = $0 == 0 ? nil : $0 })
    }

    private var world: Binding<String> {
        Binding(get: { model.sheet.world ?? "" }, set: { model.sheet.world = $0.isEmpty ? nil : $0 })
    }

    static func worldName(_ world: String?) -> String {
        switch world {
        case "telescope": "Télescope"
        case "free": "Libre"
        default: "Auto"
        }
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title)
            Spacer()
            content()
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let failure = model.failure {
                Text(failure).font(.callout).foregroundStyle(Palette.warning)
            }
            HStack {
                Spacer()
                Button("Annuler", action: dismiss).keyboardShortcut(.cancelAction)
                Button("Lancer la nuit") {
                    if model.launch({ try queue.launchNight($0) }) { launched() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.launching)
            }
        }
    }
}

private struct PlanRow: View {
    let line: NightSheetPlan.Line

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(line.title).font(.headline)
                if !line.detail.isEmpty {
                    Text(line.detail).font(.callout).foregroundStyle(Palette.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(line.duration).font(.headline.monospacedDigit())
                if !line.until.isEmpty {
                    Text(line.until).font(.callout.monospacedDigit()).foregroundStyle(Palette.secondary)
                }
            }
        }
        .padding(14)
    }
}
