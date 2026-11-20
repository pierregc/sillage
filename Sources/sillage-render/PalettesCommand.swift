import CoreGraphics
import Foundation
import SillageCore
import SillageRender
import simd

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
    let single = options.contains("--single")
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
            seed: try sceneSeed(folder).seed, telescope: references, multicolour: !single
        ).prefix(max(best, 1))
        palettes = top.map(\.palette)
        labels = top.map { String(format: "%.2f %@", $0.score.total, $0.palette.name) }
        for ranked in top {
            let s = ranked.score
            print(
                String(
                    format:
                        "palettes   %@ %.2f: separation %.2f harmony %.2f range %.2f balance %.2f reference %@ inside %@ between %@",
                    ranked.palette.name, s.total, s.separation, s.harmony, s.range, s.balance,
                    s.reference.map { String(format: "%.2f", $0) } ?? "-",
                    s.inside.map { String(format: "%.2f", $0) } ?? "-",
                    s.between.map { String(format: "%.2f", $0) } ?? "-"))
        }
    } else {
        for seed in firstSeed..<(firstSeed + UInt64(max(count, 1))) {
            palettes.append(
                try PaletteGenerator.palette(
                    galaxies: galaxies, world: world, family: option("family"),
                    harmony: harmony, seed: seed, telescope: telescope, multicolour: !single,
                    references: references))
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
        file.palette = palette.galaxyColours(references: references)
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
