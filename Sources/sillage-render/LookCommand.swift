import CoreGraphics
import Foundation
import SillageCore
import SillageRender
import simd

/// The mode `--camera` names, for the style it promotes; nil when not given.
func askedCamera(_ options: [String]) -> LookFile.CameraPlan.Mode? {
    guard let index = options.firstIndex(of: "--camera") else { return nil }
    guard index + 1 < options.count, let mode = LookFile.CameraPlan.Mode(rawValue: options[index + 1])
    else { fail("look: --camera is auto, fixed, director or immersed") }
    return mode
}

/// `look <scene folder>`: `--style`, `--palette` and `--promote <name>` choose the scene's style,
/// `--camera <mode>` the camera it is filmed with;
/// `--grid` draws a grid of looks against key frames of the take (options: `--base <look|file>`,
/// `--no-variants`, `--no-catalogue`, `--width`, `--take`, `--frames`, `--times`, and any
/// `.look.json`; every row is kept as `looks/<name>.look.json`).
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
            folder, choice: choice, world: option("world"), base: option("base"),
            single: options.contains("--single"), camera: askedCamera(options),
            generated: options.contains("--generated"))
    }
    if let name = option("promote") {
        let file = try folder.promote(look: name)
        print("look       \(file.name) is now \(folder.look.path)")
        return 0
    }
    guard options.contains("--grid") else {
        print("look       choose a style in the app (Choose style), or with")
        print("           sillage-render look \(folder.url.path) --style auto")
        print("           sillage-render look \(folder.url.path) --palette auto")
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
        .nonEmpty ?? loaded.scene.galaxies.map { GalaxyColours($0.color) }
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
    let clip = try folder.storedClip()
    let hires = folder.storedHires()
    // The director's shots, printed, and `--frames shots` draws the middle of each.
    let planned = Date()
    let plan = looks.first { $0.camera.mode == .director }.map {
        ShotPlan(take: loaded, file: $0, framesPerSecond: hires?.fps ?? clip.fps)
    }
    for line in plan?.summary ?? [] { print("shot       \(line)") }
    if let plan {
        print(
            String(
                format: "shots      %.0f %% of the clip close, planned in %.1f s",
                plan.closeShare * 100, Date().timeIntervalSince(planned)))
    }
    let samples =
        (try? String(contentsOf: folder.hiresCurves, encoding: .utf8))
        .map(KeyFrames.samples) ?? []
    let lastFrame = sheet.capturedFrames - 1
    var keys: [KeyFrame]
    if option("frames") == "shots", let plan {
        keys = plan.shots.map {
            KeyFrame(frame: ($0.start + $0.end - 1) / 2, role: .chosen, timeMyr: 0)
        }
    } else if let list = option("frames") {
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

    // `--stills <dir>` writes every look at every key frame at full size, one PNG each, and
    // leaves the scene's looks folder alone: it is for looking closely, not for choosing.
    // `--width` sets that size, for the one an export draws; the take's own by default.
    let stillsDirectory = option("stills").map { URL(fileURLWithPath: $0) }
    let takeWidth = hires?.width ?? clip.width
    let takeHeight = hires?.height ?? clip.height
    let stillsWidth = stillsDirectory == nil ? nil : option("width").flatMap { Int($0) }
    let renderWidth = stillsWidth ?? takeWidth
    let renderHeight = stillsWidth.map { $0 * takeHeight / takeWidth } ?? takeHeight
    let cellWidth = stillsDirectory != nil ? renderWidth : Int(option("width").flatMap(Double.init) ?? 480)
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
    if let stillsDirectory {
        try FileManager.default.createDirectory(at: stillsDirectory, withIntermediateDirectories: true)
        var last = Date()
        var exposures = 0
        try sheet.draw(
            looks: looks, frames: keys.map(\.frame), width: renderWidth, height: renderHeight,
            cellWidth: cellWidth, cellHeight: cellHeight, framesPerSecond: hires?.fps ?? clip.fps
        ) { row, column, cell in
            let drawn = Date().timeIntervalSince(last)
            let url = stillsDirectory.appendingPathComponent(
                "\(looks[row].name)-\(keys[column].frame).png")
            try PNGWriter.write(cell.pixels, width: cellWidth, height: cellHeight, to: url)
            print(String(format: "still      %@  %.2f s", url.lastPathComponent, drawn))
            if let (_, _, solved) = sheet.exposures.last, sheet.exposures.count > exposures {
                exposures = sheet.exposures.count
                print(exposureLine(solved))
            }
            last = Date()
        }
        print(
            String(
                format: "look       %d looks x %d frames from %@, %.1f s", looks.count, keys.count,
                takeURL.lastPathComponent, Date().timeIntervalSince(started)))
        return 0
    }
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

/// What a scene's palette is drawn from: the seed in its `scene.json`.
func sceneSeed(_ folder: SceneFolder) throws -> (seed: UInt64, galaxies: Int) {
    try LookChoice.sceneSeed(folder)
}

typealias PaletteChoice = LookChoice.PaletteChoice

func askedWorld(_ name: String?, command: String) -> Palette.World? {
    do { return try LookChoice.world(name) } catch { fail("\(command): \(error)") }
}

/// `LookChoice.resolve` with the repository's references and favourites.
func resolvePalette(
    _ folder: SceneFolder, choice: String, world asked: Palette.World?, command: String,
    single: Bool = false
) throws -> PaletteChoice {
    do {
        return try LookChoice.resolve(
            folder, choice: choice, world: asked, single: single, references: telescopeReferences(),
            favourites: FavouritePalettes.load())
    } catch let failure as LookChoice.Failure {
        fail("\(command): \(failure)")
    }
}

func apply(_ choice: PaletteChoice, to look: inout LookFile) {
    LookChoice.apply(choice, to: &look, references: telescopeReferences())
}

/// `look <scene folder> --palette auto|<family>|<file.palette.json> [--world telescope|free]
/// [--base <look>] [--single] [--camera <mode>] [--generated]`: `LookChoice.promotePalette`.
func palettePromotion(
    _ folder: SceneFolder, choice: String, world: String?, base: String?, single: Bool,
    camera: LookFile.CameraPlan.Mode? = nil, generated: Bool = false
) throws -> Int32 {
    do {
        print(
            try LookChoice.promotePalette(
                folder, choice: choice, world: askedWorld(world, command: "look"), base: base, single: single,
                camera: camera, generated: generated, catalogue: catalogueLooks(),
                references: telescopeReferences(), favourites: FavouritePalettes.load()))
    } catch let failure as LookChoice.Failure {
        fail("look: \(failure)")
    }
    return 0
}

/// `look <scene folder> --style auto [--world telescope|free] [--palette <family>|<file>] [--single] [--camera <mode>] [--keep]`:
/// every rendering of the world with the scene's best palettes (or the one palette asked for), drawn on three key frames and scored; the best
/// pair is promoted unless `--keep`. Writes `looks/auto-<world>.png` (the best three) and
/// `looks/auto-<world>.json` (every pair's score).
func styleAuto(_ folder: SceneFolder, options: [String]) throws -> Int32 {
    func option(_ name: String) -> String? {
        options.firstIndex(of: "--\(name)").flatMap {
            $0 + 1 < options.count ? options[$0 + 1] : nil
        }
    }
    let started = Date()
    let single = options.contains("--single")
    var world = askedWorld(option("world"), command: "look")
    var family: String?
    var fixed: Palette?
    let favourites = FavouritePalettes.load()
    if let choice = option("palette"), choice != "auto" {
        if !FileManager.default.fileExists(atPath: choice),
            FavouritePalettes.find(choice, in: favourites) != nil
        {
            guard
                case .recipe(let palette, _) = try resolvePalette(
                    folder, choice: choice, world: world, command: "look", single: single)
            else { fail("look: favourite \(choice) could not be read") }
            fixed = palette
            world = world ?? palette.world
        } else if FileManager.default.fileExists(atPath: choice) {
            guard
                case .recipe(let palette, _) = try resolvePalette(
                    folder, choice: choice, world: world, command: "look", single: single)
            else { fail("look: --style auto needs a palette file with a family, harmony and seed") }
            fixed = palette
            world = world ?? palette.world
        } else {
            family = choice
            world =
                world
                ?? Palette.World.allCases.first { world in
                    PaletteGenerator.families(world, telescope: telescopeReferences().map(\.family))
                        .contains { $0.name == choice }
                }
            if world == nil {
                fail("look: --palette is auto, a family or a .palette.json file, not \(choice)")
            }
        }
    }
    let outcome = try StyleAuto.choose(
        folder, world: world, family: family, fixed: fixed, catalogue: catalogueLooks(),
        references: telescopeReferences(), favourites: favourites.map(\.palette),
        multicolour: !single, camera: askedCamera(options))
    let scoredAt = Date()
    let (sheet, keys, ranked) = (outcome.sheet, outcome.keys, outcome.ranked)
    let (width, height, fps) = (outcome.width, outcome.height, outcome.fps)
    let renderings = Set(ranked.map(\.rendering)).count
    let palettes = Set(ranked.map(\.palette.name)).count

    func label(_ candidate: StyleAuto.Candidate) -> String {
        String(format: "%.3f %@ · %@", candidate.total, candidate.rendering, candidate.palette.name)
    }
    for (index, candidate) in ranked.prefix(5).enumerated() {
        func part(_ path: KeyPath<FrameScore, Float>) -> Float {
            candidate.frames.map { $0[keyPath: path] }.reduce(0, +)
                / Float(max(candidate.frames.count, 1))
        }
        func mean(_ values: [Float]) -> String {
            values.isEmpty ? "-" : String(format: "%.2f", values.reduce(0, +) / Float(values.count))
        }
        print(
            String(
                format:
                    "style      %d. %@: clipping %.2f exposure %.2f colour %.2f separation %.2f noise %.2f detail %.2f reference %@ variety %@ palette %.2f",
                index + 1, label(candidate), part(\.clipping), part(\.exposure),
                part(\.colourfulness), part(\.separation), part(\.noise), part(\.detail),
                mean(candidate.frames.compactMap(\.reference)),
                mean(candidate.frames.compactMap(\.variety)), candidate.paletteScore.total))
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
    let report = folder.looks.appendingPathComponent("auto-\(outcome.world.rawValue).json")
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
    let gridURL = folder.looks.appendingPathComponent("auto-\(outcome.world.rawValue).png")
    try PNGWriter.write(grid, to: gridURL)

    print(
        String(
            format:
                "style      %d pairs (%d renderings, %d palettes) on %d frames at %dx%d: %.1f s",
            ranked.count, renderings, palettes, keys.count, width, height,
            scoredAt.timeIntervalSince(started)))
    print("grid       \(gridURL.path)")
    print("scores     \(report.path)")
    if let best = ranked.first, !options.contains("--keep") {
        try folder.promote(best.look)
        print("look       \(label(best)) is now \(folder.look.path)")
    }
    return 0
}
