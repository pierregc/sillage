import AVFoundation
import AppKit
import Foundation
import SillageRender
import SwiftUI

/// Builds a library on disk and drives the window's model through it: scenes arriving,
/// keys, clicks, filters, a ratings file changed by another tool, a render still being
/// written, the single player, and a batch of four hundred. Headless, like `--replay`, and
/// it renders the grid to `out/ui-library.png` for looking at.
@MainActor
enum LibraryCheck {
    private static var lines: [String] = []
    private static var failures = 0
    private static var stills = 0

    static func run() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sillage-librarycheck-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try exercise(root)
        } catch {
            check("le parcours va au bout", false, "\(error)")
        }
        let report = lines.joined(separator: "\n")
        try? report.write(
            to: URL(fileURLWithPath: "/tmp/sillage-library.log"), atomically: true, encoding: .utf8)
        print(report)
        try? FileManager.default.removeItem(at: root)
        exit(failures == 0 ? 0 : 1)
    }

    private static func check(_ name: String, _ passed: Bool, _ detail: String = "") {
        lines.append("\(passed ? "OUI" : "NON")  \(name)\(detail.isEmpty ? "" : "  (\(detail))")")
        if !passed { failures += 1 }
    }

    /// Turns the run loop, which is where the model's tasks resume, until the condition holds.
    private static func wait(_ seconds: Double, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return true
    }

    private static func exercise(_ root: URL) throws {
        let batch = root.appendingPathComponent("2026-10-24", isDirectory: true)
        let flat = root.appendingPathComponent("2026-09-21", isDirectory: true)
        for index in 1...3 {
            try writeScene(
                SceneFolder(batch.appendingPathComponent(String(format: "scene-%04d", index))),
                tint: index, archetype: index == 1 ? "antennae" : nil)
        }
        try FileManager.default.createDirectory(at: flat, withIntermediateDirectories: true)
        try writeVideo(to: flat.appendingPathComponent("scene-0001.mov"), tint: 4)
        try Data("id,seed,tempo,galaxies\nscene-0001,77,ballet,4\n".utf8)
            .write(to: flat.appendingPathComponent("index.csv"))

        let model = LibraryModel(root: root)
        model.watch()
        defer { model.stop() }
        check(
            "les deux formes de lot sont lues", wait(10) { model.scenes.count == 4 },
            "\(model.scenes.count) scènes")
        check("chaque vidéo est jouable", wait(10) { model.playable.count == 4 }, "\(model.playable.count)")
        let ids = model.visible.map(\.id)
        check(
            "le lot le plus récent vient en premier",
            ids == [
                "2026-10-24/scene-0001", "2026-10-24/scene-0002", "2026-10-24/scene-0003",
                "2026-09-21/scene-0001",
            ],
            ids.joined(separator: " "))

        stills = 0
        let scenes = model.scenes
        Task {
            for scene in scenes where await ThumbnailCache.shared.load(scene) != nil { stills += 1 }
        }
        check(
            "une vignette par scène, tirée de la vidéo sans thumbnail", wait(10) { stills == 4 }, "\(stills)")

        // Keys, each one saved as it is pressed.
        let first = SceneFolder(batch.appendingPathComponent("scene-0001"))
        model.handle(.right)
        check("la première flèche choisit la première scène", model.selection == "2026-10-24/scene-0001")
        model.handle(.yes)
        let now = Date()
        model.handle(.digit(1), at: now)
        model.handle(.digit(0), at: now.addingTimeInterval(0.2))
        var saved = SceneRatings.read(batch: first.batch).scenes["scene-0001"]
        check(
            "Y puis 1 0 : oui et 10 dans ratings.json", saved?.choice == .yes && saved?.rating == 10,
            "\(String(describing: saved))")
        model.handle(.digit(7), at: now.addingTimeInterval(2))
        model.handle(.digit(0), at: now.addingTimeInterval(4))
        saved = SceneRatings.read(batch: first.batch).scenes["scene-0001"]
        check("un 0 qui ne suit pas un 1 vaut 0", saved?.rating == 0, "\(String(describing: saved?.rating))")
        model.handle(.right)
        model.handle(.no)
        check(
            "N sur la scène suivante",
            SceneRatings.read(batch: batch).scenes["scene-0002"]?.choice == .no)
        model.columns = 2
        model.handle(.down)
        check("une ligne plus bas, deux colonnes plus loin", model.selection == "2026-09-21/scene-0001")
        model.handle(.digit(4))
        check(
            "un lot à plat a son propre ratings.json",
            SceneRatings.read(batch: flat).scenes["scene-0001"]?.rating == 4)
        model.handle(.clear)
        check("effacer retire la scène du fichier", SceneRatings.read(batch: flat).scenes.isEmpty)

        // Clicks: one saves, the same one again takes it back.
        let third = "2026-10-24/scene-0003"
        model.choose(.yes, for: third)
        let clicked = SceneRatings.read(batch: batch).scenes["scene-0003"]?.choice
        model.choose(.yes, for: third)
        model.rate(6, for: third)
        let rated = SceneRatings.read(batch: batch).scenes["scene-0003"]
        check(
            "un clic enregistre, un second l'annule",
            clicked == .yes && rated?.choice == nil && rated?.rating == 6)

        // The collections follow the clicks at once, without waiting for a scan.
        let counts = model.counts
        check(
            "les compteurs suivent les choix",
            counts[.toSort] == 2 && counts[.chosen] == 1 && counts[.all] == 4
                && counts[.toStyle] == nil,
            "\(counts)")
        model.query.collection = .chosen
        check("Choisies ne montre que les oui", model.visible.map(\.id) == ["2026-10-24/scene-0001"])
        model.query.collection = .toSort
        check(
            "À trier ne montre ni les oui ni les non",
            model.visible.map(\.id) == ["2026-10-24/scene-0003", "2026-09-21/scene-0001"],
            model.visible.map(\.id).joined(separator: " "))
        model.query.search = "0003"
        check("la recherche porte sur le nom", model.visible.map(\.id) == ["2026-10-24/scene-0003"])
        model.query = LibraryQuery()
        check(
            "Toutes garde les écartées",
            model.visible.count == 4 && model.visible.contains { $0.stage == .discarded })

        // Filters.
        model.query.choice = .yes
        check("filtre oui", model.visible.map(\.id) == ["2026-10-24/scene-0001"])
        model.query = LibraryQuery()
        model.query.archetype = "antennae"
        check("filtre par archétype", model.visible.map(\.id) == ["2026-10-24/scene-0001"])
        model.query = LibraryQuery()
        model.query.archetype = LibraryQuery.free
        check("les scènes sans archétype sont libres", model.visible.count == 3)
        model.query = LibraryQuery()
        model.query.batch = "2026-09-21"
        check("filtre par lot", model.visible.map(\.id) == ["2026-09-21/scene-0001"])
        model.query = LibraryQuery()
        model.query.order = .rating
        check(
            "tri par note", model.visible.first?.id == "2026-10-24/scene-0003",
            model.visible.map(\.id).joined(separator: " "))
        model.query = LibraryQuery()
        model.query.choice = .undecided
        model.selection = third
        model.handle(.yes)
        check(
            "une scène qui sort du filtre laisse la sélection à la suivante",
            model.selection == "2026-09-21/scene-0001" && !model.visible.contains { $0.id == third },
            model.selection ?? "aucune")
        model.query = LibraryQuery()

        // Another tool writes the file.
        try SceneRatings.update(batch: batch, scene: "scene-0002") { $0.rating = 3 }
        check(
            "un ratings.json changé ailleurs est relu",
            wait(6) { model.entries["2026-10-24/scene-0002"]?.rating == 3 })

        // A render still writing its preview, then finishing it.
        let arriving = SceneFolder(batch.appendingPathComponent("scene-0004"))
        try FileManager.default.createDirectory(at: arriving.url, withIntermediateDirectories: true)
        try PNGWriter.write(pixels(tint: 5), width: width, height: height, to: arriving.thumbnail)
        try Data("pas encore une vidéo".utf8).write(to: arriving.preview)
        check("une scène qui arrive apparaît sans rien relancer", wait(6) { model.scenes.count == 5 })
        check("tant qu'elle s'écrit elle ne joue pas", !model.playable.contains("2026-10-24/scene-0004"))
        try writeVideo(to: arriving.preview, tint: 5)
        check("finie, elle joue", wait(8) { model.playable.contains("2026-10-24/scene-0004") })

        // One player, following the pointer, then the opened scene.
        model.selection = "2026-10-24/scene-0001"
        check("la sélection joue", model.playing == "2026-10-24/scene-0001")
        model.hover("2026-10-24/scene-0002", inside: true)
        check("le survol joue", wait(2) { model.playing == "2026-10-24/scene-0002" })
        model.open("2026-10-24/scene-0003")
        check("la scène ouverte passe avant le survol", model.playing == "2026-10-24/scene-0003")
        check(
            "le lecteur lit vraiment",
            wait(5) { model.player.currentItem?.status == .readyToPlay },
            "\(model.player.currentItem?.status.rawValue ?? -1)")
        check("échap referme", model.handle(.close) && model.opened == nil)
        model.hover("2026-10-24/scene-0002", inside: false)
        check(
            "un seul lecteur", model.player.items().count <= 3,
            "\(model.player.items().count) éléments en file")

        var clock = Date()
        try renderShot(model)

        // A library of about a hundred scenes with every kind of file, read in one scan.
        let stages = FileManager.default.temporaryDirectory
            .appendingPathComponent("sillage-stagescan-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stages) }
        var picks: [String: SceneRatings.Entry] = [:]
        for index in 0..<100 {
            let name = String(format: "scene-%04d", index)
            let folder = SceneFolder(stages.appendingPathComponent("2026-10-26/\(name)"))
            try FileManager.default.createDirectory(
                at: folder.exports, withIntermediateDirectories: true)
            try Data().write(to: folder.thumbnail)
            try Data(#"{"draw":{"generator":"mice"}}"#.utf8).write(to: folder.scene)
            try Data(#"{"score":0.5}"#.utf8).write(to: folder.interest)
            if index % 2 == 0 { picks[name] = .init(choice: index % 6 == 0 ? .no : .yes) }
            if index % 4 == 0 {
                try Data().write(to: folder.take)
                try Data(#"{"particles":5000000,"seconds":900}"#.utf8).write(to: folder.hires)
            }
            if index % 8 == 0 { try Data().write(to: folder.rawLook) }
            if index % 16 == 0 { try Data().write(to: folder.export(preset: "1080p")) }
        }
        try SceneRatings(scenes: picks).write(batch: stages.appendingPathComponent("2026-10-26"))
        _ = SceneLibrary.scan(stages)
        clock = Date()
        let hundred = SceneLibrary.scan(stages)
        let hundredScan = Date().timeIntervalSince(clock)
        check(
            "100 scènes à toutes les étapes lues en moins de 50 ms",
            hundred.count == 100 && hundredScan < 0.05 && Set(hundred.map(\.stage)).count >= 5,
            "\(ms(hundredScan)), \(Set(hundred.map(\.stage)).count) étapes")

        // A batch of four hundred, the size a night produces.
        let crowd = root.appendingPathComponent("2026-10-25", isDirectory: true)
        for index in 1...400 {
            let folder = SceneFolder(crowd.appendingPathComponent(String(format: "scene-%04d", index)))
            try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: first.thumbnail, to: folder.thumbnail)
            try FileManager.default.copyItem(at: first.preview, to: folder.preview)
        }
        clock = Date()
        let scanned = SceneLibrary.scan(root)
        let scan = Date().timeIntervalSince(clock)
        check("405 scènes lues en moins d'une demi-seconde", scanned.count == 405 && scan < 0.5, ms(scan))
        clock = Date()
        let arrived = wait(30) { model.scenes.count == 405 }
        check("le lot entier arrive dans la fenêtre", arrived, ms(Date().timeIntervalSince(clock)))
        clock = Date()
        let probed = wait(120) { model.playable.count == 405 }
        check(
            "chaque vidéo sondée une fois", probed,
            "\(model.playable.count) en \(ms(Date().timeIntervalSince(clock)))")
        clock = Date()
        for _ in 0..<10 { _ = model.query.apply(model.scenes, entries: model.entries) }
        let filter = Date().timeIntervalSince(clock) / 10
        check("trier et filtrer 405 scènes tient dans une image", filter < 0.008, ms(filter))
        clock = Date()
        model.selection = "2026-10-25/scene-0200"
        model.handle(.digit(8))
        let click = Date().timeIntervalSince(clock)
        check("un choix dans un lot de 400 est immédiat", click < 0.016, ms(click))
        let rescans = model.scenes.count
        clock = Date()
        _ = wait(2.5) { false }
        check(
            "un scan qui ne trouve rien de neuf ne change rien", model.scenes.count == rescans,
            "dernier scan \(ms(model.lastScan))")

        try exerciseTriage()
        try exerciseScenePage()
    }

    /// Three scenes of one night at different steps, walked through the scene page: versions,
    /// steps, neighbours, a choice that takes the scene out of its collection, the commands to
    /// copy and the way back to the raw style.
    private static func exerciseScenePage() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sillage-scenepage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let night = root.appendingPathComponent("2026-10-26", isDirectory: true)
        let folders = (1...3).map {
            SceneFolder(night.appendingPathComponent(String(format: "scene-%04d", $0)))
        }
        for (offset, folder) in folders.enumerated() {
            try writeScene(folder, tint: offset + 6, archetype: offset == 0 ? "antennae" : nil)
            try Data(#"{"score":\#(0.9 - Double(offset) / 10)}"#.utf8).write(to: folder.interest)
        }
        try Data(
            "id,batch_seed,index,galaxies\nscene-0001,20261026,1,2\nscene-0002,20261026,2,3\n".utf8
        ).write(to: night.appendingPathComponent("index.csv"))
        var clip = SceneFolder.Clip()
        clip.story = .init(startFrame: 40, endFrame: 700, startMyr: 82, endMyr: 461, complete: true)
        try clip.encoded().write(to: folders[0].clip)

        // The first has gone all the way: take, hires record and clip, a style, two exports.
        let done = folders[0]
        try Data().write(to: done.take)
        try writeVideo(to: done.hiresVideo, tint: 9)
        try Data(
            """
            {"particles":2000000,"previewParticles":200000,"width":1920,"height":1080,"frames":660,
            "fps":30,"settle":300,"steps":1980,"timeStepScale":1,"timeStep":0.05,"timeStepMyr":0.2,
            "previewTimeStepMyr":0.2,"softening":0.08,"clipStartMyr":82,"clipEndMyr":461,"seconds":5100}
            """.utf8
        ).write(to: done.hires)
        try LookFile(name: "raw", palette: [[1, 0.62, 0.25], [0.3, 0.7, 1]]).encoded().write(to: done.look)
        try done.promote(LookFile(name: "dream", palette: [[0.9, 0.3, 0.6], [0.2, 0.9, 0.8]]))
        try FileManager.default.createDirectory(at: done.exports, withIntermediateDirectories: true)
        try writeVideo(to: done.export(preset: "1080p"), tint: 12)
        try Data("légende".utf8).write(to: done.exports.appendingPathComponent("whatsapp.txt"))
        try SceneRatings(scenes: [
            "scene-0001": .init(choice: .yes, rating: 8), "scene-0003": .init(choice: .yes),
        ]).write(batch: night)

        let model = LibraryModel(root: root)
        model.pasteboard = NSPasteboard(name: .init("dev.pierregc.sillage.librarycheck"))
        model.watch()
        defer { model.stop() }
        check("trois scènes pour la page", wait(10) { model.scenes.count == 3 && model.playable.count == 3 })
        let id = { (index: Int) in "2026-10-26/" + String(format: "scene-%04d", index) }

        stills = 0
        let pageScenes = model.scenes
        Task { for scene in pageScenes where await ThumbnailCache.shared.load(scene) != nil { stills += 1 } }
        _ = wait(10) { stills == 3 }
        model.open(id(1))
        check("un clic ouvre la page de la scène", model.opened == id(1) && model.selection == id(1))
        check("ce que la page lit arrive", wait(5) { model.facts?.id == id(1) })
        let scene = try found(model.scene(id(1)))
        check(
            "versions : aperçu, haute résolution, puis chaque vidéo",
            scene.versions.map(\.title) == ["Aperçu", "Haute résolution", "Vidéo 1080p"],
            scene.versions.map(\.title).joined(separator: ", "))
        check(
            "la page joue d'abord la vidéo exportée",
            model.playingURL?.lastPathComponent == "1080p.mp4" && model.playing == id(1))
        model.version = done.hiresVideo
        check("choisir une version la joue à la place", model.playingURL == done.hiresVideo)
        check(
            "un seul décodeur",
            model.player.items().count <= 3
                && wait(5) {
                    model.player.currentItem?.status == .readyToPlay
                })
        let states = SceneStep.states(scene, entry: model.entries[id(1)])
        check("tout est fait, rien n'est la suite", SceneStep.allCases.allSatisfy { states[$0] == .done })
        let facts = model.facts
        check(
            "la page lit l'histoire, le calcul et le style",
            facts?.story?.endMyr == 461 && facts?.hires?.particles == 2_000_000
                && facts?.styleName == "dream" && facts?.palette.count == 2 && facts?.rawStyle == false
                && facts?.otherLooks.map(\.name) == ["raw"],
            facts?.styleName ?? "pas de style")
        check("graine et index du lot", scene.seed == "20261026" && scene.index == 1)
        render(ScenePage(model: model, scene: scene, snapshot: true), to: "out/ui-scene-page.png")

        let hires = StageCommand.hires(done, particles: 5_000_000)
        check(
            "la commande hires vise le dossier et la taille",
            hires.contains("dev.sh hires \(done.url.path) --particles 5000000"), hires)
        let again = StageCommand.export(done, preset: "1080p", existing: scene.exports)
        check(
            "exporter à nouveau ne remplace pas la vidéo",
            again.hasSuffix("--preset 1080p --out \(done.exports.path)/1080p-2.mp4"), again)
        let otherLook = StageCommand.export(
            done, preset: "1080p", look: facts?.otherLooks.first, existing: scene.exports)
        check(
            "un autre style va dans un fichier à lui",
            otherLook.contains("--look \(done.rawLook.path)") && otherLook.hasSuffix("1080p-raw.mp4"),
            otherLook)
        check(
            "4k va à sa place",
            StageCommand.export(done, preset: "4k", existing: scene.exports).hasSuffix("--preset 4k"))
        model.copy(hires)
        check(
            "copier met la commande dans le presse-papiers",
            model.pasteboard.string(forType: .string) == hires && model.copied == hires)

        model.restoreRawLook(scene)
        check(
            "revenir au style brut garde l'autre dans looks/",
            done.hasRawLook && FileManager.default.fileExists(atPath: done.lookFile(named: "dream").path)
                && wait(5) { model.facts?.rawStyle == true })

        // Neighbours in the collection, and a choice that takes the scene out of it.
        model.handle(.right)
        check(
            "→ passe à la voisine et revient à sa version par défaut",
            model.opened == id(2) && model.version == nil
                && model.playingURL == folders[1].preview)
        model.close()
        model.query.collection = .toSort
        model.open(id(2))
        model.handle(.yes)
        check(
            "oui sur la page : la scène quitte À trier mais la page reste",
            model.opened == id(2) && !model.visible.contains { $0.id == id(2) }
                && model.entries[id(2)]?.choice == .yes)
        let chosen = try found(model.scene(id(2)))
        let next = SceneStep.states(chosen, entry: model.entries[id(2)])
        check("la suite est la haute résolution", next[.highResolution] == .next && next[.style] == .later)
        model.query.collection = .chosen
        model.open(id(3))
        _ = wait(5) { model.facts?.id == id(3) }
        check(
            "les tailles proposées disent leur durée",
            model.facts?.hiresCosts.first { $0.particles == 2_000_000 }?.label == "2 M, environ 1 h 25",
            model.facts?.hiresCosts.map(\.label).joined(separator: " / ") ?? "rien")
        render(
            ScenePage(model: model, scene: try found(model.scene(id(3))), snapshot: true),
            to: "out/ui-scene-page-next.png")
        model.handle(.left)
        check("← passe à la voisine de Choisies", model.opened == id(2), model.opened ?? "fermée")
        model.handle(.digit(6))
        check("un chiffre note la scène de la page", model.entries[id(2)]?.rating == 6)
        check(
            "échap revient à la grille sur la même scène",
            model.handle(.close) && model.opened == nil && model.selection == id(2))
        model.handle(.open)
        check("espace rouvre la page", model.opened == id(2))
        model.stop()
        check("quitter la bibliothèque ferme la page", model.opened == nil && model.playing == nil)
    }

    private struct Missing: Error {}

    private static func found<T>(_ value: T?) throws -> T {
        guard let value else { throw Missing() }
        return value
    }

    private static func render(_ page: ScenePage, to path: String) {
        write(page.frame(width: 1180, height: 940), to: path)
    }

    /// Four scored scenes in one night, sorted through the triage view the way a night is: yes,
    /// no, ratings, back and forth, a scene arriving, the end.
    private static func exerciseTriage() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sillage-triagecheck-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let night = root.appendingPathComponent("2026-10-26", isDirectory: true)
        func addScene(_ index: Int) throws {
            let folder = SceneFolder(night.appendingPathComponent(String(format: "scene-%04d", index)))
            try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
            try Data().write(to: folder.thumbnail)
            try Data("{}".utf8).write(to: folder.scene)
            try Data(#"{"score":\#(1 - Double(index) / 10)}"#.utf8).write(to: folder.interest)
        }
        for index in 1...4 { try addScene(index) }
        let other = root.appendingPathComponent("2026-10-25/scene-0001", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: SceneFolder(other).scene)

        let model = LibraryModel(root: root)
        model.watch()
        defer { model.stop() }
        model.query.collection = .toSort
        check("cinq scènes à trier", wait(10) { model.visible.count == 5 }, "\(model.visible.count)")
        let id = { (index: Int) in "2026-10-26/" + String(format: "scene-%04d", index) }
        func saved(_ index: Int) -> SceneRatings.Entry? {
            SceneRatings.read(batch: night).scenes[String(format: "scene-%04d", index)]
        }

        model.startTriage(batch: "2026-10-26")
        check(
            "trier ouvre la première scène de la nuit, dans l'ordre du tri",
            model.triage?.current == id(1) && model.triage?.order.count == 4,
            model.triage?.current ?? "fermé")
        check("0 / 4 triées", model.triageProgress?.decided == 0 && model.triageProgress?.total == 4)
        model.handle(.digit(7))
        check(
            "un chiffre note sans changer de scène",
            model.triage?.current == id(1) && saved(1)?.rating == 7)
        model.handle(.yes)
        check(
            "oui s'écrit tout de suite et passe à la suivante",
            saved(1)?.choice == .yes && model.triage?.current == id(2))
        check("1 / 4 triées", model.triageProgress?.decided == 1)
        let now = Date()
        model.handle(.digit(1), at: now)
        model.handle(.digit(0), at: now.addingTimeInterval(0.3))
        check("1 puis 0 vaut 10", saved(2)?.rating == 10 && model.triage?.current == id(2))
        model.handle(.no)
        check(
            "non écarte et passe à la suivante",
            saved(2)?.choice == .no && model.triage?.current == id(3))
        check(
            "la scène décidée a quitté À trier mais reste dans la séance",
            !model.visible.contains { $0.id == id(1) } && model.triage?.order.contains(id(1)) == true)
        model.handle(.left)
        check("← revient sur la scène décidée", model.triage?.current == id(2))
        model.handle(.right)
        model.handle(.right)
        model.handle(.right)
        check("→ s'arrête à la dernière", model.triage?.current == id(4))
        model.handle(.left)
        model.handle(.left)
        model.handle(.left)
        model.handle(.clear)
        check(
            "effacer vide la scène et la rend à trier",
            saved(1) == nil && model.triageProgress?.decided == 1 && model.triage?.current == id(1))
        model.handle(.right)
        model.handle(.right)
        model.handle(.yes)
        check(
            "oui sur la 3 va à la prochaine à trier, la 4",
            saved(3)?.choice == .yes && model.triage?.current == id(4))

        renderTriage(model, to: "out/ui-triage.png")
        try addScene(5)
        check(
            "une scène qui arrive en cours de séance la rejoint",
            wait(6) { model.triageProgress?.total == 5 }, "\(model.triageProgress?.total ?? 0)")
        model.handle(.yes)
        check("la prochaine à trier fait le tour du début", model.triage?.current == id(5))
        model.handle(.no)
        check(
            "il reste la première, que l'on a effacée",
            model.triage?.current == id(1) && model.triage?.finished == false)
        model.handle(.yes)
        check(
            "tout est trié : 5 / 5 et la séance le dit",
            model.triage?.finished == true && model.triageProgress?.decided == 5
                && model.triageProgress?.total == 5)
        check("rien ne se décide quand tout est trié", !model.handle(.yes) && saved(1)?.choice == .yes)
        renderTriage(model, to: "out/ui-triage-finished.png")
        model.handle(.left)
        check("← sort de la fin", model.triage?.finished == false)
        check("échap quitte la séance", model.handle(.close) && model.triage == nil)
        check(
            "à trier ne garde que la scène de l'autre nuit",
            model.visible.map(\.id) == ["2026-10-25/scene-0001"])
        model.startTriage()
        check("une séance sur À trier tout entier", model.triageProgress?.total == 1)
        model.stop()
        check("quitter la bibliothèque ferme la séance", model.triage == nil)
    }

    private static func ms(_ seconds: TimeInterval) -> String { String(format: "%.1f ms", seconds * 1000) }

    private static let width = 160
    private static let height = 90

    private static func pixels(tint: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                pixels[offset] = UInt8((x * 255 / width + tint * 50) % 256)
                pixels[offset + 1] = UInt8(y * 255 / height)
                pixels[offset + 2] = UInt8((tint * 70) % 256)
            }
        }
        return pixels
    }

    private static func writeVideo(to url: URL, tint: Int) throws {
        let writer = try VideoWriter(width: width, height: height, framesPerSecond: 30, to: url)
        for frame in 0..<20 {
            let rgba = pixels(tint: tint + frame)
            try writer.append { buffer in
                CVPixelBufferLockBaseAddress(buffer, [])
                defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
                guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
                let stride = CVPixelBufferGetBytesPerRow(buffer)
                let bgra = base.bindMemory(to: UInt8.self, capacity: stride * height)
                for y in 0..<height {
                    for x in 0..<width {
                        let from = (y * width + x) * 4
                        let to = y * stride + x * 4
                        (bgra[to], bgra[to + 1], bgra[to + 2]) = (rgba[from + 2], rgba[from + 1], rgba[from])
                        bgra[to + 3] = 255
                    }
                }
            }
        }
        try writer.finish()
    }

    private static func writeScene(_ folder: SceneFolder, tint: Int, archetype: String?) throws {
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        try PNGWriter.write(pixels(tint: tint), width: width, height: height, to: folder.thumbnail)
        try writeVideo(to: folder.preview, tint: tint)
        let scene = archetype.map { #"{"draw": {"generator": "\#($0)"}}"# } ?? "{}"
        try Data(scene.utf8).write(to: folder.scene)
    }

    private static func renderTriage(_ model: LibraryModel, to path: String) {
        guard let triage = model.triage else { return }
        write(TriageView(model: model, triage: triage) {}.frame(width: 1180, height: 640), to: path)
    }

    private static func write(_ view: some View, to path: String) {
        let renderer = ImageRenderer(content: view.panelSurface().environment(\.colorScheme, .dark))
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
            let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else {
            check("\(path) se rend", false)
            return
        }
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? png.write(to: url)
        check("\(path) se rend", true)
    }

    private static func renderShot(_ model: LibraryModel) throws {
        model.columns = 2
        let cards = model.visible.prefix(4).map { scene in
            LibraryCard(
                model: model, scene: scene, entry: model.entries[scene.id],
                selected: model.selection == scene.id, playing: false,
                ready: model.playable.contains(scene.id))
        }
        let view = VStack(spacing: 0) {
            LibraryHeader(model: model, collection: model.query.collection)
            Divider()
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow { ForEach(0..<2, id: \.self) { cards[$0] } }
                GridRow { ForEach(2..<min(4, cards.count), id: \.self) { cards[$0] } }
            }
            .frame(width: LibraryCard.width * 2 + 12)
            .padding(12)
        }
        .frame(width: 1180)
        .panelSurface()
        .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
            let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else {
            check("la grille se rend", false)
            return
        }
        let url = URL(fileURLWithPath: "out/ui-library.png")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: url)
        check("la grille se rend", true, url.path)
    }
}
