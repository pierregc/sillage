import Foundation

/// The repository's looks, `looks/*.look.json`, and which colour world each belongs to.
public enum LookCatalogue {
    /// Every look in `directory` but the raw one, the built in five first; those five alone
    /// when the folder has none.
    public static func load(from directory: URL) -> [LookFile] {
        let order = RenderLook.catalogue.map(\.id)
        let files =
            ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasSuffix(".look.json") && $0 != "raw.look.json" }
            .sorted { a, b in
                let ia = order.firstIndex(of: String(a.dropLast(10))) ?? order.count
                let ib = order.firstIndex(of: String(b.dropLast(10))) ?? order.count
                return ia == ib ? a < b : ia < ib
            }
            .compactMap { name in
                (try? Data(contentsOf: directory.appendingPathComponent(name)))
                    .flatMap { try? LookFile.decoded(from: $0) }
            }
        return files.isEmpty
            ? RenderLook.catalogue.map { LookFile(name: $0.id, look: $0.look) } : files
    }

    /// The renderings Auto chooses among in `world`: Hubble and Webb for the telescope, the
    /// rest of the catalogue for the free world.
    public static func renderings(_ world: Palette.World, in catalogue: [LookFile]) -> [LookFile] {
        catalogue.filter { $0.world == world }
    }
}
