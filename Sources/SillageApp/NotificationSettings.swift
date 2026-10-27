import AppKit
import SillageRender
import SwiftUI

/// The reglages window, ⌘, : whether the runner tells of a night's phases, its end and its
/// failures. The runner reads the file each time, so the switch counts at once.
@MainActor
final class NotificationSettings: ObservableObject {
    @Published var enabled: Bool {
        didSet {
            guard let store, enabled != oldValue else { return }
            try? QueueSettings(notifications: enabled).write(store)
        }
    }

    private let store: QueueStore?

    init(library: URL?) {
        store = library.map(QueueStore.init)
        enabled = store.map { QueueSettings.read($0).notifications } ?? true
    }
}

struct SettingsView: View {
    @ObservedObject var library: LibraryModel

    var body: some View {
        // Rebuilt when the library changes, so the switch always belongs to the open library.
        SettingsForm(settings: NotificationSettings(library: library.root))
            .id(library.root)
    }
}

struct SettingsForm: View {
    @StateObject var settings: NotificationSettings

    var body: some View {
        Form {
            Toggle("Notifications de la file d'attente", isOn: $settings.enabled)
            Text(
                "Sillage prévient quand une phase de la nuit se termine, quand la nuit est finie, "
                    + "quand un travail échoue et quand la file d'attente se vide après des travaux lancés à la main."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 440)
    }
}

/// What the menu bar item shows while something runs: `activity.json`, read every two seconds.
@MainActor
final class MenuBarStatus: ObservableObject {
    @Published private(set) var activity: ActivityFile?

    private var timer: Timer?
    private let library: () -> URL?

    init(library: @escaping () -> URL?) {
        self.library = library
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                self.refresh()
            }
        }
    }

    var isRunning: Bool { activity.map { $0.state != .idle && $0.job != nil } ?? false }
    var progress: Double { activity?.job?.progress ?? 0 }
    var line: String { activity.map(Notices.statusLine) ?? "Rien en cours" }

    func refresh() {
        let read = library().flatMap { ActivityFile.read(from: RunStatusFiles.activity(library: $0)) }
        if read != activity { activity = read }
    }

    /// A ring that fills with the progress, drawn as a template image so the menu bar tints it.
    static func ring(_ progress: Double) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let box = rect.insetBy(dx: 3, dy: 3)
            let centre = NSPoint(x: rect.midX, y: rect.midY)
            let radius = box.width / 2
            let track = NSBezierPath(ovalIn: box)
            track.lineWidth = 2
            NSColor.black.withAlphaComponent(0.3).setStroke()
            track.stroke()
            let arc = NSBezierPath()
            arc.appendArc(
                withCenter: centre, radius: radius, startAngle: 90,
                endAngle: 90 - 360 * min(max(progress, 0.02), 1), clockwise: true)
            arc.lineWidth = 2
            arc.lineCapStyle = .round
            NSColor.black.setStroke()
            arc.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}

struct StatusMenu: View {
    @ObservedObject var status: MenuBarStatus
    @ObservedObject var navigation: AppNavigation
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(status.line)
        Divider()
        Button("Ouvrir Sillage") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: AppNavigation.windowID)
        }
    }
}
