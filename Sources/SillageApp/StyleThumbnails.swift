import Combine
import CoreGraphics
import Foundation
import QuartzCore
import SillageCore
import SillageRender

/// The Rendu section's thumbnails: the frame on the canvas drawn with every rendering and the
/// style's palette and camera, off the main actor (#114). Drawn again when the playhead has
/// moved more than a tenth of the take, when the palette or the camera plan changed, or when
/// asked.
@MainActor
final class StyleThumbnails: ObservableObject {
    /// By rendering name, the last drawn of each, kept until its new one arrives.
    @Published private(set) var images: [String: CGImage] = [:]
    @Published private(set) var drawing = false
    /// The captured frame the thumbnails show.
    @Published private(set) var frame: Int?
    /// Width over height of a thumbnail.
    let aspectRatio: Double

    /// What the last complete pass took, and how many it drew rather than found kept.
    private(set) var lastSeconds: Double?
    private(set) var lastDrawn = 0
    private(set) var passes = 0

    weak var session: StyleSession?
    private let model: SimulationModel
    private let catalogue: [LookFile]
    private let clip: (width: Int, height: Int)
    private let worker = Worker()
    private var target: Target?
    private var running: Flag?
    private var watching: AnyCancellable?

    /// What a pass is drawing: a frame, and the style with no rendering of its own.
    private struct Target: Equatable {
        var frame: Int
        var style: LookFile
    }

    init(model: SimulationModel, catalogue: [LookFile], folder: SceneFolder?) {
        self.model = model
        self.catalogue = catalogue
        let hires = folder?.storedHires()
        let clip = folder.flatMap { try? $0.storedClip() }
        self.clip = (
            hires?.width ?? clip?.width ?? 1920, hires?.height ?? clip?.height ?? 1080
        )
        aspectRatio = Double(self.clip.width) / Double(max(self.clip.height, 1))
        watching = Publishers.MergeMany(
            model.$playbackPosition.map { _ in () }.eraseToAnyPublisher(),
            model.$lookFile.map { _ in () }.eraseToAnyPublisher(),
            model.$mode.map { _ in () }.eraseToAnyPublisher(),
            model.$sceneFolder.map { _ in () }.eraseToAnyPublisher(),
            model.$fileActivity.map { _ in () }.eraseToAnyPublisher(),
            model.$isPreparing.map { _ in () }.eraseToAnyPublisher()
        )
        .throttle(for: .milliseconds(300), scheduler: DispatchQueue.main, latest: true)
        .sink { [weak self] in
            MainActor.assumeIsolated { self?.refreshIfStale() }
        }
    }

    /// The renderings in the order the section shows them.
    var renderings: [LookFile] {
        LookCatalogue.renderings(.telescope, in: catalogue) + LookCatalogue.renderings(.free, in: catalogue)
    }

    /// The style the thumbnails follow: the one being edited, with the rendering taken out.
    private var style: LookFile? {
        guard let session, session.isOpen, let first = catalogue.first else { return nil }
        return session.current.withRendering(first)
    }

    /// A tenth of the take, in captured frames.
    private var stride: Int { max((model.playedTake?.recording.capturedFrames ?? 0) / 10, 1) }

    func refreshIfStale() {
        guard let style else { return }
        let now = Target(frame: model.playheadCapturedFrame, style: style)
        guard let target else { return refresh() }
        if target.style != now.style || abs(target.frame - now.frame) > stride { refresh() }
    }

    /// Draws the frame on the canvas through the camera on the canvas, whatever is shown.
    func refresh() {
        guard let session, let style, let take = model.playedTake else { return }
        running?.raise()
        let flag = Flag()
        running = flag
        let frame = model.playheadCapturedFrame
        target = Target(frame: frame, style: style)
        let renderings = renderings
        let names = renderings.map(\.name)
        let looks = renderings.map { session.current.withRendering($0) }
        let camera = model.activeCamera
        let (worker, clip, pacer) = (worker, clip, model.canvasPacer)
        drawing = true
        let start = CACurrentMediaTime()
        worker.queue.async { [weak self] in
            let outcome = Result {
                if worker.engine == nil {
                    worker.engine = try RenderingThumbnails(
                        take: take, clipWidth: clip.width, clipHeight: clip.height)
                }
                return try worker.engine!.draw(
                    looks, frame: frame, camera: camera, pacer: pacer, cancelled: { flag.raised }
                ) { index, thumbnail in
                    let name = names[index]
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard !flag.raised, let image = thumbnail.image else { return }
                            self?.images[name] = image
                        }
                    }
                }
            }
            let seconds = CACurrentMediaTime() - start
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !flag.raised else { return }
                    self.drawing = false
                    self.frame = frame
                    self.passes += 1
                    switch outcome {
                    case .success(let drawn):
                        self.lastDrawn = drawn
                        self.lastSeconds = seconds
                    case .failure:
                        self.lastDrawn = 0
                        self.lastSeconds = nil
                    }
                }
            }
        }
    }

    /// Stops the pass under way, draws nothing more and lets the GPU buffers go.
    func close() {
        watching = nil
        running?.raise()
        running = nil
        target = nil
        drawing = false
        let worker = worker
        worker.queue.async { worker.engine = nil }
    }

    /// The engine lives on its own queue and is only touched there.
    private final class Worker: @unchecked Sendable {
        let queue = DispatchQueue(label: "sillage.style-thumbnails", qos: .userInitiated)
        var engine: RenderingThumbnails?
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var raised: Bool { lock.withLock { value } }
        func raise() { lock.withLock { value = true } }
    }
}
