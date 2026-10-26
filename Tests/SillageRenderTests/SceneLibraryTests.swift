import Foundation
import Testing

@testable import SillageRender

@Suite("Scene library")
struct SceneLibraryTests {
    private func temporaryLibrary() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("library-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func touch(_ url: URL, _ text: String = "") throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @Test func findsSceneFoldersAndFlatBatchesAlike() throws {
        let root = try temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let batch = root.appendingPathComponent("2026-10-24")
        try touch(batch.appendingPathComponent("scene-0001/preview.mov"))
        try touch(
            batch.appendingPathComponent("scene-0001/scene.json"), #"{"draw": {"generator": "antennae"}}"#)
        try touch(batch.appendingPathComponent("scene-0001/exports/final.mov"))
        try touch(batch.appendingPathComponent("scene-0002/thumbnail.png"))
        try touch(batch.appendingPathComponent("scene-0002/interest.json"), #"{"score": 0.42}"#)
        try touch(batch.appendingPathComponent("notes/readme.txt"))
        try touch(
            batch.appendingPathComponent("index.csv"),
            "id,seed,tempo,galaxies,score\nscene-0001,7,lent,2,\nscene-0001,8,pose,3,0.6\n")
        let legacy = root.appendingPathComponent("2026-09-21")
        try touch(legacy.appendingPathComponent("scene-0003.mov"))
        try touch(legacy.appendingPathComponent("scene-0004.mov.partial"))
        try touch(legacy.appendingPathComponent("index.csv"), "id,archetype\nscene-0003,mice\n")

        let scenes = SceneLibrary.scan(root)
        #expect(
            scenes.map(\.id).sorted() == [
                "2026-09-21/scene-0003", "2026-10-24/scene-0001", "2026-10-24/scene-0002",
            ])
        let first = try #require(scenes.first { $0.name == "scene-0001" })
        #expect(first.archetype == "antennae" && first.tempo == "pose" && first.seed == "8")
        #expect(first.video?.lastPathComponent == "preview.mov" && first.thumbnail == nil)
        let second = try #require(scenes.first { $0.name == "scene-0002" })
        #expect(second.video == nil && second.thumbnail?.lastPathComponent == "thumbnail.png")
        #expect(scenes.first { $0.name == "scene-0003" }?.archetype == "mice")
        #expect(first.score == 0.6 && second.score == 0.42)

        // Pointed at one batch rather than the library, it is the same batch.
        #expect(
            SceneLibrary.scan(batch).map(\.id).sorted() == ["2026-10-24/scene-0001", "2026-10-24/scene-0002"])
    }

    /// `scripts/explore-batch.sh` explores into `.scene-0001` and renames it when the clip is
    /// done, which is all that keeps a scene halfway written out of the grid.
    @Test func aSceneStillBeingExploredStaysHiddenUntilItIsRenamed() throws {
        let batch = try temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: batch) }
        let staging = batch.appendingPathComponent(".scene-0001")
        try touch(staging.appendingPathComponent("scene.json"), "{}")
        try touch(staging.appendingPathComponent("preview.mov"))
        try touch(batch.appendingPathComponent(".logs/scene-0001.log"))
        #expect(SceneLibrary.scan(batch).isEmpty)

        try FileManager.default.moveItem(at: staging, to: batch.appendingPathComponent("scene-0001"))
        #expect(SceneLibrary.scan(batch).map(\.name) == ["scene-0001"])
    }

    @Test func aPickIsKeptApartFromChoiceAndRating() throws {
        let batch = try temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: batch) }
        try touch(
            SceneRatings.url(batch: batch),
            """
            {"version":1,"scenes":{"old":{"choice":"yes","rating":3},
            "new":{"picked":{"by":"score","score":0.8,"date":"2026-10-25T19:57:45Z"}}}}
            """)
        let ratings = SceneRatings.read(batch: batch)
        #expect(ratings.scenes["old"]?.picked == nil && ratings.scenes["old"]?.rating == 3)
        let pick = try #require(ratings.scenes["new"]?.picked)
        #expect(pick.by == "score" && pick.score == 0.8)
        #expect(ratings.scenes["new"]?.choice == nil && ratings.scenes["new"]?.rating == nil)
        #expect(ratings.chosen == ["new", "old"])

        // A manual no wins and keeps the pick as history; a rating does not need a choice.
        let no = try SceneRatings.update(batch: batch, scene: "new") { $0.choice = .no }
        #expect(no.scenes["new"]?.picked == pick && !no.chosen.contains("new"))
        let yes = try SceneRatings.update(batch: batch, scene: "new") { $0.choice = .yes }
        #expect(yes.chosen.contains("new"))
        let rated = try SceneRatings.update(batch: batch, scene: "new") {
            $0.choice = nil
            $0.rating = 6
        }
        #expect(rated.scenes["new"]?.rating == 6 && rated.chosen.contains("new"))
        let cleared = try SceneRatings.update(batch: batch, scene: "new") { $0.rating = nil }
        #expect(cleared.scenes["new"]?.picked == pick)
    }

    @Test func aChangeKeepsWhatAnotherToolWroteMeanwhile() throws {
        let batch = try temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: batch) }
        #expect(SceneRatings.read(batch: batch) == SceneRatings())

        try SceneRatings.update(batch: batch, scene: "scene-0001") { $0.choice = .yes }
        try SceneRatings(scenes: [
            "scene-0001": .init(choice: .yes), "scene-0009": .init(rating: 4),
        ]).write(batch: batch)
        let ratings = try SceneRatings.update(batch: batch, scene: "scene-0001") { $0.rating = 14 }
        #expect(ratings.scenes["scene-0009"]?.rating == 4)
        #expect(ratings.scenes["scene-0001"]?.rating == 10)
        #expect(ratings.scenes["scene-0001"]?.choice == .yes)
        #expect(SceneRatings.read(batch: batch) == ratings)
        #expect(ratings.chosen == ["scene-0001"])

        try SceneRatings.update(batch: batch, scene: "scene-0009") { $0.rating = nil }
        #expect(SceneRatings.read(batch: batch).scenes["scene-0009"] == nil)

        try touch(SceneRatings.url(batch: batch), "{ not json")
        #expect(SceneRatings.read(batch: batch) == SceneRatings())
    }

    /// Other tools read the file, so its shape is part of the contract.
    @Test func theFileIsPlainJSON() throws {
        let batch = try temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: batch) }
        try SceneRatings.update(batch: batch, scene: "scene-0001", at: Date(timeIntervalSince1970: 0)) {
            $0.choice = .no
            $0.rating = 3
        }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: SceneRatings.url(batch: batch)))
        let scenes = try #require((object as? [String: Any])?["scenes"] as? [String: [String: Any]])
        #expect(scenes["scene-0001"]?["choice"] as? String == "no")
        #expect(scenes["scene-0001"]?["rating"] as? Int == 3)
        #expect(scenes["scene-0001"]?["updated"] as? String == "1970-01-01T00:00:00Z")
    }

    @Test func filtersAndOrders() {
        let batch = URL(fileURLWithPath: "/l")
        func scene(_ batchName: String, _ name: String, _ archetype: String? = nil, _ age: Double = 0)
            -> LibraryScene
        {
            LibraryScene(
                batch: batchName, batchURL: batch, name: name, archetype: archetype,
                modified: Date(timeIntervalSince1970: age))
        }
        let scenes = [
            scene("a", "s1", "mice", 5), scene("a", "s2", nil, 9), scene("b", "s1", "ring", 1),
            scene("b", "s2", nil, 3),
        ]
        let entries: [String: SceneRatings.Entry] = [
            "a/s1": .init(choice: .yes, rating: 8), "a/s2": .init(choice: .no, rating: 8),
            "b/s1": .init(rating: 2),
        ]
        var query = LibraryQuery()
        #expect(query.apply(scenes, entries: entries).map(\.id) == ["b/s1", "b/s2", "a/s1", "a/s2"])
        query.order = .newest
        #expect(query.apply(scenes, entries: entries).map(\.id) == ["a/s2", "a/s1", "b/s2", "b/s1"])
        query.order = .rating
        #expect(query.apply(scenes, entries: entries).map(\.id) == ["a/s1", "a/s2", "b/s1", "b/s2"])

        // Scored scenes first, highest first, and the unscored ones still shown after them.
        var scored = scenes
        scored[0].score = 0.2
        scored[3].score = 0.7
        query.order = .score
        #expect(query.apply(scored, entries: entries).map(\.id) == ["b/s2", "a/s1", "b/s1", "a/s2"])

        query = LibraryQuery()
        query.choice = .undecided
        #expect(query.apply(scenes, entries: entries).map(\.id) == ["b/s1", "b/s2"])
        query.rating = .unrated
        #expect(query.apply(scenes, entries: entries).map(\.id) == ["b/s2"])
        query = LibraryQuery()
        query.rating = .atLeast(5)
        query.choice = .yes
        #expect(query.apply(scenes, entries: entries).map(\.id) == ["a/s1"])
        query = LibraryQuery()
        query.batch = "a"
        query.archetype = LibraryQuery.free
        #expect(query.apply(scenes, entries: entries).map(\.id) == ["a/s2"])
    }
}
