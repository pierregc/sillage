import Foundation
import Testing

@testable import SillageRender

@Suite("The fields of a look file")
struct LookFieldsTests {
    private func labels(_ value: Any) -> Set<String> {
        Set(Mirror(reflecting: value).children.compactMap(\.label))
    }

    @Test("Every field of a look file is described, and nothing else")
    func everyField() {
        #expect(Set(LookFields.file.map(\.0)) == labels(LookFile()))
        #expect(Set(LookFields.look.map(\.0)) == labels(RenderLook()))
        #expect(Set(LookFields.camera.map(\.0)) == labels(LookFile.CameraPlan()))
    }

    @Test("The text gives defaults and the catalogue's ranges")
    func text() throws {
        let catalogue = try RepositoryRoot.resolve().appendingPathComponent("looks")
        let text = LookFields.text(catalogue: catalogue)
        #expect(text.contains("whitePoint"))
        #expect(text.contains("default 2500"))
        #expect(text.contains("looks/ use"))
    }

    @Test("Every option of every command says what it does")
    func everyOptionIsDescribed() {
        let specs = [RenderCommands.plain] + RenderCommands.all + CUDACommands.all
        let bare = specs.flatMap { spec in
            spec.options.filter(\.help.isEmpty).map { "\(spec.name) --\($0.name)" }
        }
        #expect(bare.isEmpty, "no description: \(bare)")
    }
}
