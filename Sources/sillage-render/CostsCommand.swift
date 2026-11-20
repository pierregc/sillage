import CoreGraphics
import Foundation
import SillageCore
import SillageRender
import simd

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
