import Foundation
import SillageCore
import simd

/// The shots the director takes of a whole take, planned from a story it already knows.
///
/// Live, the director cannot see ahead and frames the whole scene, which leaves the galaxies a
/// few per cent of the frame (`docs/notes/gigantism.md`). A take is all there before the first
/// frame is drawn, so the plan can put the camera close on what is worth filling the frame
/// with, when it happens: the calmer disk before the encounter, the pair at pericentre with the
/// bridge between them, and the survivor at the end. The wide shots between them are framed as
/// the auto camera frames them, since they are what shows the encounter. Shots join by a cut:
/// a zoom from a whole disk to the whole scene in the second or two a clip can spare is the
/// speed that destroys the sense of size.
public struct ShotPlan: Sendable {
    public enum Subject: Sendable, Equatable, CustomStringConvertible {
        /// Every galaxy, as the auto camera holds them.
        case wide
        /// One galaxy's disk, filling the frame.
        case disk(Int)
        /// A pair at their closest, the two cores and the bridge across the frame.
        case pericentre(Int, Int)

        public var description: String {
            switch self {
            case .wide: "wide"
            case .disk(let galaxy): "disk \(galaxy)"
            case .pericentre(let a, let b): "pericentre \(a)-\(b)"
            }
        }

        public var isClose: Bool { self != .wide }
    }

    public struct Shot: Sendable, Equatable {
        public var subject: Subject
        /// Captured frames, `start` included and `end` not.
        public var start: Int
        public var end: Int

        public var frames: Int { end - start }
    }

    /// What the plan reads of a take, one entry per captured frame.
    public struct Track: Sendable {
        public var centres: [[SIMD3<Float>]]
        /// Zero while a disk is a disk, one once the encounter has undone it (`DiskState`).
        public var disruption: [[Float]]
        /// Where each galaxy's light visibly ends, nine tenths of an exponential disk.
        public var reach: [Float]
        /// How far each galaxy reaches for the wide framing, as the auto camera counts it.
        public var margin: [Float]
        /// Particles drawn of each galaxy, zero for what is not drawn as one: a black hole.
        public var particles: [Int]
        /// The plane each galaxy was laid down in, signed by its spin.
        public var natal: [SIMD3<Float>]

        public init(
            centres: [[SIMD3<Float>]], disruption: [[Float]], reach: [Float], margin: [Float],
            particles: [Int], natal: [SIMD3<Float>]
        ) {
            self.centres = centres
            self.disruption = disruption
            self.reach = reach
            self.margin = margin
            self.particles = particles
            self.natal = natal
        }

        public var frames: Int { centres.count }
        var galaxies: Int { reach.count }
    }

    /// What a frame of the take shows of each galaxy's light, measured on its particles.
    public struct Light: Sendable {
        /// Where the light is densest. After an encounter the centre the solver follows can
        /// sit out in the debris while the core it was the centre of has gone on elsewhere.
        public var core: [SIMD3<Float>]
        /// The radius about the core holding the share of the light asked for.
        public var radius: [Float]
        /// The plane that light lies in: the axis it is thinnest along.
        public var axis: [SIMD3<Float>]

        public init(core: [SIMD3<Float>], radius: [Float], axis: [SIMD3<Float>]) {
            self.core = core
            self.radius = radius
            self.axis = axis
        }
    }

    public typealias Measure = (_ frame: Int, _ share: Float) -> Light?

    /// Shortest a shot may be, in seconds of the clip.
    static let shortest = 2.5
    /// Share of the frame's smaller side a close subject's light spans: two thirds or more of
    /// the frame, the size at which the single-disk spike read as matter.
    static let fill: Float = 0.85
    /// Of its own reach, how much of each galaxy a pericentre shot keeps around the two cores.
    static let pericentreMargin: Float = 0.6
    /// Share of a spread galaxy's light a close shot holds.
    static let bodyShare: Float = 0.6
    /// A galaxy is filmed close only with this share of the largest one's particles: framed
    /// as large, a galaxy of a few hundred thousand is soft blots (the spike's single disk).
    static let closeParticles: Float = 0.25

    public let shots: [Shot]
    private let track: Track
    private let wide: [(centre: SIMD3<Float>, radius: Float)]
    private let camera: LookFile.CameraPlan
    private let fieldOfView: Float
    private let framesPerSecond: Double
    /// Per shot, the view chosen for it, so a shot is the same at any frame asked.
    private let views: [View]

    private struct View: Sendable {
        /// The axis the eye sits above, and two directions across it.
        var axis = SIMD3<Float>(0, 0, 1)
        var across = SIMD3<Float>(1, 0, 0)
        var along = SIMD3<Float>(0, 1, 0)
        var elevation: Float = 1.2
        var phase: Float = 0
        /// Radians a second about `axis`.
        var turn: Float = 0
        /// Distance at the start and the end of the shot, as multiples of the framing one.
        var dolly: (from: Float, to: Float) = (1, 1)
        /// How far the subject's light reaches: a disk's, or the pair's and their margin.
        var radius: Float = 0
        /// Where its core sits against the centre the solver follows, measured at evenly
        /// spaced frames across the shot.
        var offsets: [SIMD3<Float>] = []
    }

    /// `measure` reads each galaxy's light off a captured frame. Without it a disk is framed
    /// on the reach and seen across the plane it was laid down with, which a disk the
    /// encounter has spread and turned no longer fits.
    public init(
        track: Track, camera: LookFile.CameraPlan, fieldOfView: Float, framesPerSecond: Int,
        seed: UInt64, measure: Measure = { _, _ in nil }
    ) {
        self.track = track
        self.camera = camera
        self.fieldOfView = fieldOfView
        self.framesPerSecond = Double(max(framesPerSecond, 1))
        var auto = AutoCamera()
        wide = track.centres.map {
            let framed = auto.frame(centres: $0, margins: track.margin)
            return (framed.center, framed.radius)
        }
        shots = Self.plan(track, framesPerSecond: self.framesPerSecond, measure: measure)
        var generator = SeededGenerator(seed: seed &* 0x9E37_79B9 &+ 186)
        var views: [View] = []
        for shot in shots {
            views.append(
                Self.view(
                    for: shot, track: track, camera: camera, span: Float(max(track.frames - 1, 1)),
                    measure: measure, generator: &generator))
        }
        self.views = views
    }

    /// The shot playing at a captured frame.
    public func shot(atCaptured position: Double) -> Shot? {
        let frame = Int(max(position, 0).rounded(.down))
        return shots.last { $0.start <= frame } ?? shots.first
    }

    /// Captured frames where one shot cuts to the next.
    public var cuts: [Int] { shots.dropFirst().map(\.start) }

    /// The camera at a captured frame, fractional between two. A position between the last
    /// frame of a shot and the first of the next is drawn as the nearer one, so a video at a
    /// higher rate than the take's never shows a blend of two shots.
    public func camera(atCaptured position: Double, aspect: Float) -> Camera {
        guard !shots.isEmpty else { return Camera(eye: SIMD3(0, -200, 60)) }
        var x = min(max(position, 0), Double(max(track.frames - 1, 0)))
        if let cut = cuts.first(where: { Double($0 - 1) < x && x < Double($0) }) {
            x = x - Double(cut - 1) < 0.5 ? Double(cut - 1) : Double(cut)
        }
        let index = shots.lastIndex { Double($0.start) <= x } ?? 0
        let shot = shots[index]
        let view = views[index]
        let progress = Float(x / Double(max(track.frames - 1, 1)))
        switch shot.subject {
        case .wide:
            let framed = wideFrame(at: x)
            return camera.camera(
                progress: progress, radius: framed.radius / camera.zoom, center: framed.centre,
                fieldOfView: fieldOfView)
        case .disk(let galaxy):
            var target = centre(galaxy, at: x)
            if view.offsets.count > 1 {
                let along = Float((x - Double(shot.start)) / Double(max(shot.frames - 1, 1)))
                let position = min(max(along, 0), 1) * Float(view.offsets.count - 1)
                let below = min(Int(position), view.offsets.count - 2)
                target += simd_mix(
                    view.offsets[below], view.offsets[below + 1],
                    SIMD3(repeating: position - Float(below)))
            } else if let offset = view.offsets.first {
                target += offset
            }
            return close(on: target, radius: view.radius / Self.fill, view, shot, x, aspect)
        case .pericentre(let a, let b):
            let middle = (centre(a, at: x) + centre(b, at: x)) / 2
            return close(on: middle, radius: view.radius / Self.fill, view, shot, x, aspect)
        }
    }

    /// One line a shot, for the logs.
    public var summary: [String] {
        zip(shots, views).map { shot, view in
            String(
                format: "%@ frames %d-%d (%.1f s)%@", shot.subject.description, shot.start,
                shot.end - 1, Double(shot.frames) / framesPerSecond,
                view.radius > 0 ? String(format: ", %.1f kpc held", view.radius) : "")
        }
    }

    /// Share of the clip spent close.
    public var closeShare: Double {
        let close = shots.filter(\.subject.isClose).map(\.frames).reduce(0, +)
        return Double(close) / Double(max(track.frames, 1))
    }

    // MARK: Framing

    private func close(
        on centre: SIMD3<Float>, radius: Float, _ view: View, _ shot: Shot, _ x: Double,
        _ aspect: Float
    ) -> Camera {
        let seconds = Float((x - Double(shot.start)) / framesPerSecond)
        let t = Float((x - Double(shot.start)) / Double(max(shot.frames - 1, 1)))
        let phase = view.phase + view.turn * seconds
        let level = cos(phase) * view.across + sin(phase) * view.along
        let direction = view.axis * sin(view.elevation) + level * cos(view.elevation)
        // Constant in the logarithm, so the push in reads at one steady pace.
        let dolly = view.dolly.from * pow(view.dolly.to / view.dolly.from, min(max(t, 0), 1))
        // Framed on the smaller side of the frame, so a vertical video keeps the disk whole.
        let held = radius / min(max(aspect, 0.1), 1)
        let distance = held / tan(fieldOfView / 2) * 1.05 * dolly
        // The axis is up on the screen, the far side of the disk at the top, which never
        // degenerates while the eye stays off the axis itself.
        let forward = -direction
        var up = view.axis - simd_dot(view.axis, forward) * forward
        up = simd_length(up) > 1e-4 ? simd_normalize(up) : SIMD3(0, 0, 1)
        return Camera(
            eye: centre + direction * distance, target: centre, up: up, fieldOfView: fieldOfView)
    }

    private func centre(_ galaxy: Int, at x: Double) -> SIMD3<Float> {
        let (a, b, t) = bracket(x)
        return simd_mix(track.centres[a][galaxy], track.centres[b][galaxy], SIMD3(repeating: t))
    }

    private func wideFrame(at x: Double) -> (centre: SIMD3<Float>, radius: Float) {
        let (a, b, t) = bracket(x)
        return (
            simd_mix(wide[a].centre, wide[b].centre, SIMD3(repeating: t)),
            wide[a].radius + (wide[b].radius - wide[a].radius) * t
        )
    }

    private func bracket(_ x: Double) -> (Int, Int, Float) {
        let last = max(track.frames - 1, 0)
        let a = min(Int(x.rounded(.down)), last)
        return (a, min(a + 1, last), Float(x - Double(a)))
    }

    // MARK: Planning

    /// The pair that comes closest against the size of their disks, and the frame of their
    /// first close passage: the one that pulls out the bridge and the tails, where a merger's
    /// last and deepest minimum is two galaxies already one.
    static func pericentre(_ track: Track) -> (a: Int, b: Int, frame: Int)? {
        let drawn = (0..<track.galaxies).filter { track.particles[$0] > 0 }
        var best: (a: Int, b: Int, depth: Float)?
        for (i, a) in drawn.enumerated() {
            for b in drawn[(i + 1)...] {
                let closest =
                    track.centres.map { simd_distance($0[a], $0[b]) }.min()
                    ?? .greatestFiniteMagnitude
                let depth = closest / max(track.reach[a] + track.reach[b], 1e-3)
                if best.map({ depth < $0.depth }) ?? true { best = (a, b, depth) }
            }
        }
        guard let best else { return nil }
        let separation = track.centres.map { simd_distance($0[best.a], $0[best.b]) }
        let touching = track.reach[best.a] + track.reach[best.b]
        let window = max(track.frames / 20, 2)
        for frame in separation.indices where separation[frame] < touching {
            let around = max(frame - window, 0)...min(frame + window, separation.count - 1)
            if separation[around].min() == separation[frame] {
                return (best.a, best.b, frame)
            }
        }
        let deepest = separation.indices.min { separation[$0] < separation[$1] } ?? 0
        return (best.a, best.b, deepest)
    }

    /// Of `among`, the galaxy whose disk keeps best over `frames`: the least disrupted, then
    /// the one whose light has spread least since the first frame (its half-light radius in
    /// the middle of `frames`, against the first one), then the one with the most particles.
    /// The calmer one before an encounter, the survivor after.
    static func calmest(
        _ track: Track, over frames: Range<Int>, among: [Int], measure: Measure
    ) -> Int {
        let range = frames.clamped(to: 0..<max(track.frames, 1))
        let middle = min((range.lowerBound + range.upperBound) / 2, max(track.frames - 1, 0))
        let now = measure(middle, 0.5)?.radius
        let then = measure(0, 0.5)?.radius
        func score(_ galaxy: Int) -> (Float, Float, Int) {
            let kept = range.map { track.disruption[$0][galaxy] }
            // Read to a twentieth and a tenth: past that the next criterion decides.
            let disrupted = (kept.reduce(0, +) / Float(max(kept.count, 1)) * 20).rounded()
            var grown: Float = 0
            if let now, let then, galaxy < now.count, galaxy < then.count, then[galaxy] > 0 {
                grown = (now[galaxy] / then[galaxy] * 10).rounded()
            }
            return (disrupted, grown, -track.particles[galaxy])
        }
        return among.min { score($0) < score($1) } ?? among.first ?? 0
    }

    static func plan(
        _ track: Track, framesPerSecond: Double, measure: Measure = { _, _ in nil }
    ) -> [Shot] {
        let count = track.frames
        guard count > 0 else { return [] }
        let shortest = max(Int(shortest * framesPerSecond), 1)
        let most = Float(track.particles.max() ?? 0)
        let drawn = (0..<track.galaxies).filter { track.particles[$0] > 0 }
        let filmable = drawn.filter { Float(track.particles[$0]) >= most * closeParticles }
        var shots: [Shot] = []
        func add(_ subject: Subject, _ start: Int, _ end: Int) {
            guard end > start else { return }
            if let last = shots.last, last.subject == subject {
                shots[shots.count - 1].end = end
            } else {
                shots.append(Shot(subject: subject, start: start, end: end))
            }
        }
        guard !filmable.isEmpty, count >= 3 * shortest else {
            add(.wide, 0, count)
            return shots
        }
        let closing = min(max(Int(Double(count) * 0.2), shortest), Int(8 * framesPerSecond))

        guard drawn.count > 1, let pair = pericentre(track) else {
            // A lone disk: close, wide, close.
            let opening = min(max(Int(Double(count) * 0.3), shortest), Int(8 * framesPerSecond))
            let galaxy = calmest(track, over: 0..<count, among: filmable, measure: measure)
            add(.disk(galaxy), 0, opening)
            add(.wide, opening, count - closing)
            add(.disk(galaxy), count - closing, count)
            return shots
        }

        let length = min(max(Int(Double(count) * 0.14), shortest), Int(6 * framesPerSecond))
        // In a little before the closest moment, so the cores are seen rushing together.
        let start = min(max(pair.frame - length * 3 / 10, 0), count - shortest)
        let end = min(start + length, count)
        let calm = [pair.a, pair.b].filter(filmable.contains)
        if start >= 2 * shortest, !calm.isEmpty {
            let opening = min(start / 2, Int(6 * framesPerSecond))
            add(.disk(calmest(track, over: 0..<opening, among: calm, measure: measure)), 0, opening)
            add(.wide, opening, start)
        } else {
            add(.wide, 0, start)
        }
        add(.pericentre(pair.a, pair.b), start, end)
        let survivorStart = max(count - closing, end + shortest)
        if survivorStart + shortest <= count {
            add(.wide, end, survivorStart)
            let survivor = calmest(
                track, over: survivorStart..<count, among: filmable, measure: measure)
            add(.disk(survivor), survivorStart, count)
        } else {
            add(.wide, end, count)
        }
        return shots
    }

    private static func view(
        for shot: Shot, track: Track, camera: LookFile.CameraPlan, span: Float,
        measure: Measure, generator: inout SeededGenerator
    ) -> View {
        var view = View()
        let sign: Float = generator.uniform() < 0.5 ? -1 : 1
        switch shot.subject {
        case .wide:
            return view
        case .disk(let galaxy):
            // Measured once and held for the shot: the plane a disk's light lies in, which
            // after an encounter is not the one it was laid down in, and the radius holding
            // its body. A disk as it was laid down is framed on its reach, where its light
            // visibly ends; one the encounter has spread on three fifths of its light, the
            // body whole and the roots of the tails, where the reach showed a bare core.
            let frame = shot.start == 0 ? 0 : min((shot.start + shot.end) / 2, track.frames - 1)
            let light = measure(frame, bodyShare)
            let reach = track.reach[galaxy]
            let measured = shot.start == 0 ? 0 : light.map { $0.radius[galaxy] } ?? 0
            // Capped, or a merger's remnant is framed on the debris it has thrown out.
            view.radius = min(max(measured, reach), reach * 1.6)
            view.axis = light.map { $0.axis[galaxy] } ?? track.natal[galaxy]
            let disrupted = track.disruption[frame][galaxy] > 0.5 || measured > reach
            // Nearly face on, as the single-disk renders of the spike: 1.35 rad there. What
            // the encounter has undone shows its loops and shells better from a little lower.
            view.elevation =
                disrupted
                ? generator.uniform(in: 0.95...1.2) : generator.uniform(in: 1.15...1.35)
            view.turn = sign * generator.uniform(in: 0.015...0.03)
            view.dolly = shot.start == 0 ? (1.06, 0.94) : (1.12, 0.96)
            // A core about every second and a half: it drifts, it does not jump.
            let samples = max(shot.frames / 45 + 1, 2)
            view.offsets = (0..<samples).map { index in
                let at = shot.start + (shot.frames - 1) * index / (samples - 1)
                guard let core = measure(at, bodyShare)?.core[galaxy] else { return .zero }
                return core - track.centres[at][galaxy]
            }
        case .pericentre(let a, let b):
            let peri = min(max(shot.start + shot.frames * 3 / 10, 0), track.frames - 1)
            let before = max(peri - 2, 0)
            let after = min(peri + 2, track.frames - 1)
            let separation = track.centres[peri][b] - track.centres[peri][a]
            let motion =
                (track.centres[after][b] - track.centres[after][a])
                - (track.centres[before][b] - track.centres[before][a])
            let normal = simd_cross(separation, motion)
            view.axis = simd_length(normal) > 1e-6 ? simd_normalize(normal) : SIMD3(0, 0, 1)
            if view.axis.z < 0 { view.axis = -view.axis }
            view.elevation = generator.uniform(in: 0.8...1.05)
            view.turn = sign * generator.uniform(in: 0.01...0.02)
            // Held for the shot rather than following the pair out: at pericentre they part
            // fastest, and a frame widening with them is a pull back of a sixth a second. Sized
            // on where they are three fifths of the way through, so they part inside it.
            let held = min(shot.start + shot.frames * 3 / 5, track.frames - 1)
            view.radius =
                simd_distance(track.centres[held][a], track.centres[held][b]) / 2
                + pericentreMargin * max(track.reach[a], track.reach[b])
            // The pair across the frame: the eye looks along the orbital plane at right angles
            // to the line between them.
            let line = separation - simd_dot(separation, view.axis) * view.axis
            if simd_length(line) > 1e-6 {
                view.across = simd_normalize(simd_cross(view.axis, simd_normalize(line)))
                view.along = simd_cross(view.axis, view.across)
                return view
            }
        }
        // Seen from the side of the plane the wide shots are on, and from the same quarter, so
        // a cut moves in rather than swinging round.
        if view.axis.z < 0 { view.axis = -view.axis }
        let reference = abs(view.axis.z) > 0.95 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 0, 1)
        view.across = simd_normalize(simd_cross(reference, view.axis))
        view.along = simd_cross(view.axis, view.across)
        let t = Float(shot.start) / span
        let eased = t * t * (3 - 2 * t)
        let azimuth =
            camera.azimuth + ((camera.azimuthEnd ?? camera.azimuth) - camera.azimuth) * eased
        let elevation =
            camera.elevation + ((camera.elevationEnd ?? camera.elevation) - camera.elevation)
            * eased
        let wideDirection = SIMD3<Float>(
            sin(azimuth) * cos(elevation), -cos(azimuth) * cos(elevation), sin(elevation))
        view.phase = atan2(
            simd_dot(wideDirection, view.along), simd_dot(wideDirection, view.across))
        return view
    }
}

extension ShotPlan {
    /// The plan for drawing `take` with `file`, each galaxy's light measured on the take.
    public init(take: RecordingFile.Loaded, file: LookFile, framesPerSecond: Int) {
        let track = Track(take: take)
        let meter = LightMeter(take: take, reach: track.reach)
        self.init(
            track: track, camera: file.camera, fieldOfView: file.look.fieldOfView,
            framesPerSecond: framesPerSecond, seed: take.scene.seed
        ) { frame, share in
            frame < track.frames
                ? meter.measure(atCaptured: frame, centres: track.centres[frame], share: share)
                : nil
        }
    }
}

extension ShotPlan.Track {
    /// Read off a take: the centres the frame is placed on, every captured frame.
    public init(take: RecordingFile.Loaded) {
        let recording = take.recording
        let scene = take.scene
        let count = scene.galaxies.count
        var centres: [[SIMD3<Float>]] = []
        var disruption: [[Float]] = []
        for frame in 0..<max(recording.capturedFrames, 1) {
            guard let blend = recording.blend(atCaptured: frame) else { break }
            var around = scene.framedCentres(recording.centers(at: blend))
            if around.count != count { around = scene.galaxies.map(\.position) }
            centres.append(around)
            let disks = recording.disks(at: blend)
            disruption.append(
                disks.count == count ? disks.map(\.disruption) : Array(repeating: 0, count: count))
        }
        var particles = [Int](repeating: 0, count: count)
        for owner in take.particles.galaxyIndex where Int(owner) < count {
            particles[Int(owner)] += 1
        }
        for (index, galaxy) in scene.galaxies.enumerated() where galaxy.kind == .blackHole {
            particles[index] = 0
        }
        self.init(
            centres: centres, disruption: disruption,
            reach: scene.galaxies.map(SceneCheck.brightReach),
            margin: scene.galaxies.map { max($0.diskScaleLength * $0.diskTruncation, 0.1) },
            particles: particles, natal: scene.galaxies.map { DiskState.natal($0).axis })
    }
}

/// Reads each galaxy's light off a frame of a take, one particle in several, and keeps what
/// it decoded: the plan asks the same frames more than once.
final class LightMeter: @unchecked Sendable {
    private let take: RecordingFile.Loaded
    private let reach: [Float]
    private let stride: Int
    private var decoded: [Int: [SIMD3<Float>]] = [:]
    private let lock = NSLock()

    init(take: RecordingFile.Loaded, reach: [Float]) {
        self.take = take
        self.reach = reach
        stride = max(take.recording.particleCount / 400_000, 1)
    }

    func measure(atCaptured frame: Int, centres: [SIMD3<Float>], share: Float) -> ShotPlan.Light? {
        let recording = take.recording
        guard let blend = recording.blend(atCaptured: frame) else { return nil }
        let stored = Int(blend.keys[blend.fraction < 0.5 ? 1 : 2])
        lock.lock()
        let positions = decoded[stored] ?? recording.positions(at: stored, every: stride)
        decoded[stored] = positions
        lock.unlock()
        return Self.light(
            positions: positions, stride: stride, owners: take.particles.galaxyIndex,
            luminosity: take.particles.luminosity, centres: centres, reach: reach, share: share)
    }

    /// For each galaxy: the densest point of its particles near the centre given, the radius
    /// about it holding `share` of its light, and the axis that light is thinnest along.
    static func light(
        positions: [SIMD3<Float>], stride: Int, owners: [UInt32], luminosity: [Float],
        centres: [SIMD3<Float>], reach: [Float], share: Float
    ) -> ShotPlan.Light {
        var samples = [[(offset: SIMD3<Float>, light: Float)]](
            repeating: [], count: centres.count)
        for (sample, position) in positions.enumerated() {
            let index = sample * stride
            guard index < owners.count else { break }
            let owner = Int(owners[index])
            guard owner < centres.count else { continue }
            samples[owner].append(
                (position - centres[owner], index < luminosity.count ? luminosity[index] : 1))
        }
        var cores: [SIMD3<Float>] = []
        var radii: [Float] = []
        var axes: [SIMD3<Float>] = []
        for (galaxy, kept) in samples.enumerated() {
            let shift = densest(kept.map(\.offset), from: galaxy < reach.count ? reach[galaxy] : 10)
            cores.append(centres[galaxy] + shift)
            let sorted = kept.map { ($0.offset - shift, $0.light) }.sorted {
                simd_length_squared($0.0) < simd_length_squared($1.0)
            }
            let total = sorted.reduce(0) { $0 + $1.1 }
            var sum: Float = 0
            var held = sorted.count
            for (index, entry) in sorted.enumerated() {
                sum += entry.1
                if sum >= share * total {
                    held = index + 1
                    break
                }
            }
            radii.append(held > 0 ? simd_length(sorted[held - 1].0) : 0)
            axes.append(thinnest(sorted.prefix(held).map { (offset: $0.0, light: $0.1) }))
        }
        return ShotPlan.Light(core: cores, radius: radii, axis: axes)
    }

    /// The densest point of a cloud, by a sphere shrunk onto it from `reach` about the origin:
    /// the mean of what lies inside, again and again with a smaller sphere. Counted rather
    /// than weighted by light, so a bright knot out in a tail does not pull it over.
    static func densest(_ offsets: [SIMD3<Float>], from reach: Float) -> SIMD3<Float> {
        var centre = SIMD3<Float>.zero
        var radius = max(reach * 2, 1e-3)
        while radius > reach * 0.2 {
            var sum = SIMD3<Float>.zero
            var count = 0
            for offset in offsets where simd_distance_squared(offset, centre) < radius * radius {
                sum += offset
                count += 1
            }
            guard count >= 64 else { break }
            centre = sum / Float(count)
            radius *= 0.75
        }
        return centre
    }

    /// The axis a cloud of weighted offsets is thinnest along: the smallest eigenvector of its
    /// second moments, found as the largest of their trace less themselves.
    static func thinnest(_ points: [(offset: SIMD3<Float>, light: Float)]) -> SIMD3<Float> {
        var moments = simd_float3x3()
        for point in points {
            let p = point.offset
            moments += simd_float3x3(p * p.x, p * p.y, p * p.z) * point.light
        }
        let trace = moments[0][0] + moments[1][1] + moments[2][2]
        guard trace > 0 else { return SIMD3(0, 0, 1) }
        let flipped = simd_float3x3(diagonal: SIMD3(repeating: trace)) - moments
        var axis = simd_normalize(SIMD3<Float>(0.3, 0.2, 1))
        for _ in 0..<64 {
            let next = flipped * axis
            guard simd_length(next) > 0 else { break }
            axis = simd_normalize(next)
        }
        return axis
    }
}
