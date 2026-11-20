import CoreGraphics
import Foundation
import SillageCore
import SillageRender
import simd

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
                format: "%@  %d galaxies  curves %.0f-%.0f Myr  %@  story %.0f-%.0f Myr, engaged to %.0f  %@",
                folder.url.lastPathComponent, file.galaxies.count, first.timeMyr, last.timeMyr,
                collision, span.startMyr, span.endMyr, tracker.engagedMyr ?? first.timeMyr,
                span.complete
                    ? "over" : "going on: " + tracker.activity.map(\.description).joined(separator: "; ")))
    }
    print("story      \(over) of \(folders.count) over")
    return 0
}
