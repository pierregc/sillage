import Testing

@testable import SillageRender

@Suite("Distinct labels")
struct DistinctLabelsTests {
    @Test func uniqueLabelsStayAsTheyAre() {
        #expect(DistinctLabels.make(["a", "b"]) == ["a", "b"])
    }

    @Test func repeatedLabelsAreNumberedInOrder() {
        let made = DistinctLabels.make(["a · x", "b", "a · x", "a · x", "b"])
        #expect(made == ["a · x (1)", "b (1)", "a · x (2)", "a · x (3)", "b (2)"])
        #expect(Set(made).count == made.count)
    }
}
