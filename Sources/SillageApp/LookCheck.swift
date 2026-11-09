import AppKit
import Foundation
import SillageCore
import SillageRender
import simd

/// Opens a take with a look file the way the library does, and checks what tuning promises:
/// the file comes back byte for byte, every kind of edit lands where it should and survives a
/// save, and the playhead can be thrown backwards and forwards at the take's full size. Then
/// the style editor's session on it: renderings, palettes and locks, Before / After, Cancel,
/// Use for scene, the canvas framing what the export frames in every camera mode and
/// a framing made with the mouse kept through a save (#177), and Auto when the take sits in a
/// scene folder.
///
/// `--lookcheck <take> [look]`. Headless, for the same reason as `--replay`.
enum LookCheck {
    @MainActor
    static func run() {
        guard let flag = CommandLine.arguments.firstIndex(of: "--lookcheck"),
            flag + 1 < CommandLine.arguments.count
        else { return }
        let take = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
        var lines: [String] = []
        var failed = false
        func check(_ label: String, _ passed: Bool, _ detail: String = "") {
            lines.append("\(passed ? "ok  " : "FAIL") \(label)\(detail.isEmpty ? "" : "  \(detail)")")
            if !passed { failed = true }
        }
        func fail(_ why: String) -> Never {
            FileHandle.standardError.write(Data("lookcheck: \(why)\n".utf8))
            exit(1)
        }

        // A scene folder of its own, so promoting touches nothing real.
        let folder = SceneFolder(
            FileManager.default.temporaryDirectory.appendingPathComponent(
                "lookcheck-\(UUID().uuidString)/scene-0001"))
        try? FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        // A take in a scene folder lends it what Auto reads, so Auto can run here too.
        let home = SceneFolder(take.deletingLastPathComponent())
        let lent = [
            (home.scene, folder.scene), (home.clip, folder.clip), (home.hires, folder.hires),
            (home.hiresCurves, folder.hiresCurves), (take, folder.take),
        ]
        for (from, to) in lent where FileManager.default.fileExists(atPath: from.path) {
            try? FileManager.default.createSymbolicLink(at: to, withDestinationURL: from)
        }
        var original = LookFile.standard
        original.name = "lookcheck"
        original.look = .ink
        original.palette = [GalaxyColours(SIMD3(0.9, 0.7, 0.5))]
        original.camera = .init(mode: .fixed, elevation: 0.5, elevationEnd: 0.9, azimuthEnd: 1.5)
        let lookURL: URL
        if flag + 2 < CommandLine.arguments.count {
            lookURL = URL(fileURLWithPath: CommandLine.arguments[flag + 2])
        } else {
            lookURL = folder.look
            try? original.encoded().write(to: lookURL)
        }
        guard let originalBytes = try? Data(contentsOf: lookURL),
            let loaded = try? LookFile.decoded(from: originalBytes)
        else { fail("unreadable look") }

        guard let model = SimulationModel() else { fail("no Metal device") }
        let buildsBefore = model.rendererBuilds
        let opening = CACurrentMediaTime()
        model.openTake(from: take, look: lookURL, folder: folder)
        let deadline = Date().addingTimeInterval(900)
        while model.mode != .playback || model.capturedFrames < 2 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            if let failure = model.failure { fail(failure) }
            if Date() > deadline { fail("the take did not load") }
        }
        let openSeconds = CACurrentMediaTime() - opening
        let builds = model.rendererBuilds - buildsBefore
        model.resize(to: CGSize(width: 1920, height: 1080))

        check("the open look is the file's", model.lookFile == loaded)
        check("a single renderer build on opening", builds == 1, "\(builds)")
        check(
            "the file's palette colours the scene",
            loaded.palette.isEmpty || model.scene.galaxies[0].color == loaded.palette[0].colour)
        check("the camera plan is followed", model.followsPlan, "\(loaded.camera.mode)")

        let resaved = folder.url.appendingPathComponent("resaved.look.json")
        model.saveLook(to: resaved)
        check(
            "opened then saved unchanged: same file",
            (try? Data(contentsOf: resaved)) == originalBytes)

        // The playhead thrown about, then played: what scrubbing costs at this size.
        let last = Double(model.capturedFrames - 1)
        var generator = SeededGenerator(seed: 23)
        var jumps: [Double] = []
        for index in 0..<80 {
            model.playbackPosition =
                index % 2 == 0 ? Double(generator.uniform(in: 0...Float(last))) : last - Double(index)
            model.isPlaying = false
            let start = CACurrentMediaTime()
            guard model.playbackSnapshot() != nil else { fail("nothing to draw") }
            jumps.append((CACurrentMediaTime() - start) * 1000)
            RunLoop.current.run(until: Date())
        }
        var backwards: [Double] = []
        model.playbackPosition = last
        for _ in 0..<120 {
            model.playbackPosition = max(model.playbackPosition - 0.5, 0)
            let start = CACurrentMediaTime()
            _ = model.playbackSnapshot()
            backwards.append((CACurrentMediaTime() - start) * 1000)
            RunLoop.current.run(until: Date())
        }
        model.isPlaying = true
        var forwards: [Double] = []
        for _ in 0..<120 {
            let start = CACurrentMediaTime()
            _ = model.playbackSnapshot()
            forwards.append((CACurrentMediaTime() - start) * 1000)
            RunLoop.current.run(until: Date())
        }
        model.isPlaying = false

        // Each kind of edit: live ones touch nothing that owns buffers, the others rebuild once.
        var builds0 = model.rendererBuilds
        model.look.brightness = 0.31
        model.look.saturation = 1.7
        model.setColour(SIMD3(0.2, 0.5, 1), ofGalaxy: model.scene.galaxies.count - 1)
        model.lookFile.armStrength = 0.5
        model.lookFile.camera.zoom = 1.6
        check("live settings rebuild nothing", model.rendererBuilds == builds0)
        check(
            "a galaxy's colour reaches the scene",
            model.scene.galaxies.last?.color == SIMD3(0.2, 0.5, 1))
        builds0 = model.rendererBuilds
        model.lookFile.starCount = 20_000
        model.lookFile.bloomLevels = 5
        check("each buffer setting rebuilds once", model.rendererBuilds == builds0 + 2)

        model.playbackPosition = last / 2
        _ = model.playbackSnapshot()
        let planned = model.planCamera
        check(
            "the camera shown is the plan's",
            planned != nil && model.activeCamera.eye == planned?.eye)
        model.adopt(RenderLook.catalogue[1])
        check("a named look touches neither palette nor plan", model.lookFile.camera.zoom == 1.6)

        let edited = model.lookFile
        let saved = folder.url.appendingPathComponent("edited.look.json")
        model.saveLook(to: saved)
        model.adopt(LookFile.standard, from: nil)
        model.openLook(from: saved)
        check("saved then reopened: the same look", model.lookFile == edited)
        // The editor reads the scene's look.json, which a look given on the command line is not.
        if !FileManager.default.fileExists(atPath: folder.look.path) {
            try? originalBytes.write(to: folder.look)
        }
        let savedBefore = try? Data(contentsOf: folder.look)
        let scene = LibraryScene(
            batch: "lookcheck", batchURL: folder.batch, name: "scene-0001", folder: folder, take: take)
        let favourites = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lookcheck-favourites-\(UUID().uuidString)")
        let session = StyleSession(scene: scene, model: model, favouritesDirectory: favourites)
        check("the editor finds the open take", session.isOpen)
        check("edits made before show", session.saved == loaded && session.isModified)
        session.cancel()
        check("cancel puts back the saved style", model.lookFile == loaded && !session.isModified)
        exerciseStyle(session, model, folder, check)

        // Cancel after all of it: the saved style back on the picture, nothing written.
        session.cancel()
        check("cancel after the tries", model.lookFile == loaded && !session.isModified)
        check(
            "cancel writes nothing",
            (try? Data(contentsOf: folder.look)) == savedBefore
                && !FileManager.default.fileExists(atPath: folder.rawLook.path))

        // Use for scene: look.json is the style on screen, the explored look stays aside.
        if let hubble = session.catalogue.first(where: { $0.name == "hubble" }) { session.apply(hubble) }
        model.lookFile.camera.zoom = 1.3
        let chosen = model.lookFile
        check("an edit shows", session.isModified)
        check("use for scene writes look.json", session.promote())
        check(
            "look.json is the style on screen",
            (try? LookFile.decoded(from: Data(contentsOf: folder.look))) == chosen
                && session.saved == chosen && !session.isModified && session.promoted)
        check(
            "the old look stays in look-raw.json", (try? Data(contentsOf: folder.rawLook)) == savedBefore)
        check("the workshop's look points to the scene", model.lookURL == folder.look)

        exerciseFraming(session, model, folder, take, check)

        if FileManager.default.fileExists(atPath: folder.scene.path) {
            exerciseAuto(session, model, check)
        } else {
            lines.append("-    Auto not tried: the take is not in a scene folder")
        }

        func split(_ name: String, _ samples: [Double]) -> String {
            let sorted = samples.sorted()
            return String(
                format: "%@ median %6.1f ms, worst %6.1f", name, sorted[sorted.count / 2],
                sorted.last ?? 0)
        }
        let report =
            """
            take             \(model.particleCount) particles, \(model.capturedFrames) frames kept (one in \(model.recording?.interval ?? 1)), opened in \(String(format: "%.1f", openSeconds)) s
            \(split("random jumps    ", jumps))
            \(split("backwards       ", backwards))
            \(split("forwards        ", forwards))
            """ + "\n" + lines.joined(separator: "\n")
        try? report.write(
            to: URL(fileURLWithPath: "/tmp/sillage-lookcheck.log"), atomically: true,
            encoding: .utf8)
        print(report)
        exit(failed ? 1 : 0)
    }

    /// Renderings, palettes and their locks, the camera, a reset and Before / After, each on the
    /// picture and none written.
    @MainActor
    private static func exerciseStyle(
        _ session: StyleSession, _ model: SimulationModel, _ folder: SceneFolder,
        _ check: (String, Bool, String) -> Void
    ) {
        let before = model.lookFile
        let onDisk = try? Data(contentsOf: folder.look)
        guard let webb = session.catalogue.first(where: { $0.name == "webb" }) else {
            return check("the catalogue has Webb", false, "")
        }
        session.apply(webb)
        check(
            "a rendering keeps the palette and the plan",
            session.rendering?.name == "webb" && model.lookFile.palette == before.palette
                && model.lookFile.camera == before.camera && session.isModified, "")
        check(
            "a rendering chosen by hand keeps its dust and its web",
            model.lookFile.look.dustStrength == webb.look.dustStrength
                && model.lookFile.look.dustWeb == webb.look.dustWeb && webb.look.dustWeb > 0,
            "dust \(StyleNames.number(model.lookFile.look.dustStrength)), web "
                + StyleNames.number(model.lookFile.look.dustWeb))
        session.apply(webb, colours: true)
        check(
            "with its colours takes its palette too",
            model.lookFile.palette == webb.palette && session.world == .telescope, "")

        session.world = .free
        session.propose(waiting: true)
        let galaxies = model.scene.galaxies.count
        check(
            "six proposals in the chosen world",
            session.proposals.count == StyleSession.proposalCount
                && session.proposals.allSatisfy { $0.palette.world == .free }, "\(session.proposals.count)")
        let first = session.proposals.map(\.palette)
        session.moreProposals(waiting: true)
        check("other palettes proposes others", session.proposals.map(\.palette) != first, "")
        if let proposal = session.proposals.first?.palette {
            let file = session.favouritesDirectory.appendingPathComponent("test-evening.palette.json")
            check("no favourite at first", session.favourites.isEmpty && !session.isFavourite(proposal), "")
            session.toggleFavourite(proposal)
            check("the heart asks for a name", session.naming == proposal && session.favourites.isEmpty, "")
            session.saveFavourite(proposal, named: "Test Evening")
            check(
                "the favourite is written and recognised",
                FileManager.default.fileExists(atPath: file.path) && session.isFavourite(proposal)
                    && session.naming == nil, "")
            session.propose(waiting: true)
            check(
                "the favourite leads the proposals",
                session.proposals.first?.palette == proposal.truncated(to: galaxies)
                    && session.proposals.count == StyleSession.proposalCount
                    && session.favouriteProposals.count == 1, "\(session.proposals.count)")
            session.world = .telescope
            session.propose(waiting: true)
            check(
                "a favourite from another world is not proposed there",
                session.favouriteProposals.isEmpty, "")
            session.world = .free
            session.propose(waiting: true)
            session.toggleFavourite(proposal)
            check(
                "a second click removes the favourite",
                !FileManager.default.fileExists(atPath: file.path) && session.favourites.isEmpty
                    && !session.isFavourite(proposal), "")
            try? FileManager.default.removeItem(at: session.favouritesDirectory)
        }
        if galaxies > 1, let proposal = session.proposals.last?.palette {
            let kept = model.lookFile.palette[0]
            session.toggleLock(0)
            session.use(proposal)
            check(
                "a lock keeps its colour, the others change",
                model.lookFile.palette[0] == kept && model.lookFile.palette[1].colour == proposal.colours[1]
                    && model.lookFile.paletteRecipe == proposal, "")
            check(
                "the palette reaches the scene",
                model.scene.galaxies[1].color == proposal.colours[1], "")

            // The look this check opens has plain colours, so the switch starts off.
            check(
                "multicolour off on a look without ramps: plain proposals and palette",
                !session.multicolour && !model.lookFile.hasRamps
                    && session.proposals.allSatisfy { !$0.palette.multicolour }, "")
            session.setMulticolour(true, waiting: true)
            check(
                "on: a ramp per unlocked galaxy, the chosen colour and the lock kept",
                session.multicolour && model.lookFile.palette[0] == kept
                    && model.lookFile.palette[1].ramp != nil
                    && model.lookFile.palette[1].colour == proposal.colours[1]
                    && model.lookFile.paletteRecipe == proposal.withMulticolour(true), "")
            check(
                "on: the proposals have ramps and their scores",
                session.proposals.count == StyleSession.proposalCount
                    && session.proposals.allSatisfy { $0.palette.multicolour && $0.score.between != nil },
                "")
            session.setMulticolour(false, waiting: true)
            check(
                "off: one colour per galaxy, the proposals without ramp scores",
                !session.multicolour && !model.lookFile.hasRamps
                    && model.lookFile.palette[1].colour == proposal.colours[1]
                    && model.lookFile.paletteRecipe?.multicolour == false
                    && session.proposals.allSatisfy { !$0.palette.multicolour && $0.score.between == nil },
                "")
            session.setMulticolour(true, waiting: true)
        }

        // The director plans from the whole take, so the playhead can jump onto any of its shots.
        session.setCameraMode(.director)
        model.playbackPosition = Double(model.capturedFrames - 1) / 3
        _ = model.playbackSnapshot()
        let directed = model.planCamera
        check(
            "the director follows the playhead",
            model.followsPlan && directed != nil && model.activeCamera.eye == directed?.eye, "")

        session.setCameraMode(.fixed)
        session.binding(\.camera.rotation).wrappedValue = .pi / 2
        check(
            "fixed camera and rotation",
            model.lookFile.camera.mode == .fixed && model.followsPlan
                && abs((model.lookFile.camera.azimuthEnd ?? 0) - model.lookFile.camera.azimuth - .pi / 2)
                    < 1e-5,
            "")
        session.binding(\.look.brightness).wrappedValue = 1.7
        session.reset(.light)
        check(
            "resetting the light goes back to the rendering",
            model.lookFile.look.brightness == webb.look.brightness, "")
        session.binding(\.look.glint).wrappedValue = 0.9
        session.binding(\.look.columnSmoothing).wrappedValue = 40
        session.reset(.instrument)
        check(
            "resetting the instrument goes back to the rendering, compact sources and projection included",
            model.lookFile.look.glint == webb.look.glint
                && model.lookFile.look.columnSmoothing == webb.look.columnSmoothing, "")
        session.reset(.camera)
        check("resetting the plan goes back to the saved style", model.lookFile.camera == before.camera, "")

        let edited = model.lookFile
        session.showSaved(true)
        check(
            "before: the saved style on screen",
            model.lookFile == session.saved && session.covered == edited && session.isModified, "")
        session.binding(\.look.brightness).wrappedValue = 0.01
        check("nothing moves while before shows", model.lookFile == session.saved, "")
        session.showSaved(false)
        check("after: the edit comes back", model.lookFile == edited && session.covered == nil, "")
        check("nothing written during the tries", (try? Data(contentsOf: folder.look)) == onDisk, "")
    }

    /// The canvas against the export (#177): in each mode, the camera of a frame exported from
    /// the playhead is the canvas's, scrubbed forwards and back; the immersed director's light
    /// reaches the canvas; a drag and the wheel move the plan, cheaply in Director, and
    /// `look.json` keeps what they framed for the export.
    @MainActor
    private static func exerciseFraming(
        _ session: StyleSession, _ model: SimulationModel, _ folder: SceneFolder, _ takeURL: URL,
        _ check: (String, Bool, String) -> Void
    ) {
        // What `sillage-render export` reads: the take off disk, at the folder's rate.
        guard let take = try? RecordingFile.read(from: takeURL),
            let rate = try? folder.capturedRate()
        else { return check("the take reads back for the export", false, "") }
        let last = Double(model.capturedFrames - 1)
        let (width, height) = (Int(model.drawableSize.width), Int(model.drawableSize.height))
        model.isPlaying = false

        /// The shot of the first frame of an export of `file` started at the playhead, at the
        /// canvas's size.
        func exported(_ file: LookFile, through export: TakeExport? = nil) -> ShotReplay.Shot? {
            guard let export = export ?? (try? TakeExport(take: take, look: file, capturedRate: rate))
            else { return nil }
            let start = model.capturedPlayhead / Double(rate)
            let positions = export.positions(framesPerSecond: rate, start: start, duration: 1 / Double(rate))
            return export.shots(atCaptured: positions, width: width, height: height).first
        }
        func gap(_ canvas: Camera, _ export: Camera) -> Float {
            let scale = max(simd_distance(export.eye, export.target), 1)
            let moved = max(
                simd_distance(canvas.eye, export.eye), simd_distance(canvas.target, export.target))
            return max(moved / scale, abs(canvas.fieldOfView - export.fieldOfView))
        }
        func near(_ a: Float?, _ b: Float?) -> Bool {
            guard let a, let b else { return false }
            return abs(a - b) <= 1e-5 * max(abs(a), abs(b), 1e-3)
        }
        /// The canvas at the playhead against the export of the file as it stands.
        func framedAlike() -> Float? {
            _ = model.playbackSnapshot()
            return exported(model.lookFile).map { gap(model.activeCamera, $0.camera) }
        }

        let modes: [(LookFile.CameraPlan.Mode, String)] = [
            (.auto, "Auto"), (.director, "Director"), (.fixed, "Fixed"), (.immersed, "Immersed"),
        ]
        // Forwards, back past where it was, back to the start, forwards again; between frames.
        let playheads = [0.61, 0.97, 0.23, 0, 0.42].map { min($0 * last + 0.37, last) }
        for (mode, name) in modes {
            session.setCameraMode(mode)
            let export = try? TakeExport(take: take, look: model.lookFile, capturedRate: rate)
            var worst: Float = 0
            var seen = 0
            for playhead in playheads {
                model.playbackPosition = playhead
                _ = model.playbackSnapshot()
                guard let shot = exported(model.lookFile, through: export) else { continue }
                worst = max(worst, gap(model.activeCamera, shot.camera))
                seen += 1
            }
            check(
                "\(name): the image frames as the export does, forwards and backwards",
                seen == playheads.count && worst < 1e-4 && model.followsPlan,
                String(format: "gap %.1e over %d playheads", worst, seen))
        }

        session.setCameraMode(.immersed)
        model.playbackPosition = last * 0.5
        _ = model.playbackSnapshot()
        let modulated = exported(model.lookFile)?.look
        let drawn = model.renderer?.settings
        check(
            "Immersed: the image takes the light the director modulates in the export",
            near(drawn?.brightness, modulated?.brightness) && near(drawn?.stretch, modulated?.stretch)
                && near(drawn?.bloomIntensity, modulated?.bloomIntensity),
            String(
                format: "brightness %.3f, the file's %.3f", drawn?.brightness ?? 0,
                model.look.brightness))
        let immersed = model.lookFile.camera
        model.drag(60, 30)
        check("Immersed: dragging leaves the plan alone", model.lookFile.camera == immersed, "")
        model.scroll(-30)
        let scrolled = framedAlike()
        check(
            "Immersed: the wheel moves away, and the image follows the export",
            model.lookFile.camera.zoom < immersed.zoom && scrolled.map { $0 < 1e-4 } == true,
            String(format: "zoom %.2f, gap %.1e", model.lookFile.camera.zoom, scrolled ?? -1))

        // The director's plan reads the take once; an edit only turns and scales it.
        session.setCameraMode(.director)
        _ = model.playbackSnapshot()
        let planned = model.lookFile.camera
        let started = CACurrentMediaTime()
        model.drag(-50, 20)
        model.scroll(15)
        _ = model.planShot
        let milliseconds = (CACurrentMediaTime() - started) * 1000
        let directed = framedAlike()
        check(
            "Director: drag and wheel set its wide shots, quickly, as in the export",
            model.lookFile.camera.azimuth != planned.azimuth && model.lookFile.camera.zoom > planned.zoom
                && directed.map { $0 < 1e-4 } == true && milliseconds < 100,
            String(format: "%.1f ms, gap %.1e", milliseconds, directed ?? -1))

        session.setCameraMode(.fixed)
        _ = model.playbackSnapshot()
        check(
            "Fixed: the file's light comes back",
            model.renderer?.settings.brightness == model.look.brightness, "")
        let before = model.lookFile.camera
        let eye = model.activeCamera.eye
        model.drag(40, -25)
        model.scroll(12)
        _ = model.playbackSnapshot()
        let steered = model.lookFile.camera
        check(
            "Fixed: drag turns the plan, the wheel brings it closer, the image follows",
            model.steersPlan && steered.azimuth != before.azimuth && steered.elevation < before.elevation
                && steered.zoom > before.zoom && abs(steered.rotation - before.rotation) < 1e-5
                && simd_distance(model.activeCamera.eye, eye) > 1,
            String(
                format: "azimuth %.2f, elevation %.2f, zoom %.2f", steered.azimuth, steered.elevation,
                steered.zoom))
        let canvas = model.activeCamera
        check("the framing made with the mouse is saved", session.promote(), "")
        let onDisk = try? folder.exportLook(nil, catalogue: [])
        let fromDisk = onDisk.flatMap { exported($0) }
        check(
            "look.json keeps this framing and the export frames it",
            onDisk?.camera == steered && fromDisk.map { gap(canvas, $0.camera) < 1e-4 } == true,
            String(format: "gap %.1e", fromDisk.map { gap(canvas, $0.camera) } ?? -1))

        model.followsPlan = false
        model.drag(30, 10)
        check(
            "free view: the mouse no longer touches the plan",
            !model.steersPlan && model.lookFile.camera == steered
                && model.activeCamera.eye == model.camera.camera.eye, "")
        model.followsPlan = true

        // A step back replays the immersed director from the first frame.
        session.setCameraMode(.immersed)
        model.playbackPosition = last
        _ = model.planShot
        model.playbackPosition = last - 0.5
        let replaying = CACurrentMediaTime()
        _ = model.planShot
        let replayed = (CACurrentMediaTime() - replaying) * 1000
        check(
            "Immersed: replaying it to the end of the take stays quick", replayed < 100,
            String(format: "%.1f ms for %d frames", replayed, model.playheadCapturedFrame))
    }

    /// Auto on the telescope world, with a lock: a rendering and a palette from the catalogue,
    /// the locked colour kept, the camera left alone, the rendering's dust drawn as a web.
    @MainActor
    private static func exerciseAuto(
        _ session: StyleSession, _ model: SimulationModel, _ check: (String, Bool, String) -> Void
    ) {
        session.world = .telescope
        session.locked = [0]
        session.setMulticolour(true, waiting: true)
        let kept = model.lookFile.colour(ofGalaxy: 0, in: model.scene)
        let camera = model.lookFile.camera
        let started = CACurrentMediaTime()
        session.runAuto()
        let deadline = Date().addingTimeInterval(300)
        while session.autoRunning, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        let seconds = CACurrentMediaTime() - started
        let note = session.note ?? ""
        check(
            "auto chooses a telescope rendering and palette",
            note.hasPrefix("Auto:") && session.rendering?.world == .telescope
                && model.lookFile.paletteRecipe?.world == .telescope,
            String(format: "%.1f s · %@", seconds, note))
        check(
            "auto gives ramps when multicolour is on",
            session.multicolour && model.lookFile.palette.dropFirst().allSatisfy { $0.ramp != nil }
                && model.lookFile.paletteRecipe?.multicolour == true, "")
        check(
            "auto respects the lock and the plan",
            model.lookFile.colour(ofGalaxy: 0, in: model.scene) == kept && model.lookFile.camera == camera,
            "")
        let dust = session.rendering.map { min($0.look.dustStrength, StyleAuto.dustCap ?? .infinity) }
        check(
            "auto keeps the rendering's dust and its web",
            model.lookFile.look.dustStrength == dust
                && model.lookFile.look.dustWeb == RenderLook.styleDustWeb,
            "dust \(StyleNames.number(model.lookFile.look.dustStrength)), web "
                + StyleNames.number(model.lookFile.look.dustWeb))
    }
}
