import Foundation
import Testing

@testable import SillageCore
@testable import SillageRender

#if canImport(simd)
    import simd
#endif

/// Two galaxies falling together over `frames` captured frames, a pass at `passage`, written and
/// read back as a real take is. Their stars are a few points: what is drawn does not matter here.
func overlayTake(
    frames: Int = 200, myrPerFrame: Double = 2, separation: (Int) -> Double
) throws -> RecordingFile.Loaded {
    let particles = 64
    let scene = SceneConfig.merger(particleCount: particles)
    let recording = Recording(particleCount: particles, galaxyCount: 2)
    var system = ParticleSystem()
    for index in 0..<particles {
        system.append(
            position: SIMD3(Float(index), 0, 0), velocity: .zero, galaxy: UInt32(index % 2),
            radius: 1, population: 0.5, luminosity: 1, formation: ParticleSystem.ancient,
            component: .star)
    }
    let positions = (0..<particles).map { SIMD3<Float>(Float($0), 0, 0) }
    for frame in 0..<frames {
        let half = Float(separation(frame) / 2)
        positions.withUnsafeBufferPointer {
            recording.append(
                positions: $0.baseAddress!,
                time: Float(Double(frame) * myrPerFrame / Physics.megayearsPerTimeUnit),
                centers: [SIMD3(-half, 0, 0), SIMD3(half, 0, 0)])
        }
    }
    recording.finish()
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("overlay-\(UUID().uuidString).\(RecordingFile.fileExtension)")
    defer { try? FileManager.default.removeItem(at: url) }
    try RecordingFile.write(recording, scene: scene, particles: system, to: url)
    return try RecordingFile.read(from: url)
}

/// A pair coming in from 60 kpc to a pass at frame 40 (8 kpc), out to 40 kpc, back through a
/// second pass at frame 120 (4 kpc), and merged from frame 160.
func overlaySeparation(_ frame: Int) -> Double {
    switch frame {
    case ..<40: 60 - 52 * Double(frame) / 40
    case ..<80: 8 + 32 * Double(frame - 40) / 40
    case ..<120: 40 - 36 * Double(frame - 80) / 40
    case ..<140: 4 + 6 * Double(frame - 120) / 20
    case ..<160: 10 - 9 * Double(frame - 140) / 20
    default: 0.5
    }
}

@Suite("Overlay")
struct OverlayTests {
    private static let story = Story(
        profiles: Array(
            repeating: EncounterCentres.Profile(
                stellarMass: 15, stellarScale: 0.5, haloMass: 0, haloScale: 1, haloPlummer: false,
                haloEdge: nil), count: 2),
        reaches: [10, 10])

    private func centres(_ frames: Int) -> [[SIMD3<Double>]] {
        (0..<frames).map {
            let half = overlaySeparation($0) / 2
            return [SIMD3(-half, 0, 0), SIMD3(half, 0, 0)]
        }
    }

    /// The share of stars in tails: none before the pass, a quarter by frame 80, more again
    /// after the merger.
    private func tidal(_ frame: Int) -> Double {
        frame < 40 ? 0 : frame < 80 ? 0.25 * Double(frame - 40) / 40 : frame < 160 ? 0.25 : 0.3
    }

    private func plan(
        _ overlay: Overlay, events: [OverlayEvent: Int] = [:], times: [Double]? = nil,
        positions: [Double]? = nil, framesPerSecond: Int = 10, pixelsPerKpc: Double = 10,
        width: Int = 1920, height: Int = 1080, texts: OverlayTexts = .english, eyes: [SIMD3<Double>] = []
    ) -> OverlayPlan {
        let positions = positions ?? (0..<250).map(Double.init)
        return OverlayPlan(
            overlay: overlay, texts: texts, scene: SceneConfig.merger(particleCount: 64),
            events: events, times: times ?? positions.map { 300 + 2 * $0 }, positions: positions,
            framesPerSecond: framesPerSecond,
            pixelsPerKpc: Array(repeating: pixelsPerKpc, count: positions.count), width: width,
            height: height, eyes: eyes)
    }

    // MARK: The story's events

    @Test func theEventsAreFoundOnTheCentresAndTheTails() {
        let frames = 200
        let found = OverlayMoments.find(
            times: (0..<frames).map { 300 + 2 * Double($0) }, centres: centres(frames),
            story: Self.story, tidal: Dictionary(uniqueKeysWithValues: (0..<frames).map { ($0, tidal($0)) }))
        #expect(found[.passage] == 40)
        #expect(found[.returning] == 120)
        // The last frame the pair is 2 kpc apart or more is 157.
        #expect(found[.merger] == 158)
        // Halfway from 60 to 8 kpc, 34, is reached at frame 20.
        #expect(found[.approach] == 20)
        // Halfway up from none to a quarter, before the merger raises the tails again.
        #expect(found[.tails] == 60)
    }

    @Test func withoutCurvesThereAreNoTailsAndWithoutAPassNothing() {
        let frames = 200
        let found = OverlayMoments.find(
            times: (0..<frames).map(Double.init), centres: centres(frames), story: Self.story)
        #expect(found[.tails] == nil && found[.passage] == 40)
        let apart = (0..<frames).map { _ in [SIMD3<Double>(-30, 0, 0), SIMD3<Double>(30, 0, 0)] }
        #expect(
            OverlayMoments.find(times: (0..<frames).map(Double.init), centres: apart, story: Self.story)
                .isEmpty)
    }

    @Test func aTakesEventsAreReadFromItsOwnCentres() throws {
        let take = try overlayTake(separation: overlaySeparation)
        let found = OverlayMoments.find(take: take)
        #expect(found[.passage] == 40 && found[.returning] == 120 && found[.merger] == 158)
    }

    /// Each caption shows from its moment less its lead, in the order of the video, and none
    /// overlaps another or the title.
    @Test func captionsFollowTheEventsAndGiveWay() {
        var events: [OverlayEvent: Int] = [
            .approach: 10, .passage: 75, .tails: 95, .returning: 140, .merger: 175,
        ]
        let all = plan(Overlay(captions: [:]), events: events)
        // At 10 frames a second: the approach at 1 s, the pass 1 s early, the tails at 9.5 s
        // overlap the pass's 4.5 s and give way, the return 2 s early, the merger 0.5 s early.
        #expect(all.captions.map(\.event) == [.approach, .passage, .returning, .merger])
        #expect(all.captions.map(\.frame) == [10, 65, 120, 170])

        let replaced = plan(
            Overlay(captions: ["passage": "Through each other", "merger": ""]), events: events)
        #expect(replaced.captions.map(\.event) == [.approach, .passage, .returning])
        #expect(replaced.frames[70].lines.map(\.text) == ["Through each other"])

        // The title holds 3.3 s instead of 3.5 to give way to the pass; the approach goes.
        events[.passage] = 72
        let titled = plan(Overlay(title: Overlay.Title(), captions: [:]), events: events)
        #expect(titled.captions.map(\.event) == [.passage, .returning, .merger])
        let titleFrames = titled.frames.indices.filter { index in
            titled.frames[index].lines.contains { $0.text == "Merger" }
        }
        #expect(titleFrames.count > 50 && titleFrames.last! < 58)
    }

    /// A caption due just before the one ahead of it ends waits for it, a little.
    @Test func aCaptionWaitsBrieflyForTheOneBefore() {
        let waited = plan(Overlay(captions: [:]), events: [.passage: 75, .tails: 105, .returning: 140])
        // The tails wait 0.9 s for the pass's caption to go; the return would wait 4.3 s.
        #expect(waited.captions.map(\.event) == [.passage, .tails])
        #expect(waited.captions.map(\.frame) == [65, 115])
    }

    @Test func aCaptionOutsideTheVideoIsLeftOut() {
        let events: [OverlayEvent: Int] = [.passage: 40, .merger: 195]
        let cut = plan(Overlay(captions: [:]), events: events, positions: (60..<200).map(Double.init))
        // The pass is before the cut, the merger too near the end to be read.
        #expect(cut.captions.isEmpty)
    }

    // MARK: The clock

    /// Through a video whose pace changes, holds still and speeds up, the clock reads the take's
    /// time at every frame, rounded to its step, and stands still where time does.
    @Test func theClockFollowsTheTakesTime() throws {
        let take = try overlayTake(separation: overlaySeparation)
        var positions: [Double] = []
        positions += (0..<100).map { Double($0) * 0.25 }
        positions += Array(repeating: 25, count: 30)
        positions += (0..<40).map { 25 + Double($0) * 2 }
        let plan = OverlayPlan(
            overlay: Overlay(clock: Overlay.Clock()), texts: .english, take: take, positions: positions,
            framesPerSecond: 30,
            cameras: Array(repeating: Camera(eye: SIMD3(0, -100, 0)), count: positions.count),
            width: 1920, height: 1080)
        let times = positions.map {
            Double(take.recording.blend(atCaptured: $0)!.time) * Physics.megayearsPerTimeUnit
        }
        // Half a million years a frame most of the time, fifteen a second: steps of 5.
        let step = OverlayPlan.clockStep(times: times, framesPerSecond: 30)
        #expect(step == 5)
        for index in positions.indices where index > 30 {
            let expected = Int(((times[index] - times[0]) / step).rounded() * step)
            #expect(
                plan.frames[index].lines.first { $0.tabular }?.text
                    == "\(OverlayTexts.english.number(expected)) million years")
        }
        let frozen = Set((100..<130).compactMap { plan.frames[$0].lines.first { $0.tabular }?.text })
        #expect(frozen.count == 1)
        #expect(plan.frames[169].lines.first { $0.tabular }?.text == "205 million years")
    }

    @Test func fromThePassageTheClockIsSignedAndFallsBackWithoutOne() {
        let overlay = Overlay(clock: Overlay.Clock(origin: .passage))
        let signed = plan(overlay, events: [.passage: 100])
        let texts = signed.frames.map { $0.lines.first { $0.tabular }?.text }
        // Two Myr a frame at ten frames a second: steps of 10 Myr.
        #expect(texts[30] == "\u{2212}140 million years")
        #expect(texts[100] == "0 million years")
        #expect(texts[150] == "+100 million years")
        #expect(texts[5] == nil)
        let unsigned = plan(overlay)
        #expect(unsigned.frames[150].lines.first { $0.tabular }?.text == "300 million years")
        #expect(unsigned.notes.count == 1)
    }

    /// Cut later than the take's start, a video's clock still counts from the take's start.
    @Test func aClockCountsFromTheTakesStartWhereverTheVideoBegins() {
        let late = plan(Overlay(clock: Overlay.Clock()), positions: (50..<200).map(Double.init))
        #expect(late.frames[100].lines.first { $0.tabular }?.text == "300 million years")
    }

    // MARK: The scale bar

    /// At two zooms and in a wide and a tall frame, the bar is as long as its length projects
    /// at the camera's target, and between a tenth and a quarter of the width.
    @Test(arguments: [(1920, 1080), (1080, 1920)], [80.0, 240.0])
    func theBarIsItsLengthAtTheTarget(_ size: (Int, Int), _ distance: Double) throws {
        let (width, height) = size
        let camera = Camera(
            eye: SIMD3(0, -Float(distance), 10), target: SIMD3(0, 0, 10), fieldOfView: 0.6)
        let scale = OverlayPlan.pixelsPerKpc(camera, height: height)
        let bar = try #require(
            OverlayPlan.scaleTrack(
                pixelsPerKpc: [scale], width: Double(width), unit: .lightYears, framesPerSecond: 30)[0]
                .first)
        let kpc = Float(bar.length / OverlayPlan.lightYearsPerKpc)
        let projection = camera.viewProjection(aspectRatio: Float(width) / Float(height))
        func pixel(_ x: Float) -> Double {
            let clip = projection * SIMD4(x, 0, 10, 1)
            return Double(clip.x / clip.w) * Double(width) / 2
        }
        let projected = pixel(kpc / 2) - pixel(-kpc / 2)
        #expect(abs(bar.pixels - projected) < 1e-3 * projected)
        #expect(OverlayPlan.barShare.contains(bar.pixels / Double(width)))
        #expect(OverlayPlan.lengths(.lightYears).contains(bar.length))
    }

    /// Zooming out, the bar shrinks until it leaves its range; the longer length then fades in
    /// as the old fades out, each always drawn at its own true length.
    @Test func theBarChangesItsLengthByFading() {
        let scales = (0..<300).map { 40 * pow(0.995, Double($0)) }
        let track = OverlayPlan.scaleTrack(
            pixelsPerKpc: scales, width: 1920, unit: .kiloparsecs, framesPerSecond: 30)
        var changes = 0
        for (index, bars) in track.enumerated() {
            #expect(!bars.isEmpty && bars.count <= 2)
            #expect(abs(bars.map(\.alpha).reduce(0, +) - 1) < 1e-9)
            for bar in bars { #expect(abs(bar.pixels - bar.length * scales[index]) < 1e-9) }
            if index > 0, bars.last!.length != track[index - 1].last!.length { changes += 1 }
            #expect(OverlayPlan.barShare.contains(bars.last!.pixels / 1920) || bars.count == 2)
        }
        #expect(changes >= 2)
        // A crossfade lasts 0.8 s.
        #expect(track.filter { $0.count == 2 }.count >= 2 * 23)
    }

    @Test func aCutChangesTheBarAtOnce() {
        let track = OverlayPlan.scaleTrack(
            pixelsPerKpc: [10, 10, 100, 100], width: 1920, unit: .kiloparsecs, framesPerSecond: 30)
        #expect(track[2].count == 1 && track[2][0].alpha == 1)
    }

    @Test func lengthsAreWrittenInTheirUnit() {
        let english = OverlayTexts.english
        #expect(OverlayPlan.lengthText(100_000, unit: .lightYears, texts: english) == "100,000 light years")
        #expect(OverlayPlan.lengthText(1, unit: .kiloparsecs, texts: english) == "1 kiloparsec")
        #expect(OverlayPlan.lengthText(20, unit: .kiloparsecs, texts: english) == "20 kiloparsecs")
        #expect(OverlayPlan.lengthText(0.5, unit: .kiloparsecs, texts: english) == "0.5 kiloparsecs")
    }

    /// Inside an arm the frame is a few hundred light years across at the target: the bar
    /// still finds a length between a tenth and a quarter of it (#407).
    @Test func theBarReachesDownToTheStars() throws {
        for unit in [Overlay.Scale.Unit.lightYears, .kiloparsecs] {
            // 0.17 kpc across a 1920 frame, 550 light years.
            let bar = try #require(
                OverlayPlan.scaleTrack(
                    pixelsPerKpc: [1920 / 0.17], width: 1920, unit: unit, framesPerSecond: 30)[0]
                    .first)
            #expect(OverlayPlan.barShare.contains(bar.pixels / 1920), "\(unit): \(bar.length)")
        }
        #expect(OverlayPlan.lengthText(50, unit: .lightYears, texts: .english) == "50 light years")
        #expect(OverlayPlan.lengthText(0.02, unit: .kiloparsecs, texts: .english) == "0.02 kiloparsecs")
    }

    // MARK: The eye's speed

    /// A dive that slows from 7 kpc a second to 50 pc a second over 15 s: the speed said steps
    /// down a short ladder, never far from the true one, and changes no faster than the eye can
    /// read it.
    @Test func theSpeedFollowsADiveOnAShortLadder() {
        let rate = 30
        let frames = 15 * rate
        let decay = log(7 / 0.05) / 15
        var x = 0.0
        var eyes: [SIMD3<Double>] = []
        var truth: [Double] = []
        for n in 0..<frames {
            let speed = 7 * exp(-decay * Double(n) / Double(rate))
            truth.append(speed * OverlayPlan.lightYearsPerKpc)
            eyes.append(SIMD3(x, 0, 0))
            x += speed / Double(rate)
        }
        // The frame is 20 times the nearness across, the nearness three times the speed.
        let scales = truth.map { 1920 / (20 * 3 * $0 / OverlayPlan.lightYearsPerKpc) }
        let track = OverlayPlan.speedTrack(
            eyes: eyes, pixelsPerKpc: scales, width: 1920, unit: .lightYears, framesPerSecond: rate)
        #expect(track.count == frames)
        var changes = 0
        for (index, entry) in track.enumerated() {
            #expect(OverlayPlan.speedLadder(entry.value) == entry.value)
            if index > 10 && index < frames - 10 {
                #expect(
                    abs(log(entry.value / truth[index])) < log(1.6),
                    "\(index): \(entry.value) for \(truth[index])")
            }
            if index > 0, entry.value != track[index - 1].value { changes += 1 }
        }
        #expect(changes >= 8 && changes <= 20, "\(changes) changes")
        // Fading in as the instruments do, then shown.
        #expect(track[0].shown < 0.1 && track[frames / 2].shown == 1)
        #expect(track.first!.value >= 15_000 && track.last!.value <= 200)
    }

    /// An eye at rest has no speed to say; once it moves the line fades in.
    @Test func aStillEyeSaysNoSpeed() {
        let still = OverlayPlan.speedTrack(
            eyes: Array(repeating: SIMD3(1, 2, 3), count: 60), pixelsPerKpc: Array(repeating: 100, count: 60),
            width: 1920, unit: .lightYears, framesPerSecond: 30)
        #expect(still.allSatisfy { $0.shown == 0 })
        // A drift of a five hundredth of the frame a second is too slow to be worth saying.
        let crawl = OverlayPlan.speedTrack(
            eyes: (0..<60).map { SIMD3(Double($0) * 0.192 / 30 / 500, 0, 0) },
            pixelsPerKpc: Array(repeating: 100, count: 60), width: 1920, unit: .lightYears,
            framesPerSecond: 30)
        #expect(crawl.allSatisfy { $0.shown == 0 })
        let moving = OverlayPlan.speedTrack(
            eyes: (0..<60).map { SIMD3(Double($0) * 0.5 / 30, 0, 0) },
            pixelsPerKpc: Array(repeating: 100, count: 60), width: 1920, unit: .lightYears,
            framesPerSecond: 30)
        #expect(moving.last!.shown == 1 && moving.last!.value == 1_500)
    }

    @Test func speedsAreWrittenInTheirUnit() {
        let english = OverlayTexts.english
        #expect(
            OverlayPlan.speedText(7_000, unit: .lightYears, texts: english) == "7,000 light years a second")
        #expect(OverlayPlan.speedText(1.5, unit: .lightYears, texts: english) == "1.5 light years a second")
        #expect(OverlayPlan.speedText(0.05, unit: .kiloparsecs, texts: english) == "50 parsecs a second")
        #expect(OverlayPlan.speedText(2, unit: .kiloparsecs, texts: english) == "2 kiloparsecs a second")
        let french = try? JSONDecoder().decode(
            OverlayTexts.self,
            from: Data(#"{"lightYearsPerSecond": "{n} années-lumière par seconde", "thousands": " "}"#.utf8))
        #expect(
            french.map { OverlayPlan.speedText(7_000, unit: .lightYears, texts: $0) }
                == "7 000 années-lumière par seconde")
    }

    /// Asked for, the speed sits between the clock and the bar's label; not asked, the frames
    /// are the ones laid before it existed.
    @Test func theSpeedSitsBetweenTheClockAndTheBar() throws {
        let eyes = (0..<250).map { SIMD3(Double($0) * 0.05, 0, 0) }
        let with = plan(
            Overlay(clock: Overlay.Clock(), scale: Overlay.Scale(speed: true)), pixelsPerKpc: 400, eyes: eyes)
        let without = plan(
            Overlay(clock: Overlay.Clock(), scale: Overlay.Scale()), pixelsPerKpc: 400, eyes: eyes)
        let lines = with.frames[100].lines
        #expect(lines.count == 3)
        let speed = lines.first { $0.text.hasSuffix("light years a second") }
        let clock = lines.first { $0.text.hasSuffix("million years") }
        let label = lines.first { $0.text.hasSuffix("light years") }
        #expect(speed?.text == "1,500 light years a second")
        #expect(clock!.baseline < speed!.baseline && speed!.baseline < label!.baseline)
        #expect(without.frames[100].lines.count == 2)
        #expect(without.frames[100].bars == with.frames[100].bars)
        #expect(try Overlay.elements("clock,speed").scale == Overlay.Scale(speed: true))
        #expect(try Overlay.elements("speed,scale").scale?.speed == true)
    }

    // MARK: The title and the layout

    @Test func theTitleNamesTheSceneOrDescribesIt() {
        var scene = SceneConfig.merger(particleCount: 64)
        #expect(OverlayPlan.titleText(scene: scene, texts: .english) == "Merger")
        scene.name = "Archetype"
        #expect(OverlayPlan.titleText(scene: scene, texts: .english) == OverlayTexts.english.title)
        let subtitle = OverlayPlan.subtitle(scene: scene, texts: .english)
        #expect(subtitle.hasPrefix("Two ") && subtitle.hasSuffix(" light years across"))
        let titled = plan(Overlay(title: Overlay.Title(text: "The Mice", subtitle: "")))
        #expect(titled.frames[30].lines.map(\.text) == ["The Mice"])
    }

    /// Every mark lies inside the frame less what the 9:16 platforms cover with their buttons.
    @Test(arguments: [(1920, 1080), (3840, 2160), (1080, 1920), (1080, 1080)])
    func everyMarkStaysInTheSafeArea(_ size: (Int, Int)) {
        let (width, height) = size
        let all = Overlay(
            title: Overlay.Title(), clock: Overlay.Clock(), scale: Overlay.Scale(), captions: [:])
        let made = plan(
            all, events: [.passage: 100], pixelsPerKpc: 0.15 * Double(width) / 10, width: width,
            height: height)
        let portrait = height > width
        let lines = made.frames.flatMap(\.lines)
        #expect(!lines.isEmpty && !made.frames.flatMap(\.bars).isEmpty)
        for line in lines {
            #expect(line.baseline > 0.05 * Double(height))
            #expect(line.baseline < (portrait ? 0.78 : 0.95) * Double(height))
            #expect(line.x >= (portrait ? 0.06 : 0.04) * Double(width) - 1e-9)
            #expect(line.x <= (portrait ? 0.85 : 0.96) * Double(width) + 1e-9)
        }
        // 4K text is 1080p text at twice the pixels.
        if width == 3840 {
            let small = plan(all, pixelsPerKpc: 0.15 * 1920 / 10).frames[30].lines.map(\.size)
            #expect(made.frames[30].lines.map(\.size) == small.map { $0 * 2 })
        }
    }

    // MARK: Asking for it

    @Test func nothingIsAskedByDefault() throws {
        #expect(Overlay().isEmpty)
        #expect(plan(Overlay()).frames.allSatisfy { $0.isEmpty })
        let text = try String(decoding: LookFile.standard.encoded(), as: UTF8.self)
        #expect(!text.contains("overlay"))
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("overlay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(try SceneFolder(folder).overlayRequest(look: .standard) == nil)
    }

    @Test func theSceneOverridesTheLookAndTheCommandBoth() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("overlay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var look = LookFile.standard
        look.overlay = Overlay(clock: Overlay.Clock())
        let scene = SceneFolder(folder)
        #expect(try scene.overlayRequest(look: look)?.overlay == look.overlay)
        try Data(#"{"scale": {"unit": "kiloparsecs"}}"#.utf8).write(to: scene.overlay)
        #expect(
            try scene.overlayRequest(look: look)?.overlay == Overlay(scale: Overlay.Scale(unit: .kiloparsecs))
        )
        #expect(
            try scene.overlayRequest(look: look, asked: "title,captions")?.overlay
                == Overlay(title: Overlay.Title(), captions: [:]))
        #expect(throws: Overlay.Failure.self) { try Overlay.elements("clock,weather") }
    }

    @Test func aLookCarriesItsOverlayAndRefusesWhatItDoesNotKnow() throws {
        var look = LookFile.standard
        look.overlay = Overlay(
            title: Overlay.Title(text: "Two galaxies"),
            clock: Overlay.Clock(origin: .passage, corner: .topRight),
            scale: Overlay.Scale(unit: .kiloparsecs), captions: ["merger": ""], size: 1.2)
        #expect(try LookFile.decoded(from: look.encoded()) == look)
        for json in [
            #"{"clock": {"form": "passage"}}"#, #"{"captions": {"collision": "Boom"}}"#,
            #"{"scale": {"corner": "middle"}}"#, #"{"subtitle": "x"}"#,
        ] {
            #expect(throws: DecodingError.self) { try Overlay.decoded(from: Data(json.utf8)) }
        }
    }

    /// Another language is a file: what it leaves out is read in English.
    @Test func textsInAnotherLanguageAreAFile() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("overlay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(
            #"{"clock": "{n} millions d'années", "thousands": " ", "captions": {"passage": "Elles se traversent"}}"#
                .utf8
        ).write(to: folder.appendingPathComponent("fr.json"))
        let texts = try Overlay(texts: "fr.json").loadTexts(folder: folder)
        #expect(texts.number(1_234_567) == "1\u{202f}234\u{202f}567")
        #expect(texts.captions["passage"] == "Elles se traversent")
        #expect(texts.captions["merger"] == OverlayTexts.english.captions["merger"])
        #expect(texts.lightYears == OverlayTexts.english.lightYears)
        #expect(
            OverlayPlan.clockText(1_250, step: 10, signed: false, texts: texts)
                == "1\u{202f}250 millions d'années")
        #expect(throws: Overlay.Failure.self) { try Overlay(texts: "de.json").loadTexts(folder: folder) }
    }

    // MARK: The run's videos

    private final class Blind: RunVideoDrawing, FramePreparing {
        var styling: any FramePreparing { self }
        func prepare(
            _ file: LookFile, shot: ShotReplay.Shot, take: RecordingFile.Loaded,
            at blend: Recording.Blend
        ) {}
        func begin(_ url: URL) throws {}
        func append(camera: Camera, still: ((any RunVideoStill) throws -> Void)?) throws {}
        func end() throws {}
    }

    /// An engine that cannot draw an overlay refuses one before the run starts, and runs
    /// without one as before.
    @Test func anEngineWithoutTextRefusesAnOverlay() throws {
        let take = try overlayTake(frames: 20, separation: { _ in 30 })
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("overlay-run-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let formats = [
            try RunVideos.Format(
                preset: VideoPreset(name: "small", width: 64, height: 36), frames: 20,
                framesPerSecond: 30, url: folder.appendingPathComponent("small.mp4"))
        ]
        func run(_ overlay: OverlayRequest?) throws -> RunVideos {
            try RunVideos(
                formats: formats, look: .standard, framing: take, capturedRate: 30, overlay: overlay,
                drawing: { _, _, _ in Blind() }, join: { _, _, _, _, _ in })
        }
        #expect(throws: RunVideos.Failure.self) {
            try run(OverlayRequest(overlay: Overlay(clock: Overlay.Clock())))
        }
        #expect(try run(nil).overlayNotes.isEmpty)
        #expect(try run(OverlayRequest(overlay: Overlay())).overlayNotes.isEmpty)
    }
}
