import AppKit
import Combine
import Foundation
import QuartzCore
import SillageCore
import SillageRender
import simd

/// Flying over a take and keeping the flight (#298): the recorder, the waypoints, the scene's
/// flights, and a flight played back on the canvas with the playhead driven by its own time.
///
/// The model draws and this decides what the camera and the playhead are while one of them
/// is going on. It sits beside the model rather than in it, as `SimulationModel` asks of what it
/// owns; what it needs of the canvas it reads from the model, and what it gives back goes through
/// `setPlayhead`, `activeCamera` and `playedShot`.
@MainActor
final class FlightSession: ObservableObject {
    /// Radians of bank for each radian a second of turn, when banking is on.
    static let bankingStrength: Float = 0.35
    /// Published this often at most: the panel is not drawn sixty times a second for a clock.
    static let clockStep = 0.25

    enum Activity: Equatable {
        case idle
        case recording
        case playing
    }

    private unowned let model: SimulationModel

    @Published private(set) var activity = Activity.idle
    /// The scene's flights, as `flights/` holds them.
    @Published private(set) var listings: [FlightListing] = []
    /// What the last thing done came to, or why it did not.
    @Published private(set) var notice: String?
    /// The roll follows the turn (`FlyCamera.banking`).
    @Published var banking: Bool {
        didSet { UserDefaults.standard.set(banking, forKey: Self.bankingKey) }
    }
    @Published private(set) var recordedSeconds = 0.0
    @Published private(set) var waypointCount = 0
    @Published private(set) var waypointSeconds = 0.0
    /// The throttle as the panel reads it.
    @Published private(set) var speedLabel = ""
    @Published private(set) var playingName: String?
    @Published private(set) var playedSeconds = 0.0
    @Published private(set) var playedPaused = false
    private(set) var flightSeconds = 0.0

    private static let bankingKey = "flightBanking"

    private var recorder = FlightRecorder()
    private var recordingStart: CFTimeInterval = 0
    private var waypoints = FlightWaypoints()
    private var player: Player?
    private var saving: Task<Void, Never>?

    private struct Player {
        var name: String
        var flight: Flight
        var seconds: Double
        var paused: Bool
        var shot: ShotReplay.Shot?
    }

    init(model: SimulationModel) {
        self.model = model
        banking = UserDefaults.standard.bool(forKey: Self.bankingKey)
        speedLabel = FlyCamera.describe(speed: model.flight.speed)
        refresh()
    }

    // MARK: What the model asks

    var isRecording: Bool { activity == .recording }
    var isPlaying: Bool { activity == .playing }
    /// Whether the playhead is the flight's, which sets it at every frame.
    var drivesPlayhead: Bool { player != nil }
    /// The camera and the look the canvas draws while a flight plays.
    var playedShot: ShotReplay.Shot? { player?.shot }
    /// What the canvas draws a flight from inside with: the flight's own, or the defaults.
    var insideSettings: InsideSettings { player?.flight.inside ?? InsideSettings() }
    /// A take of a scene is on the canvas: where the flights are kept.
    var canKeep: Bool { model.mode == .playback && model.takeFolder != nil }

    // MARK: The scene's flights

    func refresh() {
        listings = model.takeFolder?.flightListings() ?? []
    }

    /// Another take, or none: nothing recorded, played or set is carried over.
    func reset() {
        recorder = FlightRecorder()
        waypoints.clear()
        player = nil
        activity = .idle
        notice = nil
        recordedSeconds = 0
        waypointCount = 0
        waypointSeconds = 0
        playingName = nil
        playedSeconds = 0
        refresh()
    }

    func rename(_ name: String, to text: String) {
        guard let folder = model.takeFolder else { return }
        guard let new = SceneFolder.flightName(from: text) else {
            notice = "A name is letters, digits, - and _"
            return
        }
        do {
            try folder.renameFlight(name, to: new)
            if playingName == name { playingName = new }
            notice = "\(name) is now \(new)"
        } catch {
            notice = "\(error)"
        }
        refresh()
    }

    /// How a flight leaves the folder: into the Bin, so that one deleted by mistake can be taken
    /// back. The checks put it elsewhere, and leave nothing in the Bin.
    var removal: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }

    func delete(_ name: String) {
        guard let folder = model.takeFolder else { return }
        if playingName == name { takeOver() }
        do {
            try removal(folder.flight(name))
            notice = "\(name) is gone"
        } catch {
            notice = "\(error)"
        }
        refresh()
    }

    // MARK: Recording

    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    /// Records the camera and the playhead's moment as they go, from where the camera is now.
    /// From orbit, the recording starts in free flight, from the view on the canvas.
    func startRecording() {
        guard !isRecording else { return }
        guard canKeep else {
            notice = "A flight is recorded over a take of a scene"
            return
        }
        takeOver()
        if !model.isFlying { model.toggleFlight() }
        recorder = FlightRecorder()
        recordingStart = CACurrentMediaTime()
        recordedSeconds = 0
        activity = .recording
        notice = nil
        sample()
    }

    /// Ends the recording and keeps it: smoothed, thinned and written as the scene's next flight.
    func stopRecording() {
        guard isRecording else { return }
        activity = .idle
        let recorder = self.recorder
        self.recorder = FlightRecorder()
        guard let folder = model.takeFolder, let recording = model.recording else { return }
        let megayears = TimeTrack.megayears(of: recording)
        let rate = model.capturedRate
        notice = "Saving the flight…"
        saving = Task { [weak self] in
            let made: Result<(name: String, file: FlightFile), Error> = await Task.detached {
                do {
                    let file = try recorder.flight(megayears: megayears, capturedRate: rate)
                    let name = folder.nextFlightName()
                    try folder.writeFlight(file, named: name)
                    return .success((name, file))
                } catch {
                    return .failure(error)
                }
            }.value
            guard let self else { return }
            switch made {
            case .success(let kept):
                notice = String(
                    format: "Saved %@: %.1f s, %d keys", kept.name, kept.file.seconds, kept.file.keys.count)
            case .failure(let error):
                notice = "\(error)"
            }
            refresh()
        }
    }

    /// Waits for a recording being saved; the checks use it.
    func saved() async { await saving?.value }

    /// One sample of the camera, taken as every frame is drawn: a recording is of real time, and
    /// the recorder lays it on its grid.
    func sample() {
        guard isRecording else { return }
        guard model.isFlying else {
            stopRecording()
            return
        }
        recorder.append(current())
        if recorder.seconds - recordedSeconds >= Self.clockStep { recordedSeconds = recorder.seconds }
    }

    /// The playhead jumped, a scrub, Restart or the take looping: a flight's time never does,
    /// so the recording ends there, keeping what it has.
    func playheadJumped() {
        guard isRecording else { return }
        notice = "The playhead moved: the recording ended there"
        stopRecording()
    }

    private func current() -> FlightSample {
        let view = model.activeCamera
        func double(_ v: SIMD3<Float>) -> SIMD3<Double> { SIMD3(Double(v.x), Double(v.y), Double(v.z)) }
        return FlightSample(
            seconds: CACurrentMediaTime() - recordingStart, eye: double(view.eye), aim: double(view.target),
            fov: Double(view.fieldOfView), roll: Double(model.flight.roll), myr: model.elapsedMyr,
            nearness: model.nearness)
    }

    // MARK: Waypoints

    /// A key where the camera and the playhead stand, after the last by the distance flown at the
    /// throttle's speed.
    func addWaypoint() {
        guard canKeep else {
            notice = "Keys are set over a take of a scene"
            return
        }
        guard model.isFlying else {
            notice = "Press F to fly, then K adds a key where the camera is"
            return
        }
        do {
            let key = try waypoints.add(current(), speed: Double(model.flight.speed))
            notice = String(format: "Key %d at %.1f s, %.1f Myr", waypoints.count, key.at, key.myr ?? 0)
        } catch {
            notice = "\(error)"
        }
        publishWaypoints()
    }

    func removeLastWaypoint() {
        waypoints.removeLast()
        publishWaypoints()
    }

    func clearWaypoints() {
        waypoints.clear()
        publishWaypoints()
    }

    /// The keys as they are, a flight of their own.
    func saveWaypoints() {
        guard let folder = model.takeFolder else { return }
        do {
            let name = folder.nextFlightName(prefix: "path")
            try folder.writeFlight(try waypoints.file(), named: name)
            notice = String(format: "Saved %@: %d keys, %.1f s", name, waypoints.count, waypoints.seconds)
            waypoints.clear()
            publishWaypoints()
        } catch {
            notice = "\(error)"
        }
        refresh()
    }

    private func publishWaypoints() {
        waypointCount = waypoints.count
        waypointSeconds = waypoints.seconds
    }

    // MARK: The throttle

    func stepThrottle(_ direction: Int) {
        guard model.isFlying else { return }
        model.flight.stepThrottle(direction)
        speedChanged()
    }

    func speedChanged() { speedLabel = FlyCamera.describe(speed: model.flight.speed) }

    // MARK: Playing a flight

    /// Plays a flight on the canvas: the camera its keys give, the playhead where its time puts
    /// the take, as the export draws it.
    func play(_ name: String) {
        guard !isRecording else {
            notice = "Stop the recording first"
            return
        }
        guard let folder = model.takeFolder, let take = model.playedTake else {
            notice = "A flight is played over a take of a scene"
            return
        }
        do {
            let file = try FlightFile.decoded(from: Data(contentsOf: folder.flight(name)))
            let made = try Flight(
                file, take: FlightTake(take: take, capturedRate: model.capturedRate),
                look: { [model] position in
                    model.planShot(atCaptured: position)?.camera ?? model.camera.camera
                })
            player = Player(name: name, flight: made, seconds: 0, paused: false, shot: nil)
            flightSeconds = made.seconds
            playingName = name
            playedSeconds = 0
            playedPaused = false
            activity = .playing
            notice = nil
            model.renderer?.prepareInside()
            advance(seconds: 0)
        } catch {
            notice = "\(name): \(error)"
        }
    }

    func togglePause() {
        guard var current = player else { return }
        current.paused.toggle()
        playedPaused = current.paused
        player = current
    }

    /// Moves a flight being played to `seconds` of it.
    func seek(to seconds: Double) {
        guard var current = player else { return }
        current.seconds = min(max(seconds, 0), current.flight.seconds)
        player = current
        playedSeconds = current.seconds
        advance(seconds: 0)
    }

    /// One frame of the flight being played: its time moves on by the frame's, the playhead is put
    /// where the take is then, and at its end the pilot has the controls.
    func advance(seconds: Double) {
        guard var current = player else { return }
        // A stall is not skipped over.
        if !current.paused { current.seconds += min(seconds, 0.1) }
        let ended = current.seconds >= current.flight.seconds
        if ended { current.seconds = current.flight.seconds }
        current.shot = current.flight.shot(atSeconds: current.seconds, look: model.look)
        model.setPlayhead(captured: current.flight.captured(atSeconds: current.seconds))
        player = current
        if abs(current.seconds - playedSeconds) >= 0.1 || ended { playedSeconds = current.seconds }
        if ended {
            takeOver()
            notice = "The flight ended: the controls are yours"
        }
    }

    /// The pilot takes the controls from a flight on the canvas, where it is: free flight from its
    /// camera, the take's time as it stands.
    func takeOver() {
        guard let current = player else { return }
        player = nil
        activity = .idle
        playingName = nil
        if let shot = current.shot {
            model.flight.adopt(shot.camera)
            model.flight.near = Float(FlightFile.near)
            model.isFlying = true
            model.lastDrawTime = nil
            speedChanged()
        }
    }
}
