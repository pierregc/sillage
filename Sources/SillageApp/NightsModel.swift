import Foundation
import SillageRender

/// The nights of the library and the page of the one open, read from the files every second so
/// that a change shows within two. It reads nothing the night's own files do not hold, so a
/// night that ran while the app was closed shows as it ended.
@MainActor
final class NightsModel: ObservableObject {
    @Published private(set) var items: [NightListItem] = []
    @Published private(set) var page: NightPage?
    /// The night whose page is wanted: its folder name.
    @Published private(set) var selected: String?
    /// The scene a skip was asked for, so that one click is not two while the night goes on.
    @Published private(set) var skipAsked: String?

    private(set) var library: URL
    private let read: @Sendable (URL, String?) -> NightsSnapshot
    private var timer: Timer?
    private var reading = false
    private var generation = 0

    static let interval: TimeInterval = 1

    init(
        library: URL, watch: Bool = true,
        read: @escaping @Sendable (URL, String?) -> NightsSnapshot = {
            NightsSnapshot.read(library: $0, selected: $1)
        }
    ) {
        self.library = QueueModel.libraryFolder(for: library)
        self.read = read
        refresh()
        guard watch else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) {
            [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                self.poll()
            }
        }
    }

    func use(library root: URL) {
        let folder = QueueModel.libraryFolder(for: root)
        guard folder.standardizedFileURL != library.standardizedFileURL else { return }
        library = folder
        items = []
        page = nil
        refresh()
    }

    /// Opens a night's page, or none.
    func select(_ id: String?) {
        guard id != selected else { return }
        selected = id
        if id != page?.id { page = nil }
        refresh()
    }

    /// Reads now, on the caller's thread: the files are a few kilobytes.
    func refresh() {
        generation += 1
        apply(read(library, selected), library: library, selected: selected)
    }

    private func poll() {
        guard !reading else { return }
        reading = true
        let (library, selected, read) = (library, selected, read)
        Task.detached {
            let snapshot = read(library, selected)
            await MainActor.run {
                self.reading = false
                self.apply(snapshot, library: library, selected: selected)
            }
        }
    }

    private func apply(_ snapshot: NightsSnapshot, library: URL, selected: String?) {
        guard library == self.library, selected == self.selected else { return }
        if snapshot.items != items { items = snapshot.items }
        if snapshot.page != page { page = snapshot.page }
        // A skip asked is over once the night has moved on to another scene.
        if let asked = skipAsked, snapshot.page?.current?.scene != asked { skipAsked = nil }
    }

    func skipWasAsked(for scene: String?) { skipAsked = scene }
}
