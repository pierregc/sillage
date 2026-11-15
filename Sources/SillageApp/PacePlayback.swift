import Foundation
import SillageCore
import SillageRender
import SwiftUI

/// The pace the style editor's playhead can follow (#311): Auto, as an export at Auto draws it,
/// or a track file kept in the scene's `exports/`. It plays the take at the track's speed and
/// gives the transport the speed to draw along the scrubber, against the take's time.
@MainActor
final class PacePlayback: ObservableObject {
    enum Choice: Equatable, Hashable {
        case off
        case auto
        case file(URL)

        var title: String {
            switch self {
            case .off: "Take's own"
            case .auto: "Auto"
            case .file(let url): url.lastPathComponent.replacingOccurrences(of: ".time.json", with: "")
            }
        }
    }

    /// Where along the scrubber, 0 to 1 of the take, and how fast.
    struct Sample: Equatable {
        var at: Double
        var speed: Double
    }

    let model: SimulationModel
    let folder: SceneFolder?
    @Published var choice = Choice.off {
        didSet { if choice != oldValue { apply() } }
    }
    @Published private(set) var samples: [Sample] = []
    @Published private(set) var failure: String?
    /// The take's first and last moments, for the scrubber's ends.
    private(set) var span: ClosedRange<Double>?
    private var track: TimeTrack?

    static let sampleCount = 240

    init(model: SimulationModel, folder: SceneFolder?) {
        self.model = model
        self.folder = folder
    }

    /// The track files of the scene: what an export drew along, or was given by hand.
    var files: [URL] {
        guard let folder else { return [] }
        let names =
            (try? FileManager.default.contentsOfDirectory(atPath: folder.exports.path)) ?? []
        return names.filter { $0.hasSuffix("." + TimeTrackFile.fileExtension) }.sorted().map {
            folder.exports.appendingPathComponent($0)
        }
    }

    var isOn: Bool { track != nil }

    /// The speed at the playhead.
    var speedNow: Double? {
        guard let track, let recording = model.playedTake?.recording else { return nil }
        let captured = recording.capturedPosition(atStored: model.playbackPosition)
        return track.speed(atPlayed: track.played(atCaptured: captured))
    }

    /// Reads the track again, once the take is open and when the choice changes.
    func apply() {
        failure = nil
        track = nil
        samples = []
        model.playbackTrack = nil
        guard choice != .off else { return }
        guard let loaded = model.playedTake, let folder else {
            failure = "The take is not open"
            return
        }
        do {
            let megayears = TimeTrack.megayears(of: loaded.recording)
            let rate = try folder.capturedRate()
            let file: TimeTrackFile
            switch choice {
            case .off: return
            case .auto:
                let read = try PaceTrack.fromCurves(
                    PaceSpec.auto, folder: folder, scene: loaded.scene, megayears: megayears)
                file = TimeTrackFile(speeds: read.made.speeds)
            case .file(let url):
                file = try TimeTrackFile.decoded(from: Data(contentsOf: url))
            }
            let made = try file.track(megayears: megayears, capturedRate: rate)
            track = made
            model.playbackTrack = made
            span = megayears.first.flatMap { first in megayears.last.map { first...$0 } }
            samples = Self.samples(made, recording: loaded.recording)
        } catch {
            failure = "\(error)"
        }
    }

    /// The speed at evenly spaced places along the take, which is what the scrubber spans.
    static func samples(_ track: TimeTrack, recording: Recording) -> [Sample] {
        let last = Double(max(recording.count - 1, 1))
        return (0..<sampleCount).map { index in
            let along = Double(index) / Double(sampleCount - 1)
            let captured = recording.capturedPosition(atStored: along * last)
            return Sample(at: along, speed: track.speed(atPlayed: track.played(atCaptured: captured)))
        }
    }
}

/// The speed along the scrubber: a filled strip on a log scale from x0.25 to x8 with x1 marked,
/// the take's moments at its ends, and the playhead.
struct PaceStrip: View {
    let samples: [PacePlayback.Sample]
    let span: ClosedRange<Double>?
    /// 0 to 1 along the take.
    var playhead: Double?

    static let height: CGFloat = 26
    static let range = 0.25...8.0

    /// 0 at the slowest the strip shows, 1 at the fastest.
    static func level(_ speed: Double) -> Double {
        let low = log(range.lowerBound)
        return min(max((log(max(speed, 1e-3)) - low) / (log(range.upperBound) - low), 0), 1)
    }

    var body: some View {
        VStack(spacing: 2) {
            GeometryReader { geometry in
                let width = geometry.size.width
                let height = geometry.size.height
                ZStack(alignment: .bottomLeading) {
                    Path { path in
                        guard let first = samples.first else { return }
                        path.move(to: CGPoint(x: first.at * width, y: height))
                        for sample in samples {
                            path.addLine(
                                to: CGPoint(
                                    x: sample.at * width, y: height - Self.level(sample.speed) * height))
                        }
                        path.addLine(to: CGPoint(x: (samples.last?.at ?? 1) * width, y: height))
                        path.closeSubpath()
                    }
                    .fill(Color.accentColor.opacity(0.55))
                    Path { path in
                        let y = height - Self.level(1) * height
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: width, y: y))
                    }
                    .stroke(Color(white: 0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    if let playhead {
                        Rectangle().fill(Palette.label).frame(width: 1.5)
                            .offset(x: min(max(playhead, 0), 1) * width - 0.75)
                    }
                }
            }
            .frame(height: Self.height)
            HStack {
                Text(span.map { String(format: "%.0f Myr", $0.lowerBound) } ?? "")
                Spacer()
                Text(Self.legend(samples))
                Spacer()
                Text(span.map { String(format: "%.0f Myr", $0.upperBound) } ?? "")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(Palette.secondary)
        }
    }

    /// "dashed: ×1 · up to ×4.6".
    static func legend(_ samples: [PacePlayback.Sample]) -> String {
        let top = samples.map(\.speed).max() ?? 1
        return String(format: "dashed ×1 · up to ×%.1f", top)
    }
}
