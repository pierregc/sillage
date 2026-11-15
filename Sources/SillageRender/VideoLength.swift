import Foundation
import SillageCore

/// How long a video is along the `--speed` it is asked, which the queue's and a night's
/// estimates need before anything is drawn (#311): the share of the take's frames it keeps.
public enum VideoLength {
    /// The video's frames over the take's, from `speed` as `export --speed` reads it: nothing or
    /// `1`, a number, `auto` or another pace, or a track file. A pace is read off the scene's
    /// curves when they are there, else its expected share; a track file whose length depends
    /// on the take's moments is read against the hires record's, else counts as 1.
    public static func share(of speed: String?, folder: SceneFolder) -> Double {
        guard let speed, speed != "1" else { return 1 }
        if let value = Double(speed) { return TimeTrack.speeds.contains(value) ? 1 / value : 1 }
        guard let frames = takeFrames(folder), frames > 1 else {
            return PaceSpec(speed) == nil ? 1 : PaceSpec.expectedShare
        }
        let rate = (try? folder.capturedRate()) ?? 30
        if let spec = PaceSpec(speed) {
            return cache.value(folder: folder, speed: speed) {
                paced(spec, folder: folder, frames: frames, rate: rate) ?? PaceSpec.expectedShare
            }
        }
        return cache.value(folder: folder, speed: speed) {
            kept(file: speed, folder: folder, frames: frames, rate: rate) ?? 1
        }
    }

    /// The frames of the whole take the scene keeps: the hires run's, else the clip's.
    public static func takeFrames(_ folder: SceneFolder) -> Int? {
        folder.storedHires()?.frames ?? (try? folder.storedClip())?.frames
    }

    /// The moments of the take's captured frames when the take itself is not open: evenly spaced
    /// between the hires run's ends, else the curves' own.
    static func megayears(_ folder: SceneFolder, frames: Int) -> [Double]? {
        if let hires = folder.storedHires(), hires.frames > 1, hires.clipEndMyr > hires.clipStartMyr {
            let span = hires.clipEndMyr - hires.clipStartMyr
            return (0..<hires.frames).map {
                hires.clipStartMyr + span * Double($0) / Double(hires.frames - 1)
            }
        }
        guard let text = try? String(contentsOf: folder.curves, encoding: .utf8) else { return nil }
        let times = Story.samples(csv: text).map(\.timeMyr)
        return times.count > 1 ? times : nil
    }

    private static func paced(_ spec: PaceSpec, folder: SceneFolder, frames: Int, rate: Int) -> Double? {
        guard let megayears = megayears(folder, frames: frames),
            let file = try? SceneFile.decoded(from: Data(contentsOf: folder.scene)),
            let particles = (try? folder.storedClip())?.particles,
            let made = try? PaceTrack.fromCurves(
                spec, folder: folder, scene: file.scene(particleCount: particles), megayears: megayears)
        else { return nil }
        return share(speeds: made.made.speeds, rate: rate)
    }

    private static func kept(file: String, folder: SceneFolder, frames: Int, rate: Int) -> Double? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: file)),
            let track = try? TimeTrackFile.decoded(from: data)
        else { return nil }
        if let speeds = track.speeds { return share(speeds: speeds, rate: rate, ramp: track.ramp) }
        if let times = track.times, let last = times.last {
            return min(last.at * Double(rate) / Double(frames - 1), 1e3)
        }
        guard let megayears = megayears(folder, frames: frames),
            let made = try? track.track(megayears: megayears, capturedRate: rate)
        else { return nil }
        return made.length / Double(max(made.capturedFrames - 1, 1))
    }

    private static func share(speeds: [Double], rate: Int, ramp: Double? = nil) -> Double? {
        guard speeds.count > 1,
            let track = try? TimeTrack(
                speeds: speeds, capturedRate: rate, ramp: ramp ?? TimeTrack.defaultRamp)
        else { return nil }
        return track.length / Double(speeds.count - 1)
    }

    /// Read from the curves and the files again only when they change: a sheet asks for every
    /// card at every redraw.
    private static let cache = Cache()

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var shares: [String: Double] = [:]

        func value(folder: SceneFolder, speed: String, make: () -> Double) -> Double {
            let key = [folder.url.path, speed, stamp(folder.hiresCurves), stamp(folder.curves), stamp(speed)]
                .joined(separator: "|")
            lock.lock()
            defer { lock.unlock() }
            if let known = shares[key] { return known }
            let made = make()
            shares[key] = made
            return made
        }

        private func stamp(_ url: URL) -> String { stamp(url.path) }

        private func stamp(_ path: String) -> String {
            let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            return date.map { String($0.timeIntervalSince1970) } ?? ""
        }
    }
}
