import Foundation
import SillageCore

#if canImport(simd)
    import simd
#endif

/// The stretches a take pass has stepped through (#377): the settle's chunks, then one a
/// captured frame, each with the run's time, centres and disks once it was stepped, exactly.
/// A resumed run replays over it what the CPU carries from frame to frame (the step
/// scheduler's judge and switches, the director or `AutoCamera`) rather than saving the inside
/// of each. The curves cannot serve: they print four decimals.
public struct FrameJournal: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        /// The run's own steps the stretch took.
        public var steps: Int
        /// The captured frame it led to; nil while settling.
        public var frame: Int?
        public var time: Float
        public var centres: [SIMD3<Float>]
        public var disks: [DiskState]

        public init(steps: Int, frame: Int?, time: Float, centres: [SIMD3<Float>], disks: [DiskState]) {
            self.steps = steps
            self.frame = frame
            self.time = time
            self.centres = centres
            self.disks = disks
        }
    }

    public private(set) var entries: [Entry] = []

    public init() {}

    public mutating func append(_ entry: Entry) { entries.append(entry) }

    /// The settle's own steps done, and the captured frames.
    public var settled: Int { entries.lazy.filter { $0.frame == nil }.reduce(0) { $0 + $1.steps } }
    public var frames: Int { entries.lazy.filter { $0.frame != nil }.count }
    /// The time the last stretch ended at, which star formation is counted from.
    public var time: Float? { entries.last?.time }
}

extension StepScheduler {
    /// Takes a stretch a run already stepped: its scale and its switch as the run took them,
    /// its centres shown to the judge.
    public mutating func replay(_ entry: FrameJournal.Entry) {
        _ = next(entry.steps, frame: entry.frame)
        observe(timeMyr: Double(entry.time) * Physics.megayearsPerTimeUnit, centres: entry.centres)
    }
}

/// The camera of each frame of a take pass, from the run's centres alone: the director's, or
/// the look's own plan, framed once or by `AutoCamera`. A resumed run replays it over its
/// journal (#377).
public final class TakePassFraming {
    /// The director, which also lights each frame; nil when the look films by its own plan.
    public let director: Cinematographer?
    /// The radius the scene is framed at, fixed on the first frame so the camera does not drift
    /// as the tails grow; 0 until then.
    public var radius: Float
    private var autoCamera = AutoCamera()
    private let scene: SceneConfig
    private let look: LookFile
    private let frames: Int
    private let framesPerSecond: Int
    private let reach: [Float]

    /// `reach` is where each galaxy's disk ends.
    public init(scene: SceneConfig, look: LookFile, frames: Int, framesPerSecond: Int, reach: [Float]) {
        self.scene = scene
        self.look = look
        self.frames = frames
        self.framesPerSecond = framesPerSecond
        self.reach = reach
        radius = look.camera.radius
        // The director places the camera and lights the scene on its own. Without it a hundred
        // generated scenes come out framed identically, which is the thing that makes a library
        // dull.
        let directed = look.camera.mode == .director || look.camera.mode == .immersed
        director = directed ? Cinematographer(seed: scene.seed) : nil
        director?.beginScene(seed: scene.seed, base: look.look, immersed: look.camera.mode == .immersed)
    }

    /// The camera of captured frame `frame`, the run's centres being `centres`. Moves the
    /// director or the automatic framing on by that frame.
    public func camera(frame: Int, centres: [SIMD3<Float>]) -> Camera {
        if let director {
            // Advanced by one frame of playback rather than by wall clock, so the move reads
            // the same however long the frame took to compute.
            director.advance(
                seconds: 1 / Double(framesPerSecond),
                of: Subject(centres: scene.framedCentres(centres), radius: radius))
            return director.camera
        }
        var framed = (center: look.camera.center ?? .zero, radius: radius)
        if look.camera.mode == .auto {
            framed = autoCamera.frame(centres: scene.framedCentres(centres), margins: reach)
            framed.radius /= look.camera.zoom
        }
        return look.camera.camera(
            progress: Float(frame) / Float(max(frames - 1, 1)), radius: framed.radius,
            center: framed.center, fieldOfView: look.look.fieldOfView)
    }

    /// Moves on by the frames `journal` holds, as the run that wrote it did.
    public func replay(_ journal: FrameJournal) {
        for entry in journal.entries {
            if let frame = entry.frame { _ = camera(frame: frame, centres: entry.centres) }
        }
    }
}

/// A run's own video in segments, one a checkpoint interval (#377), as `RunVideos` writes a
/// full pass's: a checkpoint closes the segment whole, a resumed run draws the one it was
/// writing again from its first frame, and the end joins them without encoding them again.
public final class RunVideoSegments {
    public let drawing: any RunVideoDrawing
    private let directory: URL
    private let name: String
    public private(set) var state: VideoProgress

    private static func file(_ name: String, _ index: Int) -> String {
        String(format: "%@-%04d", (name as NSString).deletingPathExtension, index) + "."
            + (name as NSString).pathExtension
    }

    /// `begin` makes the drawing, begun at the segment's file. `name` is the video's.
    public init(
        directory: URL, name: String, resume: VideoProgress? = nil,
        begin: (URL) throws -> any RunVideoDrawing
    ) throws {
        self.directory = directory
        self.name = name
        var state = resume ?? VideoProgress()
        if state.segments.count != 1 { state.segments = [[]] }
        self.state = state
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        drawing = try begin(directory.appendingPathComponent(Self.file(name, state.segment)))
    }

    public func append(camera: Camera, still: ((any RunVideoStill) throws -> Void)?) throws {
        try drawing.append(camera: camera, still: still)
        state.frames += 1
    }

    /// Closes the segment and opens the next, so a checkpoint taken now has every frame drawn
    /// so far in whole files.
    public func cut() throws {
        guard state.frames > state.segmentStart else { return }
        try drawing.end()
        try? ResumedFile.synchronize(at: directory.appendingPathComponent(Self.file(name, state.segment)))
        state.segments[0].append(Self.file(name, state.segment))
        state.segment += 1
        state.segmentStart = state.frames
        try drawing.begin(directory.appendingPathComponent(Self.file(name, state.segment)))
    }

    /// Closes the video and joins its segments at `url`.
    public func finish(into url: URL, join: (_ parts: [URL], _ into: URL, _ frames: Int) throws -> Void)
        throws
    {
        try drawing.end()
        let parts =
            state.segments[0] + (state.frames > state.segmentStart ? [Self.file(name, state.segment)] : [])
        try join(parts.map { directory.appendingPathComponent($0) }, url, state.frames)
    }
}

/// What a take pass's checkpoint keeps beside the solver (#377).
public struct TakePassProgress: Codable, Sendable {
    public var journal: FrameJournal
    /// The radius the scene is framed at once a frame fixed it.
    public var radius: Float
    /// The take on disk, the bytes of the curves, and the video's segments, for a run that
    /// writes them.
    public var take: Recording.Progress?
    public var curvesBytes: Int?
    public var video: VideoProgress?
    /// The light tracers a massive pass drew to pick its massive set, then dropped.
    public var droppedTracers: Int
    /// Spent quantising the take and writing the curves so far.
    public var takeSeconds: Double
    public var curvesSeconds: Double

    public init(
        journal: FrameJournal, radius: Float, take: Recording.Progress?, curvesBytes: Int?,
        video: VideoProgress?, droppedTracers: Int, takeSeconds: Double, curvesSeconds: Double
    ) {
        self.journal = journal
        self.radius = radius
        self.take = take
        self.curvesBytes = curvesBytes
        self.video = video
        self.droppedTracers = droppedTracers
        self.takeSeconds = takeSeconds
        self.curvesSeconds = curvesSeconds
    }
}

/// A file a checkpointed run appends to, as its curves.
public enum ResumedFile {
    public struct CutShort: Error, CustomStringConvertible {
        public var url: URL
        public var recorded: Int
        public var description: String {
            "\(url.path) holds fewer than the \(recorded) bytes its checkpoint recorded"
        }
    }

    /// `url` opened for appending: begun empty, or cut back to the `kept` bytes a checkpoint
    /// recorded, and refused when it holds fewer.
    public static func open(_ url: URL, kept: Int?) throws -> FileHandle {
        if kept == nil { _ = FileManager.default.createFile(atPath: url.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: url)
        if let kept {
            guard try handle.seekToEnd() >= UInt64(kept) else {
                try? handle.close()
                throw CutShort(url: url, recorded: kept)
            }
            try handle.truncate(atOffset: UInt64(kept))
        }
        return handle
    }

    /// Flushes the file at `url` to the disk itself.
    public static func synchronize(at url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try synchronize(handle)
    }

    /// Flushes `handle` to the disk itself.
    public static func synchronize(_ handle: FileHandle) throws {
        #if canImport(Darwin)
            if fcntl(handle.fileDescriptor, F_FULLFSYNC) == 0 { return }
        #endif
        try handle.synchronize()
    }
}
