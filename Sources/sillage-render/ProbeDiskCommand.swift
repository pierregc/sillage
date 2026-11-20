import CoreGraphics
import Foundation
import SillageCore
import SillageRender
import simd

/// One galaxy of a scene, alone, measured as it settles (#169). See docs/notes/calm-disk-probe.md.
func probeDiskCommand(_ arguments: [String]) -> Int32 {
    let usage =
        "usage: sillage-render probe-disk <scene.json | scene folder> <galaxy index> [--particles N]"
        + " [--myr T] [--frame-myr T] [--seed S] [--out DIR] [--width W] [--height H] [--no-clip]"
        + " [--painted] [--lag-myr T] [--stills 0,300,...] [--dt-scale X] [--softening KPC]"
        + " [--clumpiness X] [--toomre-q X] [--arm-strength X] [--arm-count N]"
        + " [--arm-irregularity X] [--disk-mass-fraction X] [--disk-thickness KPC] [--dissipation T]"
        + " [--mass-contrast X] [--streaming X] [--young-clumpiness X] [--dust-fraction X]"
        + " [--dust-mass X] [--effective-q X] [--calm] [--sf-leaves FILE]"
    guard arguments.count >= 2, !arguments[0].hasPrefix("--"), let galaxy = Int(arguments[1]) else {
        fail(usage)
    }
    var options = DiskProbe.Options(scene: arguments[0], galaxy: galaxy)
    let rest = Array(arguments.dropFirst(2))
    func value(_ name: String) -> String? {
        guard let index = rest.firstIndex(of: "--\(name)"), index + 1 < rest.count else { return nil }
        return rest[index + 1]
    }
    func float(_ name: String) -> Float? { value(name).flatMap(Float.init) }
    for word in rest where word.hasPrefix("--") {
        let known = [
            "particles", "myr", "frame-myr", "seed", "out", "width", "height", "no-clip", "painted",
            "lag-myr", "stills", "dt-scale", "clumpiness", "toomre-q", "arm-strength", "arm-count",
            "arm-irregularity", "disk-mass-fraction", "disk-thickness", "dissipation", "mass-contrast",
            "streaming", "young-clumpiness", "dust-fraction", "dust-mass", "calm", "softening",
            "effective-q", "sf-leaves",
        ]
        guard known.contains(String(word.dropFirst(2))) else {
            fail("probe-disk: unknown option \(word)\n" + usage)
        }
    }
    options.particles = value("particles").flatMap(Int.init)
    if let myr = value("myr").flatMap(Double.init) { options.durationMyr = myr }
    if let myr = value("frame-myr").flatMap(Double.init) { options.frameMyr = myr }
    options.seed = value("seed").flatMap(UInt64.init)
    options.output = value("out")
    if let width = value("width").flatMap(Int.init) { options.width = width }
    if let height = value("height").flatMap(Int.init) { options.height = height }
    options.clip = !rest.contains("--no-clip")
    options.painted = rest.contains("--painted")
    if let lag = value("lag-myr").flatMap(Double.init) { options.lagMyr = lag }
    options.stillsMyr = value("stills")?.split(separator: ",").compactMap { Double($0) } ?? []
    options.timeStepScale = float("dt-scale")
    options.softening = float("softening")
    options.clumpiness = float("clumpiness")
    options.toomreQ = float("toomre-q")
    options.effectiveToomreQ = float("effective-q")
    options.armStrength = float("arm-strength")
    options.armCount = value("arm-count").flatMap(Int.init)
    options.armIrregularity = float("arm-irregularity")
    options.diskMassFraction = float("disk-mass-fraction")
    options.diskThickness = float("disk-thickness")
    options.dissipationTime = float("dissipation")
    options.armMassContrast = float("mass-contrast")
    options.armStreaming = float("streaming")
    options.youngClumpiness = float("young-clumpiness")
    options.dustFraction = float("dust-fraction")
    options.dustMassFraction = float("dust-mass")
    options.calm = rest.contains("--calm")
    options.formationLeaves = value("sf-leaves")
    do {
        let report = try DiskProbe.run(options)
        let summary = report.summary
        print(
            String(
                format: "probe      %d steps in %.0f s (%.1f ms a step), r50 %.2f -> %.2f kpc, "
                    + "first excursion %.1f %% at %.0f Myr, settled from %.0f Myr",
                report.steps, report.seconds, report.millisecondsPerStep, summary.medianStartKpc,
                summary.medianEndKpc, summary.firstExcursion * 100, summary.firstExcursionMyr,
                summary.settledMyr))
        print(
            String(
                format: "           sigma_R/v_c %.3f -> %.3f (300 Myr) -> %.3f, a2 peak %.3f at %.0f Myr, "
                    + "late a2 %.3f a1 %.3f, lumpiness %.3f -> %.3f, coherence pattern %.2f "
                    + "material %.2f static %.2f",
                summary.sigmaRatioStart, summary.sigmaRatio300, summary.sigmaRatioEnd,
                summary.amplitude2Peak, summary.amplitude2PeakMyr, summary.amplitude2Late,
                summary.amplitude1Late, summary.lumpinessStart, summary.lumpinessLate,
                summary.coherencePatternLate, summary.coherenceMaterialLate,
                summary.coherenceStaticLate))
        print(
            String(
                format: "           axis tilt up to %.2f deg, nucleus jitter %.3f kpc a frame, solver centre "
                    + "%.3f, offset %.2f kpc, outer offset %.3f h",
                summary.axisTiltMaxDeg, summary.nucleusJitterKpc, summary.solverCentreJitterKpc,
                summary.centreOffsetLateKpc, summary.outerOffsetLate))
        print(
            String(
                format: "           bound knots %.1f %% of the disk at most within %.0f Myr, %.1f %% late, "
                    + "first from %.0f Myr",
                summary.knotShareClip * 100, DiskProbe.KnotTracker.clipMyr, summary.knotShareLate * 100,
                summary.firstKnotMyr))
        if let clip = report.clip { print("clip       \(clip)") }
        return 0
    } catch {
        fail("probe-disk: \(error)")
    }
}
