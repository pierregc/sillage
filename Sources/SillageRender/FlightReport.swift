import Foundation
import SillageCore

#if canImport(simd)
    import simd
#endif

/// `flight <scene folder> --at <myr,...> [--look <name>] [--take <file>] [--arms <kpc,...>]`
/// (#295, #297, #467): what a flight's keys are written from, at each moment: every galaxy's
/// centre and disk axes as the take holds them, where each disk is densest at the radii asked,
/// and the camera the export draws there, as a key ready to paste. Reads the take on the CPU,
/// for either engine.
public enum FlightReport {
    public static let usage =
        "usage: flight <scene folder> --at <myr,...> [--look <name>] [--take <file>]"
        + " [--arms <kpc,...>]"

    public enum Failure: Error, CustomStringConvertible {
        case usage
        public var description: String { FlightReport.usage }
    }

    public static func lines(_ arguments: [String], catalogue: [LookFile]) throws -> [String] {
        guard let path = arguments.first, !path.hasPrefix("--") else { throw Failure.usage }
        func option(_ name: String) -> String? {
            arguments.firstIndex(of: "--\(name)").flatMap {
                $0 + 1 < arguments.count ? arguments[$0 + 1] : nil
            }
        }
        let times = option("at")?.split(separator: ",").compactMap { Double($0) } ?? []
        guard !times.isEmpty else { throw Failure.usage }
        let folder = SceneFolder(path: path)
        let loaded = try RecordingFile.read(
            from: option("take").map { URL(fileURLWithPath: $0) } ?? folder.take)
        let look = try folder.exportLook(option("look"), catalogue: catalogue)
        let rate = try folder.capturedRate()
        let take = FlightTake(take: loaded, capturedRate: rate)
        let replay = TakeFraming.replay(
            look: look, framing: loaded, capturedRate: rate, width: 1920, height: 1080)
        var lines = [
            String(
                format: "take       %.1f to %.1f Myr, %d galaxies; look %@ (%@ camera)",
                take.megayears.first ?? 0, take.megayears.last ?? 0, take.galaxies, look.name,
                look.camera.mode.rawValue)
        ]
        func text(_ v: SIMD3<Double>) -> String { String(format: "[%.2f, %.2f, %.2f]", v.x, v.y, v.z) }
        func text(_ v: SIMD3<Float>) -> String { text(SIMD3<Double>(Double(v.x), Double(v.y), Double(v.z))) }
        let radii = option("arms")?.split(separator: ",").compactMap { Double($0) } ?? []
        for myr in times.sorted() {
            let position = try TimeTrack.position(of: myr, in: take.megayears)
            lines.append(String(format: "\n%.1f Myr   captured frame %.2f", myr, position))
            let centres = take.centres(position)
            let disks = take.disks(position)
            let arms =
                try radii.isEmpty
                ? nil : densest(loaded, atCaptured: position, centres: centres, disks: disks, radii: radii)
            for (galaxy, (centre, axes)) in zip(centres, disks).enumerated() {
                lines.append(
                    "galaxy \(galaxy)   centre \(text(centre))  disk x \(text(axes[0])) y \(text(axes[1])) spin \(text(axes[2]))"
                )
                for arm in arms?[galaxy] ?? [] {
                    lines.append(
                        String(
                            format:
                                "  densest at %.1f kpc   {\"galaxy\": %d, \"offset\": %@, \"disk\": true}, %.1f times the ring's mean",
                            simd_length(arm.offset), galaxy, text(arm.offset), arm.contrast))
                }
            }
            let camera = replay.shot(atCaptured: position).camera
            lines.append(
                String(
                    format: "look       {\"eye\": %@, \"aim\": %@, \"fov\": %.3f}, %.1f kpc from its aim",
                    text(camera.eye), text(camera.target), camera.fieldOfView,
                    simd_length(camera.eye - camera.target)))
        }
        return lines
    }

    /// Where each disk is densest at each of `radii`, in its own plane: the light emitting
    /// particles within 0.3 kpc of the plane and 8% of the radius, counted in 120 sectors and
    /// smoothed over three, an arm rather than a clump of a few particles.
    public static func densest(
        _ take: RecordingFile.Loaded, atCaptured position: Double, centres: [SIMD3<Double>],
        disks: [[SIMD3<Double>]], radii: [Double]
    ) throws -> [[(offset: SIMD3<Double>, contrast: Double)]] {
        guard let blend = take.recording.blend(atCaptured: position) else {
            throw RecordingFile.Failure.truncated
        }
        let points = take.recording.positions(at: blend)
        guard !points.isEmpty else { throw RecordingFile.Failure.truncated }
        let particles = take.particles
        let drawn = min(particles.visibleCount > 0 ? particles.visibleCount : particles.count, points.count)
        let sectors = 120
        var counts = [[[Double]]](
            repeating: [[Double]](repeating: [Double](repeating: 0, count: sectors), count: radii.count),
            count: centres.count)
        for index in 0..<drawn {
            guard let component = ParticleComponent(rawValue: particles.component[index]), component.emits
            else { continue }
            let galaxy = Int(particles.galaxyIndex[index])
            guard galaxy < centres.count, galaxy < disks.count else { continue }
            let p = points[index]
            let rel = SIMD3(Double(p.x), Double(p.y), Double(p.z)) - centres[galaxy]
            let axes = disks[galaxy]
            guard abs(simd_dot(rel, axes[2])) < 0.3 else { continue }
            let (u, v) = (simd_dot(rel, axes[0]), simd_dot(rel, axes[1]))
            let radius = (u * u + v * v).squareRoot()
            for (ring, wanted) in radii.enumerated() where abs(radius - wanted) < 0.08 * wanted {
                let turn = (atan2(v, u) / (2 * .pi) + 1).truncatingRemainder(dividingBy: 1)
                counts[galaxy][ring][min(Int(turn * Double(sectors)), sectors - 1)] += 1
            }
        }
        return counts.map { rings in
            zip(radii, rings).map { radius, ring in
                let smooth = (0..<sectors).map { at in
                    (-1...1).reduce(0.0) { $0 + ring[(at + $1 + sectors) % sectors] } / 3
                }
                let mean = max(ring.reduce(0, +) / Double(sectors), 1e-9)
                let best = smooth.indices.max { smooth[$0] < smooth[$1] } ?? 0
                let angle = (Double(best) + 0.5) / Double(sectors) * 2 * .pi
                return (SIMD3(radius * cos(angle), radius * sin(angle), 0), smooth[best] / mean)
            }
        }
    }
}
