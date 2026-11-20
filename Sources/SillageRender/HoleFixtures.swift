import Foundation
import Metal
import SillageCore

/// The black hole close up's reference outputs (#336), in `Tests/Fixtures/hole`: a moment of a
/// small run, Metal's run a few steps on from it, and three stills of that, which the CUDA
/// engine has to give again. The README there gives the formats.
public enum HoleFixtures {
    public static let width = 256
    public static let height = 144
    /// The moment kept, in steps from the release, after the stream's first return, and the steps
    /// taken from it.
    public static let start = 6000
    public static let steps = 40

    /// A grid of 131,072 cells rather than the default's 2.4 million, so that the CPU target
    /// steps it in seconds and 4,000 tracers find neighbours in it.
    public static var gas: GasGrid {
        var gas = GasGrid()
        gas.radii = 64
        gas.angles = 128
        gas.heights = 16
        gas.heightCell = 1.0 / 32
        return gas
    }

    public static var scene: HoleSceneFile {
        var scene = TidalDisruption()
        scene.tracers = 4000
        scene.seed = 336
        return HoleSceneFile(name: "fixture", blackHole: scene)
    }

    /// The three views drawn: the physics look, the photon ring close with a thin disk's
    /// temperatures, and the hole drawn straight with its shadow. The exposure is the frame's own.
    public static var views: [(name: String, look: HoleLookFile)] {
        var physics = HoleLookFile(name: "physics")
        physics.exposureAt = nil
        physics.images = 3
        // 4,000 tracers each stand for 1,500 of a run's 6 million: a twentieth of the light
        // keeps their splats off the white.
        physics.exposure = 0.05
        // On the distance of a lens table, 1.1^45, so that one table is built, not two.
        physics.camera.distance = 72.8908
        var ring = physics
        ring.name = "ring"
        ring.temperature = .radius
        ring.thinning = 0
        ring.camera.distance = 19.1944
        ring.camera.elevation = 5
        var straight = physics
        straight.name = "straight"
        straight.lensed = false
        straight.camera.distance = 60.2404
        straight.camera.elevation = 12
        return [("physics", physics), ("ring", ring), ("straight", straight)]
    }

    /// A still of `frame` as `black-hole still` draws it, its exposure measured on the frame:
    /// 8-bit RGB, rows from the top.
    public static func still(_ frame: TidalFrame, look: HoleLookFile, device: MTLDevice) throws -> Data {
        let renderer = try HoleRenderer(settings: look.settings(width: width, height: height), device: device)
        renderer.upload(frame)
        let rgba = renderer.render(frame, camera: look.camera.camera(progress: 0), look: look.renderLook)
        var rgb = Data(capacity: width * height * 3)
        for pixel in 0..<(width * height) { rgb.append(contentsOf: rgba[(pixel * 4)..<(pixel * 4 + 3)]) }
        return rgb
    }

    /// The run's moments: the one kept, and Metal's `steps` steps on from it.
    public static func frames(device: MTLDevice) throws -> (start: TidalFrame, end: TidalFrame) {
        let run = try TidalRun(scene: scene.blackHole, gas: gas, device: device)
        run.step(start)
        let first = run.frame
        run.step(steps)
        return (first, run.frame)
    }

    public static func bytes(_ values: [SIMD4<Float>]) -> Data { values.withUnsafeBytes { Data($0) } }

    private struct Manifest: Encodable {
        struct View: Encodable {
            var look: String
            var file: String
        }

        var format = "sillage-hole-fixtures"
        var version = 1
        var byteOrder = "little"
        var source = "Metal, ./scripts/dev.sh fixtures"
        var device: String
        var system: String
        var scene = "scene.json"
        var tracers: Int
        var gas = HoleFixtures.gas
        var startStep = HoleFixtures.start
        var steps = HoleFixtures.steps
        var start = "start.bin"
        var end = "end.bin"
        var width = HoleFixtures.width
        var height = HoleFixtures.height
        var pixels = "rgb8"
        var rows = "top first"
        var views: [View]
    }

    public static func write(into directory: URL) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw RenderError.noDevice }
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        func put(_ data: Data, _ name: String) throws {
            try data.write(to: directory.appendingPathComponent(name))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try put(encoder.encode(scene), "scene.json")
        let (first, last) = try frames(device: device)
        try put(bytes(first.positions) + bytes(first.velocities), "start.bin")
        try put(bytes(last.positions) + bytes(last.velocities), "end.bin")
        var views: [Manifest.View] = []
        for (name, look) in Self.views {
            try put(look.encoded(), "\(name).hole.json")
            try put(still(last, look: look, device: device), "\(name).rgb")
            views.append(.init(look: "\(name).hole.json", file: "\(name).rgb"))
        }
        let system = ProcessInfo.processInfo.operatingSystemVersion
        try put(
            encoder.encode(
                Manifest(
                    device: device.name,
                    system: "macOS \(system.majorVersion).\(system.minorVersion).\(system.patchVersion)",
                    tracers: first.count, views: views)),
            "manifest.json")
    }
}
