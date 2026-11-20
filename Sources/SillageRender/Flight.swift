import Foundation
import SillageCore

#if canImport(simd)
    import simd
#endif

/// A camera path through a take, as written by hand (#295): keys at seconds of the video, each
/// placing the eye and the aim, the field of view, a roll and an exposure trim, and pinning the
/// take's time where it gives one. Kept as `flights/<name>.flight.json` in the scene folder,
/// strict as `LookFile` is: a field this build does not know is an error.
public struct FlightFile: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public static let fileExtension = "flight.json"

    /// A point in kiloparsecs, fixed in the world or carried by a galaxy.
    public enum Point: Codable, Sendable, Equatable {
        case world(SIMD3<Double>)
        /// `offset` from the galaxy's centre, in the world's axes or, with `disk`, in its disk's:
        /// x and y in its plane, z along its spin.
        case galaxy(Int, offset: SIMD3<Double>, disk: Bool)

        private enum CodingKeys: String, CodingKey {
            case galaxy, offset, disk
        }

        public init(from decoder: any Decoder) throws {
            if var list = try? decoder.unkeyedContainer() {
                self = .world(try Self.vector(&list))
                return
            }
            try rejectUnknownFields(decoder, CodingKeys.self)
            let c = try decoder.container(keyedBy: CodingKeys.self)
            var offset = SIMD3<Double>.zero
            if c.contains(.offset) {
                var list = try c.nestedUnkeyedContainer(forKey: .offset)
                offset = try Self.vector(&list)
            }
            self = .galaxy(
                try c.decode(Int.self, forKey: .galaxy), offset: offset,
                disk: try c.decodeIfPresent(Bool.self, forKey: .disk) ?? false)
        }

        public func encode(to encoder: any Encoder) throws {
            switch self {
            case .world(let point):
                var list = encoder.unkeyedContainer()
                try list.encode(contentsOf: [point.x, point.y, point.z])
            case .galaxy(let galaxy, let offset, let disk):
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(galaxy, forKey: .galaxy)
                if offset != .zero { try c.encode([offset.x, offset.y, offset.z], forKey: .offset) }
                if disk { try c.encode(true, forKey: .disk) }
            }
        }

        private static func vector(_ list: inout any UnkeyedDecodingContainer) throws -> SIMD3<Double> {
            let x = try list.decode(Double.self)
            let y = try list.decode(Double.self)
            let z = try list.decode(Double.self)
            guard list.isAtEnd else {
                throw DecodingError.dataCorruptedError(in: list, debugDescription: "a point is [x, y, z]")
            }
            return SIMD3(x, y, z)
        }
    }

    public struct Key: Codable, Sendable, Equatable {
        /// Seconds into the video.
        public var at: Double
        /// The take's moment then; absent, the time is left to the keys around.
        public var myr: Double?
        /// The camera the export draws without a flight at this moment.
        public var look: Bool?
        public var eye: Point?
        public var aim: Point?
        /// Vertical field of view in radians, as `Camera`'s.
        public var fov: Double?
        /// Radians about the line of sight; positive turns the camera anticlockwise.
        public var roll: Double?
        /// Stops on the look's brightness, the stretch moving with it.
        public var exposure: Double?

        public init(
            at: Double, myr: Double? = nil, look: Bool? = nil, eye: Point? = nil, aim: Point? = nil,
            fov: Double? = nil, roll: Double? = nil, exposure: Double? = nil
        ) {
            self.at = at
            self.myr = myr
            self.look = look
            self.eye = eye
            self.aim = aim
            self.fov = fov
            self.roll = roll
            self.exposure = exposure
        }

        public init(from decoder: any Decoder) throws {
            try rejectUnknownFields(decoder, CodingKeys.self)
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                at: try c.decode(Double.self, forKey: .at),
                myr: try c.decodeIfPresent(Double.self, forKey: .myr),
                look: try c.decodeIfPresent(Bool.self, forKey: .look),
                eye: try c.decodeIfPresent(Point.self, forKey: .eye),
                aim: try c.decodeIfPresent(Point.self, forKey: .aim),
                fov: try c.decodeIfPresent(Double.self, forKey: .fov),
                roll: try c.decodeIfPresent(Double.self, forKey: .roll),
                exposure: try c.decodeIfPresent(Double.self, forKey: .exposure))
        }

        /// A key that places the camera; one that does not only pins the time.
        var placesCamera: Bool { look == true || eye != nil || aim != nil }
    }

    /// The near distance of a flight's camera when the file gives none: a parsec, where every
    /// other camera keeps `Camera`'s kiloparsec (#297).
    public static let near = 0.001

    public var version: Int
    /// The camera's near distance in kiloparsecs; absent, `FlightFile.near`.
    public var near: Double?
    /// What the frames are drawn with once inside a galaxy (#297); absent, `InsideSettings`'s
    /// own values.
    public var inside: InsideSettings?
    public var keys: [Key]

    public init(near: Double? = nil, inside: InsideSettings? = nil, keys: [Key]) {
        version = Self.currentVersion
        self.near = near
        self.inside = inside
        self.keys = keys
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownFields(decoder, CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            near: try c.decodeIfPresent(Double.self, forKey: .near),
            inside: try c.decodeIfPresent(InsideSettings.self, forKey: .inside),
            keys: try c.decode([Key].self, forKey: .keys))
        version = try c.decode(Int.self, forKey: .version)
    }

    public enum ReadError: Error, CustomStringConvertible, Equatable {
        case unsupportedVersion(Int)
        case shape(String)

        public var description: String {
            switch self {
            case .unsupportedVersion(let version):
                "flight version \(version), this build reads \(FlightFile.currentVersion)"
            case .shape(let detail): "flight: \(detail)"
            }
        }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func decoded(from data: Data) throws -> FlightFile {
        let file = try JSONDecoder().decode(FlightFile.self, from: data)
        guard file.version == currentVersion else { throw ReadError.unsupportedVersion(file.version) }
        try file.validate()
        return file
    }

    /// What can be told without the take.
    public func validate() throws {
        func fail(_ detail: String) -> ReadError { .shape(detail) }
        guard keys.count >= 2 else { throw fail("two keys at least") }
        guard keys[0].at == 0 else { throw fail("the first key is at 0 s") }
        guard keys[0].myr != nil, keys[keys.count - 1].myr != nil else {
            throw fail("the first and the last keys give myr")
        }
        if let near, !(near > 0 && near.isFinite) { throw fail("near \(near) kpc: it is above zero") }
        if let fault = inside?.fault { throw fail("inside: \(fault)") }
        let first = keys[0]
        guard first.look == true || (first.eye != nil && first.aim != nil) else {
            throw fail("the first key places the camera: look, or eye and aim")
        }
        for (index, key) in keys.enumerated() {
            let name = "key \(index) at \(key.at) s"
            guard key.at.isFinite else { throw fail("\(name): at is a number") }
            if index > 0, key.at <= keys[index - 1].at { throw fail("\(name): keys go forward in the video") }
            if key.look == true, key.eye != nil || key.aim != nil || key.fov != nil || key.roll != nil {
                throw fail("\(name): a look key takes its eye, aim, fov and roll from the look")
            }
            if !key.placesCamera, key.fov != nil || key.roll != nil || key.exposure != nil {
                throw fail("\(name): fov, roll and exposure go on a key that places the camera")
            }
            if case .galaxy(_, let offset, _) = key.eye, offset == .zero {
                throw fail("\(name): an eye on a galaxy needs an offset from its centre")
            }
            if let fov = key.fov, !(fov > 0 && fov < .pi) { throw fail("\(name): fov \(fov) rad") }
            if let roll = key.roll, !roll.isFinite { throw fail("\(name): roll is a number") }
            if let exposure = key.exposure, !Flight.exposures.contains(exposure) {
                throw fail(
                    "\(name): exposure \(exposure) is outside \(Flight.exposures.lowerBound)"
                        + " to \(Flight.exposures.upperBound) stops")
            }
        }
    }

    /// The take's time along the video: #305's track through the keys that give `myr`.
    public func timeTrack(megayears: [Double], capturedRate: Int) throws -> TimeTrack {
        try TimeTrack(
            times: keys.compactMap { key in key.myr.map { TimeTrack.TimeKey(at: key.at, myr: $0) } },
            megayears: megayears, capturedRate: capturedRate)
    }

    public var seconds: Double { keys.last?.at ?? 0 }
}

/// What a flight reads of a take: its moments, and where its galaxies and their disks are at
/// any captured position.
public struct FlightTake {
    public var megayears: [Double]
    public var capturedRate: Int
    public var galaxies: Int
    /// Each galaxy's centre at a captured position.
    public var centres: (Double) -> [SIMD3<Double>]
    /// Each disk's axes at a captured position: two in its plane, then its spin.
    public var disks: (Double) -> [[SIMD3<Double>]]

    public init(
        megayears: [Double], capturedRate: Int, galaxies: Int,
        centres: @escaping (Double) -> [SIMD3<Double>], disks: @escaping (Double) -> [[SIMD3<Double>]]
    ) {
        self.megayears = megayears
        self.capturedRate = capturedRate
        self.galaxies = galaxies
        self.centres = centres
        self.disks = disks
    }

    /// The centres the take holds, and the disk states it holds or the natal planes, carried as
    /// the painted arms carry them (`DiskFrame`).
    public init(take: RecordingFile.Loaded, capturedRate: Int) {
        let recording = take.recording
        let scene = take.scene
        func double(_ v: SIMD3<Float>) -> SIMD3<Double> { SIMD3(Double(v.x), Double(v.y), Double(v.z)) }
        self.init(
            megayears: TimeTrack.megayears(of: recording), capturedRate: capturedRate,
            galaxies: scene.galaxies.count,
            centres: { position in
                guard let blend = recording.blend(atCaptured: position) else { return [] }
                let held = recording.centers(at: blend)
                return scene.galaxies.indices.map {
                    double($0 < held.count ? held[$0] : scene.galaxies[$0].position)
                }
            },
            disks: { position in
                let held = recording.blend(atCaptured: position).map { recording.disks(at: $0) } ?? []
                return scene.galaxies.enumerated().map { index, galaxy in
                    let natal = galaxy.orientation.columns.2 * galaxy.spin.sign
                    let live = index < held.count ? held[index] : DiskState.natal(galaxy)
                    let axis = simd_length_squared(live.axis) > 1e-12 ? simd_normalize(live.axis) : natal
                    let (u, v) = DiskFrame.planeAxes(natal: galaxy.orientation, normal: natal, axis: axis)
                    return [double(u), double(v), double(axis)]
                }
            })
    }
}

/// A flight resolved on a take: the camera and the exposure at any second of the video. Eye and
/// aim run through the keys against the video's time, with the tangents of a centripetal
/// Catmull-Rom spline converted to seconds and held to the chords on either side, so the path
/// passes through every key with a continuous velocity and never loops or overshoots between
/// close keys. Every key's point is placed at the frame's own moment, so a key anchored on a
/// galaxy moves with it. Field of view, roll and exposure are eased from key to key.
public final class Flight {
    /// The trim a key may ask, in stops.
    public static let exposures: ClosedRange<Double> = -8...4
    /// Past `clear` (|forward . z|) the up vector is carried from the frames before rather than
    /// taken from the world's z, wholly past `pole`, so looking straight down neither flips nor
    /// spins.
    static let clear = 0.95
    static let pole = 0.995
    /// Video seconds between the samples the carried up vector is kept at.
    static let upStep = 1.0 / 240

    public let file: FlightFile
    public let track: TimeTrack
    public let near: Float
    /// What its frames are drawn with from inside a galaxy (#297).
    public let inside: InsideSettings
    private let take: FlightTake
    private let keys: [Resolved]
    /// The look's camera at every captured frame a stretch between two look keys crosses.
    private let lookCameras: [Int: Camera]
    private var ups: [(up: SIMD3<Double>, level: Bool)] = []

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case noGalaxy(key: Int, galaxy: Int, galaxies: Int)
        case noLook(key: Int)

        public var description: String {
            switch self {
            case .noGalaxy(let key, let galaxy, let galaxies):
                "flight: key \(key) is on galaxy \(galaxy), and the take has \(galaxies) (0 to \(galaxies - 1))"
            case .noLook(let key): "flight: key \(key) asks for the look's camera, and none was given"
            }
        }
    }

    struct Resolved {
        var at: Double
        var eye: FlightFile.Point
        var aim: FlightFile.Point
        var fov: Double
        var roll: Double
        var exposure: Double
        var look: Bool
    }

    /// `look` gives the camera an export draws without a flight at a captured position; it is
    /// asked here only, in order, for the flight's `look` keys and the stretches between them.
    public init(
        _ file: FlightFile, take: FlightTake, look: ((Double) -> Camera)? = nil
    ) throws {
        try file.validate()
        self.file = file
        self.take = take
        track = try file.timeTrack(megayears: take.megayears, capturedRate: take.capturedRate)
        near = Float(file.near ?? FlightFile.near)
        inside = file.inside ?? InsideSettings()
        let rate = Double(take.capturedRate)
        let track = self.track
        func captured(_ seconds: Double) -> Double { track.captured(atPlayed: seconds * rate) }

        let placing = file.keys.enumerated().filter { $0.element.placesCamera }
        for (index, key) in placing {
            for case .galaxy(let galaxy, _, _)? in [key.eye, key.aim]
            where !(0..<take.galaxies).contains(galaxy) {
                throw Failure.noGalaxy(key: index, galaxy: galaxy, galaxies: take.galaxies)
            }
            if key.look == true, look == nil { throw Failure.noLook(key: index) }
        }

        // Asked in order of the take's time, as a replayed camera must be.
        var wanted = Set<Int>()
        let lookKeys = placing.map { $0.element.look == true }
        for (offset, (_, key)) in placing.enumerated().dropLast()
        where lookKeys[offset] && lookKeys[offset + 1] {
            let from = captured(key.at).rounded(.down)
            let to = captured(placing[offset + 1].element.at).rounded(.up)
            wanted.formUnion(Int(from)...Int(to))
        }
        var asked: [(position: Double, frame: Int?, key: Int?)] = wanted.map { (Double($0), $0, nil) }
        for (offset, (_, key)) in placing.enumerated() where key.look == true {
            asked.append((captured(key.at), nil, offset))
        }
        asked.sort { $0.position < $1.position }
        var cameras: [Int: Camera] = [:]
        var lookAt: [Int: Camera] = [:]
        for entry in asked {
            guard let camera = look?(entry.position) else { continue }
            if let frame = entry.frame { cameras[frame] = camera }
            if let key = entry.key { lookAt[key] = camera }
        }
        lookCameras = cameras

        var resolved: [Resolved] = []
        for (offset, (_, key)) in placing.enumerated() {
            let previous = resolved.last
            if let camera = lookAt[offset] {
                let eye = Self.double(camera.eye)
                let aim = Self.double(camera.target)
                resolved.append(
                    Resolved(
                        at: key.at, eye: .world(eye), aim: .world(aim), fov: Double(camera.fieldOfView),
                        roll: Self.roll(of: camera), exposure: key.exposure ?? previous?.exposure ?? 0,
                        look: true))
                continue
            }
            guard let eye = key.eye ?? previous?.eye, let aim = key.aim ?? previous?.aim else {
                throw FlightFile.ReadError.shape("key \(offset) has no eye or aim to keep")
            }
            resolved.append(
                Resolved(
                    at: key.at, eye: eye, aim: aim, fov: key.fov ?? previous?.fov ?? 0.6,
                    roll: key.roll ?? previous?.roll ?? 0, exposure: key.exposure ?? previous?.exposure ?? 0,
                    look: false))
        }
        keys = resolved
        ups = carriedUps()
    }

    public var seconds: Double { track.seconds }

    /// The moment of the take, as a captured position, at `seconds` into the video.
    public func captured(atSeconds seconds: Double) -> Double {
        track.captured(atPlayed: seconds * Double(take.capturedRate))
    }

    /// The camera at `seconds` into the video, and the exposure trim in stops.
    public func camera(atSeconds seconds: Double) -> (camera: Camera, exposure: Double) {
        let position = captured(atSeconds: seconds)
        let (i, u) = segment(seconds)
        let exposure = eased(keys[i].exposure, keys[min(i + 1, keys.count - 1)].exposure, u)
        if i + 1 < keys.count, keys[i].look, keys[i + 1].look, let camera = lookCamera(at: position) {
            var drawn = camera
            drawn.near = near
            return (drawn, exposure)
        }
        let (eye, aim) = (point(\.eye, seconds, position), point(\.aim, seconds, position))
        let next = keys[min(i + 1, keys.count - 1)]
        let tangent = { (fov: Double) in log(tan(fov / 2)) }
        let fov = 2 * atan(exp(eased(tangent(keys[i].fov), tangent(next.fov), u)))
        let forward = Self.normalised(aim - eye) ?? SIMD3(0, 1, 0)
        let up = rolled(
            up(at: seconds, forward: forward), forward: forward, by: eased(keys[i].roll, next.roll, u))
        return (
            Camera(
                eye: Self.float(eye), target: Self.float(aim), up: Self.float(up), fieldOfView: Float(fov),
                near: near),
            exposure
        )
    }

    /// The camera and the look a frame at `seconds` draws with.
    public func shot(atSeconds seconds: Double, look: RenderLook) -> ShotReplay.Shot {
        let (camera, exposure) = camera(atSeconds: seconds)
        return (camera, Self.trimmed(look, stops: exposure))
    }

    /// The cameras the frame at `seconds` is drawn through (#297): its own, or, when the near
    /// matter moves across a picture `height` high while the shutter is open, the cameras at the
    /// ends of the equal shares of that time the frame's renders stand for, one more than the
    /// renders. `interval` is the seconds between two frames of the video.
    public func cameras(atSeconds seconds: Double, interval: Double, frame: InsideFrame, height: Int)
        -> [Camera]
    {
        let half = interval * inside.shutter / 2
        let (from, to) = (max(seconds - half, 0), min(seconds + half, self.seconds))
        // On the look's own camera the frame is the export's, drawn once as the export draws it.
        guard inside.subframes > 1, to > from, !lookSpans.contains(where: { $0.contains(seconds) })
        else { return [camera(atSeconds: seconds).camera] }
        let count = InsideBlur.subframes(
            from: camera(atSeconds: from).camera, to: camera(atSeconds: to).camera, frame: frame,
            height: height)
        guard count > 0 else { return [camera(atSeconds: seconds).camera] }
        return (0...count).map { index in
            camera(atSeconds: from + (to - from) * Double(index) / Double(count)).camera
        }
    }

    /// The seconds of the video where the camera is the look's: each look key, and the whole
    /// stretch between two that follow each other. There a frame is the plain export's.
    public var lookSpans: [ClosedRange<Double>] {
        var spans: [ClosedRange<Double>] = []
        for (index, key) in keys.enumerated() where key.look {
            if index > 0, keys[index - 1].look, let last = spans.last {
                spans[spans.count - 1] = last.lowerBound...key.at
            } else {
                spans.append(key.at...key.at)
            }
        }
        return spans
    }

    /// The video seconds of every key, the ones that only pin time included.
    public var keySeconds: [Double] { file.keys.map(\.at) }

    /// Brightness times 2^stops, and the stretch with it as contemplation's closeness trim moves
    /// them (`Cinematographer.modulated`): the logarithmic stretch is what saturates up close.
    public static func trimmed(_ look: RenderLook, stops: Double) -> RenderLook {
        guard stops != 0 else { return look }
        var trimmed = look
        trimmed.brightness *= Float(pow(2, stops))
        trimmed.stretch *= Float(max(pow(2, stops * 1.9 / 1.3), 0.09))
        return trimmed
    }

    // MARK: The path

    /// The camera key before `seconds` and how far towards the next, 0 to 1.
    private func segment(_ seconds: Double) -> (Int, Double) {
        guard seconds > keys[0].at else { return (0, 0) }
        guard let next = keys.firstIndex(where: { $0.at > seconds }) else { return (keys.count - 1, 0) }
        let i = next - 1
        return (i, (seconds - keys[i].at) / (keys[next].at - keys[i].at))
    }

    /// Eye or aim at `seconds`, every key's point placed at the take's `position`.
    func point(_ which: KeyPath<Resolved, FlightFile.Point>, _ seconds: Double, _ position: Double)
        -> SIMD3<Double>
    {
        let (i, u) = segment(seconds)
        let centres = take.centres(position)
        var axes: [[SIMD3<Double>]]?
        func place(_ point: FlightFile.Point) -> SIMD3<Double> {
            switch point {
            case .world(let p): return p
            case .galaxy(let galaxy, let offset, let disk):
                let centre = galaxy < centres.count ? centres[galaxy] : .zero
                guard disk else { return centre + offset }
                if axes == nil { axes = take.disks(position) }
                guard let frame = axes, galaxy < frame.count else { return centre + offset }
                let (x, y, z) = (frame[galaxy][0], frame[galaxy][1], frame[galaxy][2])
                let inPlane: SIMD3<Double> = x * offset.x + y * offset.y
                return centre + inPlane + z * offset.z
            }
        }
        var points: [Int: SIMD3<Double>] = [:]
        for k in max(i - 1, 0)...min(i + 2, keys.count - 1) { points[k] = place(keys[k][keyPath: which]) }
        guard i + 1 < keys.count, u > 0, let a = points[i], let b = points[i + 1] else {
            return points[i] ?? .zero
        }
        let h = keys[i + 1].at - keys[i].at
        let (ma, mb) = (tangent(i, points), tangent(i + 1, points))
        let u2 = u * u
        let u3 = u2 * u
        // From `a`, so two keys at one point hold it to the bit.
        let blend: Double = -2 * u3 + 3 * u2
        let leaving: SIMD3<Double> = ma * ((u3 - 2 * u2 + u) * h)
        let arriving: SIMD3<Double> = mb * ((u3 - u2) * h)
        return a + (b - a) * blend + leaving + arriving
    }

    /// The velocity at key `k`, kiloparsecs a second: the centripetal Catmull-Rom tangent
    /// (Barry and Goldman's, its knots spaced by the square root of each chord) taken to video
    /// seconds at the harmonic mean of the rates on either side, and held under three chords per
    /// interval on each side, the bound past which a cubic overshoots. At rest at either end,
    /// beside a stretch that follows the look, and wherever two keys share a point.
    private func tangent(_ k: Int, _ points: [Int: SIMD3<Double>]) -> SIMD3<Double> {
        guard k > 0, k + 1 < keys.count, let p0 = points[k - 1], let p1 = points[k], let p2 = points[k + 1]
        else {
            return .zero
        }
        if (keys[k - 1].look && keys[k].look) || (keys[k].look && keys[k + 1].look) { return .zero }
        let (d0, d1) = (simd_length(p1 - p0), simd_length(p2 - p1))
        guard d0 > 1e-9, d1 > 1e-9 else { return .zero }
        let (h0, h1) = (keys[k].at - keys[k - 1].at, keys[k + 1].at - keys[k].at)
        let (t0, t1) = (d0.squareRoot(), d1.squareRoot())
        let before: SIMD3<Double> = (p1 - p0) / t0
        let across: SIMD3<Double> = (p2 - p0) / (t0 + t1)
        let after: SIMD3<Double> = (p2 - p1) / t1
        let along: SIMD3<Double> = before - across + after
        let (r0, r1) = (t0 / h0, t1 / h1)
        let rate: Double = 2 * r0 * r1 / (r0 + r1)
        var velocity: SIMD3<Double> = along * rate
        let most = min(3 * d0 / h0, 3 * d1 / h1)
        let speed = simd_length(velocity)
        if speed > most { velocity *= most / speed }
        return velocity
    }

    private func eased(_ a: Double, _ b: Double, _ u: Double) -> Double {
        let s = min(max(u, 0), 1)
        return a + (b - a) * s * s * (3 - 2 * s)
    }

    // MARK: Looking straight down

    /// Radians a second the carried up vector turns back to the world's z once clear of the
    /// vertical: a path over the top comes out upside down and rights itself in a second.
    static let righting = Double.pi

    /// The up vector carried along the flight at `upStep`, and whether it is the world's z there.
    private func carriedUps() -> [(up: SIMD3<Double>, level: Bool)] {
        let count = Int((seconds / Self.upStep).rounded(.up)) + 1
        var ups: [(up: SIMD3<Double>, level: Bool)] = []
        ups.reserveCapacity(count)
        var previous: (forward: SIMD3<Double>, up: SIMD3<Double>)?
        for n in 0..<count {
            let s = min(Double(n) * Self.upStep, seconds)
            let position = captured(atSeconds: s)
            let forward =
                Self.normalised(point(\.aim, s, position) - point(\.eye, s, position)) ?? previous?.forward
                ?? SIMD3(0, 1, 0)
            let level = Self.normalised(Self.rejected(SIMD3(0, 0, 1), forward))
            let weight = Self.weight(forward)
            var up: SIMD3<Double>
            var isLevel = false
            if let previous {
                up =
                    Self.normalised(
                        Self.rejected(Self.turned(previous.up, from: previous.forward, to: forward), forward))
                    ?? level ?? SIMD3(0, 0, 1)
                if let level {
                    let angle = atan2(simd_dot(simd_cross(up, level), forward), simd_dot(up, level))
                    let most = Self.righting * (1 - weight) * Self.upStep
                    if abs(angle) <= most {
                        up = level
                        isLevel = weight == 0
                    } else {
                        up = Self.turned(up, about: forward, by: angle < 0 ? -most : most)
                    }
                }
            } else {
                up = level ?? Self.normalised(Self.rejected(SIMD3(0, 1, 0), forward)) ?? SIMD3(0, 0, 1)
                isLevel = level != nil && weight == 0
            }
            ups.append((up, isLevel))
            previous = (forward, up)
        }
        return ups
    }

    /// The world's z, exactly, wherever the carried vector has come back to it; elsewhere the
    /// carried one.
    private func up(at seconds: Double, forward: SIMD3<Double>) -> SIMD3<Double> {
        let level = Self.normalised(Self.rejected(SIMD3(0, 0, 1), forward))
        guard !ups.isEmpty else { return level ?? SIMD3(0, 0, 1) }
        let x = min(max(seconds / Self.upStep, 0), Double(ups.count - 1))
        let n = min(Int(x), max(ups.count - 2, 0))
        let m = min(n + 1, ups.count - 1)
        if ups[n].level, ups[m].level, let level { return level }
        let t = x - Double(n)
        let carried = ups[n].up * (1 - t) + ups[m].up * t
        return Self.normalised(Self.rejected(carried, forward)) ?? level ?? SIMD3(0, 0, 1)
    }

    /// 0 clear of the vertical, 1 within `pole` of it.
    private static func weight(_ forward: SIMD3<Double>) -> Double {
        let z = abs(forward.z)
        guard z > clear else { return 0 }
        let s = min((z - clear) / (pole - clear), 1)
        return s * s * (3 - 2 * s)
    }

    private func rolled(_ up: SIMD3<Double>, forward: SIMD3<Double>, by roll: Double) -> SIMD3<Double> {
        guard roll != 0 else { return up }
        let right = simd_cross(forward, up)
        return up * cos(roll) - right * sin(roll)
    }

    /// The roll of a camera against the world's z, as a key would give it.
    static func roll(of camera: Camera) -> Double {
        let eye = double(camera.eye)
        guard let forward = normalised(double(camera.target) - eye),
            let up = normalised(rejected(double(camera.up), forward)),
            let level = normalised(rejected(SIMD3(0, 0, 1), forward))
        else { return 0 }
        let right = simd_cross(forward, level)
        return atan2(-simd_dot(up, right), simd_dot(up, level))
    }

    private func lookCamera(at position: Double) -> Camera? {
        let lower = Int(position.rounded(.down))
        guard let before = lookCameras[lower] else { return nil }
        let t = Float(position - Double(lower))
        guard t > 0, let after = lookCameras[lower + 1] else { return before }
        var camera = before
        camera.eye += (after.eye - camera.eye) * t
        camera.target += (after.target - camera.target) * t
        camera.up += (after.up - camera.up) * t
        camera.fieldOfView += (after.fieldOfView - camera.fieldOfView) * t
        return camera
    }

    // MARK: Vectors

    static func turned(_ v: SIMD3<Double>, from a: SIMD3<Double>, to b: SIMD3<Double>) -> SIMD3<Double> {
        let axis = simd_cross(a, b)
        let sine = simd_length(axis)
        let cosine = simd_dot(a, b)
        guard sine > 1e-12 else { return v }
        let k = axis / sine
        return rotated(v, about: k, cosine: cosine, sine: sine)
    }

    static func turned(_ v: SIMD3<Double>, about k: SIMD3<Double>, by angle: Double) -> SIMD3<Double> {
        rotated(v, about: k, cosine: cos(angle), sine: sin(angle))
    }

    /// Rodrigues' rotation of `v` about the unit axis `k`.
    private static func rotated(_ v: SIMD3<Double>, about k: SIMD3<Double>, cosine: Double, sine: Double)
        -> SIMD3<Double>
    {
        let along: SIMD3<Double> = k * (simd_dot(k, v) * (1 - cosine))
        let across: SIMD3<Double> = simd_cross(k, v) * sine
        return v * cosine + across + along
    }

    static func rejected(_ v: SIMD3<Double>, _ unit: SIMD3<Double>) -> SIMD3<Double> {
        v - unit * simd_dot(v, unit)
    }

    static func normalised(_ v: SIMD3<Double>) -> SIMD3<Double>? {
        let length = simd_length(v)
        return length > 1e-9 ? v / length : nil
    }

    static func double(_ v: SIMD3<Float>) -> SIMD3<Double> { SIMD3(Double(v.x), Double(v.y), Double(v.z)) }
    static func float(_ v: SIMD3<Double>) -> SIMD3<Float> { SIMD3(Float(v.x), Float(v.y), Float(v.z)) }
}
