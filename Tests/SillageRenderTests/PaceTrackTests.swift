import Foundation
import SillageCore
import Testing

@testable import SillageRender

@Suite("Pace track")
struct PaceTrackTests {
    private let megayears = (0..<300).map { 100 + Double($0) * 0.8 }

    @Test func aVisualPaceGivesATrackWhoseVideoIsShorterThanTheTake() throws {
        let times = (0...300).map { 100 + Double($0) * 0.8 }
        let changes = (0..<300).map { VisualPace.Change(lit: $0 < 100 ? 0.08 : 0.01) }
        let made = PaceTrack.visual(
            VisualPace.Settings(), times: times, changes: changes, megayears: megayears)
        #expect(made.speeds.count == 300)
        #expect(made.traceCSV.split(separator: "\n").count == 301)
        let track = try TimeTrackFile(speeds: made.speeds).track(megayears: megayears, capturedRate: 30)
        #expect(track.seconds < Double(299) / 30)
        let csv = PaceTrack.videoCSV(track, megayears: megayears, framesPerSecond: 30)
        let last = try #require(csv.split(separator: "\n").last)
        // The video ends at the take's last moment.
        let myr = try #require(Double(last.split(separator: ",")[3]))
        #expect(myr > 330)
        #expect(csv.hasPrefix("frame,seconds,captured,time_myr,speed\n0,0.0000,0.000,100.000,"))
    }

    @Test func aSlowedStretchIsLongerInTheVideo() throws {
        let fast = Array(repeating: 4.0, count: 300)
        let slowed = PaceSpec.slowed(fast, megayears: megayears, from: 150, to: 200, speed: 0.5)
        let plain = try TimeTrack(speeds: fast, capturedRate: 30)
        let slow = try TimeTrack(speeds: slowed, capturedRate: 30)
        #expect(slow.seconds > plain.seconds + 1)
    }
}
