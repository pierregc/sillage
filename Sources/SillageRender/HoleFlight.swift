import Foundation
import SillageCore

/// A camera path round a black hole close up (#335): a `FlightFile` from the scene folder's
/// `flights/`, as for galaxies, whose points are in Schwarzschild radii round the hole and whose
/// keys pin the hole's `time` rather than megayears. Its captured positions are the run's steps,
/// so time runs, slows or holds between keys as #295's flights have it through a take, and each
/// frame lands on a step the run reaches exactly.
public enum HoleFlight {
    public enum Failure: Error, CustomStringConvertible, Equatable {
        case galaxyFlight
        case outsideRun(time: Double, first: Double, last: Double)

        public var description: String {
            switch self {
            case .galaxyFlight:
                "a flight for galaxies: a black hole close up's keys give time, in the hole's units"
            case .outsideRun(let time, let first, let last):
                String(format: "time %g is outside the run, which goes from %.2f to %.2f", time, first, last)
            }
        }
    }

    /// `file` resolved on a take's run. A `look` key takes the look's camera where an export of
    /// the whole run would have it at that moment.
    public static func resolve(
        _ file: FlightFile, header: HoleTakeFile.Header, camera: HoleLookFile.CameraPlan
    ) throws -> Flight {
        guard file.isBlackHole else { throw Failure.galaxyFlight }
        let last = header.steps.last ?? 0
        let times = (0...last).map { header.time(step: $0) }
        let take = FlightTake(
            megayears: times, capturedRate: 30, galaxies: 0, centres: { _ in [] }, disks: { _ in [] })
        do {
            return try Flight(
                file, take: take,
                look: { position in
                    var drawn = camera.camera(progress: last > 0 ? position / Double(last) : 0)
                    drawn.near = Float(file.near ?? FlightFile.near)
                    return drawn
                })
        } catch TimeTrack.Failure.outsideTake(let time, let first, let last) {
            throw Failure.outsideRun(time: time, first: first, last: last)
        }
    }
}

extension HoleFlight {
    /// The three paths `black-hole new` writes in a folder's `flights/` (#335), for the default
    /// scene, whose disk has settled by t 3000 within some 20 r_s; each always looks at the hole.
    ///
    /// - `orbit`: once round the disk at 35 r_s, rising from 8° to 20° above its plane and back,
    ///   over 40 s while the settled disk turns, t 2600 to 3400.
    /// - `descent`: from 300 r_s and 40° down to just over the disk's edge, 24 r_s out and 1.5 above
    ///   its plane, over 40 s and a quarter turn while the story runs from the first return to the
    ///   settled disk, then holds for the last 6 s.
    /// - `plane`: down through the disk 14 r_s from the hole and out below it, 24 s with time
    ///   frozen at t 3000.
    public static var samples: [(name: String, file: FlightFile)] {
        [("orbit", orbit), ("descent", descent), ("plane", plane)]
    }

    static func eye(distance: Double, elevation: Double, azimuth: Double) -> FlightFile.Point {
        let (e, a) = (elevation * .pi / 180, azimuth * .pi / 180)
        return .world(distance * SIMD3(cos(e) * sin(a), -cos(e) * cos(a), sin(e)))
    }

    static let hole = FlightFile.Point.world(.zero)

    static var orbit: FlightFile {
        let count = 16
        let seconds = 40.0
        let keys = (0...count).map { n -> FlightFile.Key in
            let share = Double(n) / Double(count)
            let at = seconds * share
            return FlightFile.Key(
                at: at, time: n == 0 ? 2600 : n == count ? 3400 : nil,
                eye: eye(distance: 35, elevation: 14 - 6 * cos(2 * .pi * share), azimuth: 360 * share),
                aim: hole, fov: n == 0 ? 0.7 : nil)
        }
        return FlightFile(keys: keys)
    }

    static var descent: FlightFile {
        let stops: [(at: Double, distance: Double, elevation: Double, azimuth: Double)] = [
            (0, 300, 40, -30), (8, 160, 32, -24), (16, 90, 22, -16), (24, 52, 12, -8),
            (31, 32, 6, -2), (34, 24.05, 3.6, 0),
        ]
        var keys = stops.map { stop in
            FlightFile.Key(
                at: stop.at, time: stop.at == 0 ? 700 : stop.at == 34 ? 3000 : nil,
                eye: eye(distance: stop.distance, elevation: stop.elevation, azimuth: stop.azimuth),
                aim: hole, fov: stop.at == 0 ? 0.7 : stop.at == 34 ? 0.9 : nil)
        }
        keys.append(FlightFile.Key(at: 40, time: 3000))
        return FlightFile(keys: keys)
    }

    static var plane: FlightFile {
        let points: [(at: Double, eye: SIMD3<Double>)] = [
            (0, SIMD3(-6, -44, 16)), (8, SIMD3(-3, -24, 5)), (12, SIMD3(0, -14, 0)),
            (16, SIMD3(3, -20, -4)), (24, SIMD3(10, -40, -12)),
        ]
        let keys = points.map { point in
            FlightFile.Key(
                at: point.at, time: point.at == 0 || point.at == 24 ? 3000 : nil, eye: .world(point.eye),
                aim: hole, fov: point.at == 0 ? 0.8 : nil)
        }
        return FlightFile(keys: keys)
    }

    /// Writes the samples in `folder`'s `flights/`, leaving any flight already there.
    public static func writeSamples(in folder: SceneFolder) throws {
        try FileManager.default.createDirectory(at: folder.flights, withIntermediateDirectories: true)
        for (name, file) in samples {
            let url = folder.flight(name)
            guard !FileManager.default.fileExists(atPath: url.path) else { continue }
            try (file.encoded() + Data("\n".utf8)).write(to: url, options: .atomic)
        }
    }
}

extension HolePlan {
    /// The frames of a flight at `framesPerSecond`, from its first key to its last, each on the
    /// step nearest the moment the flight has there.
    public init(flight: Flight, framesPerSecond: Int) throws {
        let count = Int((flight.seconds * Double(framesPerSecond)).rounded()) + 1
        guard count >= 1 else { throw Failure.tooShort }
        steps = (0..<count).map { index in
            Int(flight.captured(atSeconds: Double(index) / Double(framesPerSecond)).rounded())
        }
        self.framesPerSecond = framesPerSecond
    }

    /// Seconds into the video of frame `index`.
    public func seconds(_ index: Int) -> Double { Double(index) / Double(framesPerSecond) }
}
