import AppKit
import Darwin
import Foundation
import SillageCore
import SillageRender
import SwiftUI

/// The style editor's thumbnails (#114) on a take: how long every rendering takes to draw,
/// what the canvas keeps of its frame rate meanwhile, and when they are drawn again.
///
/// `--thumbcheck <take>`. Headless, for the same reason as `--replay`. The take's scene folder
/// is lent through links, so nothing in the library is written.
enum ThumbnailCheck {
    /// Three seconds for every rendering of a 2 M take on the M4 Max.
    static let budgetSeconds = 3.0

    @MainActor
    static func run() {
        guard let flag = CommandLine.arguments.firstIndex(of: "--thumbcheck"),
            flag + 1 < CommandLine.arguments.count
        else { return }
        let take = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
        var lines: [String] = []
        var failed = false
        func check(_ label: String, _ passed: Bool, _ detail: String = "") {
            lines.append("\(passed ? "OUI" : "NON")  \(label)\(detail.isEmpty ? "" : "  \(detail)")")
            if !passed { failed = true }
        }
        func fail(_ why: String) -> Never {
            FileHandle.standardError.write(Data("thumbcheck: \(why)\n".utf8))
            exit(1)
        }

        let folder = SceneFolder(
            FileManager.default.temporaryDirectory.appendingPathComponent(
                "thumbcheck-\(UUID().uuidString)/scene-0001"))
        try? FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        let home = SceneFolder(take.deletingLastPathComponent())
        for (from, to) in [
            (home.scene, folder.scene), (home.clip, folder.clip), (home.hires, folder.hires),
            (home.hiresCurves, folder.hiresCurves), (take, folder.take),
        ] where FileManager.default.fileExists(atPath: from.path) {
            try? FileManager.default.createSymbolicLink(at: to, withDestinationURL: from)
        }
        if let look = try? Data(contentsOf: home.look) {
            try? look.write(to: folder.look)
        } else {
            try? LookFile.standard.encoded().write(to: folder.look)
        }

        guard let model = SimulationModel() else { fail("pas de périphérique Metal") }
        let opening = CACurrentMediaTime()
        model.openTake(from: folder.take, look: folder.look, folder: folder)
        let deadline = Date().addingTimeInterval(900)
        while model.mode != .playback || model.capturedFrames < 2 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            if let failure = model.failure { fail(failure) }
            if Date() > deadline { fail("la prise n'a pas chargé") }
        }
        let openSeconds = CACurrentMediaTime() - opening
        model.resize(to: CGSize(width: 1920, height: 1080))
        model.isPlaying = false
        let last = Double(model.capturedFrames - 1)
        model.playbackPosition = last / 3

        // The canvas paced at 60 Hz: each frame's wall time, GPU wait and read-back included,
        // and its GPU time.
        func canvas(until done: () -> Bool, atMost seconds: Double) -> Frames {
            var frames = Frames()
            let end = CACurrentMediaTime() + seconds
            while !done(), CACurrentMediaTime() < end {
                let start = CACurrentMediaTime()
                _ = model.playbackSnapshot()
                frames.wall.append((CACurrentMediaTime() - start) * 1000)
                frames.gpu.append(model.lastOffscreenGPUMilliseconds)
                RunLoop.current.run(
                    until: Date(timeIntervalSinceNow: max(start + 1.0 / 60 - CACurrentMediaTime(), 0)))
            }
            return frames
        }
        func wait(_ seconds: Double) { RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds)) }
        func keeps(_ label: String, _ during: Frames, _ alone: Frames) {
            check(
                "le canvas garde sa cadence \(label)",
                during.lateShare <= alone.lateShare + 0.03
                    && median(during.wall) <= median(alone.wall) * 1.15 + 1,
                String(
                    format: "%.0f %% en retard contre %.0f %% seul, médiane %.1f ms contre %.1f",
                    during.lateShare * 100, alone.lateShare * 100, median(during.wall),
                    median(alone.wall)))
        }

        _ = canvas(until: { false }, atMost: 1.5)
        let alone = canvas(until: { false }, atMost: 2)

        let scene = LibraryScene(
            batch: "thumbcheck", batchURL: folder.batch, name: "scene-0001", folder: folder, take: take)
        let session = StyleSession(scene: scene, model: model)
        let thumbnails = session.thumbnails
        check("l'éditeur trouve la prise ouverte", session.isOpen)
        let count = thumbnails.renderings.count
        let during = canvas(until: { thumbnails.passes >= 1 }, atMost: 120)
        wait(0.2)
        let seconds = thumbnails.lastSeconds ?? .infinity
        check("les vignettes partent seules à l'ouverture", thumbnails.passes == 1)
        check(
            "une vignette par rendu", thumbnails.images.count == count && thumbnails.lastDrawn == count,
            "\(thumbnails.images.count) sur \(count)")
        check(
            "toutes en moins de \(Int(budgetSeconds)) s", seconds < budgetSeconds,
            String(format: "%.2f s, %.0f ms la vignette", seconds, seconds * 1000 / Double(max(count, 1))))
        let lit = thumbnails.images.values.filter { meanLuma($0) > 0.01 }.count
        check("les vignettes montrent la scène", lit == count, "\(lit) éclairées")
        let distinct = Set(thumbnails.images.values.map { fingerprint($0) }).count
        check("les rendus se distinguent", distinct >= count * 3 / 4, "\(distinct) différentes")
        keeps("pendant le premier dessin", during, alone)
        if let first = thumbnails.images.values.first {
            check(
                "dessinées à la taille du clip puis réduites",
                first.width == RenderingThumbnails.width
                    && abs(Double(first.width) / Double(first.height) - thumbnails.aspectRatio) < 0.02,
                "\(first.width)×\(first.height)")
        }

        SillageApp.write(
            AnyView(
                RenderingSection(session: session, thumbnails: thumbnails).padding(14).frame(width: 340)
                    .environment(\.offscreen, true)),
            to: "out/ui-style-thumbnails.png")

        // The same frame and style again: everything comes from the cache.
        thumbnails.refresh()
        _ = canvas(until: { thumbnails.passes >= 2 }, atMost: 30)
        check(
            "la même image redemandée ne redessine rien", thumbnails.lastDrawn == 0,
            String(
                format: "%d dessinées, %.0f ms", thumbnails.lastDrawn, (thumbnails.lastSeconds ?? 0) * 1000))

        // A rendering applied changes nothing the thumbnails show.
        let other = thumbnails.renderings.first { !session.current.uses(rendering: $0) }
        if let other { session.apply(other) }
        wait(0.8)
        check("appliquer un rendu ne redessine pas", thumbnails.passes == 2 && !thumbnails.drawing)
        // The saved style back, so the canvas costs what it did.
        session.cancel()
        wait(0.8)

        // Another palette: drawn again in it.
        var repainted = Frames()
        var repaintedAlone = Frames()
        var repaintedSeconds = 0.0
        if session.proposals.isEmpty { session.propose(waiting: true) }
        if let palette = session.proposals.first?.palette {
            let before = thumbnails.passes
            session.use(palette)
            repainted = canvas(until: { thumbnails.passes > before }, atMost: 120)
            repaintedSeconds = thumbnails.lastSeconds ?? 0
            repaintedAlone = canvas(until: { false }, atMost: 1)
            check(
                "une autre palette les redessine",
                thumbnails.passes > before && thumbnails.lastDrawn == count,
                String(format: "%.2f s", repaintedSeconds))
            keeps("pendant le dessin d'une palette", repainted, repaintedAlone)
        } else {
            lines.append("—    palette non essayée : \(session.proposalNote ?? "aucune proposition")")
        }

        // A small move of the playhead keeps them; past a tenth of the take, drawn again.
        let tenth = last / 10
        let kept = thumbnails.passes
        model.playbackPosition += tenth / 2
        _ = model.playbackSnapshot()
        wait(0.8)
        check("un petit déplacement les garde", thumbnails.passes == kept && !thumbnails.drawing)
        model.playbackPosition += tenth
        _ = model.playbackSnapshot()
        let moved = canvas(until: { thumbnails.passes > kept }, atMost: 120)
        let movedSeconds = thumbnails.lastSeconds ?? 0
        let movedAlone = canvas(until: { false }, atMost: 1)
        check(
            "au-delà d'un dixième de la prise, redessinées", thumbnails.passes > kept,
            String(format: "%.2f s, image %d", movedSeconds, thumbnails.frame ?? -1))
        keeps("pendant le redessin", moved, movedAlone)
        check("à l'image de la tête de lecture", thumbnails.frame == model.playheadCapturedFrame)

        // A canvas with no gap left: its own rendering already misses 60 Hz. The thumbnails
        // wait for it, so they take longer and it loses nothing.
        var crowded = Frames()
        var crowdedAlone = Frames()
        var crowdedSeconds = 0.0
        if let other, session.proposals.count > 1 {
            session.apply(other)
            crowdedAlone = canvas(until: { false }, atMost: 1)
            let before = thumbnails.passes
            session.use(session.proposals[1].palette)
            crowded = canvas(until: { thumbnails.passes > before }, atMost: 120)
            crowdedSeconds = thumbnails.lastSeconds ?? 0
            check(
                "le canvas sans marge, redessinées", thumbnails.passes > before,
                String(format: "%.2f s", crowdedSeconds))
            keeps("quand il n'a pas de marge", crowded, crowdedAlone)
        }

        // Leaving cancels and lets the engine go.
        thumbnails.close()
        check("fermer arrête le dessin", !thumbnails.drawing)

        let report =
            """
            prise            \(model.particleCount) particules, \(model.capturedFrames) images gardées, ouverte en \(String(format: "%.1f", openSeconds)) s
            clip             \(String(format: "%.3f", thumbnails.aspectRatio)) de rapport, vignettes de \(RenderingThumbnails.width) px
            premier dessin   \(String(format: "%.2f s", seconds)), canvas \(alone.summary) seul, \(during.summary) pendant
            autre palette    \(String(format: "%.2f s", repaintedSeconds)), canvas \(repaintedAlone.summary) seul, \(repainted.summary) pendant
            autre image      \(String(format: "%.2f s", movedSeconds)), canvas \(movedAlone.summary) seul, \(moved.summary) pendant
            canvas chargé    \(String(format: "%.2f s", crowdedSeconds)), canvas \(crowdedAlone.summary) seul, \(crowded.summary) pendant
            mémoire          \(footprintMegabytes()) Mo au plus
            """ + "\n" + lines.joined(separator: "\n")
        try? report.write(
            to: URL(fileURLWithPath: "/tmp/sillage-thumbcheck.log"), atomically: true, encoding: .utf8)
        print(report)
        exit(failed ? 1 : 0)
    }

    /// Canvas frames: wall and GPU milliseconds.
    struct Frames {
        var wall: [Double] = []
        var gpu: [Double] = []

        var lateShare: Double {
            wall.isEmpty ? 0 : Double(wall.filter { $0 > 1000.0 / 60 }.count) / Double(wall.count)
        }

        var summary: String {
            guard !wall.isEmpty else { return "sans image" }
            return String(
                format: "%.1f ms (GPU %.1f, %.0f %% > 16,7 ms)", ThumbnailCheck.median(wall),
                ThumbnailCheck.median(gpu), lateShare * 100)
        }
    }

    static func median(_ samples: [Double]) -> Double {
        let sorted = samples.sorted()
        return sorted.isEmpty ? .infinity : sorted[sorted.count / 2]
    }

    private static func pixels(_ image: CGImage) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: image.width * image.height * 4)
        out.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return out
    }

    private static func meanLuma(_ image: CGImage) -> Double {
        let p = pixels(image)
        var sum = 0.0
        for i in Swift.stride(from: 0, to: p.count, by: 4) {
            sum += 0.2126 * Double(p[i]) + 0.7152 * Double(p[i + 1]) + 0.0722 * Double(p[i + 2])
        }
        return sum / Double(max(p.count / 4, 1)) / 255
    }

    /// Coarse enough that two drawings of one rendering match, fine enough to tell two apart.
    private static func fingerprint(_ image: CGImage) -> [UInt8] {
        let p = pixels(image)
        return Swift.stride(from: 0, to: p.count, by: 4 * 97).map { (i: Int) -> UInt8 in
            let red: UInt8 = p[i] / 16
            let green: UInt8 = p[i + 1] / 16
            return red | (green << 4)
        }
    }

    private static func footprintMegabytes() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.ledger_phys_footprint_peak / 1_048_576) : -1
    }
}
