import Foundation
import SillageCore
import Testing

@testable import SillageRender

#if canImport(simd)
    import simd
#endif

@Suite("Flight")
struct FlightTests {
    /// 101 captured frames a megayear apart from 200 Myr, at 10 a second. Galaxy 0 moves along x
    /// at a kiloparsec a frame, galaxy 1 sits still with its disk turned a quarter about z.
    private func take() -> FlightTake {
        FlightTake(
            megayears: (0...100).map { 200 + Double($0) }, capturedRate: 10, galaxies: 2,
            centres: { position in [SIMD3(position, 0, 0), SIMD3(0, 50, 0)] },
            disks: { _ in
                [
                    [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)],
                    [SIMD3(0, 1, 0), SIMD3(-1, 0, 0), SIMD3(0, 0, 1)],
                ]
            })
    }

    private func world(_ x: Double, _ y: Double, _ z: Double) -> FlightFile.Point { .world(SIMD3(x, y, z)) }

    private func double(_ v: SIMD3<Float>) -> SIMD3<Double> { SIMD3(Double(v.x), Double(v.y), Double(v.z)) }

    private var winding: FlightFile {
        FlightFile(keys: [
            .init(at: 0, myr: 200, eye: world(0, -100, 20), aim: world(0, 0, 0)),
            .init(at: 2, eye: world(60, -60, 10)),
            .init(at: 3, eye: world(70, -20, 5), fov: 0.3),
            .init(at: 7, eye: world(10, 10, 30), roll: 0.4),
            .init(at: 8, myr: 260, eye: world(-40, -80, 40), aim: world(5, 0, 0)),
        ])
    }

    @Test func thePathPassesThroughEveryKey() throws {
        let flight = try Flight(winding, take: take())
        for key in winding.keys {
            let camera = flight.camera(atSeconds: key.at).camera
            guard case .world(let eye) = key.eye else { continue }
            #expect(simd_length(double(camera.eye) - eye) < 1e-4, "\(key.at) s")
        }
        #expect(abs(flight.camera(atSeconds: 3).camera.fieldOfView - 0.3) < 1e-6)
        #expect(abs(flight.camera(atSeconds: 5).camera.fieldOfView - 0.3) < 1e-6)
    }

    @Test func itsVelocityIsContinuousAtEveryKey() throws {
        let flight = try Flight(winding, take: take())
        let step = 1e-5
        func eye(_ s: Double) -> SIMD3<Double> { flight.point(\.eye, s, flight.captured(atSeconds: s)) }
        for key in winding.keys.dropFirst().dropLast() {
            let before = (eye(key.at) - eye(key.at - step)) / step
            let after = (eye(key.at + step) - eye(key.at)) / step
            #expect(simd_length(before - after) < 1e-2 * max(simd_length(before), 1), "\(key.at) s")
        }
        let start = (eye(step) - eye(0)) / step
        #expect(simd_length(start) < 1e-2, "at rest when it sets off")
    }

    @Test func twoKeysAtOnePointHoldTheCameraThereWithoutOvershoot() throws {
        let file = FlightFile(keys: [
            .init(at: 0, myr: 200, eye: world(0, -50, 0), aim: world(0, 0, 0)),
            .init(at: 1, eye: world(0, -20, 0)),
            .init(at: 3, eye: world(0, -20, 0)),
            .init(at: 4, myr: 240, eye: world(0, -19, 0)),
        ])
        let flight = try Flight(file, take: take())
        var previous = -Double.infinity
        for n in 0...400 {
            let s = Double(n) / 100
            let y = flight.point(\.eye, s, flight.captured(atSeconds: s)).y
            if s >= 1, s <= 3 { #expect(y == -20, "\(s) s") }
            #expect(y >= previous - 1e-12 && y <= -19 + 1e-12, "\(s) s: \(y)")
            previous = y
        }
    }

    @Test func timeHoldsBetweenTwoKeysAtOneMomentAndNeverRunsBack() throws {
        let file = FlightFile(keys: [
            .init(at: 0, myr: 200, eye: world(0, -100, 0), aim: world(0, 0, 0)),
            .init(at: 2, myr: 230, eye: world(50, -50, 0)),
            .init(at: 4, eye: world(50, 50, 0)),
            .init(at: 6, myr: 230, eye: world(-50, 50, 0)),
            .init(at: 8, myr: 290, eye: world(-50, -50, 0)),
        ])
        let flight = try Flight(file, take: take())
        #expect(abs(flight.seconds - 8) < 1e-12)
        var previous = -1.0
        for n in 0...800 {
            let s = Double(n) / 100
            let position = flight.captured(atSeconds: s)
            #expect(position >= previous)
            if s >= 2, s <= 6 { #expect(abs(position - 30) < 1e-9, "\(s) s") }
            previous = position
        }
        #expect(abs(flight.captured(atSeconds: 8) - 90) < 1e-9)
        #expect(throws: TimeTrack.Failure.outsideTake(myr: 400, first: 200, last: 300)) {
            try Flight(FlightFile(keys: [file.keys[0], .init(at: 1, myr: 400)]), take: take())
        }
    }

    @Test func anAnchoredPointFollowsItsGalaxy() throws {
        let offset = SIMD3<Double>(0, -30, 10)
        let file = FlightFile(keys: [
            .init(
                at: 0, myr: 200, eye: .galaxy(0, offset: offset, disk: false),
                aim: .galaxy(0, offset: .zero, disk: false)),
            .init(at: 5, myr: 300, eye: .galaxy(0, offset: offset, disk: false)),
        ])
        let flight = try Flight(file, take: take())
        for n in 0...10 {
            let s = Double(n) / 2
            let centre = SIMD3(flight.captured(atSeconds: s), 0, 0)
            let camera = flight.camera(atSeconds: s).camera
            #expect(simd_length(double(camera.eye) - (centre + offset)) < 1e-3, "\(s) s")
            #expect(simd_length(double(camera.target) - centre) < 1e-3, "\(s) s")
        }
        let disk = FlightFile(keys: [
            .init(
                at: 0, myr: 200, eye: .galaxy(1, offset: SIMD3(10, 0, 3), disk: true),
                aim: .galaxy(1, offset: .zero, disk: false)),
            .init(at: 1, myr: 210),
        ])
        let turned = try Flight(disk, take: take()).camera(atSeconds: 0.5).camera
        #expect(simd_length(double(turned.eye) - SIMD3(0, 60, 3)) < 1e-4)
        #expect(throws: Flight.Failure.noGalaxy(key: 0, galaxy: 2, galaxies: 2)) {
            try Flight(
                FlightFile(keys: [
                    .init(at: 0, myr: 200, eye: world(0, 1, 0), aim: .galaxy(2, offset: .zero, disk: false)),
                    .init(at: 1, myr: 210),
                ]),
                take: take())
        }
    }

    /// A look key is the camera the export draws there, and between two of them the camera is
    /// the look's own, asked in the order of the take's time.
    @Test func lookKeysFollowTheLooksCamera() throws {
        var asked: [Double] = []
        func look(_ position: Double) -> Camera {
            asked.append(position)
            let angle = Float(position) * 0.01
            return Camera(
                eye: SIMD3(100 * sin(angle), -100 * cos(angle), 40), target: SIMD3(0, 0, 0), fieldOfView: 0.5)
        }
        let file = FlightFile(keys: [
            .init(at: 0, myr: 200, look: true),
            .init(at: 3, myr: 230, look: true),
            .init(at: 6, myr: 240, eye: world(20, -20, 5), aim: world(0, 0, 0), fov: 0.8),
        ])
        let flight = try Flight(file, take: take(), look: look)
        #expect(asked == asked.sorted())
        for s in [0, 0.75, 1.5, 2.25, 3] {
            let position = flight.captured(atSeconds: s)
            let drawn = flight.camera(atSeconds: s).camera
            let wanted = look(position)
            #expect(simd_length(drawn.eye - wanted.eye) < 1e-3, "\(s) s")
            #expect(abs(drawn.fieldOfView - 0.5) < 1e-6)
        }
        let leaving = flight.camera(atSeconds: 4.5).camera
        #expect(simd_length(leaving.eye - look(30).eye) > 1)
        #expect(throws: Flight.Failure.noLook(key: 0)) { try Flight(file, take: take()) }
    }

    /// Straight down and past it: the picture neither flips nor spins as it goes over.
    @Test func lookingStraightDownKeepsAnUpVector() throws {
        let file = FlightFile(keys: [
            .init(at: 0, myr: 200, eye: world(0, -40, 30), aim: world(0, 0, 0)),
            .init(at: 2, eye: world(0, 0, 50)),
            .init(at: 4, myr: 240, eye: world(0, 40, 30)),
        ])
        let flight = try Flight(file, take: take())
        var previous: SIMD3<Float>?
        for n in 0...400 {
            let camera = flight.camera(atSeconds: Double(n) / 100).camera
            let forward = simd_normalize(camera.target - camera.eye)
            #expect(camera.up.x.isFinite && abs(simd_length(camera.up) - 1) < 1e-4)
            #expect(abs(simd_dot(camera.up, forward)) < 1e-3)
            if let previous { #expect(simd_dot(previous, camera.up) > 0.95, "\(Double(n) / 100) s") }
            previous = camera.up
        }
        let level = flight.camera(atSeconds: 0).camera
        #expect(level.up.x == 0 && level.up.z > 0)
        let righted = flight.camera(atSeconds: 4).camera
        #expect(righted.up.z > 0.5, "over the top it comes out upside down and rights itself")
    }

    @Test func rollTurnsTheCameraAboutItsLineOfSight() throws {
        let file = FlightFile(keys: [
            .init(at: 0, myr: 200, eye: world(0, -10, 0), aim: world(0, 0, 0), roll: .pi / 2),
            .init(at: 1, myr: 210),
        ])
        let camera = try Flight(file, take: take()).camera(atSeconds: 0).camera
        #expect(simd_length(camera.up - SIMD3(-1, 0, 0)) < 1e-6)
        #expect(abs(Flight.roll(of: camera) - .pi / 2) < 1e-6)
    }

    @Test func exposureTrimsBrightnessAndStretchTogether() {
        var look = RenderLook.observatory
        look.brightness = 1
        look.stretch = 10
        let down = Flight.trimmed(look, stops: -2)
        #expect(abs(down.brightness - 0.25) < 1e-6)
        #expect(abs(down.stretch - 10 * Float(pow(2, -2 * 1.9 / 1.3))) < 1e-4)
        #expect(Flight.trimmed(look, stops: 0).stretch == 10)
    }

    /// The take above with matter in a sheet at z = 0: an eye is its height from it, plus 50 pc.
    private func sheet() -> FlightTake {
        var take = take()
        take.nearness = { _, eyes in eyes.map { abs($0.z) + 0.05 } }
        return take
    }

    /// A dive paced by nearness (#406) keeps its ends and its seconds, and away from its ends the
    /// eye covers the same share of the nearness each second: it never stops slowing.
    @Test func aPacedDiveKeepsSlowingWithTheNearness() throws {
        let file = FlightFile(keys: [
            .init(at: 0, myr: 200, eye: world(0, 0, 20), aim: world(0, 30, 0), pace: .nearness),
            .init(at: 10, myr: 200, eye: world(0, 0, 0.2), aim: world(0, 30, 0)),
        ])
        let flight = try Flight(file, take: sheet())
        let plain = try Flight(
            FlightFile(
                keys: file.keys.map {
                    var key = $0
                    key.pace = nil
                    return key
                }), take: take())
        #expect(flight.pacings.count == 1)
        let share = try #require(flight.pacings.first).share
        func eye(_ s: Double) -> SIMD3<Double> { double(flight.camera(atSeconds: s).camera.eye) }
        #expect(simd_length(eye(0) - SIMD3(0, 0, 20)) < 1e-4)
        #expect(simd_length(eye(10) - SIMD3(0, 0, 0.2)) < 1e-4)
        let step = 0.01
        var ratios: [Double] = []
        var previous = eye(0).z
        for s in stride(from: step, through: 10, by: step) {
            let z = eye(s).z
            #expect(z <= previous + 1e-9, "\(s) s goes back up")
            previous = z
        }
        for s in stride(from: 1.5, through: 8.5, by: 0.5) {
            let speed = simd_length(eye(s + step / 2) - eye(s - step / 2)) / step
            ratios.append(speed / (abs(eye(s).z) + 0.05))
        }
        #expect(ratios.max()! / ratios.min()! < 1.03, "\(ratios)")
        #expect(abs(ratios[ratios.count / 2] / share - 1) < 0.03, "share \(share)")
        // From 20 kpc to 250 pc, a little under half the nearness a second over ten seconds.
        #expect(share > 0.4 && share < 0.7, "share \(share)")
        // It leaves at rest, as the plain flight does, and gathers speed smoothly.
        let start = simd_length(eye(0.01) - eye(0)) / 0.01
        #expect(start < 0.05 * share * 20, "\(start) kpc a second")
        // The plain flight spends half its time far out; the paced one is down to a kpc by then.
        #expect(double(plain.camera(atSeconds: 5).camera.eye).z > 9)
        #expect(eye(5).z < 2.5, "\(eye(5).z) kpc at 5 s")
        // Time itself still follows the keys.
        #expect(flight.captured(atSeconds: 5) == plain.captured(atSeconds: 5))
    }

    /// A stretch paced by nearness leaves the rest of a flight as it was, to the bit, and keeps
    /// to the same path inside it.
    @Test func aPacedStretchLeavesTheRestOfTheFlightAlone() throws {
        var file = winding
        file.keys[2].pace = .nearness
        let paced = try Flight(file, take: sheet())
        let plain = try Flight(winding, take: sheet())
        #expect(paced.pacings.map(\.from) == [3] && paced.pacings.map(\.to) == [7])
        for s in stride(from: 0.0, through: 8, by: 0.25) where s <= 3 || s >= 7 {
            let (a, b) = (paced.camera(atSeconds: s).camera, plain.camera(atSeconds: s).camera)
            #expect(a.eye == b.eye && a.target == b.target && a.up == b.up, "\(s) s")
            #expect(a.fieldOfView == b.fieldOfView, "\(s) s")
        }
        // Inside it the eye stands on the plain path, at another of its seconds.
        for s in stride(from: 3.5, through: 6.5, by: 0.5) {
            let eye = double(paced.camera(atSeconds: s).camera.eye)
            let nearest = stride(from: 3.0, through: 7, by: 0.001).map {
                simd_length(double(plain.camera(atSeconds: $0).camera.eye) - eye)
            }.min()!
            #expect(nearest < 0.1, "\(s) s is \(nearest) kpc off the path")
        }
        // Two paced stretches in a row are one run, with one share.
        file.keys[3].pace = .nearness
        #expect(try Flight(file, take: sheet()).pacings.map(\.to) == [8])
    }

    /// An eye anchored on a galaxy that moves is asked its nearness where it stands at the
    /// captured frame the matter is read at, not half a frame away from it.
    @Test func aPacedEyeOnAMovingGalaxyIsProbedWithItsMatter() throws {
        var probed = take()
        var worst = 0.0
        probed.nearness = { moment, eyes in
            eyes.map { eye in
                worst = max(worst, abs(eye.x - moment))
                return abs(eye.z) + 0.05
            }
        }
        let file = FlightFile(keys: [
            .init(
                at: 0, myr: 200, eye: .galaxy(0, offset: SIMD3(0, 0, 20), disk: false),
                aim: world(0, 30, 0), pace: .nearness),
            .init(
                at: 10, myr: 210, eye: .galaxy(0, offset: SIMD3(0, 0, 0.2), disk: false),
                aim: world(0, 30, 0)),
        ])
        #expect(try Flight(file, take: probed).pacings.count == 1)
        #expect(worst < 1e-9, "an eye \(worst) kpc off its galaxy's centre")
    }

    @Test func aPaceIsAskedWhereItCanBeKept() throws {
        let decoded = try JSONDecoder().decode(
            FlightFile.Key.self,
            from: Data(#"{"at": 0, "eye": [0, 0, 1], "aim": [0, 1, 0], "pace": "nearness"}"#.utf8))
        #expect(decoded.pace == .nearness)
        var file = winding
        file.keys[4].pace = .nearness
        #expect(throws: FlightFile.ReadError.self) { try file.validate() }
        file = winding
        file.keys.insert(.init(at: 1, look: true), at: 1)
        file.keys[0].pace = .nearness
        #expect(throws: FlightFile.ReadError.self) { try file.validate() }
        file = winding
        file.keys[1].pace = .nearness
        #expect(throws: Flight.Failure.noNearness) { try Flight(file, take: take()) }
    }

    @Test func aFlightFileReadsWritesTheSameBytesAndRefusesStrangers() throws {
        var file = winding
        file.near = 0.5
        file.keys[1].aim = .galaxy(1, offset: .zero, disk: false)
        file.keys[2].eye = .galaxy(0, offset: SIMD3(1, 2, 3), disk: true)
        file.keys[3].exposure = -1.5
        let bytes = try file.encoded()
        let read = try FlightFile.decoded(from: bytes)
        #expect(read == file)
        #expect(try read.encoded() == bytes)

        let written = """
            {"version": 1, "keys": [
              {"at": 0, "myr": 200, "eye": [0, -40, 10], "aim": {"galaxy": 0}},
              {"at": 4, "myr": 230, "eye": {"galaxy": 1, "offset": [0, -8, 3], "disk": true}}
            ]}
            """
        let hand = try FlightFile.decoded(from: Data(written.utf8))
        #expect(hand.keys[1].eye == .galaxy(1, offset: SIMD3(0, -8, 3), disk: true))
        #expect(hand.keys[0].aim == .galaxy(0, offset: .zero, disk: false))

        for stray in [
            #"{"version": 1, "keys": [], "speed": 2}"#,
            #"{"version": 1, "keys": [{"at": 0, "myr": 200, "eye": [0, 1, 0], "aim": [0, 0, 0], "zoom": 2}]}"#,
            #"{"version": 1, "keys": [{"at": 0, "myr": 200, "eye": {"galaxy": 0, "offest": [1, 0, 0]}}]}"#,
        ] {
            #expect(throws: DecodingError.self) { try FlightFile.decoded(from: Data(stray.utf8)) }
        }
        for (wrong, because) in [
            (
                #"{"version": 1, "keys": [{"at": 0, "myr": 200, "eye": [0, 1, 0], "aim": [0, 0, 0]}]}"#,
                "two keys at least"
            ),
            (
                #"{"version": 1, "keys": [{"at": 1, "myr": 200, "look": true}, {"at": 2, "myr": 210}]}"#,
                "the first key is at 0 s"
            ),
            (
                #"{"version": 1, "keys": [{"at": 0, "myr": 200, "look": true, "fov": 1}, {"at": 2, "myr": 210}]}"#,
                "key 0 at 0.0 s: a look key takes its eye, aim, fov and roll from the look"
            ),
            (
                #"{"version": 1, "keys": [{"at": 0, "myr": 200, "look": true}, {"at": 2, "myr": 210, "fov": 1}]}"#,
                "key 1 at 2.0 s: fov, roll and exposure go on a key that places the camera"
            ),
            (
                #"{"version": 1, "keys": [{"at": 0, "myr": 200, "look": true}, {"at": 2, "eye": {"galaxy": 0}}, {"at": 3, "myr": 210}]}"#,
                "key 1 at 2.0 s: an eye on a galaxy needs an offset from its centre"
            ),
        ] {
            #expect(throws: FlightFile.ReadError.shape(because)) {
                try FlightFile.decoded(from: Data(wrong.utf8))
            }
        }
        #expect(throws: FlightFile.ReadError.unsupportedVersion(2)) {
            try FlightFile.decoded(from: Data(#"{"version": 2, "keys": []}"#.utf8))
        }
    }
}
