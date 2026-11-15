import Foundation
import SillageCore
import Testing

@testable import SillageRender

@Suite("Time track")
struct TimeTrackTests {
    /// A take of 600 captured frames 0.8 Myr apart, from 300 Myr.
    private let megayears = (0..<600).map { 300 + Double($0) * 0.8 }

    @Test func aConstantTrackOfOneMapsEachVideoFrameToItsCapturedFrame() throws {
        let track = try TimeTrack(capturedFrames: 600, capturedRate: 30)
        #expect(track.isIdentity && track.length == 599)
        #expect(track.table(framesPerSecond: 30) == (0..<600).map(Double.init))
        let integrated = try TimeTrack(speeds: Array(repeating: 1, count: 600), capturedRate: 30)
        #expect(integrated.isIdentity)
        #expect(integrated.table(framesPerSecond: 30) == (0..<600).map(Double.init))
        #expect(
            integrated.frames(framesPerSecond: 30, start: 2, duration: 0.1).map(\.captured) == [60, 61, 62])
    }

    @Test func twiceTheSpeedShowsEveryOtherCapturedFrame() throws {
        let track = try TimeTrack(capturedFrames: 601, capturedRate: 30, speed: 2)
        #expect(track.length == 300 && abs(track.seconds - 10) < 1e-12)
        #expect(track.table(framesPerSecond: 30) == (0...300).map { Double($0 * 2) })
        #expect(track.played(atCaptured: 37) == 18.5)
        #expect(throws: TimeTrack.Failure.speed(20)) {
            try TimeTrack(capturedFrames: 10, capturedRate: 30, speed: 20)
        }
    }

    private func keyed(_ keys: [TimeTrack.SpeedKey], ramp: Double = 3) throws -> TimeTrack {
        try TimeTrack(keys: keys, megayears: megayears, capturedRate: 30, ramp: ramp)
    }

    private var demo: [TimeTrack.SpeedKey] {
        [
            .init(myr: 300, speed: 1), .init(myr: 420, speed: 0.5), .init(myr: 460, speed: 1),
            .init(myr: 560, speed: 4),
        ]
    }

    /// 1.5 s a doubling when a file says nothing (#311); 0 still means none.
    @Test func aFileWithoutARampReadsWithTheDefaultOne() throws {
        #expect(TimeTrack.defaultRamp == 1.5)
        let speeds = (0..<600).map { $0 < 300 ? 1.0 : 4.0 }
        let plain = try TimeTrackFile(speeds: speeds).track(megayears: megayears, capturedRate: 30)
        let explicit = try TimeTrackFile(ramp: 1.5, speeds: speeds).track(
            megayears: megayears, capturedRate: 30)
        let none = try TimeTrackFile(ramp: 0, speeds: speeds).track(megayears: megayears, capturedRate: 30)
        let slow = try TimeTrackFile(ramp: 3, speeds: speeds).track(megayears: megayears, capturedRate: 30)
        #expect(plain == explicit && plain != none && plain != slow)
        // A doubling in 1.5 s: the step from 1x to 4x takes 3 s, and it starts before the jump.
        #expect(plain.speed(atPlayed: plain.played(atCaptured: 299)) < 4)
        #expect(none.seconds < plain.seconds && plain.seconds < slow.seconds)
        #expect(try TimeTrackFile.decoded(from: Data(#"{"version": 1, "speeds": [1, 2]}"#.utf8)).ramp == nil)
    }

    @Test func aTrackNeverRunsBackwards() throws {
        let tracks = [
            try keyed(demo),
            try keyed(demo, ramp: 0),
            try TimeTrack(
                times: [
                    .init(at: 0, myr: 300), .init(at: 4, myr: 400), .init(at: 6, myr: 400),
                    .init(at: 7, myr: 410), .init(at: 12, myr: 779.2),
                ], megayears: megayears, capturedRate: 30),
        ]
        for track in tracks {
            let table = track.table(framesPerSecond: 60)
            #expect(zip(table, table.dropFirst()).allSatisfy { $0 <= $1 })
            #expect(table.first == 0 && abs((table.last ?? 0) - 599) <= 2)
        }
    }

    /// Between two video frames the speed changes by no more than a doubling over `ramp`
    /// seconds, a slow stretch is at its speed from its first moment, and the speed picks up
    /// only after a slow stretch ends.
    @Test func theRampBoundHolds() throws {
        for ramp in [1.0, 3, 6] {
            let track = try keyed(demo, ramp: ramp)
            let fps = 30
            let frames = track.frames(framesPerSecond: fps)
            let speeds = frames.map { track.speed(atPlayed: $0.played) }
            let allowed = log(2) / ramp / Double(fps)
            for (a, b) in zip(speeds, speeds.dropFirst()) {
                #expect(abs(log(b / a)) <= allowed * (1 + 1e-9), "ramp \(ramp): \(a) to \(b)")
            }
            for frame in frames {
                let myr = 300 + frame.captured * 0.8
                let speed = track.speed(atPlayed: frame.played)
                if myr >= 420, myr < 460 { #expect(abs(speed - 0.5) < 1e-9) }
                if myr < 460 { #expect(speed <= 1 + 1e-9) }
            }
            #expect((speeds.max() ?? 0) <= 4 + 1e-9)
            if ramp == 1 { #expect(abs((speeds.max() ?? 0) - 4) < 1e-9) }
        }
        let video = try keyed(demo).seconds
        #expect(video > 599.0 / 30 / 4 && video < 599.0 / 30)
    }

    @Test func keysOutsideTheTakeAreRefusedWithItsSpan() throws {
        do {
            _ = try keyed([.init(myr: 900, speed: 2)])
            Issue.record("a key after the take was taken")
        } catch {
            let message = String(describing: error)
            #expect(message.contains("900") && message.contains("300.000") && message.contains("779.200"))
        }
        #expect(throws: TimeTrack.Failure.self) {
            try TimeTrack(
                times: [.init(at: 0, myr: 250), .init(at: 2, myr: 400)], megayears: megayears,
                capturedRate: 30)
        }
        #expect(throws: TimeTrack.Failure.self) {
            try TimeTrack(
                times: [.init(at: 0, myr: 400), .init(at: 2, myr: 350)], megayears: megayears,
                capturedRate: 30)
        }
        #expect(throws: TimeTrack.Failure.self) {
            try keyed([.init(myr: 500, speed: 2), .init(myr: 400, speed: 1)])
        }
    }

    /// #295's keys: the track passes through each, and two keys at the same moment hold it.
    @Test func timeKeysPassThroughTheirMomentsAndFreezeBetweenEqualOnes() throws {
        let keys: [TimeTrack.TimeKey] = [
            .init(at: 0, myr: 300), .init(at: 4, myr: 400), .init(at: 6, myr: 400),
            .init(at: 10, myr: 600),
        ]
        let track = try TimeTrack(times: keys, megayears: megayears, capturedRate: 30)
        #expect(abs(track.seconds - 10) < 1e-12)
        for key in keys {
            #expect(abs(track.captured(atPlayed: key.at * 30) - (key.myr - 300) / 0.8) < 1e-9)
        }
        for second in stride(from: 4.0, through: 6, by: 0.25) {
            #expect(track.captured(atPlayed: second * 30) == 125)
            #expect(track.speed(atPlayed: second * 30) < 1e-4)
        }
        #expect(abs(track.played(atCaptured: 125) - 120) < 1e-5)
    }

    @Test func aTrackFileReadsWritesTheSameBytesAndRefusesAnUnknownField() throws {
        let files = [
            TimeTrackFile(speed: 2),
            TimeTrackFile(ramp: 4, keys: [.init(myr: 300, speed: 1), .init(myr: 560.5, speed: 4)]),
            TimeTrackFile(speeds: [1, 1.5, 2.25]),
            TimeTrackFile(times: [.init(at: 0, myr: 300), .init(at: 12.5, myr: 700)]),
        ]
        for file in files {
            let bytes = try file.encoded()
            let read = try TimeTrackFile.decoded(from: bytes)
            #expect(read == file)
            #expect(try read.encoded() == bytes)
        }
        let text = """
            {
              "keys" : [
                {
                  "myr" : 300,
                  "speed" : 1
                },
                {
                  "myr" : 560.5,
                  "speed" : 4
                }
              ],
              "ramp" : 3,
              "version" : 1
            }
            """
        #expect(
            String(decoding: try TimeTrackFile.decoded(from: Data(text.utf8)).encoded(), as: UTF8.self)
                == text)
        for wrong in [
            #"{"version": 1, "speed": 2, "pace": 1}"#,
            #"{"version": 1, "keys": [{"myr": 300, "speed": 1, "ease": 2}]}"#,
            #"{"version": 1, "speed": 2, "keys": [{"myr": 300, "speed": 1}]}"#,
            #"{"version": 1}"#,
            #"{"version": 2, "speed": 2}"#,
            #"{"version": 1, "speed": 2, "ramp": 1}"#,
        ] {
            #expect(throws: (any Error).self, "\(wrong)") {
                try TimeTrackFile.decoded(from: Data(wrong.utf8))
            }
        }
        #expect(throws: TimeTrack.Failure.frames(given: 3, take: 600)) {
            try TimeTrackFile(speeds: [1, 1, 1]).track(megayears: megayears, capturedRate: 30)
        }
    }

    /// The director plans on the take resampled at the played frames: the centres between two
    /// captured frames lie between theirs.
    @Test func aResampledPlanTrackReadsBetweenCapturedFrames() {
        let track = ShotPlan.Track(
            centres: [[SIMD3(0, 0, 0)], [SIMD3(2, 0, 0)], [SIMD3(4, 0, 0)]],
            disruption: [[0], [0.2], [1]], reach: [5], margin: [5], particles: [10],
            natal: [SIMD3(0, 0, 1)])
        let resampled = track.resampled(at: [0, 0.5, 1.75, 2, 3])
        #expect(resampled.centres.map { $0[0].x } == [0, 1, 3.5, 4, 4])
        #expect(resampled.disruption.map { $0[0] } == [0, 0.2, 1, 1, 1])
    }

    /// Where each frame of a full pass's videos falls in its run (#310): on a captured frame, on
    /// a step inside one, or between two steps.
    @Test func eachFrameOfAFullPassFallsOnAStepOrBetweenTwo() {
        // Captured frame k stands (k + 1) frames of steps past the settle.
        #expect(FullPassRun.place(captured: 0, stepsPerFrame: 8) == .init(frame: 0, step: 8, fraction: 0))
        #expect(FullPassRun.place(captured: 5, stepsPerFrame: 8) == .init(frame: 5, step: 8, fraction: 0))
        #expect(FullPassRun.place(captured: 5.5, stepsPerFrame: 8) == .init(frame: 6, step: 4, fraction: 0))
        let between = FullPassRun.place(captured: 5.3, stepsPerFrame: 8)
        #expect(between.frame == 6 && between.step == 2 && abs(between.fraction - 0.4) < 1e-9)
        let one = FullPassRun.place(captured: 2.25, stepsPerFrame: 1)
        #expect(one.frame == 3 && one.step == 0 && abs(one.fraction - 0.25) < 1e-9)
        // A rounding away from a step is that step.
        #expect(
            FullPassRun.place(captured: 6 - 1e-12, stepsPerFrame: 8) == .init(frame: 6, step: 8, fraction: 0))
        #expect(
            FullPassRun.place(captured: 6 + 1e-12, stepsPerFrame: 8) == .init(frame: 6, step: 8, fraction: 0))

        let plain = FullPassRun.videoFrames(track: nil, frames: 5, framesPerSecond: 30)
        #expect(plain.map(\.captured) == [0, 1, 2, 3, 4] && plain.map(\.played) == [0, 1, 2, 3, 4])
        let doubled = try? TimeTrack(capturedFrames: 9, capturedRate: 30, speed: 2)
        let fast = FullPassRun.videoFrames(track: doubled, frames: 9, framesPerSecond: 30)
        #expect(fast.map { $0.captured.rounded() } == [0, 2, 4, 6, 8])
        // A run shorter than its take draws the frames it reaches.
        #expect(FullPassRun.videoFrames(track: doubled, frames: 6, framesPerSecond: 30).count == 3)
    }
}
