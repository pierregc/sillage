import CoreGraphics
import Foundation
import SillageCore
import SillageRender
import simd

/// Set by the stages that tell the status files what they are doing.
var reporter: StageReporter?

func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    if let reporter {
        var event = RunEvent(RunEvent.Kind.error)
        event.stage = reporter.stage
        event.message = message
        reporter.record(event)
        reporter.finish()
    }
    exit(code)
}

/// Every scene of a batch marked yes, one after another, each in a process of its own: at these
/// sizes one scene fills the GPU. A scene already done at the same size is skipped, so an
/// interrupted batch picks up where it stopped.
func hiresBatch(_ batch: URL, options: [String]) -> Int32 {
    let scenes = SceneFolder.chosen(inBatch: batch)
    guard !scenes.isEmpty else {
        fail("hires: \(batch.path) is neither a scene folder nor a batch with scenes marked yes")
    }
    let (asked, _) = SceneFolder.Clip().updated(with: options)
    let particles =
        options.contains("--particles") ? asked.particles : SceneFolder.maximumParticles()
    var failed = 0
    for (index, scene) in scenes.enumerated() {
        let name = scene.url.lastPathComponent
        if let done = scene.storedHires(), done.particles == particles,
            !options.contains("--frames") || done.frames == asked.frames
        {
            print("hires      \(index + 1)/\(scenes.count) \(name): done already")
            continue
        }
        print("hires      \(index + 1)/\(scenes.count) \(name)")
        let process = Process()
        process.executableURL = Bundle.main.executableURL
        process.arguments = ["hires", scene.url.path] + options
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            print("hires      \(name) did not start: \(error)")
        }
        if process.terminationStatus != 0 {
            failed += 1
            print("hires      \(name) failed with status \(process.terminationStatus)")
            var event = RunEvent(RunEvent.Kind.error, scene: name)
            event.stage = "hires"
            event.message = "failed with status \(process.terminationStatus)"
            try? RunStatusFiles.append(event, to: RunStatusFiles.events(batch: batch))
        }
    }
    print("hires      \(scenes.count - failed) of \(scenes.count) scenes")
    return failed == 0 ? 0 : 1
}

/// The repository's own looks, `looks/*.look.json`, with the built in catalogue first.
func catalogueLooks() -> [LookFile] {
    LookCatalogue.load(
        from: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("looks"))
}

/// `look <scene folder>`: a grid of looks against key frames of the take, and `--promote
/// <name>` to make one of its rows the scene's look.
func lookStage(_ folder: SceneFolder, options: [String]) throws -> Int32 {
    func option(_ name: String) -> String? {
        options.firstIndex(of: "--\(name)").flatMap {
            $0 + 1 < options.count ? options[$0 + 1] : nil
        }
    }
    func readLook(_ path: String) throws -> LookFile {
        try LookFile.decoded(from: Data(contentsOf: URL(fileURLWithPath: path)))
    }
    if let choice = option("style") {
        guard choice == "auto" else { fail("look: --style is auto") }
        return try styleAuto(folder, options: options)
    }
    if let choice = option("palette") {
        return try palettePromotion(
            folder, choice: choice, world: option("world"), base: option("base"))
    }
    if let name = option("promote") {
        let file = try folder.promote(look: name)
        print("look       \(file.name) is now \(folder.look.path)")
        return 0
    }

    let takeURL = option("take").map { URL(fileURLWithPath: $0) } ?? folder.take
    guard FileManager.default.fileExists(atPath: takeURL.path) else {
        throw SceneFolder.LookError.noTake(folder.url)
    }
    let catalogue = catalogueLooks()
    var base = LookFile.standard
    if let named = option("base") {
        if let found = catalogue.first(where: { $0.name == named }) {
            base = found
        } else {
            base = try readLook(named)
        }
    }
    var hand: [LookFile] = []
    for (index, value) in options.enumerated() where value.hasSuffix(".look.json") {
        if index > 0, options[index - 1] == "--base" || options[index - 1] == "--take" {
            continue
        }
        hand.append(try readLook(value))
    }

    let loaded = try RecordingFile.read(from: takeURL)
    let scenePalette =
        (try? Data(contentsOf: folder.look)).flatMap { try? LookFile.decoded(from: $0) }?.palette
        .nonEmpty ?? loaded.scene.galaxies.map(\.color)
    func withScenePalette(_ file: LookFile) -> LookFile {
        var file = file
        if file.palette.isEmpty { file.palette = scenePalette }
        return file
    }
    base = withScenePalette(base)
    // A look that names its own colours keeps them; one that does not takes the scene's.
    let looks0 =
        (options.contains("--no-variants") ? [base] : LookVariants.around(base))
        + (options.contains("--no-catalogue") ? [] : catalogue.filter { $0.name != base.name })
    var looks = looks0.map(withScenePalette)
    looks += hand.map(withScenePalette)
    var seen: [String: Int] = [:]
    for index in looks.indices {
        let name = looks[index].name
        seen[name, default: 0] += 1
        if let count = seen[name], count > 1 { looks[index].name = "\(name)-\(count)" }
    }

    let sheet = try LookSheet(take: loaded)
    let samples =
        (try? String(contentsOf: folder.hiresCurves, encoding: .utf8))
        .map(KeyFrames.samples) ?? []
    let lastFrame = sheet.capturedFrames - 1
    var keys: [KeyFrame]
    if let list = option("frames") {
        keys = list.split(separator: ",").compactMap { Int($0) }.map {
            KeyFrame(frame: min(max($0, 0), lastFrame), role: .chosen, timeMyr: 0)
        }
    } else if let list = option("times") {
        keys = list.split(separator: ",").compactMap { Double($0) }.map { myr in
            let frame =
                KeyFrames.nearest(timeMyr: myr, in: samples)?.frame
                ?? (0...lastFrame).min {
                    abs(sheet.timeMyr(atCaptured: $0) - myr) < abs(sheet.timeMyr(atCaptured: $1) - myr)
                } ?? 0
            return KeyFrame(frame: min(frame, lastFrame), role: .chosen, timeMyr: 0)
        }
    } else {
        keys = KeyFrames.pick(samples.filter { $0.frame <= lastFrame })
        if keys.isEmpty {
            keys = [0, lastFrame / 2, lastFrame].map {
                KeyFrame(frame: $0, role: .middle, timeMyr: 0)
            }
            keys[0].role = .start
            keys[2].role = .end
        }
    }
    guard !keys.isEmpty else { fail("look: no key frame to draw") }

    let clip = try folder.storedClip()
    let hires = folder.storedHires()
    let renderWidth = hires?.width ?? clip.width
    let renderHeight = hires?.height ?? clip.height
    let cellWidth = Int(option("width").flatMap(Double.init) ?? 480)
    let cellHeight = max(
        Int((Double(cellWidth) * Double(renderHeight) / Double(renderWidth)).rounded()), 1)
    let columnLabels = keys.map { key in
        let drawn = sheet.isStored(frame: key.frame) ? "stored" : "blend"
        let label = String(
            format: "%@ · %d · %.0f Myr · %@", key.role.rawValue, key.frame,
            sheet.timeMyr(atCaptured: key.frame), drawn)
        print("key frame  \(label)")
        return label
    }

    let started = Date()
    let cells = try sheet.render(
        looks: looks, frames: keys.map(\.frame), width: renderWidth, height: renderHeight,
        cellWidth: cellWidth, cellHeight: cellHeight, framesPerSecond: hires?.fps ?? clip.fps)

    let manager = FileManager.default
    try manager.createDirectory(at: folder.looks, withIntermediateDirectories: true)
    let gridName = folder.lookGrid.deletingPathExtension().lastPathComponent
    for stale in (try? manager.contentsOfDirectory(atPath: folder.looks.path)) ?? []
    where stale.hasSuffix(".look.json") || (stale.hasPrefix(gridName) && stale.hasSuffix(".png")) {
        try manager.removeItem(at: folder.looks.appendingPathComponent(stale))
    }
    for file in looks { try file.encoded().write(to: folder.lookFile(named: file.name)) }
    // Fifteen rows to an image: more would be too tall to look at. grid.png holds the first.
    let rowsPerImage = 15
    var written: [URL] = []
    for (page, start) in stride(from: 0, to: looks.count, by: rowsPerImage).enumerated() {
        let rows = start..<min(start + rowsPerImage, looks.count)
        guard
            let grid = LookGrid.image(
                cells: Array(cells[rows]), rowLabels: rows.map { looks[$0].name },
                columnLabels: columnLabels, cellWidth: cellWidth, cellHeight: cellHeight)
        else { fail("look: could not compose the grid") }
        let url =
            page == 0
            ? folder.lookGrid
            : folder.looks.appendingPathComponent("\(gridName)-\(page + 1).png")
        try PNGWriter.write(grid, to: url)
        written.append(url)
    }
    print(
        String(
            format: "look       %d looks x %d frames from %@, %.1f s", looks.count, keys.count,
            takeURL.lastPathComponent, Date().timeIntervalSince(started)))
    for url in written { print("grid       \(url.path)") }
    print("promote    sillage-render look \(folder.url.path) --promote <name>")
    return 0
}

/// The measured Hubble and Webb colour sets of `references/telescope`.
func telescopeReferences() -> [TelescopeReference] {
    TelescopeReference.load(
        from: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("references/telescope"))
}

/// What a scene's palette is drawn from: the seed in its `scene.json`.
func sceneSeed(_ folder: SceneFolder) throws -> (seed: UInt64, galaxies: Int) {
    let file = try SceneFile.decoded(from: Data(contentsOf: folder.scene))
    return (file.seed, file.galaxies.count)
}

/// `look <scene folder> --palette auto|<family>|<file.palette.json> [--world telescope|free]`:
/// puts a palette in the scene's look, promoted as `--promote` does with the old look kept.
/// `auto` is the best scored of a fixed number of candidates drawn from the scene's seed,
/// `<family>` the same inside one family, and a file is taken as it is.
func palettePromotion(
    _ folder: SceneFolder, choice: String, world: String?, base: String?
) throws -> Int32 {
    let asked = world.map { name -> Palette.World in
        guard let world = Palette.World(rawValue: name) else {
            fail("look: --world is telescope or free")
        }
        return world
    }
    let references = telescopeReferences()
    var look =
        (try? Data(contentsOf: folder.look)).flatMap { try? LookFile.decoded(from: $0) }
        ?? .standard
    if let base {
        guard
            let found = catalogueLooks().first(where: { $0.name == base })
                ?? (try? LookFile.decoded(from: Data(contentsOf: URL(fileURLWithPath: base))))
        else { fail("look: no look \(base)") }
        look = found
    }

    let palette: Palette
    var score: PaletteScore?
    if FileManager.default.fileExists(atPath: choice) {
        let data = try Data(contentsOf: URL(fileURLWithPath: choice))
        struct Bare: Decodable { var colours: [SIMD3<Float>] }
        if let recipe = try? JSONDecoder().decode(Palette.self, from: data) {
            palette = recipe
            score = PaletteScore(recipe, references: references)
            look.paletteRecipe = recipe
        } else if let bare = try? JSONDecoder().decode(Bare.self, from: data),
            !bare.colours.isEmpty
        {
            look.paletteRecipe = nil
            look.palette = bare.colours
            try folder.promote(look)
            print("look       \(choice): \(bare.colours.count) colours set in \(folder.look.path)")
            return 0
        } else {
            fail("look: \(choice) is not a palette file: {\"colours\": [[r, g, b], ...]}")
        }
    } else {
        let (seed, galaxies) = try sceneSeed(folder)
        let family = choice == "auto" ? nil : choice
        var chosen = asked ?? .free
        if let family, asked == nil {
            let worlds = Palette.World.allCases.filter { world in
                PaletteGenerator.families(world, telescope: references.map(\.family))
                    .contains { $0.name == family }
            }
            guard let found = worlds.first else {
                fail("look: --palette is auto, a family or a .palette.json file, not \(choice)")
            }
            chosen = found
        }
        let top = try PaletteAuto.ranked(
            galaxies: galaxies, world: chosen, family: family, seed: seed,
            telescope: references)[0]
        palette = top.palette
        score = top.score
        look.paletteRecipe = palette
    }
    look.palette = palette.colours
    try folder.promote(look)
    print(
        String(
            format: "look       palette %@ (%@ world, score %.2f) is now in %@", palette.name,
            palette.world.rawValue, score?.total ?? 0, folder.look.path))
    return 0
}

/// `look <scene folder> --style auto [--world telescope|free] [--keep]`: every rendering of
/// the world with the scene's best palettes, drawn on three key frames and scored; the best
/// pair is promoted unless `--keep`. Writes `looks/auto-<world>.png` (the best three) and
/// `looks/auto-<world>.json` (every pair's score).
func styleAuto(_ folder: SceneFolder, options: [String]) throws -> Int32 {
    func option(_ name: String) -> String? {
        options.firstIndex(of: "--\(name)").flatMap {
            $0 + 1 < options.count ? options[$0 + 1] : nil
        }
    }
    guard FileManager.default.fileExists(atPath: folder.take.path) else {
        throw SceneFolder.LookError.noTake(folder.url)
    }
    let started = Date()
    let base =
        (try? Data(contentsOf: folder.look)).flatMap { try? LookFile.decoded(from: $0) }
        ?? .standard
    let world: Palette.World
    if let name = option("world") {
        guard let asked = Palette.World(rawValue: name) else {
            fail("look: --world is telescope or free")
        }
        world = asked
    } else {
        world = base.world
    }
    let references = telescopeReferences()
    let renderings = LookCatalogue.renderings(world, in: catalogueLooks())
    guard !renderings.isEmpty else { fail("look: no rendering in the \(world.rawValue) world") }
    let (seed, galaxies) = try sceneSeed(folder)
    let palettes = Array(
        try PaletteAuto.ranked(
            galaxies: galaxies, world: world, seed: seed, telescope: references
        ).prefix(StyleAuto.palettesPerRendering(world)))

    let loaded = try RecordingFile.read(from: folder.take)
    let sheet = try LookSheet(take: loaded)
    let lastFrame = sheet.capturedFrames - 1
    let samples =
        (try? String(contentsOf: folder.hiresCurves, encoding: .utf8))
        .map(KeyFrames.samples) ?? []
    var keys = StyleAuto.frames(KeyFrames.pick(samples.filter { $0.frame <= lastFrame }))
    if keys.isEmpty {
        keys = [lastFrame / 4, lastFrame / 2, 3 * lastFrame / 4].map {
            KeyFrame(frame: $0, role: .middle, timeMyr: 0)
        }
    }
    let loadedAt = Date()
    let clip = try folder.storedClip()
    let hires = folder.storedHires()
    let width = hires?.width ?? clip.width
    let height = hires?.height ?? clip.height
    let fps = hires?.fps ?? clip.fps
    let ranked = try StyleAuto.ranked(
        sheet: sheet, base: base, renderings: renderings, palettes: palettes,
        frames: keys.map(\.frame), width: width, height: height, framesPerSecond: fps,
        references: references)
    let scoredAt = Date()

    func label(_ candidate: StyleAuto.Candidate) -> String {
        String(format: "%.3f %@ · %@", candidate.total, candidate.rendering, candidate.palette.name)
    }
    for (index, candidate) in ranked.prefix(5).enumerated() {
        func part(_ path: KeyPath<FrameScore, Float>) -> Float {
            candidate.frames.map { $0[keyPath: path] }.reduce(0, +)
                / Float(max(candidate.frames.count, 1))
        }
        let reference = candidate.frames.compactMap(\.reference)
        print(
            String(
                format:
                    "style      %d. %@: clipping %.2f exposure %.2f colour %.2f separation %.2f noise %.2f reference %@ palette %.2f",
                index + 1, label(candidate), part(\.clipping), part(\.exposure),
                part(\.colourfulness), part(\.separation), part(\.noise),
                reference.isEmpty
                    ? "-" : String(format: "%.2f", reference.reduce(0, +) / Float(reference.count)),
                candidate.paletteScore.total))
    }

    let manager = FileManager.default
    try manager.createDirectory(at: folder.looks, withIntermediateDirectories: true)
    struct Row: Encodable {
        var rendering: String
        var palette: Palette
        var total: Float
        var paletteScore: Float
        var frames: [FrameScore]
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let report = folder.looks.appendingPathComponent("auto-\(world.rawValue).json")
    try encoder.encode(
        ranked.map {
            Row(
                rendering: $0.rendering, palette: $0.palette, total: $0.total,
                paletteScore: $0.paletteScore.total, frames: $0.frames)
        }
    ).write(to: report)

    let top = Array(ranked.prefix(3))
    let cellHeight = max(
        Int((Double(StyleAuto.cellWidth) * Double(height) / Double(width)).rounded()), 1)
    let cells = try sheet.render(
        looks: top.map(\.look), frames: keys.map(\.frame), width: width, height: height,
        cellWidth: StyleAuto.cellWidth, cellHeight: cellHeight, framesPerSecond: fps)
    guard
        let grid = LookGrid.image(
            cells: cells, rowLabels: top.map(label),
            columnLabels: keys.map {
                String(
                    format: "%@ · %.0f Myr", $0.role.rawValue, sheet.timeMyr(atCaptured: $0.frame))
            }, cellWidth: StyleAuto.cellWidth, cellHeight: cellHeight)
    else { fail("look: could not compose the grid") }
    let gridURL = folder.looks.appendingPathComponent("auto-\(world.rawValue).png")
    try PNGWriter.write(grid, to: gridURL)

    print(
        String(
            format:
                "style      %d pairs (%d renderings x %d palettes) on %d frames at %dx%d: %.1f s (take %.1f s, scoring %.1f s)",
            ranked.count, renderings.count, palettes.count, keys.count, width, height,
            scoredAt.timeIntervalSince(started), loadedAt.timeIntervalSince(started),
            scoredAt.timeIntervalSince(loadedAt)))
    print("grid       \(gridURL.path)")
    print("scores     \(report.path)")
    if let best = ranked.first, !options.contains("--keep") {
        try folder.promote(best.look)
        print("look       \(label(best)) is now \(folder.look.path)")
    }
    return 0
}

/// `palettes <scene folder>`: palettes drawn from seeds for the scene's galaxies, each on a
/// frame of the take, beside a sheet of their swatches.
func paletteStage(_ folder: SceneFolder, options: [String]) throws -> Int32 {
    func option(_ name: String) -> String? {
        options.firstIndex(of: "--\(name)").flatMap {
            $0 + 1 < options.count ? options[$0 + 1] : nil
        }
    }
    guard let world = Palette.World(rawValue: option("world") ?? "free") else {
        fail("palettes: --world is telescope or free")
    }
    let harmony = option("harmony").map {
        guard let harmony = Palette.Harmony(rawValue: $0) else {
            fail(
                "palettes: --harmony is one of "
                    + Palette.Harmony.allCases.map(\.rawValue).joined(separator: ", "))
        }
        return harmony
    }
    let count = Int(option("count") ?? "24") ?? 24
    let firstSeed = UInt64(option("seed") ?? "1") ?? 1
    guard FileManager.default.fileExists(atPath: folder.take.path) else {
        throw SceneFolder.LookError.noTake(folder.url)
    }

    let references = telescopeReferences()
    let telescope = references.map(\.family)
    for family in PaletteGenerator.families(world, telescope: telescope) {
        if let note = family.note { print("palettes   \(note)") }
    }

    let loaded = try RecordingFile.read(from: folder.take)
    let galaxies = min(max(loaded.scene.galaxies.count, 1), 5)
    var palettes: [Palette] = []
    var labels: [String]?
    if let best = option("best").flatMap(Int.init) {
        // The Auto candidates of the scene, best first, instead of seeds in a row.
        guard harmony == nil else { fail("palettes: --best draws its own harmonies") }
        let top = try PaletteAuto.ranked(
            galaxies: galaxies, world: world, family: option("family"),
            seed: try sceneSeed(folder).seed, telescope: references
        ).prefix(max(best, 1))
        palettes = top.map(\.palette)
        labels = top.map { String(format: "%.2f %@", $0.score.total, $0.palette.name) }
        for ranked in top {
            let s = ranked.score
            print(
                String(
                    format:
                        "palettes   %@ %.2f: separation %.2f harmony %.2f range %.2f balance %.2f reference %@",
                    ranked.palette.name, s.total, s.separation, s.harmony, s.range, s.balance,
                    s.reference.map { String(format: "%.2f", $0) } ?? "-"))
        }
    } else {
        for seed in firstSeed..<(firstSeed + UInt64(max(count, 1))) {
            palettes.append(
                try PaletteGenerator.palette(
                    galaxies: galaxies, world: world, family: option("family"),
                    harmony: harmony, seed: seed, telescope: telescope))
        }
    }
    // Palettes are judged on a full look: a plain one shows no glow, bloom or saturation.
    let catalogue = catalogueLooks()
    let sceneLook = (try? Data(contentsOf: folder.look)).flatMap {
        try? LookFile.decoded(from: $0)
    }
    var base = sceneLook.flatMap { $0.plain ? nil : $0 } ?? LookFile.standard
    if let fallback = catalogue.first(where: { $0.name == "nebula-soft" }), sceneLook?.plain ?? true {
        base = fallback
    }
    if let named = option("base") {
        guard
            let found = catalogue.first(where: { $0.name == named })
                ?? (try? LookFile.decoded(from: Data(contentsOf: URL(fileURLWithPath: named))))
        else { fail("palettes: no look \(named)") }
        base = found
    }
    print("palettes   on the look \(base.name)")
    let looks = palettes.map { palette in
        var file = base
        file.name = palette.name
        file.palette = palette.colours
        file.paletteRecipe = palette
        return file
    }

    let sheet = try LookSheet(take: loaded)
    let lastFrame = sheet.capturedFrames - 1
    let samples =
        (try? String(contentsOf: folder.hiresCurves, encoding: .utf8))
        .map(KeyFrames.samples) ?? []
    let keys = KeyFrames.pick(samples.filter { $0.frame <= lastFrame })
    let frame = min(
        max(
            option("frame").flatMap(Int.init)
                ?? (keys.first { $0.role == .tails } ?? keys.first { $0.role == .pericentre })?
                .frame ?? lastFrame / 2, 0), lastFrame)
    let clip = try folder.storedClip()
    let hires = folder.storedHires()
    let renderWidth = hires?.width ?? clip.width
    let renderHeight = hires?.height ?? clip.height
    let cellWidth = Int(option("width").flatMap(Double.init) ?? 400)
    let cellHeight = max(
        Int((Double(cellWidth) * Double(renderHeight) / Double(renderWidth)).rounded()), 1)
    print(
        String(
            format: "palettes   %d %@ palettes for %d galaxies on frame %d (%.0f Myr)",
            palettes.count, world.rawValue, galaxies, frame, sheet.timeMyr(atCaptured: frame)))

    let started = Date()
    let cells = try sheet.render(
        looks: looks, frames: [frame], width: renderWidth, height: renderHeight,
        cellWidth: cellWidth, cellHeight: cellHeight, framesPerSecond: hires?.fps ?? clip.fps
    ).map { $0[0] }

    let manager = FileManager.default
    try manager.createDirectory(at: folder.palettes, withIntermediateDirectories: true)
    for stale in (try? manager.contentsOfDirectory(atPath: folder.palettes.path)) ?? []
    where stale.hasSuffix(".look.json") {
        try manager.removeItem(at: folder.palettes.appendingPathComponent(stale))
    }
    for file in looks {
        try file.encoded().write(
            to: folder.palettes.appendingPathComponent("\(file.name).look.json"))
    }
    guard
        let tiles = PaletteSheet.sheet(
            cells: cells, palettes: palettes, cellWidth: cellWidth, cellHeight: cellHeight,
            columns: min(palettes.count, 4), labels: labels),
        let swatches = PaletteSheet.swatches(palettes, labels: labels)
    else { fail("palettes: could not compose the sheet") }
    let sheetURL = folder.palettes.appendingPathComponent("sheet.png")
    let swatchURL = folder.palettes.appendingPathComponent("swatches.png")
    try PNGWriter.write(tiles, to: sheetURL)
    try PNGWriter.write(swatches, to: swatchURL)
    print(String(format: "palettes   drawn in %.1f s", Date().timeIntervalSince(started)))
    print("sheet      \(sheetURL.path)")
    print("swatches   \(swatchURL.path)")
    return 0
}

/// `export <scene folder>`: the take drawn with the scene's look into `exports/<preset>.mp4`,
/// HEVC unless the preset or `--codec` says otherwise; another codec adds its name, as
/// `<preset>-h264.mp4` and `<preset>-prores.mov`.
func exportStage(_ folder: SceneFolder, options: [String], reporter: StageReporter) throws -> Int32 {
    func option(_ name: String) -> String? {
        options.firstIndex(of: "--\(name)").flatMap {
            $0 + 1 < options.count ? options[$0 + 1] : nil
        }
    }
    func value(_ name: String) throws -> Double? {
        guard let text = option(name) else { return nil }
        guard let number = Double(text), number >= 0 else {
            throw SceneFolder.ExportError.badValue(name, text)
        }
        return number
    }

    let presetName = option("preset") ?? "1080p"
    guard let preset = VideoPreset.named(presetName) else {
        throw SceneFolder.ExportError.noSuchPreset(presetName)
    }
    let codec: VideoCodec
    if let name = option("codec") {
        guard let named = VideoCodec(rawValue: name.lowercased()) else {
            throw SceneFolder.ExportError.noSuchCodec(name)
        }
        codec = named
    } else {
        codec = preset.defaultCodec
    }
    if let pinned = preset.codec, pinned != codec {
        throw SceneFolder.ExportError.codecNotAllowed(preset: preset.name, codec: pinned)
    }
    let takeURL = option("take").map { URL(fileURLWithPath: $0) } ?? folder.take
    guard FileManager.default.fileExists(atPath: takeURL.path) else {
        throw SceneFolder.LookError.noTake(folder.url)
    }
    let loaded = try RecordingFile.read(from: takeURL)
    let scenePalette =
        (try? Data(contentsOf: folder.look)).flatMap { try? LookFile.decoded(from: $0) }?.palette
        .nonEmpty ?? loaded.scene.galaxies.map(\.color)
    var look = try folder.exportLook(option("look"), catalogue: catalogueLooks())
    if look.palette.isEmpty { look.palette = scenePalette }

    let clip = try folder.storedClip()
    let capturedRate = folder.storedHires()?.fps ?? clip.fps
    let export = try TakeExport(take: loaded, look: look, capturedRate: capturedRate)
    let start = try value("start") ?? 0
    if let name = option("format") {
        guard let format = AnimatedImage.Format(rawValue: name.lowercased()) else {
            throw SceneFolder.ExportError.badValue("format", name)
        }
        return try previewStage(
            folder, export: export, format: format, preset: options.contains("--preset") ? preset : nil,
            start: start, reporter: reporter, option: option, value: value)
    }

    // H.264 wants even sides.
    let width = Int(try value("width") ?? Double(preset.width)) / 2 * 2
    let height = Int(try value("height") ?? Double(preset.height)) / 2 * 2
    let fps = Int(try value("fps") ?? Double(capturedRate))
    guard width >= 16, height >= 16, fps >= 1 else {
        throw SceneFolder.ExportError.badValue("width, height or fps", "\(width)x\(height) at \(fps)")
    }
    let quality = try value("quality")
    if let quality, quality > 1 {
        throw SceneFolder.ExportError.badValue("quality", option("quality") ?? "")
    }
    let asked = try value("bitrate").map { Int($0 * 1e6) }
    if !codec.hasRateControl && (asked != nil || quality != nil) {
        throw SceneFolder.ExportError.noRateControl(codec)
    }
    let out =
        option("out").map { URL(fileURLWithPath: $0) }
        ?? folder.export(
            preset: preset.name, codec: codec == preset.defaultCodec ? nil : codec)
    try FileManager.default.createDirectory(
        at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
    let partial = SceneFolder.partial(out)

    let duration = try value("duration")
    let frames = export.positions(framesPerSecond: fps, start: start, duration: duration).count
    var bitRate = asked
    if bitRate == nil { bitRate = try preset.bitRate(forSeconds: Double(frames) / Double(fps)) }
    let rate = bitRate ?? codec.defaultBitRate(width: width, height: height)
    let steering =
        quality.map { String(format: "quality %.2f", $0) }
        ?? rate.map {
            String(
                format: "%.1f Mbit/s, about %.0f MB", Double($0) / 1e6,
                Double($0) * Double(frames) / Double(fps) / 8e6)
        } ?? "ProRes 422 HQ"
    print(
        String(
            format: "export     %@ %@ %dx%d at %d fps, %d frames (%.1f s from %.1f s of a %.1f s take),"
                + " look %@, %@",
            preset.name, codec.rawValue, width, height, fps, frames, Double(frames) / Double(fps),
            start, export.takeSeconds, look.name, steering))
    var reported = 0
    reporter.start(detail: "frame 0/\(frames)")
    let report = try export.write(
        to: partial, width: width, height: height, framesPerSecond: fps, start: start,
        duration: duration, codec: codec, bitsPerSecond: bitRate, quality: quality,
        metadata: VideoMetadata(sceneID: folder.sceneID)
    ) { done, total in
        reporter.update(
            progress: Double(done) / Double(max(total, 1)), detail: "frame \(done)/\(total)")
        let tenth = done * 10 / max(total, 1)
        if tenth > reported {
            reported = tenth
            print("export     \(done)/\(total)")
        }
    }
    try SceneFolder.commit(out)
    let bytes =
        (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
    print(
        String(
            format: "export     %d frames in %.1f s, %.1f frames a second, %.2fx real time, %.1f MB",
            report.frames, report.seconds, report.renderedPerSecond, report.speed,
            Double(bytes) / 1e6))
    print("video      \(out.path)")
    var done = RunEvent(RunEvent.Kind.exportDone)
    done.preset = preset.name
    done.style = look.name
    done.codec = codec.rawValue
    done.frames = report.frames
    done.megabytes = Double(bytes) / 1e6
    done.seconds = report.seconds
    done.path = out.path
    reporter.record(done)
    if let limit = preset.maxBytes, bytes > limit {
        print("warning    \(bytes / 1_000_000) MB, over the \(limit / 1_000_000) MB aimed for")
    }
    if preset.caption {
        let captionURL = out.deletingPathExtension().appendingPathExtension("txt")
        try VideoMetadata(sceneID: folder.sceneID).caption.write(
            to: captionURL, atomically: true, encoding: .utf8)
        print("caption    \(captionURL.path)")
    }
    return 0
}

/// `export <scene folder> --format webp|gif`: a looping preview, 960 wide at 16 fps for eight
/// seconds unless told otherwise, the README's own animation.
func previewStage(
    _ folder: SceneFolder, export: TakeExport, format: AnimatedImage.Format, preset: VideoPreset?,
    start: Double, reporter: StageReporter, option: (String) -> String?,
    value: (String) throws -> Double?
) throws -> Int32 {
    let width = Int(try value("width") ?? 960)
    let aspect = preset.map { Double($0.height) / Double($0.width) } ?? 9.0 / 16
    let height = Int(try value("height") ?? (Double(width) * aspect).rounded())
    let fps = Int(try value("fps") ?? 16)
    let duration = try value("duration") ?? 8
    // From 0 to 1 as for a video.
    let quality = try value("quality") ?? 0.8
    guard width >= 16, height >= 16, fps >= 1, quality <= 1 else {
        throw SceneFolder.ExportError.badValue(
            "width, height, fps or quality", "\(width)x\(height) at \(fps)")
    }
    let maximum = try option("max-size").map {
        guard let bytes = AnimatedImage.bytes($0) else {
            throw SceneFolder.ExportError.badValue("max-size", $0)
        }
        return bytes
    }
    let out =
        option("out").map { URL(fileURLWithPath: $0) }
        ?? folder.preview(preset?.name ?? "preview", extension: format.rawValue)
    try FileManager.default.createDirectory(
        at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
    print(
        String(
            format: "export     %@ %dx%d at %d fps, %.1f s from %.1f s of a %.1f s take, look %@%@",
            format.rawValue, width, height, fps, duration, start, export.takeSeconds,
            export.look.name, maximum.map { String(format: ", at most %.1f MB", Double($0) / 1e6) } ?? ""))
    reporter.start(detail: "\(format.rawValue) preview")
    let report = try export.writePreview(
        to: SceneFolder.partial(out), format: format, width: width, height: height,
        framesPerSecond: fps, start: start, duration: duration, maximumBytes: maximum,
        quality: Int((quality * 100).rounded()))
    try SceneFolder.commit(out)
    for attempt in report.attempts.dropLast() {
        print(
            String(
                format: "export     %d wide at %d fps: %.1f MB, too big", attempt.width,
                attempt.framesPerSecond, Double(attempt.bytes) / 1e6))
    }
    print(
        String(
            format: "export     %dx%d, %d frames at %.1f fps, %.1f MB in %.1f s",
            report.width, report.height, report.frames,
            AnimatedImage.playedRate(report.framesPerSecond, format: format),
            Double(report.bytes) / 1e6, report.seconds))
    if let maximum, report.bytes > maximum {
        print(
            "export     still over \(maximum / 1_000_000) MB at the smallest size tried: shorten it with --duration"
        )
    }
    print("preview    \(out.path)")
    var done = RunEvent(RunEvent.Kind.exportDone)
    done.preset = preset?.name
    done.style = export.look.name
    done.codec = format.rawValue
    done.frames = report.frames
    done.megabytes = Double(report.bytes) / 1e6
    done.seconds = report.seconds
    done.path = out.path
    reporter.record(done)
    return 0
}

/// `event <batch folder> <kind> [--field value]...`: one line appended to the batch's
/// `events.jsonl`, for the scripts that run the stages and have no JSON of their own to write.
func eventCommand(_ arguments: [String]) -> Int32 {
    guard arguments.count >= 2, !arguments[0].hasPrefix("--"), !arguments[1].hasPrefix("--") else {
        fail("usage: sillage-render event <batch folder> <kind> [--scene id] [--field value]...")
    }
    let batch = URL(fileURLWithPath: arguments[0], isDirectory: true)
    do {
        let event = try RunEvent(arguments[1], options: Array(arguments.dropFirst(2)))
        try RunStatusFiles.append(event, to: RunStatusFiles.events(batch: batch))
        return 0
    } catch {
        fail("event: \(error)")
    }
}

/// `story <scene folder | batch folder>`: the story judged again on curves already written,
/// one line a scene: the first collision, and where the story starts and ends or what still goes
/// on when the curves stop.
func storyCommand(_ arguments: [String]) -> Int32 {
    guard let path = arguments.first, !path.hasPrefix("--") else {
        fail("usage: sillage-render story <scene folder | batch folder>")
    }
    let root = SceneFolder(path: path)
    let manager = FileManager.default
    let folders =
        manager.fileExists(atPath: root.curves.path)
        ? [root]
        : ((try? manager.contentsOfDirectory(atPath: root.url.path)) ?? []).sorted()
            .filter { !$0.hasPrefix(".") }
            .map { SceneFolder(root.url.appendingPathComponent($0, isDirectory: true)) }
            .filter {
                manager.fileExists(atPath: $0.curves.path) && manager.fileExists(atPath: $0.scene.path)
            }
    var over = 0
    for folder in folders {
        guard let text = try? String(contentsOf: folder.curves, encoding: .utf8),
            let data = try? Data(contentsOf: folder.scene), let file = try? SceneFile.decoded(from: data),
            let clip = try? folder.storedClip()
        else {
            print("\(folder.url.lastPathComponent)  unreadable")
            continue
        }
        let samples = Story.samples(csv: text)
        let story = Story(scene: file.scene(particleCount: clip.particles))
        var tracker = Story.Tracker(story: story)
        for sample in samples { tracker.append(sample) }
        guard let first = samples.first, let last = samples.last,
            let span = tracker.span(plannedFrames: clip.frames)
        else { continue }
        if span.complete { over += 1 }
        let collision =
            story.firstApproach(samples).map {
                String(
                    format: "collision %.0f Myr (%.1f kpc, %.0f after the start)", $0.timeMyr,
                    $0.distanceKpc, $0.timeMyr - first.timeMyr)
            } ?? "no collision"
        print(
            String(
                format: "%@  %d galaxies  curves %.0f-%.0f Myr  %@  story %.0f-%.0f Myr  %@",
                folder.url.lastPathComponent, file.galaxies.count, first.timeMyr, last.timeMyr,
                collision, span.startMyr, span.endMyr,
                span.complete
                    ? "over" : "going on: " + tracker.activity.map(\.description).joined(separator: "; ")))
    }
    print("story      \(over) of \(folders.count) over")
    return 0
}

extension Array {
    var nonEmpty: Self? { isEmpty ? nil : self }
}

/// The most the process has had resident at once, GPU buffers included: on unified memory
/// they count against the same footprint.
func peakFootprint() -> Int? {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
        MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Int(info.ledger_phys_footprint_peak) : nil
}

/// `costs [library]`: fits the library's history again, writes `.sillage/costs.json` and
/// prints it; `--json` prints the file itself, `--check <batch>` how well it predicts a batch.
func costsCommand(_ options: [String]) -> Int32 {
    let path = options.first.flatMap { $0.hasPrefix("--") ? nil : $0 } ?? "library"
    let library = URL(fileURLWithPath: path, isDirectory: true)
    do {
        let model = try CostModel.refresh(library: library)
        if let index = options.firstIndex(of: "--check"), index + 1 < options.count {
            print("| run | at once | took | predicted | error | before the batch | error |")
            print("| --- | --- | --- | --- | --- | --- | --- |")
            let history = CostHistory.read(library: library)
            for row in CostModel.check(history, batch: options[index + 1]) {
                let run = row.kind == "explore" ? history.explore.first { $0.id == row.id } : nil
                let alongside = run.map { String(format: "%.1f", $0.alongside) } ?? ""
                print(
                    String(
                        format: "| %@ %@ | %@ | %.0f s | %.0f s | %+.1f %% | %.0f s | %+.1f %% |",
                        row.kind, row.id, alongside, row.took, row.predicted, row.error * 100,
                        row.before, row.errorBefore * 100))
            }
        } else if options.contains("--json") {
            print(String(decoding: try model.encoded(), as: UTF8.self))
        } else {
            print("costs      \(CostModel.url(library: library).path)")
            for line in model.lines { print(line) }
        }
        return 0
    } catch {
        fail("costs: \(error)")
    }
}

/// After every finished job, so the next estimate already knows what this one took.
func refreshCosts(_ folder: SceneFolder) {
    do {
        try CostModel.refresh(library: folder.library)
    } catch {
        print("costs      not refreshed: \(error)")
    }
}

// `sillage-render <stage> <scene folder> [options]` runs one stage of the pipeline, every path
// derived from the folder. Anything else is a plain render driven by its flags.
let started = Date()
let arguments: [String]
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "event" {
    exit(eventCommand(Array(CommandLine.arguments.dropFirst(2))))
}
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "queue" {
    exit(
        QueueCommand.main(
            Array(CommandLine.arguments.dropFirst(2)), executable: Spawn.currentExecutable))
}
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "story" {
    exit(storyCommand(Array(CommandLine.arguments.dropFirst(2))))
}
var hiresRun: (folder: SceneFolder, record: SceneFolder.Hires)?
var exploreRun: SceneFolder?
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "costs" {
    exit(costsCommand(Array(CommandLine.arguments.dropFirst(2))))
}
if CommandLine.arguments.count > 1,
    let stage = SceneFolder.Stage(rawValue: CommandLine.arguments[1])
{
    guard CommandLine.arguments.count > 2, !CommandLine.arguments[2].hasPrefix("--") else {
        fail("usage: sillage-render \(stage.rawValue) <scene folder> [options]")
    }
    let folder = SceneFolder(path: CommandLine.arguments[2])
    let options = Array(CommandLine.arguments.dropFirst(3))
    switch stage {
    case .look:
        do {
            exit(try lookStage(folder, options: options))
        } catch {
            fail("look: \(error)")
        }
    case .palettes:
        do {
            exit(try paletteStage(folder, options: options))
        } catch {
            fail("palettes: \(error)")
        }
    case .export:
        let run = StageReporter(stage: stage.rawValue, folder: folder)
        reporter = run
        do {
            let code = try exportStage(folder, options: options, reporter: run)
            run.finish()
            if code == 0 { refreshCosts(folder) }
            exit(code)
        } catch {
            fail("export: \(error)")
        }
    case .hires:
        if !folder.isExplored && FileManager.default.fileExists(atPath: folder.url.path) {
            exit(hiresBatch(folder.url, options: options))
        }
        do {
            let plan = try folder.hiresArguments(
                options, maximumParticles: SceneFolder.maximumParticles())
            arguments = plan.arguments
            hiresRun = (folder, plan.record)
            let record = plan.record
            let run = StageReporter(stage: stage.rawValue, folder: folder)
            reporter = run
            run.start(detail: "starting")
            var begun = RunEvent(RunEvent.Kind.hiresStart)
            begun.particles = record.particles
            begun.steps = record.steps
            run.record(begun)
            print(
                String(
                    format: "hires      %d particles (preview %d), step %.5f Myr (preview %.5f),"
                        + " settle %d, %d steps, clip %.1f to %.1f Myr, about %.1f h",
                    record.particles, record.previewParticles, record.timeStepMyr,
                    record.previewTimeStepMyr, record.settle, record.steps, record.clipStartMyr,
                    record.clipEndMyr,
                    CostModel.current(library: folder.library).hiresSeconds(
                        particles: record.particles, steps: record.settle + record.steps) / 3600))
        } catch {
            fail("hires: \(error)")
        }
    default:
        var (clip, rest) = try folder.storedClip().updated(with: options)
        // Written again once the run has followed the story to its end.
        clip.story = nil
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        try clip.encoded().write(to: folder.clip)
        arguments = folder.exploreArguments(rest, clip: clip)
        exploreRun = folder
        let run = StageReporter(stage: stage.rawValue, folder: folder)
        reporter = run
        run.start(detail: "starting")
        exploreRun = folder
    }
} else {
    // A plain render takes flags only: a word here is a command this binary does not have,
    // and must not start a render of a million particles.
    if let word = CommandLine.arguments.dropFirst().first, !word.hasPrefix("--") {
        fail("sillage-render: no command \"\(word)\"")
    }
    arguments = Array(CommandLine.arguments.dropFirst())
}

func argument(_ name: String, default fallback: String? = nil) -> String? {
    guard let index = arguments.firstIndex(of: "--\(name)"), index + 1 < arguments.count
    else { return fallback }
    return arguments[index + 1]
}

func number(_ name: String, _ fallback: Double) -> Double {
    argument(name).flatMap(Double.init) ?? fallback
}

let presetName = argument("preset", default: "merger")!
let particles = Int(number("particles", 1_000_000))
let steps = Int(number("steps", 3_000))
let frames = Int(number("frames", 1))
let width = Int(number("width", 1920))
let height = Int(number("height", 1080))
// A PNG sequence is still the default, but a run asked for a video does not need one too.
let videoPath = argument("video")
let outputPath = argument("out", default: videoPath == nil ? "out/sillage.png" : nil)

let seed = argument("seed").flatMap(UInt64.init)
let scenePath = argument("scene")
let lookPath = argument("look")

// Everything that decides the image, from the look file if one is given; each flag below
// overrides its field.
var look =
    try lookPath.map { try LookFile.decoded(from: Data(contentsOf: URL(fileURLWithPath: $0))) }
    ?? .standard
func flag(_ name: String, _ field: WritableKeyPath<LookFile, Float>) {
    if let value = argument(name).flatMap(Double.init) { look[keyPath: field] = Float(value) }
}
func flag(_ name: String, _ field: WritableKeyPath<LookFile, Float?>) {
    if let value = argument(name).flatMap(Double.init) { look[keyPath: field] = Float(value) }
}
func flag(_ name: String, _ field: WritableKeyPath<LookFile, Int>) {
    if let value = argument(name).flatMap(Double.init) { look[keyPath: field] = Int(value) }
}
flag("brightness", \.look.brightness)
flag("dust", \.look.dustStrength)
flag("star-size", \.look.starSize)
flag("smoothing", \.look.smoothingScale)
flag("min-kernel", \.look.minimumKernel)
flag("max-kernel", \.look.maximumKernel)
flag("bloom-threshold", \.look.bloomThreshold)
flag("bloom-knee", \.look.bloomSoftKnee)
flag("bloom", \.look.bloomIntensity)
flag("stretch", \.look.stretch)
flag("saturation", \.look.saturation)
flag("white-point", \.look.whitePoint)
flag("spikes", \.look.spikeArms)
flag("spike-length", \.look.spikeLength)
flag("spike-intensity", \.look.spikeIntensity)
flag("sky", \.look.skyLevel)
flag("noise", \.look.noiseLevel)
flag("tint", \.look.galaxyTint)
flag("fov", \.look.fieldOfView)
flag("stars", \.starCount)
if arguments.contains("--plain") { look.plain = true }
flag("supersample", \.supersample)
flag("bloom-levels", \.bloomLevels)
flag("arms", \.armStrength)
flag("zoom", \.camera.zoom)
flag("percentile", \.camera.percentile)
flag("radius", \.camera.radius)
flag("elevation", \.camera.elevation)
flag("elevation-end", \.camera.elevationEnd)
flag("azimuth", \.camera.azimuth)
if let orbit = argument("orbit").flatMap(Double.init) {
    look.camera.azimuthEnd = look.camera.azimuth + Float(orbit)
}
flag("azimuth-end", \.camera.azimuthEnd)
if arguments.contains("--director") {
    look.camera.mode = arguments.contains("--immersed") ? .immersed : .director
}
if let mode = argument("camera") {
    guard let parsed = LookFile.CameraPlan.Mode(rawValue: mode) else {
        FileHandle.standardError.write(Data("unknown camera: \(mode)\n".utf8))
        exit(2)
    }
    look.camera.mode = parsed
}

// Every scene runs from its scene file, so the file written beside the output replays exactly
// what ran. Read from disk, a scene keeps its own values unless a flag is given.
var file: SceneFile
var palette: [SIMD3<Float>] = []
// A generated scene's pericentres are drawn for a default stretch of time and moved into the
// clip once its step is known.
var generatedHaste: Float?
if let scenePath {
    file = try SceneFile.decoded(from: Data(contentsOf: URL(fileURLWithPath: scenePath)))
} else {
    let preset: SceneConfig
    switch presetName {
    case "merger": preset = .merger(particleCount: particles)
    case "encounter": preset = .encounter(particleCount: particles)
    case "flyby": preset = .flyby(particleCount: particles)
    case "disk": preset = .isolatedDisk(particleCount: particles)
    // Drawn from the seed and nothing else, which is what a library of scenes wants: the seed
    // is the whole description, so a scene worth keeping can be rendered again from one integer.
    case "contemplation":
        preset = .contemplation(
            particleCount: particles, seed: seed ?? 1, haste: Float(number("haste", 0)),
            galaxies: argument("galaxies").flatMap(Int.init),
            lookSeed: argument("look-seed").flatMap(UInt64.init))
        generatedHaste = Float(number("haste", 0))
    // The scene at `--index` in the batch `--seed` draws, archetypes mixed in at `--archetypes`.
    // The seed is the batch's here, and the scene's own follows from it and the index.
    case "free":
        preset = BatchDraw(
            batchSeed: seed ?? 1,
            archetypeShare: Float(number("archetypes", Double(BatchDraw.defaultArchetypeShare))),
            spacing: Float(number("spacing", Double(FreeDraw.defaultSpacing))),
            haste: Float(number("haste", 0))
        ).scene(at: Int(number("index", 0)), particleCount: particles)
        generatedHaste = Float(number("haste", 0))
    // An archetype alone: its scene number `--index` in batch `--seed`, the same one the batch
    // draws when that archetype comes round for that time.
    default:
        guard let archetype = Archetype(rawValue: presetName) else {
            FileHandle.standardError.write(Data("unknown preset: \(presetName)\n".utf8))
            exit(2)
        }
        preset = archetype.scene(
            batchSeed: seed ?? 1, occurrence: Int(number("index", 0)), particleCount: particles,
            haste: Float(number("haste", 0)))
        generatedHaste = Float(number("haste", 0))
    }
    file = SceneFile(preset)
    palette = preset.galaxies.map(\.color)
    file.openingAngle = 0.6
}
let batchSeeded = presetName == "free" || Archetype(rawValue: presetName) != nil
if let seed, scenePath != nil || !batchSeeded { file.seed = seed }
let placedFor = (file.solver, file.galaxies.map(\.haloParticleRatio))
let backend = argument(
    "solver", default: scenePath == nil || file.solver == .restricted ? "restricted" : "barnes-hut")!
// The presets are self-gravitating by default, so the flag has to set the solver both ways.
switch backend {
case "barnes-hut":
    file.solver = .barnesHut
    if let ratio = argument("halo").flatMap(Float.init) ?? (scenePath == nil ? 1.5 : nil) {
        for index in file.galaxies.indices { file.galaxies[index].haloParticleRatio = ratio }
    }
case "restricted", "cpu":
    file.solver = .restricted
default:
    FileHandle.standardError.write(Data("unknown solver: \(backend)\n".utf8))
    exit(2)
}
// Softening and step follow from the counts and the solver unless overridden below. Only an
// explicit flag overrides the scale, because a generated scene picks its own.
if let scale = argument("dt-scale").flatMap(Float.init) { file.timeStepScale = scale }
if let dissipation = argument("dissipation").flatMap(Float.init) {
    for index in file.galaxies.indices { file.galaxies[index].dissipationTime = dissipation }
}
if let dt = argument("dt").flatMap(Float.init) { file.timeStep = dt }
if let theta = argument("theta").flatMap(Float.init) { file.openingAngle = theta }
if let value = argument("softening").flatMap(Float.init) { file.softening = value }
for (index, colour) in look.palette.enumerated() {
    if index < palette.count { palette[index] = colour } else { palette.append(colour) }
}
var scene = file.scene(particleCount: particles, palette: palette)
// Encounters are placed for a solver and a halo; a flag that changes either places them again.
if !scene.encounters.isEmpty,
    generatedHaste != nil || placedFor.0 != file.solver
        || placedFor.1 != file.galaxies.map(\.haloParticleRatio)
{
    if let generatedHaste {
        scene.retimeEncounters(
            from: SceneConfig.contemplationWindow(haste: generatedHaste),
            to: scene.encounterWindow(
                settleSteps: Int(number("settle", 0)), steps: Int(number("steps", 3_000))))
    }
    scene.placeEncountersGivingWay()
    let kept = file
    file = SceneFile(scene)
    file.softening = kept.softening
    file.timeStep = kept.timeStep
}
if let draw = scene.draw {
    print(
        "draw       \(draw.generator), batch \(draw.batchSeed) scene \(draw.index) (point \(draw.point)): "
            + draw.families.map(\.rawValue).joined(separator: ", "))
}
for encounter in scene.encounters {
    print(
        String(
            format: "encounter  %d-%d, pericentre %.1f kpc at %.0f Myr, e %.2f (%@), mass ratio %.2f",
            encounter.primary, encounter.secondary, encounter.pericentre,
            encounter.pericentreTime, encounter.eccentricity, encounter.orbit.rawValue,
            encounter.massRatio))
}
// A generated scene is judged from its centres before any particle is drawn, so one that would
// show nothing costs a moment rather than a night's slot. A scene read from a file was judged
// when it was drawn; `--check` judges it again and `--no-check` spares a generated one.
// `--check-only` stops here with the numbers.
if generatedHaste != nil && !arguments.contains("--no-check")
    || arguments.contains("--check") || arguments.contains("--check-only")
{
    let checkStart = Date()
    let verdict = scene.sanityCheck(
        settleSteps: Int(number("settle", 0)), steps: Int(number("steps", 3_000)))
    if arguments.contains("--check-only") {
        print(
            String(
                format: "check      closest %@, Toomre %@, start clearance %@, frame %.1f, "
                    + "step %.5f Myr, %.0f ms",
                verdict.closestApproach.map { String(format: "%.1f kpc at %.0f Myr", $0.distance, $0.time) }
                    ?? "none",
                verdict.toomre.map { String(format: "%.2f-%.2f", $0.lowerBound, $0.upperBound) } ?? "none",
                verdict.startClearance.map { String(format: "%.2f", $0) } ?? "none",
                verdict.fieldRatio, Double(scene.timeStep) * Physics.megayearsPerTimeUnit,
                Date().timeIntervalSince(checkStart) * 1000))
    }
    if !verdict.accepted {
        print("rejected   " + verdict.reasons.map(\.description).joined(separator: "; "))
        reporter?.finish()
        exit(3)
    }
    if arguments.contains("--check-only") { exit(0) }
}
// The colours the scene was drawn with, so the look file written beside it replays it exactly.
look.palette = scene.galaxies.map(\.color)

let settings = look.renderSettings(width: width, height: height)

print(
    "scene      \(scene.name), \(scene.totalParticleCount) visible"
        + (scene.hasLiveHalos
            ? ", \(scene.simulatedParticleCount - scene.totalParticleCount) halo" : ""))

let seeded = RestrictedSolver.sampleParticles(for: scene)
let gpuSolver: (any GPUSolver)? =
    backend == "cpu" ? nil : try GPUSolverFactory.make(scene: scene, particles: seeded)
let solver: any Solver = gpuSolver ?? RestrictedSolver(scene: scene, particles: seeded)
let renderer = try Renderer(
    particles: seeded, settings: settings, externalPositions: gpuSolver?.positions,
    externalFormation: gpuSolver?.formation)
// Each particle's kernel spans its own local interparticle spacing, so the surface stays
// continuous instead of resolving the sampling.
let drawnCount = seeded.visibleCount > 0 ? seeded.visibleCount : seeded.count
let smoothing = try SmoothingField(device: renderer.device, particleCount: drawnCount)
renderer.setSmoothing(smoothing.buffer)
print("solver     \(backend) (\(scene.solver.rawValue))")
print("gpu        \(renderer.gpuName)")

func prepared(_ path: String) throws -> URL {
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    return url
}

let outputURL = try outputPath.map(prepared)
// One still, small enough for a grid of a few hundred scenes, from the middle of the clip
// unless a frame is named.
let thumbnailURL = try argument("thumbnail").map(prepared)
let thumbnailFrame = min(Int(number("thumbnail-frame", Double(frames / 2))), frames - 1)

// Named after the main output, so `x.mov` and `x.sillage` both get `x.scene.json` and
// `x.look.json`.
func beside(_ suffix: String) -> String? {
    guard !arguments.contains("--no-sidecars") else { return nil }
    return [argument("take"), videoPath, outputPath].compactMap { $0 }.first.map { path in
        let url = URL(fileURLWithPath: path)
        let stem = url.lastPathComponent.split(separator: ".").first.map(String.init) ?? "scene"
        return url.deletingLastPathComponent().appendingPathComponent(stem + suffix).path
    }
}
if let sceneOutPath = argument("scene-out") ?? beside(".scene.json") {
    try file.encoded().write(to: prepared(sceneOutPath))
    print("scene file \(sceneOutPath)")
}

let stepsPerFrame = max(steps / max(frames, 1), 1)
let zoom = look.camera.zoom
let clock = Date()

// Framing is fixed once so the camera does not drift as the tails grow.
var frozenRadius = look.camera.radius

let framesPerSecond = Int32(number("fps", 30))

// The director re-applies a look every frame, so it is handed this one to build on; without
// it, it would pick one of its own named looks and every look flag would be silently ignored.
renderer.apply(look.look)

// The director places the camera and lights the scene on its own. Without it a hundred
// generated scenes come out framed identically, which is the thing that makes a library dull.
let directed = look.camera.mode == .director || look.camera.mode == .immersed
let director: Cinematographer? = directed ? Cinematographer(seed: scene.seed) : nil
var autoCamera = AutoCamera()
let reach = scene.galaxies.map { max($0.diskScaleLength * $0.diskTruncation, 0.1) }
director?.beginScene(seed: scene.seed, base: look.look, immersed: look.camera.mode == .immersed)

if let lookOutPath = argument("look-out") ?? beside(".look.json") {
    try (director?.lookFile(look) ?? look).encoded().write(to: prepared(lookOutPath))
    print("look file  \(lookOutPath)")
}

let videoWriter = try videoPath.map {
    try VideoWriter(
        width: width, height: height, framesPerSecond: framesPerSecond, to: prepared($0))
}

// A take holds the run rather than the picture, so a scene can be rendered again at another
// size, another exposure or another camera without simulating it a second time.
// Past its budget it carries on in a scratch file, which is what lets a take of tens of
// gigabytes be captured on a machine with less memory than that.
let takeBudget = Int(
    number("take-memory", Double(ProcessInfo.processInfo.physicalMemory / 4) / 1e6) * 1e6)
// `--take-interval n` keeps one frame in n, and whatever draws the take again interpolates
// the rest.
let takeInterval = max(Int(number("take-interval", 1)), 1)
let take: Recording? = argument("take").map { _ in
    let reel = Recording(
        particleCount: drawnCount, galaxyCount: scene.galaxies.count, interval: takeInterval)
    reel.reserve(frames: min(frames / takeInterval + 1, takeBudget / max(drawnCount * 6, 1) + 1))
    return reel
}

/// Per frame scalars, written for whoever scores the result later: a curve to drive a filter
/// with is worth more than a picture of one.
let curvesHeader =
    "frame,time_myr,separation_kpc,extent_kpc,formed,closest_kpc,tidal_fraction"
    + scene.galaxies.indices.map { ",disruption_\($0)" }.joined()
    + scene.galaxies.indices.map { ",x_\($0),y_\($0),z_\($0)" }.joined() + "\n"
let curves: FileHandle? = try argument("curves").map { path in
    let url = try prepared(path)
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    try handle.write(contentsOf: Data(curvesHeader.utf8))
    return handle
}
// `--story-cap <Myr>` keeps capturing past the planned frames while the story goes on, up to
// that much simulated time; `explore` asks for it. It reads the curves as written, so judging
// the file again afterwards gives the same answer.
let storyCap = argument("story-cap").flatMap(Double.init) ?? 0
// Frames kept after the story ends, to see that nothing happens next. For measuring only.
let storyAfter = number("story-after", 0)
var storySettings = Story.Settings()
storySettings.horizon = storyCap
var story =
    storyCap > 0 && curves != nil
    ? Story.Tracker(story: Story(scene: scene, settings: storySettings)) : nil
var previousTime = solver.time
var curvesSeconds: Double = 0
// `--density path` counts the stars on a fixed grid at `--density-frames` instants, the same
// grid at every particle count, so runs of one scene compare without a camera in between.
let densityURL = try argument("density").map(prepared)
var density = densityURL.map { _ in
    DensityMap(
        frames: frames, count: Int(number("density-frames", 8)),
        extent: Float(number("density-extent", 60)))
}
// A sampled star farther than this from every centre is in a tail or a bridge, not a disk.
let tidalReach = reach.map { $0 * 1.5 }

// Steps run before the first frame is written. A sampled disk is not born in equilibrium and
// settles over its first few hundred megayears, which is worth simulating and not worth
// watching.
let settle = Int(number("settle", 0))
// The cost of a step is flat (#19), so what has been done so far says what is left: while
// settling, from the pace of the steps; once frames come, from the pace of the frames, which
// the drawing of each one is part of.
let totalSteps = settle + stepsPerFrame * frames
if settle > 0 {
    let settleStart = Date()
    // In chunks, so a settle of minutes still reports.
    let chunk = max(settle / 50, 1)
    var settled = 0
    while settled < settle {
        let count = min(chunk, settle - settled)
        solver.step(count: count)
        settled += count
        let elapsed = Date().timeIntervalSince(settleStart)
        reporter?.update(
            progress: Double(settled) / Double(max(totalSteps, 1)), detail: "settle \(settled)/\(settle)",
            eta: RunStatus.eta(
                elapsed: elapsed, progress: Double(settled) / Double(max(totalSteps, 1)),
                now: Date()))
    }
    print(
        String(
            format: "settle     %d steps, t=%.1f Myr, %.1f s", settle,
            Double(solver.time) * Physics.megayearsPerTimeUnit,
            Date().timeIntervalSince(settleStart)))
    // Stars formed while settling are not the clip's, and would read as a burst on frame 0.
    previousTime = solver.time
}

/// Past the planned frames, whether the story still wants more.
func storyGoesOn() -> Bool {
    guard let story, let last = story.samples.last, last.timeMyr < storyCap else { return false }
    guard let quiet = story.quietFrom else { return true }
    return last.timeMyr < story.samples[quiet].timeMyr + storyAfter
}

let framesStart = Date()
var frame = 0
while frame < frames || storyGoesOn() {
    defer { frame += 1 }
    let simulationStart = Date()
    solver.step(count: stepsPerFrame)
    let simulationMs = Date().timeIntervalSince(simulationStart) * 1000

    if gpuSolver == nil {
        renderer.upload(positions: solver.particles.positions)
    }
    if frozenRadius <= 0 && look.camera.mode != .auto {
        frozenRadius = look.camera.framedRadius(positions: solver.particles.positions)
    }

    let smoothingStart = Date()
    // Plain points have no kernel to size.
    if !look.plain {
        if let gpuSolver {
            smoothing.update(from: gpuSolver)
        } else {
            smoothing.update(positions: solver.particles.positions)
        }
    }
    let smoothingMs = Date().timeIntervalSince(smoothingStart) * 1000
    renderer.time = solver.time
    renderer.setDiskFrames(
        DiskFrame.make(
            scene: scene, centers: solver.centers, time: solver.time,
            strength: LookFile.diskStrength(look.armStrength, director?.look ?? look.look)))
    let camera: Camera
    if let director {
        // Advanced by one frame of playback rather than by wall clock, so the move reads the
        // same however long the frame took to compute.
        director.advance(
            seconds: 1 / Double(framesPerSecond),
            of: Subject(centres: solver.centers, radius: frozenRadius))
        renderer.apply(director.look)
        camera = director.camera
    } else {
        var framed = (center: SIMD3<Float>.zero, radius: frozenRadius)
        if look.camera.mode == .auto {
            framed = autoCamera.frame(centres: solver.centers, margins: reach)
            framed.radius /= zoom
        }
        camera = look.camera.camera(
            progress: Float(frame) / Float(max(frames - 1, 1)), radius: framed.radius,
            center: framed.center, fieldOfView: look.look.fieldOfView)
    }
    let renderStart = Date()
    // The video is drawn straight into the encoder's buffers; a still is read off the same
    // frame rather than drawn twice.
    let wantsStill = outputURL != nil || (thumbnailURL != nil && frame == thumbnailFrame)
    var still: CGImage?
    if let videoWriter {
        try videoWriter.append(
            on: renderer.device,
            drawing: { target, buffer in
                renderer.encode(camera: camera, into: buffer, present: target)
            },
            read: wantsStill ? { still = PNGWriter.image(bgra: $0) } : nil)
    } else {
        still = PNGWriter.image(renderer.render(camera: camera), width: width, height: height)
    }
    let renderMs = Date().timeIntervalSince(renderStart) * 1000

    if let outputURL {
        let url =
            frames == 1
            ? outputURL
            : outputURL.deletingPathExtension().appendingPathExtension(
                String(format: "%04d.png", frame))
        if let still { try PNGWriter.write(still, maximumWidth: nil, to: url) }
    }
    if let thumbnailURL, frame == thumbnailFrame {
        if let still { try PNGWriter.write(still, maximumWidth: 480, to: thumbnailURL) }
        print("thumbnail  \(thumbnailURL.path)")
    }

    if let take {
        if let gpuSolver {
            take.offer(
                positions: gpuSolver.positions.contents().bindMemory(
                    to: SIMD3<Float>.self, capacity: seeded.count),
                time: solver.time, centers: solver.centers, budget: takeBudget)
        } else {
            solver.particles.positions.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                take.offer(
                    positions: base, time: solver.time, centers: solver.centers,
                    budget: takeBudget)
            }
        }
    }

    if density?.wants(frame: frame) == true {
        if let gpuSolver {
            density?.add(
                gpuSolver.positions.contents().bindMemory(
                    to: SIMD3<Float>.self, capacity: seeded.count), count: drawnCount)
        } else {
            solver.particles.positions.withUnsafeBufferPointer { buffer in
                if let base = buffer.baseAddress { density?.add(base, count: drawnCount) }
            }
        }
    }

    if let curves {
        let curvesStart = Date()
        let centres = solver.centers
        let separation =
            centres.count >= 2 ? simd_length(centres[1] - centres[0]) : Float(0)
        var closest = Float.infinity
        for i in centres.indices {
            for j in centres.indices where j > i {
                closest = min(closest, simd_length(centres[j] - centres[i]))
            }
        }
        if !closest.isFinite { closest = 0 }
        var sum: Float = 0
        var counted = 0
        var tidal = 0
        func tally(_ position: SIMD3<Float>) {
            sum += simd_length_squared(position)
            counted += 1
            for (centre, limit) in zip(centres, tidalReach)
            where simd_length_squared(position - centre) < limit * limit {
                return
            }
            tidal += 1
        }
        // Root mean square radius over a subsample: a smooth measure of how far the thing has
        // spread, for a fraction of the cost of sorting every radius. Read straight out of the
        // position buffer: `particles` on a GPU solver rebuilds the whole system on every
        // access, and calling it once per sample made each frame nine seconds slower.
        if let gpuSolver {
            let positions = gpuSolver.positions.contents().bindMemory(
                to: SIMD3<Float>.self, capacity: seeded.count)
            for index in stride(from: 0, to: drawnCount, by: 64) { tally(positions[index]) }
        } else {
            let positions = solver.particles.positions
            for index in stride(from: 0, to: drawnCount, by: 64) { tally(positions[index]) }
        }
        let extent = counted > 0 ? (sum / Float(counted)).squareRoot() : 0
        let tidalFraction = counted > 0 ? Float(tidal) / Float(counted) : 0
        let disruption = (gpuSolver as? MetalBarnesHutSolver)?.diskFrames.map(\.disruption) ?? []
        let disks = scene.galaxies.indices.map {
            String(format: ",%.3f", $0 < disruption.count ? disruption[$0] : 0)
        }.joined()
        var formed = 0
        if let gpuSolver {
            let times = gpuSolver.formation.contents().bindMemory(
                to: Float.self, capacity: seeded.count)
            for index in 0..<drawnCount
            where times[index] > previousTime && times[index] <= solver.time {
                formed += 1
            }
        }
        let myr = Double(solver.time) * Physics.megayearsPerTimeUnit
        let track = centres.map { String(format: ",%.4f,%.4f,%.4f", $0.x, $0.y, $0.z) }.joined()
        let line =
            String(
                format: "%d,%.3f,%.4f,%.4f,%d,%.4f,%.4f", frame, myr, separation, extent, formed,
                closest, tidalFraction) + disks + track + "\n"
        try curves.write(contentsOf: Data(line.utf8))
        if let sample = Story.samples(csv: curvesHeader + line).first { story?.append(sample) }
        curvesSeconds += Date().timeIntervalSince(curvesStart)
    }
    previousTime = solver.time

    if frame < frames {
        let framesDone = Double(frame + 1) / Double(max(frames, 1))
        reporter?.update(
            progress: Double(settle + (frame + 1) * stepsPerFrame) / Double(max(totalSteps, 1)),
            detail: "frame \(frame + 1)/\(frames)",
            eta: RunStatus.eta(
                elapsed: Date().timeIntervalSince(framesStart), progress: framesDone, now: Date()))
    } else {
        // How long a story still has is not known until it ends.
        reporter?.update(
            progress: 0.99,
            detail: String(
                format: "frame %d, story going on at %.0f Myr", frame + 1,
                Double(solver.time) * Physics.megayearsPerTimeUnit))
    }

    print(
        String(
            format:
                "frame %04d  t=%.1f Myr  sim %7.1f ms (%.3f ms/step)  smoothing %6.1f ms"
                + "  render %5.1f ms (gpu %5.2f)",
            frame, Double(solver.time) * Physics.megayearsPerTimeUnit, simulationMs,
            simulationMs / Double(stepsPerFrame), smoothingMs, renderMs,
            (videoWriter?.lastGPUTime ?? renderer.lastGPUTime) * 1000))
}

reporter?.update(progress: 1, detail: "finishing", eta: Date())
try videoWriter?.finish()
try curves?.close()
if let story, let span = story.span(plannedFrames: frames) {
    print(
        String(
            format: "story      %.0f to %.0f Myr (frames %d to %d of %d), %@", span.startMyr,
            span.endMyr, span.startFrame, span.endFrame, frame,
            span.complete
                ? "over"
                : "still going at the cap: "
                    + story.activity.map(\.description).joined(separator: "; ")))
    // The clip as it ran, so a rerun and every later stage see the same stretch of time.
    if let folder = exploreRun {
        var clip = try folder.storedClip()
        clip.frames = frame
        clip.steps = frame * stepsPerFrame
        clip.story = span
        try clip.encoded().write(to: folder.clip)
    }
}
if let density, let densityURL {
    try density.npy().write(to: densityURL)
    print("density    \(density.instants.count) maps, \(densityURL.path)")
}
if curves != nil {
    print(
        String(
            format: "curves     %.1f ms in all, %.3f ms a frame", curvesSeconds * 1000,
            curvesSeconds * 1000 / Double(max(frames, 1))))
}
if let take, let path = argument("take") {
    if let failure = take.spillFailure { print("take       held in memory: \(failure)") }
    try RecordingFile.write(take, scene: scene, particles: seeded, to: prepared(path))
}
if let (folder, done) = hiresRun {
    do {
        try folder.commitHires()
    } catch {
        fail("hires: could not put the take in place: \(error)")
    }
    var record = done
    record.seconds = Date().timeIntervalSince(started)
    record.peakMemoryBytes = peakFootprint()
    record.takeBytes =
        (try? FileManager.default.attributesOfItem(atPath: folder.take.path)[.size] as? Int)
        ?? nil
    try record.encoded().write(to: folder.hires)
    print(
        String(
            format: "hires      %.0f s, peak %.2f GB, take %.2f GB", record.seconds ?? 0,
            Double(record.peakMemoryBytes ?? 0) / 1e9, Double(record.takeBytes ?? 0) / 1e9))
    var finished = RunEvent(RunEvent.Kind.hiresDone)
    finished.particles = record.particles
    finished.steps = record.steps
    finished.minutes = (record.seconds ?? 0) / 60
    finished.takeGB = Double(record.takeBytes ?? 0) / 1e9
    reporter?.record(finished)
}
reporter?.finish()
if let (folder, _) = hiresRun { refreshCosts(folder) }
if let exploreRun { refreshCosts(exploreRun) }

print(String(format: "done in %.1f s", Date().timeIntervalSince(clock)))
