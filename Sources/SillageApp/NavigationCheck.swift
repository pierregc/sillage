import AppKit
import Foundation
import SillageRender

/// Walks the sidebar with the window up: what each part mounts, a run that keeps computing
/// behind the library, a take opened for tuning, contemplation and its way back. Writes a
/// picture of each part to `out/ui-main-*.png`.
@MainActor
enum NavigationCheck {
    private static var lines: [String] = []
    private static var failures = 0

    static func run(_ model: SimulationModel, _ library: LibraryModel, _ navigation: AppNavigation) {
        guard CommandLine.arguments.contains("--navcheck") else { return }
        Task {
            await exercise(model, library, navigation)
            let report = lines.joined(separator: "\n") + "\n\n\(failures) échec(s)"
            try? report.write(
                to: URL(fileURLWithPath: "/tmp/sillage-navigation.log"), atomically: true,
                encoding: .utf8)
            print(report)
            exit(failures == 0 ? 0 : 1)
        }
    }

    private static func check(_ name: String, _ passed: Bool, _ detail: String = "") {
        lines.append("\(passed ? "ok  " : "FAIL") \(name)\(detail.isEmpty ? "" : "  (\(detail))")")
        FileHandle.standardError.write(Data(((lines.last ?? "") + "\n").utf8))
        if !passed { failures += 1 }
    }

    /// Lets SwiftUI apply a change, then waits for the condition, drawing as a window would.
    private static func settle(
        _ model: SimulationModel, _ seconds: Double, until condition: () -> Bool = { false }
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            model.drawOnce()
            try? await Task.sleep(for: .milliseconds(16))
            if condition() { return true }
        } while Date() < deadline
        return condition()
    }

    private static func exercise(
        _ model: SimulationModel, _ library: LibraryModel, _ navigation: AppNavigation
    ) async {
        _ = await settle(model, 1)
        check("la bibliothèque est l'accueil", navigation.selection == .library(.all))
        check("la grille est montée", await settle(model, 2) { library.isShown })
        check("l'atelier n'est pas monté", !model.hasPreviewCanvas && !model.hasCanvas)
        snapshot("library")

        // Each collection of the sidebar is the grid on its own scenes, and the sidebar counts
        // them whichever part shows.
        for collection in LibraryCollection.allCases {
            navigation.selection = .library(collection)
            let shown = await settle(model, 2) { library.query.collection == collection }
            let expected = library.scenes.filter { collection.contains($0.stage) }.count
            let listed = await settle(model, 2) { library.visible.count == expected }
            check(
                "\(collection.title) montre ses scènes", shown && listed,
                "\(library.visible.count) sur \(expected)")
        }
        let staged = LibraryCollection.allCases.dropLast().map { library.counts[$0] ?? 0 }.reduce(0, +)
        let discarded = library.scenes.filter { $0.stage == .discarded }.count
        check(
            "chaque scène est dans une collection, les écartées dans Toutes seulement",
            staged + discarded == library.scenes.count && library.counts[.all] ?? 0 == library.scenes.count,
            "\(staged) + \(discarded) écartées sur \(library.scenes.count)")
        navigation.selection = .library(.all)
        _ = await settle(model, 1)

        navigation.selection = .nights
        check("les nuits remplacent la grille", await settle(model, 2) { !library.isShown })
        check("le dossier reste lu pour les compteurs", library.isWatching)
        snapshot("nights")

        navigation.selection = .workshop
        check("nouvelle collision montre le réglage", await settle(model, 2) { model.hasPreviewCanvas })
        snapshot("workshop")

        model.draft.solver = .restricted
        model.draft.retune()
        model.setTotalParticles(200_000)
        navigation.selection = .library(.all)
        model.start()
        check(
            "lancer montre la simulation dans l'atelier",
            await settle(model, 10) {
                navigation.selection == .workshop && model.hasCanvas && !model.isPreparing
            })
        _ = await settle(model, 2)

        navigation.selection = .library(.all)
        check(
            "le canevas quitte la fenêtre", await settle(model, 2) { !model.hasCanvas && library.isShown })
        let before = model.elapsedMyr
        _ = await settle(model, 3)
        check(
            "la simulation continue derrière la bibliothèque",
            model.stage == .running && model.elapsedMyr > before + 1,
            String(format: "%.0f → %.0f Myr", before, model.elapsedMyr))
        snapshot("library-running")

        navigation.selection = .workshop
        let drawn = model.framesDrawn
        check(
            "revenir à l'atelier la remontre",
            await settle(model, 3) { model.hasCanvas && model.framesDrawn > drawn + 10 },
            "\(model.framesDrawn - drawn) images")

        let take = FileManager.default.temporaryDirectory
            .appendingPathComponent("sillage-navcheck-\(UUID().uuidString).sillage")
        defer { try? FileManager.default.removeItem(at: take) }
        model.isPlaying = false
        model.saveTake(to: take)
        _ = await settle(model, 20) { model.fileActivity == nil }
        model.returnToSetup()
        navigation.selection = .library(.all)
        _ = await settle(model, 1)
        let scene = LibraryScene(
            batch: "navcheck", batchURL: take.deletingLastPathComponent(), name: "navcheck",
            take: take)
        library.tune(scene)
        check(
            "régler le style ouvre la prise dans l'atelier",
            await settle(model, 20) {
                navigation.selection == .workshop && model.mode == .playback && model.hasCanvas
            },
            model.failure ?? "")

        model.returnToSetup()
        navigation.selection = .library(.all)
        _ = await settle(model, 1) { library.isShown }
        model.startContemplation(pace: .brisk)
        check(
            "la contemplation prend toute la fenêtre",
            await settle(model, 5) { model.hasCanvas && !library.isShown })
        _ = await settle(model, 3)
        // What escape does.
        DispatchQueue.main.async { model.stopContemplation() }
        check(
            "échap revient là où elle a été lancée",
            await settle(model, 5) {
                model.stage == .setup && navigation.selection == .library(.all) && library.isShown
            })
        let window = NSApp.windows.first { $0.isVisible }
        check(
            "la fenêtre quitte le plein écran",
            await settle(model, 5) { window?.styleMask.contains(.fullScreen) == false })
        check("aucune erreur", model.failure == nil, model.failure ?? "")
    }

    private static func snapshot(_ name: String) {
        guard let view = NSApp.windows.first(where: { $0.isVisible })?.contentView,
            let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        let url = URL(fileURLWithPath: "out/ui-main-\(name).png")
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? png.write(to: url)
    }
}
