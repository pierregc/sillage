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

    /// How a stretch of a flight is timed (#406).
    public enum Pace: String, Codable, Sendable, Equatable {
        /// The eye's speed along the path follows the distance to the nearest matter.
        case nearness
    }

    public struct Key: Codable, Sendable, Equatable {
        /// Seconds into the video.
        public var at: Double
        /// The take's moment then; absent, the time is left to the keys around.
        public var myr: Double?
        /// A black hole close up's moment then, in the hole's time units (#335), where a flight
        /// through galaxies gives `myr`.
        public var time: Double?
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
        /// How the eye is timed along the path from this key to the next (#406); absent, by the
        /// keys' seconds.
        public var pace: Pace?

        public init(
            at: Double, myr: Double? = nil, time: Double? = nil, look: Bool? = nil, eye: Point? = nil,
            aim: Point? = nil, fov: Double? = nil, roll: Double? = nil, exposure: Double? = nil,
            pace: Pace? = nil
        ) {
            self.at = at
            self.myr = myr
            self.time = time
            self.look = look
            self.eye = eye
            self.aim = aim
            self.fov = fov
            self.roll = roll
            self.exposure = exposure
            self.pace = pace
        }

        public init(from decoder: any Decoder) throws {
            try rejectUnknownFields(decoder, CodingKeys.self)
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                at: try c.decode(Double.self, forKey: .at),
                myr: try c.decodeIfPresent(Double.self, forKey: .myr),
                time: try c.decodeIfPresent(Double.self, forKey: .time),
                look: try c.decodeIfPresent(Bool.self, forKey: .look),
                eye: try c.decodeIfPresent(Point.self, forKey: .eye),
                aim: try c.decodeIfPresent(Point.self, forKey: .aim),
                fov: try c.decodeIfPresent(Double.self, forKey: .fov),
                roll: try c.decodeIfPresent(Double.self, forKey: .roll),
                exposure: try c.decodeIfPresent(Double.self, forKey: .exposure),
                pace: try c.decodeIfPresent(Pace.self, forKey: .pace))
        }

        /// A key that places the camera; one that does not only pins the time.
        var placesCamera: Bool { look == true || eye != nil || aim != nil }

        /// The moment it pins, in the take's time or the close up's.
        var moment: Double? { myr ?? time }
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
        let hole = isBlackHole
        guard keys[0].moment != nil, keys[keys.count - 1].moment != nil else {
            throw fail("the first and the last keys give \(hole ? "time" : "myr")")
        }
        if hole, keys.contains(where: { $0.myr != nil }) {
            throw fail("a key gives myr and another time: myr for galaxies, time for a black hole")
        }
        if let near, !(near > 0 && near.isFinite) { throw fail("near \(near) kpc: it is above zero") }
        if let fault = inside?.fault { throw fail("inside: \(fault)") }
        if hole, inside != nil { throw fail("inside is for galaxies, not a black hole close up") }
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
            for case .galaxy? in [key.eye, key.aim] where hole {
                throw fail("\(name): a black hole close up has no galaxy to hold on to")
            }
            if key.pace != nil {
                if hole {
                    throw fail("\(name): pace follows matter, which a black hole close up has none of")
                }
                guard key.placesCamera, key.look != true else {
                    throw fail("\(name): pace goes on a key that places the camera with eye and aim")
                }
                guard let next = keys[(index + 1)...].first(where: \.placesCamera), next.look != true else {
                    throw fail(
                        "\(name): a paced stretch ends on a later key that places the camera with eye and aim"
                    )
                }
            }
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
            times: keys.compactMap { key in key.moment.map { TimeTrack.TimeKey(at: key.at, myr: $0) } },
            megayears: megayears, capturedRate: capturedRate)
    }

    public var seconds: Double { keys.last?.at ?? 0 }

    /// A flight round a black hole close up (#335): its keys give the hole's `time`, its points
    /// are in Schwarzschild radii round the hole, and it holds on to no galaxy.
    public var isBlackHole: Bool { keys.contains { $0.time != nil } }
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
    /// Kiloparsecs from each eye to the nearest matter (`Nearness`) at a captured position, for
    /// the stretches paced by it (#406); nil where the take's particles are not at hand.
    public var nearness: ((Double, [SIMD3<Double>]) -> [Double])?

    public init(
        megayears: [Double], capturedRate: Int, galaxies: Int,
        centres: @escaping (Double) -> [SIMD3<Double>], disks: @escaping (Double) -> [[SIMD3<Double>]],
        nearness: ((Double, [SIMD3<Double>]) -> [Double])? = nil
    ) {
        self.megayears = megayears
        self.capturedRate = capturedRate
        self.galaxies = galaxies
        self.centres = centres
        self.disks = disks
        self.nearness = nearness
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
            },
            nearness: { position, eyes in
                guard let blend = recording.blend(atCaptured: position) else {
                    return eyes.map { _ in .infinity }
                }
                let points = recording.positions(at: blend)
                let drawn = min(
                    take.particles.visibleCount > 0 ? take.particles.visibleCount : take.particles.count,
                    points.count)
                return points.withUnsafeBytes { bytes in
                    eyes.map { eye in
                        bytes.baseAddress.map {
                            Double(Nearness.distance(from: Flight.float(eye), to: $0, count: drawn))
                        } ?? .infinity
                    }
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
        case noNearness

        public var description: String {
            switch self {
            case .noGalaxy(let key, let galaxy, let galaxies):
                "flight: key \(key) is on galaxy \(galaxy), and the take has \(galaxies) (0 to \(galaxies - 1))"
            case .noLook(let key): "flight: key \(key) asks for the look's camera, and none was given"
            case .noNearness: "flight: a stretch paced by nearness needs the take's particles"
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
        var pace: FlightFile.Pace? = nil
    }

    /// A run of stretches paced by nearness (#406): the path's seconds at even steps of the
    /// video's from `from` to `to`, and the share of the nearness the eye covers each second
    /// away from the run's ends.
    public struct Pacing: Sendable, Equatable {
        public var from: Double
        public var to: Double
        public var path: [Double]
        public var share: Double
    }

    /// The paced runs, in the video's order.
    public private(set) var pacings: [Pacing] = []

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
                    look: false, pace: key.pace))
        }
        keys = resolved
        if keys.contains(where: { $0.pace != nil }) {
            guard let nearness = take.nearness else { throw Failure.noNearness }
            pacings = paced(nearness)
        }
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
        let seconds = pathSeconds(seconds)
        let (i, u) = segment(seconds)
        let exposure = eased(keys[i].exposure, keys[min(i + 1, keys.count - 1)].exposure, u)
        if i + 1 < keys.count, keys[i].look, keys[i + 1].look, let camera = lookCamera(at: position) {
            var drawn = camera
            drawn.near = near
            return (drawn, exposure)
        }
        let (eye, aim) = (point(\.eye, seconds, position), point(\.aim, seconds, position))
        let (roll, fov) = attitude(atSeconds: seconds)
        let forward = Self.normalised(aim - eye) ?? SIMD3(0, 1, 0)
        let up = rolled(up(at: seconds, forward: forward), forward: forward, by: roll)
        return (
            Camera(
                eye: Self.float(eye), target: Self.float(aim), up: Self.float(up), fieldOfView: Float(fov),
                near: near),
            exposure
        )
    }

    /// The roll and the vertical field of view the keys give at `seconds`, each eased from key to
    /// key. What a recorded flight's thinned keys are checked against (#298).
    func attitude(atSeconds seconds: Double) -> (roll: Double, fov: Double) {
        let (i, u) = segment(seconds)
        let next = keys[min(i + 1, keys.count - 1)]
        let tangent = { (fov: Double) in log(tan(fov / 2)) }
        return (
            eased(keys[i].roll, next.roll, u),
            2 * atan(exp(eased(tangent(keys[i].fov), tangent(next.fov), u)))
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

    /// Seconds over which a frame's slabs leave the look's stack for the matter's (#355).
    public static let slabEase = 1.0

    /// How much the camera at `seconds` is still the look's, for its slabs: 1 on a look span, 0
    /// from `slabEase` seconds away, smoothly between.
    public func look(atSeconds seconds: Double) -> Float {
        var on = 0.0
        for span in lookSpans {
            let off = max(span.lowerBound - seconds, seconds - span.upperBound, 0)
            let t = min(off / Self.slabEase, 1)
            on = max(on, 1 - t * t * (3 - 2 * t))
        }
        return Float(on)
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

    // MARK: Paced by nearness

    /// Seconds a run eases over at an end, from the speed the path has there to the paced one.
    static let paceRamp = 1.0
    /// Path samples a stretch is measured at, and how many of them nearness is measured at.
    static let paceSamples = 512
    static let paceProbes = 48
    /// Steps of the video's time a run is integrated over.
    static let paceSteps = 4096

    /// Where on the path the camera is at `seconds` of the video: the same second, but inside a
    /// paced run.
    func pathSeconds(_ seconds: Double) -> Double {
        guard let run = pacings.first(where: { seconds > $0.from && seconds < $0.to }) else {
            return seconds
        }
        let x = (seconds - run.from) / (run.to - run.from) * Double(run.path.count - 1)
        let n = min(Int(x), run.path.count - 2)
        return run.path[n] + (run.path[n + 1] - run.path[n]) * (x - Double(n))
    }

    /// The video's seconds at which the camera stands at `path` seconds of the path: the
    /// inverse of `pathSeconds`.
    func videoSeconds(_ path: Double) -> Double {
        guard let run = pacings.first(where: { path > $0.from && path < $0.to }) else { return path }
        let upper = run.path.firstIndex { $0 >= path } ?? run.path.count - 1
        let n = max(upper - 1, 0)
        let span = run.path[upper] - run.path[n]
        let t = span > 0 ? (path - run.path[n]) / span : 0
        return run.from + (Double(n) + t) / Double(run.path.count - 1) * (run.to - run.from)
    }

    /// Each run of keys that ask for it, timed so that the eye's speed is a share of the
    /// nearness, the share that keeps the run's seconds; at either end the speed eases over
    /// `paceRamp` from the one the path has there (none at the flight's ends).
    private func paced(_ nearness: (Double, [SIMD3<Double>]) -> [Double]) -> [Pacing] {
        var runs: [Pacing] = []
        var k = 0
        while k + 1 < keys.count {
            guard keys[k].pace != nil else {
                k += 1
                continue
            }
            var end = k + 1
            while end + 1 < keys.count, keys[end].pace != nil { end += 1 }
            if let run = pacing(from: k, to: end, nearness) { runs.append(run) }
            k = end
        }
        return runs
    }

    private func pacing(from first: Int, to last: Int, _ probe: (Double, [SIMD3<Double>]) -> [Double])
        -> Pacing?
    {
        let (from, to) = (keys[first].at, keys[last].at)
        let duration = to - from
        let count = Self.paceSamples * (last - first)
        func eye(_ path: Double) -> SIMD3<Double> { point(\.eye, path, captured(atSeconds: path)) }
        // The path's length from the run's start at even steps of its own seconds.
        let samples = (0...count).map { from + duration * Double($0) / Double(count) }
        let eyes = samples.map(eye)
        var lengths = [0.0]
        for n in 1...count { lengths.append(lengths[n - 1] + simd_length(eyes[n] - eyes[n - 1])) }
        let length = lengths[count]
        guard length > 1e-9 else { return nil }
        // Nearness at fewer of them, each set of eyes at one moment of the take asked at once.
        let every = max(count / (Self.paceProbes * (last - first)), 1)
        let probes = Array(stride(from: 0, through: count, by: every))
        var near = [Double](repeating: .infinity, count: probes.count)
        var byMoment: [Double: [Int]] = [:]
        for (slot, n) in probes.enumerated() {
            // At the nearest captured frame: the nearness moves with the eye far more than with
            // time, and each moment asked is a whole take decoded.
            byMoment[captured(atSeconds: samples[n]).rounded(), default: []].append(slot)
        }
        for (moment, slots) in byMoment {
            let found = probe(moment, slots.map { eyes[probes[$0]] })
            for (slot, value) in zip(slots, found) { near[slot] = value }
        }
        let finite = near.filter { $0.isFinite && $0 > 0 }
        guard let largest = finite.max() else { return nil }
        let logs = near.map { log(min(max($0.isFinite && $0 > 0 ? $0 : largest, 1e-5), 1e5)) }
        let probeLengths = probes.map { lengths[$0] }
        func nearness(along s: Double) -> Double {
            let upper = probeLengths.firstIndex { $0 >= s } ?? probeLengths.count - 1
            guard upper > 0 else { return exp(logs[0]) }
            let span = probeLengths[upper] - probeLengths[upper - 1]
            let t = span > 0 ? (s - probeLengths[upper - 1]) / span : 0
            return exp(logs[upper - 1] + (logs[upper] - logs[upper - 1]) * t)
        }
        // The path's own speeds at the run's ends, which the paced speed eases from and to.
        func speed(at key: Int) -> Double {
            let position = captured(atSeconds: keys[key].at)
            var points: [Int: SIMD3<Double>] = [:]
            for k in max(key - 1, 0)...min(key + 1, keys.count - 1) {
                points[k] = point(\.eye, keys[k].at, position)
            }
            return simd_length(tangent(key, points))
        }
        let (start, end) = (speed(at: first), speed(at: last))
        let ramp = min(Self.paceRamp, duration / 4)
        let steps = Self.paceSteps
        let dt = duration / Double(steps)
        func ease(_ t: Double) -> Double {
            let x = min(max(t, 0), 1)
            return x * x * (3 - 2 * x)
        }
        // The length covered at each step for a share `k`.
        func run(_ k: Double, _ scale: Double) -> [Double] {
            var covered = [0.0]
            covered.reserveCapacity(steps + 1)
            var s = 0.0
            for n in 0..<steps {
                let t = (Double(n) + 0.5) * dt
                let (rise, fall) = (ease(t / ramp), ease((duration - t) / ramp))
                var v = scale * ((1 - rise) * start + (1 - fall) * end)
                v += rise * fall * k * nearness(along: min(s, length))
                s += v * dt
                covered.append(s)
            }
            return covered
        }
        var k = 0.0
        var scale = 1.0
        var covered = run(0, 1)
        if covered[steps] >= length {
            scale = length / covered[steps]
            covered = run(0, scale)
        } else {
            var high = 1.0
            while run(high, 1)[steps] < length, high < 1e12 { high *= 2 }
            var low = 0.0
            for _ in 0..<60 {
                let middle = (low + high) / 2
                if run(middle, 1)[steps] < length { low = middle } else { high = middle }
            }
            k = (low + high) / 2
            covered = run(k, 1)
        }
        // From length to the path's own seconds, held to the run's ends.
        let path = covered.enumerated().map { n, s -> Double in
            if n == 0 { return from }
            if n == steps { return to }
            let target = min(s / covered[steps] * length, length)
            let upper = lengths.firstIndex { $0 >= target } ?? count
            guard upper > 0 else { return from }
            let span = lengths[upper] - lengths[upper - 1]
            let t = span > 0 ? (target - lengths[upper - 1]) / span : 0
            return samples[upper - 1] + (samples[upper] - samples[upper - 1]) * t
        }
        return Pacing(from: from, to: to, path: path, share: k)
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
            let position = captured(atSeconds: videoSeconds(s))
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
