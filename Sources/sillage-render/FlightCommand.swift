import CoreGraphics
import Foundation
import SillageCore
import SillageRender
import simd

/// `story <scene folder | batch folder>`: the story judged again on curves already written,
/// one line a scene: the first collision, and where the story starts and ends or what still goes
/// on when the curves stop.
/// `flight <scene folder> --at <myr,...> [--look <name>] [--take <file>]` (#295): what a flight's
/// keys are written from, at each moment: every galaxy's centre and disk axes as the take holds
/// them, and the camera the export draws there, as a key ready to paste.
func flightCommand(_ arguments: [String]) -> Int32 {
    let usage =
        "usage: sillage-render flight <scene folder> --at <myr,...> [--look <name>] [--take <file>]"
        + " [--arms <kpc,...>]"
    guard let path = arguments.first, !path.hasPrefix("--") else { fail(usage) }
    func option(_ name: String) -> String? {
        arguments.firstIndex(of: "--\(name)").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
    }
    let times = option("at")?.split(separator: ",").compactMap { Double($0) } ?? []
    guard !times.isEmpty else { fail(usage) }
    let folder = SceneFolder(path: path)
    do {
        let loaded = try RecordingFile.read(
            from: option("take").map { URL(fileURLWithPath: $0) } ?? folder.take)
        let look = try folder.exportLook(option("look"), catalogue: catalogueLooks())
        let rate = try folder.capturedRate()
        let take = FlightTake(take: loaded, capturedRate: rate)
        let replay = TakeFraming.replay(
            look: look, framing: loaded, capturedRate: rate, width: 1920, height: 1080)
        print(
            String(
                format: "take       %.1f to %.1f Myr, %d galaxies; look %@ (%@ camera)",
                take.megayears.first ?? 0, take.megayears.last ?? 0, take.galaxies, look.name,
                look.camera.mode.rawValue))
        func text(_ v: SIMD3<Double>) -> String { String(format: "[%.2f, %.2f, %.2f]", v.x, v.y, v.z) }
        func text(_ v: SIMD3<Float>) -> String { text(SIMD3<Double>(Double(v.x), Double(v.y), Double(v.z))) }
        // `--arms <kpc,...>` (#297): where each disk is densest at those radii, a place to fly into.
        let radii = option("arms")?.split(separator: ",").compactMap { Double($0) } ?? []
        let export = try radii.isEmpty ? nil : TakeExport(take: loaded, look: look, capturedRate: rate)
        for myr in times.sorted() {
            let position = try TimeTrack.position(of: myr, in: take.megayears)
            print(String(format: "\n%.1f Myr   captured frame %.2f", myr, position))
            let arms = try export?.densest(atCaptured: position, radii: radii)
            for (galaxy, (centre, axes)) in zip(take.centres(position), take.disks(position)).enumerated() {
                print(
                    "galaxy \(galaxy)   centre \(text(centre))  disk x \(text(axes[0])) y \(text(axes[1])) spin \(text(axes[2]))"
                )
                for arm in arms?[galaxy] ?? [] {
                    print(
                        String(
                            format:
                                "  densest at %.1f kpc   {\"galaxy\": %d, \"offset\": %@, \"disk\": true}, %.1f times the ring's mean",
                            simd_length(arm.offset), galaxy, text(arm.offset), arm.contrast))
                }
            }
            let camera = replay.shot(atCaptured: position).camera
            print(
                String(
                    format: "look       {\"eye\": %@, \"aim\": %@, \"fov\": %.3f}, %.1f kpc from its aim",
                    text(camera.eye), text(camera.target), camera.fieldOfView,
                    simd_length(camera.eye - camera.target)))
        }
    } catch {
        fail("flight: \(error)")
    }
    return 0
}
