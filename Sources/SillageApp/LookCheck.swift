import AppKit
import Foundation
import SillageCore
import SillageRender

/// Opens a take with a look file the way the library does, and checks what tuning promises:
/// the file comes back byte for byte, every kind of edit lands where it should and survives a
/// save, and the playhead can be thrown backwards and forwards at the take's full size.
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
        model.promoteLook()
        let keptAside = lookURL == folder.look ? loaded : nil
        check(
            "promu dans la scène, l'ancien gardé à côté",
            (try? LookFile.decoded(from: Data(contentsOf: folder.look))) == edited
                && (try? LookFile.decoded(from: Data(contentsOf: folder.rawLook))) == keptAside)

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
}
