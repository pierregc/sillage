import Foundation
import SillageCore
import Testing

@testable import SillageRender

#if canImport(simd)
    import simd
#endif

@Suite("Recording a flight")
struct FlightRecorderTests {
    /// 601 captured frames a megayear apart, at 30 a second.
    private let megayears = (0...600).map(Double.init)

    /// The camera at `t` seconds: a kiloparsec a second along x, the view turning when `curvy`.
    private func camera(_ t: Double, curvy: Bool) -> (eye: SIMD3<Double>, aim: SIMD3<Double>) {
        let eye = SIMD3(t, -50 + (curvy ? 4 * sin(2 * t) : 0), 5)
        let angle = curvy ? 0.5 * sin(t) : 0
        return (eye, eye + SIMD3(sin(angle), cos(angle), 0) * 10)
    }

    /// Time runs at 30 Myr a second to 3 s, stands at 190 Myr until 5 s, runs on from there.
    private func moment(_ t: Double) -> Double {
        t < 3 ? 100 + 30 * t : t < 5 ? 190 : 190 + 30 * (t - 5)
    }

    private func recording(
        seconds: Double = 8, curvy: Bool = false, nearness: Double? = nil,
        myr: (Double) -> Double? = { _ in nil }
    ) -> FlightRecorder {
        var recorder = FlightRecorder()
        // 60 a second, as the canvas draws.
        for n in 0...Int(seconds * 60) {
            let t = Double(n) / 60
            let (eye, aim) = camera(t, curvy: curvy)
            recorder.append(
                FlightSample(
                    seconds: t, eye: eye, aim: aim, fov: 0.6, roll: 0, myr: myr(t) ?? moment(t),
                    nearness: nearness))
        }
        return recorder
    }

    private func double(_ v: SIMD3<Float>) -> SIMD3<Double> { SIMD3(Double(v.x), Double(v.y), Double(v.z)) }

    private func make(_ recorder: FlightRecorder) throws -> (file: FlightFile, flight: Flight) {
        let file = try recorder.flight(megayears: megayears, capturedRate: 30)
        let take = FlightTake(
            megayears: megayears, capturedRate: 30, galaxies: 0, centres: { _ in [] }, disks: { _ in [] })
        return (file, try Flight(file, take: take))
    }

    @Test func aFreezeInTheRecordingIsAFreezeInTheFlight() throws {
        let (file, flight) = try make(recording())
        try file.validate()
        #expect(file.keys.first?.at == 0)
        #expect((file.keys.last?.at ?? 0) > 7.9)
        // Two keys at one moment hold time between them, exactly.
        let held = zip(file.keys, file.keys.dropFirst()).filter { $0.myr == $1.myr && $0.myr == 190 }
        #expect(held.count >= 1)
        for key in file.keys where key.at > 3.1 && key.at < 4.9 { #expect(key.myr == 190, "\(key.at) s") }
        for s in stride(from: 3.1, through: 4.9, by: 0.1) {
            #expect(abs(flight.captured(atSeconds: s) - 190) < 1e-9, "\(s) s")
        }
        // And either side of it time runs as it did.
        for s in [0.5, 1.5, 2.5, 5.5, 6.5, 7.5] {
            #expect(abs(flight.captured(atSeconds: s) - moment(s)) < 0.3, "\(s) s")
        }
    }

    /// What the flight gives back is the smoothed recording, within the tolerance; the raw
    /// path of a bend is a little further than that, which is what smoothing is for.
    @Test func theFlightGivesTheSmoothedRecordingBackWithinTheTolerance() throws {
        for curvy in [false, true] {
            let recorder = recording(curvy: curvy)
            let (_, flight) = try make(recorder)
            let grid = try recorder.smoothed(.init(), megayears: megayears)
            for sample in grid where sample.seconds > 0.2 && sample.seconds < 7.8 {
                let made = flight.camera(atSeconds: sample.seconds).camera
                let drawn = (double(made.eye), double(made.target))
                // Ten kiloparsecs from the aim, so half a percent of that.
                #expect(simd_length(drawn.0 - sample.eye) < 0.06, "\(sample.seconds) s, curvy \(curvy)")
                let a = simd_normalize(sample.aim - sample.eye)
                let b = simd_normalize(drawn.1 - drawn.0)
                #expect(acos(min(simd_dot(a, b), 1)) < 0.003, "\(sample.seconds) s, curvy \(curvy)")
            }
            // And the raw path is within a few hundredths of it.
            for s in stride(from: 0.4, through: 7.6, by: 0.37) {
                let (eye, _) = camera(s, curvy: curvy)
                let made = flight.camera(atSeconds: s).camera
                #expect(simd_length(double(made.eye) - eye) < 0.15, "\(s) s, curvy \(curvy)")
            }
        }
    }

    @Test func aStraightPathNeedsAKeyASecondAndABentOneMore() throws {
        let straight = try make(recording()).file.keys.count
        let bent = try make(recording(curvy: true)).file.keys.count
        // A second apart at most, the freeze's two ends and the first and last on top of that.
        #expect(straight <= 8 + 8)
        #expect(bent > straight)
        // Never closer than the shortest the settings allow.
        let keys = try make(recording(curvy: true)).file.keys
        for (a, b) in zip(keys, keys.dropFirst()) { #expect(b.at - a.at >= 0.099, "\(a.at) s") }
    }

    @Test func theToleranceIsAShareOfTheDistanceToMatter() throws {
        let far = try make(recording(curvy: true, nearness: 500)).file.keys.count
        let near = try make(recording(curvy: true, nearness: 0.01)).file.keys.count
        #expect(near > far)
    }

    @Test func smoothingTurnsAHardStopIntoARamp() {
        // A kiloparsec a second to 2 s, then standing still.
        let grid = (0..<121).map { n -> FlightSample in
            let t = Double(n) / 30
            let x = min(t, 2)
            return FlightSample(
                seconds: t, eye: SIMD3(x, 0, 0), aim: SIMD3(x, 10, 0), fov: 0.6, roll: 0, myr: 100)
        }
        let smooth = FlightRecorder.smooth(grid, width: 0.5, rate: 30)
        // Far from the corner nothing moves, at it the speed falls over a quarter second each side.
        #expect(abs(smooth[30].eye.x - 1) < 1e-9)
        #expect(abs(smooth[100].eye.x - 2) < 1e-9)
        func speed(_ s: [FlightSample], _ n: Int) -> Double { (s[n + 1].eye.x - s[n].eye.x) * 30 }
        #expect(abs(speed(grid, 59) - 1) < 1e-9 && abs(speed(grid, 60)) < 1e-9)
        #expect(speed(smooth, 56) < 1 && speed(smooth, 56) > 0.6)
        #expect(speed(smooth, 64) > 0 && speed(smooth, 64) < 0.4)
        // Which never goes past the corner.
        #expect(smooth.allSatisfy { $0.eye.x <= 2 + 1e-12 })
        // Moments are left as they were.
        #expect(smooth.allSatisfy { $0.myr == 100 })
    }

    @Test func aRecordingTooShortToSmoothIsRefused() {
        var recorder = FlightRecorder()
        recorder.append(
            FlightSample(seconds: 0, eye: .zero, aim: SIMD3(0, 1, 0), fov: 0.6, roll: 0, myr: 100))
        recorder.append(
            FlightSample(seconds: 0.03, eye: .zero, aim: SIMD3(0, 1, 0), fov: 0.6, roll: 0, myr: 100))
        #expect(throws: FlightRecorder.Failure.self) {
            try recorder.flight(megayears: (0...600).map(Double.init), capturedRate: 30)
        }
    }

    @Test func aRecordedFlightReadsBackAsItWasWritten() throws {
        let (file, _) = try make(recording(curvy: true))
        let again = try FlightFile.decoded(from: file.encoded())
        #expect(again == file)
    }

    @Test func aPlayheadThatRanBackIsHeldRatherThanWrittenBackwards() throws {
        // Noise in the moment, as a float sum leaves: the flight's time still never runs back.
        let (file, _) = try make(
            recording(myr: { 100 + 30 * $0 + ($0 * 977).truncatingRemainder(dividingBy: 1e-4) }))
        let moments = file.keys.compactMap(\.myr)
        #expect(zip(moments, moments.dropFirst()).allSatisfy { $0 <= $1 })
    }
}

@Suite("Waypoints")
struct FlightWaypointTests {
    private func sample(_ eye: SIMD3<Double>, myr: Double, turn: Double = 0) -> FlightSample {
        FlightSample(
            seconds: 0, eye: eye, aim: eye + SIMD3(sin(turn), cos(turn), 0), fov: 0.6, roll: 0, myr: myr)
    }

    @Test func eachKeyComesAfterTheLastByTheDistanceAtTheSpeed() throws {
        var path = FlightWaypoints()
        try path.add(sample(SIMD3(0, 0, 0), myr: 300), speed: 20)
        try path.add(sample(SIMD3(60, 0, 0), myr: 300), speed: 20)
        try path.add(sample(SIMD3(60, 100, 0), myr: 320), speed: 50)
        #expect(path.keys.map(\.at) == [0, 3, 5])
        #expect(path.keys.map(\.myr) == [300, 300, 320])
        #expect(path.seconds == 5)
    }

    @Test func aKeyNeverComesCloserThanHalfASecondAndATurnTakesItsTime() throws {
        var path = FlightWaypoints()
        try path.add(sample(.zero, myr: 300), speed: 1000)
        try path.add(sample(SIMD3(1, 0, 0), myr: 300), speed: 1000)
        #expect(path.keys[1].at == 0.5)
        // A quarter turn in place at 0.8 rad a second.
        try path.add(sample(SIMD3(1, 0, 0), myr: 300, turn: .pi / 2), speed: 1000)
        let expected = 0.5 + (.pi / 2 - 0) / 0.8
        #expect(abs(path.keys[2].at - (expected * 1000).rounded() / 1000) < 2e-3)
    }

    @Test func timeCannotRunBackwardsFromOneKeyToTheNext() throws {
        var path = FlightWaypoints()
        try path.add(sample(.zero, myr: 400), speed: 10)
        #expect(throws: FlightWaypoints.Failure.self) {
            try path.add(sample(SIMD3(10, 0, 0), myr: 300), speed: 10)
        }
        #expect(path.count == 1)
    }

    @Test func thePathIsAFlightOnceItHasTwoKeys() throws {
        var path = FlightWaypoints()
        try path.add(sample(.zero, myr: 100), speed: 10)
        #expect(throws: FlightFile.ReadError.self) { try path.file() }
        try path.add(sample(SIMD3(20, 0, 0), myr: 100), speed: 10)
        let file = try path.file()
        let take = FlightTake(
            megayears: (0...600).map(Double.init), capturedRate: 30, galaxies: 0, centres: { _ in [] },
            disks: { _ in [] })
        let flight = try Flight(file, take: take)
        #expect(flight.seconds == 2)
        #expect(flight.captured(atSeconds: 1) == 100)
    }
}

@Suite("A scene's flights")
struct FlightFolderTests {
    private func folder() throws -> SceneFolder {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flights-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return SceneFolder(url)
    }

    private var file: FlightFile {
        FlightFile(keys: [
            .init(at: 0, myr: 100, eye: .world(SIMD3(0, -50, 0)), aim: .world(.zero)),
            .init(at: 4, myr: 130, eye: .world(SIMD3(0, -20, 0))),
        ])
    }

    @Test func aNameIsMadeSafeForACommandLine() {
        #expect(SceneFolder.flightName(from: " first dive ") == "first-dive")
        #expect(SceneFolder.flightName(from: "dive/../x.json") == "divexjson")
        #expect(SceneFolder.flightName(from: "  ") == nil)
        #expect(SceneFolder.flightName(from: "../") == nil)
    }

    @Test func flightsAreWrittenListedRenamedAndNumbered() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder.url) }
        #expect(folder.flightNames().isEmpty)
        #expect(folder.nextFlightName() == "flight-1")
        try folder.writeFlight(file, named: "flight-1")
        try folder.writeFlight(file, named: "flight-10")
        try folder.writeFlight(file, named: "flight-2")
        #expect(folder.flightNames() == ["flight-1", "flight-2", "flight-10"])
        #expect(folder.nextFlightName() == "flight-3")
        let listing = try #require(folder.flightListings().first)
        #expect(listing.seconds == 4 && listing.keys == 2 && listing.fault == nil)

        // A name taken is refused unless asked to replace it.
        #expect(throws: SceneFolder.FlightError.exists("flight-1")) {
            try folder.writeFlight(file, named: "flight-1")
        }
        try folder.writeFlight(file, named: "flight-1", replacing: true)
        try folder.renameFlight("flight-1", to: "dive")
        #expect(folder.flightNames().contains("dive") && !folder.flightNames().contains("flight-1"))
        #expect(throws: SceneFolder.FlightError.exists("flight-2")) {
            try folder.renameFlight("dive", to: "flight-2")
        }
        #expect(throws: SceneFolder.FlightError.badName("a b")) { try folder.renameFlight("dive", to: "a b") }
        #expect(throws: SceneFolder.FlightError.missing("nothing")) {
            try folder.renameFlight("nothing", to: "x")
        }
        // The file `export --flight` is given is the one written.
        let read = try FlightFile.decoded(from: Data(contentsOf: folder.flight("dive")))
        #expect(read == file)
    }

    @Test func aFileThatCannotBeReadIsListedWithItsFault() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder.url) }
        try FileManager.default.createDirectory(at: folder.flights, withIntermediateDirectories: true)
        try Data("{\"version\": 9, \"keys\": []}".utf8).write(to: folder.flight("odd"))
        let listing = try #require(folder.flightListings().first)
        #expect(listing.name == "odd" && listing.seconds == nil && listing.fault != nil)
    }
}

@Suite("Piloting")
struct PilotingTests {
    private func holding(turn: SIMD2<Float> = .zero) -> FlyCamera.Demand {
        var demand = FlyCamera.Demand()
        demand.turn = turn
        return demand
    }

    @Test func bankingLeansIntoATurnAndLevelsAgain() {
        var camera = FlyCamera(position: .zero)
        camera.banking = 0.35
        // A turn to the right, which yaw counts up: the camera leans right, a negative roll.
        for _ in 0..<90 { camera.advance(holding(turn: SIMD2(1.4, 0)), seconds: 1.0 / 60) }
        #expect(camera.yaw > 0)
        #expect(camera.roll < -0.3 && camera.roll >= -FlyCamera.bankLimit)
        for _ in 0..<300 { camera.advance(holding(), seconds: 1.0 / 60) }
        #expect(abs(camera.roll) < 1e-5)
        // The other way.
        for _ in 0..<90 { camera.advance(holding(turn: SIMD2(-1.4, 0)), seconds: 1.0 / 60) }
        #expect(camera.roll > 0.3)
    }

    @Test func withoutBankingTheCameraStaysLevel() {
        var camera = FlyCamera(position: .zero)
        for _ in 0..<120 { camera.advance(holding(turn: SIMD2(1.4, 0)), seconds: 1.0 / 60) }
        #expect(camera.roll == 0)
        #expect(camera.camera.up == SIMD3<Float>(0, 0, 1))
    }

    /// The roll the camera holds is the roll a flight key writes: its up vector is what
    /// `Flight` would draw for it.
    @Test func theCamerasUpVectorIsTheOneAFlightDrawsForItsRoll() throws {
        var camera = FlyCamera(position: SIMD3(0, -10, 2), yaw: 0.4, pitch: -0.2)
        camera.banking = 0.35
        for _ in 0..<60 { camera.advance(holding(turn: SIMD2(1.4, 0)), seconds: 1.0 / 60) }
        let view = camera.camera
        let file = FlightFile(keys: [
            .init(
                at: 0, myr: 100,
                eye: .world(SIMD3(Double(view.eye.x), Double(view.eye.y), Double(view.eye.z))),
                aim: .world(SIMD3(Double(view.target.x), Double(view.target.y), Double(view.target.z))),
                roll: Double(camera.roll)),
            .init(at: 1, myr: 100),
        ])
        let take = FlightTake(
            megayears: [100, 200], capturedRate: 30, galaxies: 0, centres: { _ in [] }, disks: { _ in [] })
        let drawn = try Flight(file, take: take).camera(atSeconds: 0).camera
        #expect(simd_length(drawn.up - view.up) < 1e-4)
        // And a camera adopted from that one keeps the roll.
        var adopted = FlyCamera()
        adopted.adopt(drawn)
        #expect(abs(adopted.roll - camera.roll) < 1e-4)
    }

    @Test func theThrottleStepsDownToAFewParsecsASecond() {
        var camera = FlyCamera()
        camera.speed = 90
        camera.stepThrottle(-1)
        #expect(camera.speed == 50)
        for _ in 0..<40 { camera.stepThrottle(-1) }
        #expect(camera.speed == FlyCamera.slowest && FlyCamera.slowest <= 0.005)
        camera.stepThrottle(1)
        #expect(camera.speed == 0.01)
        for _ in 0..<40 { camera.stepThrottle(1) }
        #expect(camera.speed == FlyCamera.fastest)
        // From between two steps, to the one past it.
        camera.speed = 3
        camera.stepThrottle(1)
        #expect(camera.speed == 5)
        camera.speed = 3
        camera.stepThrottle(-1)
        #expect(camera.speed == 2)
        #expect(FlyCamera.describe(speed: 90) == "90 kpc/s")
        #expect(FlyCamera.describe(speed: 0.05) == "50 pc/s")
        #expect(FlyCamera.describe(speed: 0.005) == "5 pc/s")
    }

    @Test func theWheelReachesTheSlowSpeedsToo() {
        var camera = FlyCamera()
        for _ in 0..<2000 { camera.changeSpeed(factor: 0.98) }
        #expect(camera.speed == FlyCamera.slowest)
    }

    @Test func theAimIsWhereTheDustIsOrderedFrom() {
        var camera = FlyCamera(position: SIMD3(0, -100, 0))
        #expect(simd_length(camera.camera.target - camera.position) == 1)
        camera.aimDistance = 80
        #expect(abs(simd_length(camera.camera.target - camera.position) - 80) < 1e-4)
        camera.near = 0.001
        #expect(camera.camera.near == 0.001)
    }
}

@Suite("Exporting a flight")
struct FlightExportJobTests {
    private let cost = CostModel.fallback(at: Date(timeIntervalSince1970: 1_800_000_000))

    private func scene() throws -> SceneFolder {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flight-jobs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let folder = SceneFolder(url)
        let file = FlightFile(keys: [
            .init(at: 0, myr: 100, eye: .world(SIMD3(0, -50, 0)), aim: .world(.zero)),
            .init(at: 20, myr: 130, eye: .world(SIMD3(0, -20, 0))),
        ])
        try folder.writeFlight(file, named: "dive")
        return folder
    }

    private func plan(_ folder: SceneFolder, _ settings: ExportSettings) -> PlannedJob {
        StageJobs.export(
            .hd, settings, folder: folder, state: ExportFolderState.read(folder), cost: cost,
            queue: JobQueue())
    }

    @Test func aFlightIsDrawnByTheExportThatNamesIt() throws {
        let folder = try scene()
        defer { try? FileManager.default.removeItem(at: folder.url) }
        let state = ExportFolderState.read(folder)
        #expect(state.flights.map(\.name) == ["dive"] && state.flights.first?.seconds == 20)

        var settings = ExportSettings()
        settings.flight = StageFlight(name: "dive", seconds: 20)
        // A speed is not carried: the flight keeps its own time.
        settings.speed = .constant(4)
        let job = plan(folder, settings)
        #expect(job.options.starts(with: ["--preset", "1080p", "--flight", "dive"]))
        #expect(!job.options.contains("--speed"))
        #expect(job.output?.lastPathComponent == "dive-1080p.mp4")
        #expect(!job.replaces)
        // The same asked twice is not queued twice.
        #expect(plan(folder, settings).options == job.options)
    }

    @Test func aFlightsVideoLastsAsLongAsTheFlight() throws {
        let folder = try scene()
        defer { try? FileManager.default.removeItem(at: folder.url) }
        var settings = ExportSettings()
        settings.flight = StageFlight(name: "dive", seconds: 20)
        let job = plan(folder, settings)
        let queued = QueueJob(
            id: 1, kind: .export, path: folder.url.path, options: job.options, added: Date())
        let preset = try #require(VideoPreset.named("1080p"))
        // 20 s at the 30 frames a second the take has none of, so the default rate.
        let frames = Int(20 * 30)
        let expected =
            cost.exportSeconds(preset: preset, codec: preset.defaultCodec, frames: frames)
            + StageJobs.flightSeconds(preset: preset, frames: frames)
        let seconds = try #require(JobEstimate.seconds(queued, cost: cost))
        #expect(abs(seconds - expected) < 1e-6)
        // And far more than a plain export of as many frames, which is what the forecast is for.
        #expect(seconds > 10 * cost.exportSeconds(preset: preset, codec: preset.defaultCodec, frames: frames))
        // A range of it.
        var ranged = job.options
        ranged += ["--start", "5", "--duration", "4"]
        let part = QueueJob(id: 2, kind: .export, path: folder.url.path, options: ranged, added: Date())
        let partFrames = 4 * 30
        #expect(
            abs(
                (JobEstimate.seconds(part, cost: cost) ?? 0)
                    - (cost.exportSeconds(preset: preset, codec: preset.defaultCodec, frames: partFrames)
                        + StageJobs.flightSeconds(preset: preset, frames: partFrames))) < 1e-6)
    }

    @Test func aFlightThatCannotBeReadCannotBeChosen() throws {
        let folder = try scene()
        defer { try? FileManager.default.removeItem(at: folder.url) }
        try Data("not json".utf8).write(to: folder.flight("broken"))
        let listings = ExportFolderState.read(folder).flights
        #expect(listings.map(\.name) == ["broken", "dive"])
        #expect(listings.first { $0.name == "broken" }?.seconds == nil)
    }
}

@Suite("The canvas's exposure")
struct LiveExposureTests {
    /// The mean luminance of a frame that falls by 0.7 of a stop for each stop of trim: the tone
    /// curve's, as measured on #297's frames, is under one.
    private func mean(_ bright: Double, _ stops: Double) -> Double { bright * pow(2, -0.7 * stops) }

    @Test func theTrimHoldsABrightFrameUnderTheTarget() {
        var live = InsideExposure.Live()
        var worst = 0.0
        // Readings every twentieth of a second, as the canvas takes one every three frames.
        for _ in 0..<100 {
            live.update(mean: mean(0.9, live.stops), target: 0.16, seconds: 0.05)
            worst = max(worst, live.stops)
        }
        let wanted = log2(0.9 / 0.16) / 0.7
        #expect(abs(live.stops - wanted) < 0.25, "\(live.stops) against \(wanted)")
        // And does not overshoot far on the way.
        #expect(worst < wanted + 0.4)
    }

    @Test func aFrameUnderTheTargetIsLeftAloneAndTheTrimGoesBack() {
        var live = InsideExposure.Live()
        for _ in 0..<100 { live.update(mean: mean(0.9, live.stops), target: 0.16, seconds: 0.05) }
        #expect(live.stops > 2)
        // Out of the disk: the frame is far under the target at any trim.
        for _ in 0..<200 {
            live.update(mean: mean(0.03, live.stops), target: 0.16, seconds: 0.05)
            #expect(live.stops >= 0)
        }
        #expect(live.stops == 0)
        var untouched = InsideExposure.Live()
        untouched.update(mean: 0.05, target: 0.16, seconds: 0.05)
        #expect(untouched.stops == 0)
    }

    @Test func awayFromMatterTheTrimRelaxesAndNeverPassesTheDeepest() {
        var live = InsideExposure.Live()
        for _ in 0..<200 { live.update(mean: 100, target: 0.16, seconds: 0.2) }
        #expect(live.stops <= InsideExposure.deepest)
        live.relax(seconds: 3)
        #expect(live.stops < 0.01)
        live.update(mean: .nan, target: 0.16, seconds: 0.05)
        #expect(live.stops < 0.01)
    }

    @Test func aPictureIsReadThroughItsDrawablesByteOrder() {
        // A 4 x 4 picture of one colour, as the canvas keeps it (BGRA) and as the renderer's output
        // is (RGBA): the same grey either way, and a red one not the blue one.
        func picture(_ r: UInt8, _ g: UInt8, _ b: UInt8, bgra: Bool) -> [UInt8] {
            (0..<16).flatMap { _ in bgra ? [b, g, r, 255] : [r, g, b, 255] }
        }
        func read(_ bytes: [UInt8], bgra: Bool, step: Int = 1) -> Double {
            bytes.withUnsafeBytes {
                InsideExposure.meanLuminance(
                    pixels: $0.baseAddress!, width: 4, height: 4, bytesPerRow: 16, bgra: bgra, step: step)
            }
        }
        let red = (
            rgba: read(picture(255, 0, 0, bgra: false), bgra: false),
            bgra: read(picture(255, 0, 0, bgra: true), bgra: true)
        )
        #expect(abs(red.rgba - 0.2126) < 1e-9 && red.rgba == red.bgra)
        #expect(abs(read(picture(255, 255, 255, bgra: true), bgra: true, step: 2) - 1) < 1e-9)
        #expect(abs(read(picture(0, 0, 255, bgra: true), bgra: true) - 0.0722) < 1e-9)
        // The same mean as the whole-picture reader the exports use.
        let grey = picture(120, 130, 140, bgra: false)
        #expect(abs(read(grey, bgra: false) - InsideExposure.meanLuminance(rgba: grey)) < 1e-12)
    }
}
