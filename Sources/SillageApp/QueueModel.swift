import Foundation
import SillageRender

/// The app's side of the queue: it reads `library/.queue/` to show it and writes jobs into it,
/// starting the runner bundled beside the app when none is at work. There is no other channel
/// between the two, so the queue goes on when the app quits.
@MainActor
final class QueueModel: ObservableObject {
    @Published private(set) var queue = JobQueue()
    @Published private(set) var runner: RunnerLock.Record?

    let store: QueueStore
    private var timer: Timer?

    init(library: URL, watch: Bool = true) {
        store = QueueStore(library: library)
        refresh()
        guard watch else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                self.refresh()
            }
        }
    }

    /// The `sillage-render` that `scripts/dev.sh app` copies into the bundle.
    nonisolated static var runnerExecutable: URL? {
        Bundle.main.url(forAuxiliaryExecutable: "sillage-render")
    }

    func refresh() {
        let read = store.read()
        if read != queue { queue = read }
        let alive = store.runner()
        if alive != runner { runner = alive }
    }

    /// Returns the job and the pid of the runner it started, if it had to.
    @discardableResult
    func submit(_ kind: QueueJob.Kind, path: String, options: [String] = []) throws -> (
        job: QueueJob, runner: Int32?
    ) {
        defer { refresh() }
        return try store.submit(kind, path: path, options: options, runner: Self.runnerExecutable)
    }

    func cancel(_ id: Int) throws {
        defer { refresh() }
        try store.cancel(id, runner: Self.runnerExecutable)
    }

    func moveFirst(_ id: Int) throws {
        defer { refresh() }
        try store.change { try $0.moveFirst(id, at: Date()) }
    }

    func pause() throws {
        defer { refresh() }
        try store.change { $0.pause(at: Date()) }
    }

    func resume() throws {
        defer { refresh() }
        try store.resume(runner: Self.runnerExecutable)
    }
}
