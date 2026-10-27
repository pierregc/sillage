import AppKit
import Foundation
import SillageCore
import SillageRender

/// Opens a take with a look file the way the library does, and checks what tuning promises:
/// the file comes back byte for byte, every kind of edit lands where it should and survives a
/// save, and the playhead can be thrown backwards and forwards at the take's full size. Then
/// the style editor's session on it: renderings, palettes and locks, Avant/Après, Annuler,
/// Utiliser pour la scène, and Auto when the take sits in a scene folder.
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
            lines.append("\(passed ? "OUI" : "NON")  \(label)\(detail.isEmpty ? "" : "  \(detail)")")
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
        else { fail("look illisible") }

        guard let model = SimulationModel() else { fail("pas de périphérique Metal") }
        let buildsBefore = model.rendererBuilds
        let opening = CACurrentMediaTime()
        model.openTake(from: take, look: lookURL, folder: folder)
        let deadline = Date().addingTimeInterval(900)
        while model.mode != .playback || model.capturedFrames < 2 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            if let failure = model.failure { fail(failure) }
            if Date() > deadline { fail("la prise n'a pas chargé") }
        }
        let openSeconds = CACurrentMediaTime() - opening
        let builds = model.rendererBuilds - buildsBefore
        model.resize(to: CGSize(width: 1920, height: 1080))

        check("le look ouvert est celui du fichier", model.lookFile == loaded)
        check("une seule construction du rendu à l'ouverture", builds == 1, "\(builds)")
        check(
            "la palette du fichier colore la scène",
            loaded.palette.isEmpty || model.scene.galaxies[0].color == loaded.palette[0].colour)
        check(
            "le plan de caméra est suivi", model.followsPlan == [.fixed, .auto].contains(loaded.camera.mode))

        let resaved = folder.url.appendingPathComponent("resaved.look.json")
        model.saveLook(to: resaved)
        check(
            "ouvert puis enregistré sans changement : même fichier",
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
            guard model.playbackSnapshot() != nil else { fail("rien à dessiner") }
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
        check("les réglages vifs ne reconstruisent rien", model.rendererBuilds == builds0)
        check(
            "la couleur d'une galaxie arrive à la scène",
            model.scene.galaxies.last?.color == SIMD3(0.2, 0.5, 1))
        builds0 = model.rendererBuilds
        model.lookFile.starCount = 20_000
        model.lookFile.bloomLevels = 5
        check("chaque réglage de tampon reconstruit une fois", model.rendererBuilds == builds0 + 2)

        model.playbackPosition = last / 2
        _ = model.playbackSnapshot()
        let planned = model.planCamera
        check(
            "la caméra affichée est celle du plan",
            planned != nil && model.activeCamera.eye == planned?.eye)
        model.adopt(RenderLook.catalogue[1])
        check("un look nommé ne touche ni palette ni plan", model.lookFile.camera.zoom == 1.6)

        let edited = model.lookFile
        let saved = folder.url.appendingPathComponent("edited.look.json")
        model.saveLook(to: saved)
        model.adopt(LookFile.standard, from: nil)
        model.openLook(from: saved)
        check("enregistré puis rouvert : le même look", model.lookFile == edited)
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
        check("l'éditeur trouve la prise ouverte", session.isOpen)
        check("les retouches faites avant se voient", session.saved == loaded && session.isModified)
        session.cancel()
        check("annuler remet le style enregistré", model.lookFile == loaded && !session.isModified)
        exerciseStyle(session, model, folder, check)

        // Annuler after all of it: the saved style back on the picture, nothing written.
        session.cancel()
        check("annuler après les essais", model.lookFile == loaded && !session.isModified)
        check(
            "annuler n'écrit rien",
            (try? Data(contentsOf: folder.look)) == savedBefore
                && !FileManager.default.fileExists(atPath: folder.rawLook.path))

        // Utiliser pour la scène: look.json is the style on screen, the explored look stays aside.
        if let hubble = session.catalogue.first(where: { $0.name == "hubble" }) { session.apply(hubble) }
        model.lookFile.camera.zoom = 1.3
        let chosen = model.lookFile
        check("une retouche se voit", session.isModified)
        check("utiliser pour la scène écrit look.json", session.promote())
        check(
            "look.json est le style à l'écran",
            (try? LookFile.decoded(from: Data(contentsOf: folder.look))) == chosen
                && session.saved == chosen && !session.isModified && session.promoted)
        check(
            "l'ancien look reste dans look-raw.json", (try? Data(contentsOf: folder.rawLook)) == savedBefore)
        check("le look de l'atelier pointe sur la scène", model.lookURL == folder.look)

        if FileManager.default.fileExists(atPath: folder.scene.path) {
            exerciseAuto(session, model, check)
        } else {
            lines.append("—    Auto non essayé : la prise n'est pas dans un dossier de scène")
        }

        func split(_ name: String, _ samples: [Double]) -> String {
            let sorted = samples.sorted()
            return String(
                format: "%@ médiane %6.1f ms, pire %6.1f", name, sorted[sorted.count / 2],
                sorted.last ?? 0)
        }
        let report =
            """
            prise            \(model.particleCount) particules, \(model.capturedFrames) images gardées (une sur \(model.recording?.interval ?? 1)), ouverte en \(String(format: "%.1f", openSeconds)) s
            \(split("sauts au hasard ", jumps))
            \(split("en arrière      ", backwards))
            \(split("en avant        ", forwards))
            """ + "\n" + lines.joined(separator: "\n")
        try? report.write(
            to: URL(fileURLWithPath: "/tmp/sillage-lookcheck.log"), atomically: true,
            encoding: .utf8)
        print(report)
        exit(failed ? 1 : 0)
    }

    /// Renderings, palettes and their locks, the camera, a reset and Avant/Après, each on the
    /// picture and none written.
    @MainActor
    private static func exerciseStyle(
        _ session: StyleSession, _ model: SimulationModel, _ folder: SceneFolder,
        _ check: (String, Bool, String) -> Void
    ) {
        let before = model.lookFile
        let onDisk = try? Data(contentsOf: folder.look)
        guard let webb = session.catalogue.first(where: { $0.name == "webb" }) else {
            return check("le catalogue a Webb", false, "")
        }
        session.apply(webb)
        check(
            "un rendu garde la palette et le plan",
            session.rendering?.name == "webb" && model.lookFile.palette == before.palette
                && model.lookFile.camera == before.camera && session.isModified, "")
        session.apply(webb, colours: true)
        check(
            "avec ses couleurs prend aussi sa palette",
            model.lookFile.palette == webb.palette && session.world == .telescope, "")

        session.world = .free
        session.propose(waiting: true)
        let galaxies = model.scene.galaxies.count
        check(
            "six propositions dans le monde choisi",
            session.proposals.count == StyleSession.proposalCount
                && session.proposals.allSatisfy { $0.palette.world == .free }, "\(session.proposals.count)")
        let first = session.proposals.map(\.palette)
        session.moreProposals(waiting: true)
        check("autres palettes en propose d'autres", session.proposals.map(\.palette) != first, "")
        if let proposal = session.proposals.first?.palette {
            let file = session.favouritesDirectory.appendingPathComponent("soir-de-test.palette.json")
            check("aucun favori au départ", session.favourites.isEmpty && !session.isFavourite(proposal), "")
            session.toggleFavourite(proposal)
            check("le cœur demande un nom", session.naming == proposal && session.favourites.isEmpty, "")
            session.saveFavourite(proposal, named: "Soir de Test")
            check(
                "le favori est écrit et reconnu",
                FileManager.default.fileExists(atPath: file.path) && session.isFavourite(proposal)
                    && session.naming == nil, "")
            session.propose(waiting: true)
            check(
                "le favori passe en tête des propositions",
                session.proposals.first?.palette == proposal.truncated(to: galaxies)
                    && session.proposals.count == StyleSession.proposalCount
                    && session.favouriteProposals.count == 1, "\(session.proposals.count)")
            session.world = .telescope
            session.propose(waiting: true)
            check("un favori d'un autre monde ne s'y propose pas", session.favouriteProposals.isEmpty, "")
            session.world = .free
            session.propose(waiting: true)
            session.toggleFavourite(proposal)
            check(
                "un second clic retire le favori",
                !FileManager.default.fileExists(atPath: file.path) && session.favourites.isEmpty
                    && !session.isFavourite(proposal), "")
            try? FileManager.default.removeItem(at: session.favouritesDirectory)
        }
        if galaxies > 1, let proposal = session.proposals.last?.palette {
            let kept = model.lookFile.palette[0]
            session.toggleLock(0)
            session.use(proposal)
            check(
                "un cadenas garde sa couleur, les autres changent",
                model.lookFile.palette[0] == kept && model.lookFile.palette[1].colour == proposal.colours[1]
                    && model.lookFile.paletteRecipe == proposal, "")
            check(
                "la palette arrive à la scène",
                model.scene.galaxies[1].color == proposal.colours[1], "")

            // The look this check opens has plain colours, so the switch starts off.
            check(
                "multicolore éteint sur un look sans rampes : propositions et palette unies",
                !session.multicolour && !model.lookFile.hasRamps
                    && session.proposals.allSatisfy { !$0.palette.multicolour }, "")
            session.setMulticolour(true, waiting: true)
            check(
                "allumé : une rampe par galaxie libre, la couleur choisie et le cadenas gardés",
                session.multicolour && model.lookFile.palette[0] == kept
                    && model.lookFile.palette[1].ramp != nil
                    && model.lookFile.palette[1].colour == proposal.colours[1]
                    && model.lookFile.paletteRecipe == proposal.withMulticolour(true), "")
            check(
                "allumé : les propositions ont des rampes et leurs notes",
                session.proposals.count == StyleSession.proposalCount
                    && session.proposals.allSatisfy { $0.palette.multicolour && $0.score.between != nil },
                "")
            session.setMulticolour(false, waiting: true)
            check(
                "éteint : une couleur par galaxie, les propositions sans notes de rampe",
                !session.multicolour && !model.lookFile.hasRamps
                    && model.lookFile.palette[1].colour == proposal.colours[1]
                    && model.lookFile.paletteRecipe?.multicolour == false
                    && session.proposals.allSatisfy { !$0.palette.multicolour && $0.score.between == nil },
                "")
            session.setMulticolour(true, waiting: true)
        }

        session.setCameraMode(.fixed)
        session.binding(\.camera.rotation).wrappedValue = .pi / 2
        check(
            "caméra fixe et rotation",
            model.lookFile.camera.mode == .fixed && model.followsPlan
                && abs((model.lookFile.camera.azimuthEnd ?? 0) - model.lookFile.camera.azimuth - .pi / 2)
                    < 1e-5,
            "")
        session.binding(\.look.brightness).wrappedValue = 1.7
        session.reset(.light)
        check(
            "réinitialiser la lumière revient au rendu",
            model.lookFile.look.brightness == webb.look.brightness, "")
        session.reset(.camera)
        check("réinitialiser le plan revient au style enregistré", model.lookFile.camera == before.camera, "")

        let edited = model.lookFile
        session.showSaved(true)
        check(
            "avant : le style enregistré à l'écran",
            model.lookFile == session.saved && session.covered == edited && session.isModified, "")
        session.binding(\.look.brightness).wrappedValue = 0.01
        check("rien ne bouge pendant l'avant", model.lookFile == session.saved, "")
        session.showSaved(false)
        check("après : la retouche revient", model.lookFile == edited && session.covered == nil, "")
        check("rien d'écrit pendant les essais", (try? Data(contentsOf: folder.look)) == onDisk, "")
    }

    /// Auto on the telescope world, with a lock: a rendering and a palette from the catalogue,
    /// the locked colour kept, the camera left alone.
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
            "auto choisit un rendu et une palette du télescope",
            note.hasPrefix("Auto :") && session.rendering?.world == .telescope
                && model.lookFile.paletteRecipe?.world == .telescope,
            String(format: "%.1f s · %@", seconds, note))
        check(
            "auto donne des rampes quand multicolore est allumé",
            session.multicolour && model.lookFile.palette.dropFirst().allSatisfy { $0.ramp != nil }
                && model.lookFile.paletteRecipe?.multicolour == true, "")
        check(
            "auto respecte le cadenas et le plan",
            model.lookFile.colour(ofGalaxy: 0, in: model.scene) == kept && model.lookFile.camera == camera,
            "")
    }
}
