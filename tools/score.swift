// Throwaway (#315): Auto's telescope pick against a given look, scored the way Auto scores.
import Foundation
import SillageCore
@testable import SillageRender

let args = CommandLine.arguments
let folder = SceneFolder(URL(fileURLWithPath: args[1]))
let lookFile = try LookFile.decoded(from: Data(contentsOf: URL(fileURLWithPath: args[2])))
let catalogue = LookCatalogue.repository
let references = TelescopeReference.repository

let outcome = try StyleAuto.choose(folder, world: .telescope, catalogue: catalogue, references: references)
let frames = outcome.keys.map(\.frame)
print("key frames", outcome.keys.map { "\($0.role.rawValue) \($0.frame)" })

func line(_ name: String, _ scores: [FrameScore], palette: Float?) {
    func mean(_ p: KeyPath<FrameScore, Float>) -> Float { scores.map { $0[keyPath: p] }.reduce(0, +) / Float(scores.count) }
    let reference = scores.compactMap(\.reference)
    let variety = scores.compactMap(\.variety)
    let total = FrameScore.mean(scores)
    let overall = palette.map { (1 - StyleAuto.paletteWeight) * total + StyleAuto.paletteWeight * $0 }
    print(String(format: "%@\tframe %.3f\tclip %.2f expo %.2f colour %.2f sep %.2f noise %.2f detail %.2f ref %.2f variety %.2f\tpalette %@\ttotal %@",
        name, total, mean(\.clipping), mean(\.exposure), mean(\.colourfulness), mean(\.separation), mean(\.noise), mean(\.detail),
        reference.isEmpty ? -1 : reference.reduce(0, +) / Float(reference.count),
        variety.isEmpty ? -1 : variety.reduce(0, +) / Float(variety.count),
        palette.map { String(format: "%.3f", $0) } ?? "-", overall.map { String(format: "%.3f", $0) } ?? "-"))
}

for candidate in outcome.ranked.prefix(3) {
    line("auto: \(candidate.rendering) \(candidate.palette.family)-\(candidate.palette.harmony.rawValue)", candidate.frames, palette: candidate.paletteScore.total)
}

// The given look drawn with its own palette, through the scene's camera as Auto keeps it.
var base = (try? Data(contentsOf: folder.look)).flatMap { try? LookFile.decoded(from: $0) } ?? .standard
var look = lookFile
look.camera = base.camera
look.look.fieldOfView = base.look.fieldOfView
let cellHeight = max(Int((Double(StyleAuto.cellWidth) * Double(outcome.height) / Double(outcome.width)).rounded()), 1)
var scores: [FrameScore] = []
try outcome.sheet.draw(
    looks: [look], frames: frames, width: outcome.width, height: outcome.height,
    cellWidth: StyleAuto.cellWidth, cellHeight: cellHeight, framesPerSecond: outcome.fps, owners: true
) { _, _, cell in
    scores.append(FrameScore(
        pixels: cell.pixels, width: StyleAuto.cellWidth, height: cellHeight, owners: cell.owners,
        references: references, ramps: true))
}
let colour = look.palette.first?.colour ?? SIMD3(1, 1, 1)
let one = Palette(world: .telescope, family: "hubble-visible", harmony: .monochrome, seed: 0,
    colours: Array(repeating: colour, count: max(look.palette.count, 2)), multicolour: false)
let paletteScore = PaletteScore(one, references: references)
print(String(format: "photograph palette: separation %.2f harmony %.2f range %.2f balance %.2f reference %.2f total %.3f",
    paletteScore.separation, paletteScore.harmony, paletteScore.range, paletteScore.balance, paletteScore.reference ?? -1, paletteScore.total))
line("given: \(lookFile.name)", scores, palette: paletteScore.total)
for (key, s) in zip(outcome.keys, scores) {
    print(String(format: "  %@ %d: nearest %@ colourfulness %.1f referenceMiss %@ detail %.3f litLuma %.2f",
        key.role.rawValue, key.frame, s.measures.nearest.map { String(format: "%.3f", $0) } ?? "-",
        s.measures.colourfulness, s.measures.referenceMiss.map { String(format: "%.3f", $0) } ?? "-",
        s.measures.detail, s.measures.litLuma))
}
