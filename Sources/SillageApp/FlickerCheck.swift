import AppKit
import Foundation
import SillageCore
import SillageRender

/// Is anything in the picture different from one frame to the next when nothing has moved?
///
/// With the playhead held still and the camera untouched, two consecutive frames should be
/// identical to the bit. Anything that is not is a scintillation, and this says how much of
/// it each suspect accounts for by turning them off one at a time.
enum FlickerCheck {
    @MainActor
    static func run() {
        guard let flag = CommandLine.arguments.firstIndex(of: "--flicker"),
            flag + 1 < CommandLine.arguments.count
        else { return }
        guard let model = SimulationModel() else { exit(1) }
        model.openTake(from: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
        let deadline = Date().addingTimeInterval(600)
        while model.mode != .playback || model.capturedFrames < 2 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            if let failure = model.failure {
                FileHandle.standardError.write(Data("flicker: \(failure)\n".utf8))
                exit(1)
            }
            if Date() > deadline { exit(1) }
        }
        model.resize(to: CGSize(width: 1280, height: 800))
        // Nothing advances: the playhead is parked and the camera is not being flown, so
        // every difference measured below is the renderer disagreeing with itself.
        model.isPlaying = false
        // Somewhere with disk in it rather than the very first frame.
        model.playbackPosition = Double(model.capturedFrames / 3)

        /// Root-mean-square difference between consecutive frames, in 8-bit levels, and the
        /// worst single channel. Six frames, so a two-frame cycle cannot hide in it.
        func scintillation() -> (rms: Double, worst: Int, lit: Double) {
            var previous: [UInt8] = []
            var total = 0.0
            var samples = 0
            var worst = 0
            var lit = 0.0
            for _ in 0..<6 {
                guard let pixels = model.playbackSnapshot() else { return (0, 0, 0) }
                if !previous.isEmpty {
                    var sum = 0.0
                    var count = 0
                    for index in stride(from: 0, to: pixels.count, by: 4) {
                        for channel in 0..<3 {
                            let delta = Int(pixels[index + channel]) - Int(previous[index + channel])
                            sum += Double(delta * delta)
                            worst = max(worst, abs(delta))
                            count += 1
                        }
                    }
                    total += (sum / Double(count)).squareRoot()
                    samples += 1
                }
                lit =
                    Double(
                        pixels.enumerated().filter { $0.offset % 4 != 3 && $0.element > 8 }.count)
                    / Double(pixels.count / 4 * 3) * 100
                previous = pixels
            }
            return (samples == 0 ? 0 : total / Double(samples), worst, lit)
        }

        var lines: [String] = []
        func measure(_ name: String) {
            let (rms, worst, lit) = scintillation()
            lines.append(
                String(
                    format: "%@ rms %6.3f niveaux, pire écart %3d, %.1f %% de pixels allumés",
                    name.padding(toLength: 34, withPad: " ", startingAt: 0), rms, worst, lit))
        }

        let look = model.look
        measure("tel quel")
        let noise = model.look.noiseLevel
        model.look.noiseLevel = 0
        measure("sans bruit de détecteur")
        model.look.noiseLevel = noise
        model.look.skyLevel = 0
        measure("sans fond de ciel (bruit remis)")
        model.look.noiseLevel = 0
        measure("sans bruit ni fond de ciel")

        // Second question, and the one a frozen playhead cannot answer: a star crossing a
        // pixel boundary is a scintillation too, and no amount of turning the detector noise
        // down touches it. Played very slowly, real motion moves a pixel by very little; what
        // is left over is aliasing, and a wider kernel is the only thing that reaches it.
        model.look = look
        model.look.noiseLevel = 0
        model.isPlaying = true
        model.playbackSpeed = 0.5
        lines.append("")
        lines.append("en lecture à 0,5 image de prise par seconde, sans bruit :")
        for floor in [Float(1.1), 1.6, 2.4, 3.5] {
            model.look.minimumKernel = floor
            model.playbackPosition = Double(model.capturedFrames / 3)
            let (rms, worst, _) = scintillation()
            lines.append(
                String(
                    format: "  noyau minimal %.1f px   rms %6.3f niveaux, pire écart %3d", floor,
                    rms, worst))
        }

        let report = lines.joined(separator: "\n")
        try? report.write(
            to: URL(fileURLWithPath: "/tmp/sillage-flicker.log"), atomically: true, encoding: .utf8)
        print(report)
        exit(0)
    }
}
