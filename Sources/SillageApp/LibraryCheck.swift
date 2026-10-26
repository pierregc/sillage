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

        // One player, following the pointer, then the enlarged scene.
        model.selection = "2026-10-24/scene-0001"
        check("la sélection joue", model.playing == "2026-10-24/scene-0001")
        model.hover("2026-10-24/scene-0002", inside: true)
        check("le survol joue", wait(2) { model.playing == "2026-10-24/scene-0002" })
        model.enlarged = "2026-10-24/scene-0003"
        check("l'agrandie passe avant le survol", model.playing == "2026-10-24/scene-0003")
        check(
            "le lecteur lit vraiment",
            wait(5) { model.player.currentItem?.status == .readyToPlay },
            "\(model.player.currentItem?.status.rawValue ?? -1)")
        check("échap referme", model.handle(.close) && model.enlarged == nil)
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
