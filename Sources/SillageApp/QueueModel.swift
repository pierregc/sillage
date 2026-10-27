import Foundation
import SillageRender

/// The app's side of the queue: it reads `library/.queue/` to show it and writes jobs into it,
/// starting the runner bundled beside the app when none is at work. There is no other channel
/// between the two, so the queue goes on when the app quits. It also reads the status files
/// every second and keeps what the sidebar and the queue view say, from the formatter that
/// `sillage-render status` prints with.
@MainActor
final class QueueModel: ObservableObject {
    @Published private(set) var queue = JobQueue()
    @Published private(set) var runner: RunnerLock.Record?
    @Published private(set) var status: QueueStatus
    /// Why the last action failed.
    @Published var failure: String?

    private(set) var store: QueueStore
    /// The runner started when nothing is at work; the checks clear it, so what they queue
    /// stays queued.
    var runnerURL: URL? = QueueModel.runnerExecutable
    private let readStatus: @Sendable (URL) -> QueueStatus
    private var timer: Timer?
    private var reading = false

    /// Every second, so a change in the files shows within two.
    static let interval: TimeInterval = 1

    /// `status` reads a library's status files; the checks give it fixed inputs.
    init(
        library: URL, watch: Bool = true,
        status readStatus: @escaping @Sendable (URL) -> QueueStatus = { QueueStatus.read(library: $0) }
    ) {
        store = QueueStore(library: Self.libraryFolder(for: library))
        self.readStatus = readStatus
        status = readStatus(store.library)
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

    /// The folder holding the batches and the queue: the library the user opened, or the one
    /// above it when a single batch was opened.
    nonisolated static func libraryFolder(for root: URL) -> URL {
        func holdsStatus(_ url: URL) -> Bool {
            let manager = FileManager.default
            return manager.fileExists(atPath: url.appendingPathComponent(".queue").path)
                || manager.fileExists(atPath: RunStatusFiles.activity(library: url).path)
        }
        let parent = root.deletingLastPathComponent()
        return !holdsStatus(root) && holdsStatus(parent) ? parent : root
    }

    /// Follows another library.
    func use(library: URL) {
        let folder = Self.libraryFolder(for: library)
        guard folder.standardizedFileURL != store.library else { return }
        store = QueueStore(library: folder)
        refresh()
    }

    /// The `sillage-render` that `scripts/dev.sh app` copies into the bundle.
    nonisolated static var runnerExecutable: URL? {
        Bundle.main.url(forAuxiliaryExecutable: "sillage-render")
    }

    func refresh() {
        apply(Self.read(store, readStatus))
    }

    private struct Reading: Sendable {
        var store: QueueStore
        var queue: JobQueue
        var runner: RunnerLock.Record?
        var status: QueueStatus
    }

    nonisolated private static func read(
        _ store: QueueStore, _ status: @Sendable (URL) -> QueueStatus
    ) -> Reading {
        Reading(
            store: store, queue: store.read(), runner: store.runner(), status: status(store.library))
    }

    private func apply(_ read: Reading) {
        guard read.store.library == store.library else { return }
        if read.queue != queue { queue = read.queue }
        if read.runner != runner { runner = read.runner }
        if read.status != status { status = read.status }
    }

    /// Reads off the main actor: the processes are listed and a dozen files opened.
    private func poll() {
        guard !reading else { return }
        reading = true
        let store = store
        let readStatus = readStatus
        Task.detached {
            let read = Self.read(store, readStatus)
            await MainActor.run {
                self.reading = false
                self.apply(read)
            }
        }
    }

    /// Returns the job and the pid of the runner it started, if it had to.
    @discardableResult
    func submit(_ kind: QueueJob.Kind, path: String, options: [String] = []) throws -> (
        job: QueueJob, runner: Int32?
    ) {
        defer { refresh() }
        return try store.submit(kind, path: path, options: options, runner: runnerURL)
    }

    /// Adds a night from the new night sheet, with a recipe file of its own.
    @discardableResult
    func launchNight(_ sheet: NightSheet) throws -> QueueJob {
        defer { refresh() }
        return try sheet.launch(library: store.library, runner: runnerURL).job
    }

    /// A night ends once the step it is on is done.
    func stopAfterStep(_ id: Int) throws {
        defer { refresh() }
        try store.change { try $0.stopAfterStep(id, at: Date()) }
    }

    /// A night leaves out the scene it works on.
    func skip(_ id: Int) throws {
        defer { refresh() }
        try store.change { try $0.skip(id, at: Date()) }
    }

    func cancel(_ id: Int) throws {
        defer { refresh() }
        try store.cancel(id, runner: runnerURL)
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
        try store.resume(runner: runnerURL)
    }

    /// Queues what the page planned, leaving out what is queued already. Returns how many.
    @discardableResult
    func submit(_ planned: [PlannedJob]) -> Int {
        var added = 0
        attempt {
            for job in planned where !job.queued {
                try submit(job.kind, path: job.path, options: job.options)
                added += 1
            }
        }
        return added
    }

    /// The status line of a job waiting or running.
    func row(_ id: Int) -> QueueStatus.Row? {
        ([status.running].compactMap { $0 } + status.waiting).first { $0.job == id }
    }

    /// The scene folders a hires waits or runs for, which the library lists as Haute résolution.
    var activeHires: Set<String> {
        Set(
            queue.jobs.filter { !$0.isFinished && $0.kind == .hires }.map {
                SceneFolder(path: $0.path).url.path
            })
    }

    /// Runs an action from the view and keeps its error to show.
    func attempt(_ action: () throws -> Void) {
        do {
            try action()
            failure = nil
        } catch {
            failure = "\(error)"
        }
    }
}
