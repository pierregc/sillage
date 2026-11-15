import Foundation
import SillageCore

/// The speeds of an automatic pace (#309), and what the sheets and the notes read of them.
public enum PaceTrack {
    public struct Made: Sendable {
        /// One speed for each captured frame, before the track's ramp.
        public var speeds: [Double]
        /// What the pace was read from, as CSV: the curves' activity or the pictures' change.
        public var traceCSV: String
        public var firstPassMyr: Double?
        public var engagedUntilMyr: Double?
    }

    public enum Failure: Error, CustomStringConvertible {
        case noCurves(URL)
        case curvesOutsideTake(URL, curves: ClosedRange<Double>, take: ClosedRange<Double>)

        public var description: String {
            switch self {
            case .noCurves(let folder): "no curves.csv or curves-hires.csv in \(folder.path)"
            case .curvesOutsideTake(let url, let curves, let take):
                String(
                    format: "%@ runs from %.0f to %.0f Myr, the take from %.0f to %.0f",
                    url.lastPathComponent,
                    curves.lowerBound, curves.upperBound, take.lowerBound, take.upperBound)
            }
        }
    }

    /// The curves of the take: the hires run's when there are, else the explore run's, the ones
    /// that start and end where the take does.
    public static func curves(of folder: SceneFolder, megayears: [Double]) throws -> (
        url: URL, samples: [Story.Sample]
    ) {
        let found = [folder.hiresCurves, folder.curves].filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
        guard !found.isEmpty, let first = megayears.first, let last = megayears.last else {
            throw Failure.noCurves(folder.url)
        }
        var best: (url: URL, samples: [Story.Sample], miss: Double)?
        for url in found {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let samples = Story.samples(csv: text)
            guard let start = samples.first?.timeMyr, let end = samples.last?.timeMyr else { continue }
            let miss = abs(start - first) + abs(end - last)
            if best == nil || miss < best!.miss { best = (url, samples, miss) }
        }
        guard let best else { throw Failure.noCurves(folder.url) }
        // A frame or two of difference is the captured frame the curves start a step after.
        guard let start = best.samples.first?.timeMyr, let end = best.samples.last?.timeMyr,
            start - first < 20, first - start < 20, end - last < 20, last - end < 20
        else {
            throw Failure.curvesOutsideTake(
                best.url,
                curves: (best.samples.first?.timeMyr ?? 0)...(best.samples.last?.timeMyr ?? 0),
                take: first...last)
        }
        return (best.url, best.samples)
    }

    public static func story(
        _ settings: StoryPace.Settings, samples: [Story.Sample], story: Story, megayears: [Double]
    ) -> Made {
        let pace = StoryPace(story: story, settings: settings)
        let trace = pace.trace(samples)
        let speeds = pace.speeds(trace, atMyr: megayears)
        var csv = "time_myr,activity,tails,extent,disruption,held,speed\n"
        let each = pace.speeds(trace, atMyr: trace.timeMyr)
        for index in trace.timeMyr.indices {
            csv += String(
                format: "%.3f,%.4f,%.4f,%.4f,%.4f,%d,%.4f\n", trace.timeMyr[index], trace.activity[index],
                trace.tails[index], trace.extent[index], trace.disruption[index],
                trace.held[index] ? 1 : 0, each[index])
        }
        return Made(
            speeds: speeds, traceCSV: csv, firstPassMyr: trace.firstPassMyr,
            engagedUntilMyr: trace.engagedUntilMyr)
    }

    public static func visual(
        _ settings: VisualPace.Settings, times: [Double], changes: [VisualPace.Change],
        megayears: [Double]
    ) -> Made {
        let speeds = VisualPace(settings: settings).speeds(
            changes: changes.map { $0.value(settings.metric) }, times: times, megayears: megayears)
        var csv = "time_myr,all,lit,moving\n"
        for index in changes.indices {
            csv += String(
                format: "%.3f,%.6f,%.6f,%.6f\n", (times[index] + times[index + 1]) / 2,
                changes[index].all, changes[index].lit, changes[index].moving)
        }
        return Made(speeds: speeds, traceCSV: csv, firstPassMyr: nil, engagedUntilMyr: nil)
    }

    /// Every frame of the video along `track` at `framesPerSecond`: where in the take it is.
    public static func videoCSV(_ track: TimeTrack, megayears: [Double], framesPerSecond: Int) -> String {
        var csv = "frame,seconds,captured,time_myr,speed\n"
        for (index, frame) in track.frames(framesPerSecond: framesPerSecond).enumerated() {
            let low = min(max(Int(frame.captured), 0), megayears.count - 1)
            let high = min(low + 1, megayears.count - 1)
            let myr = megayears[low] + (megayears[high] - megayears[low]) * (frame.captured - Double(low))
            csv += String(
                format: "%d,%.4f,%.3f,%.3f,%.4f\n", index, Double(index) / Double(framesPerSecond),
                frame.captured, myr, track.speed(atPlayed: frame.played))
        }
        return csv
    }
}
