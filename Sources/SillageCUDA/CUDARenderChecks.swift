import Foundation
import SillageCore
import SillageRender

#if canImport(simd)
    import simd
#endif

/// The CUDA renderer measured against itself (#276): the faint light through half floats and
/// through fixed point, and the time of the particle passes. Small on the CPU target, where the
/// tests only make sure they run; at 4K and up to 200 M drawn on a GPU, in #283.
public enum CUDARenderChecks {
    /// A merger drawn at `drawn` particles of which a quarter carry the mass, as a full pass
    /// holds it: the light tracers in the solver's layout, uploaded a chunk at a time, and the
    /// massive particles with the lengths and the spacing records of their tree. No solver:
    /// these are the sampler's starting positions.
    public struct Stage {
        public let renderer: CUDARenderer
        public let scene: SceneConfig
        public let drawn: Int
        public let tracers: Int
        public let seconds: Double

        public init(
            context: CUDAContext, drawn: Int, settings: RenderSettings, largeSplatCapacity: Int = 0,
            laceTexels: Int = DustWeb.laceTexels
        ) throws {
            let started = Date()
            var drawnScene = SceneConfig.merger(particleCount: max(drawn, 8))
            drawnScene.solver = .barnesHut
            var massiveScene = SceneConfig.merger(particleCount: max(drawn / 4, 4))
            massiveScene.solver = .barnesHut
            let room = ParticleSystem.lightTracerTotal(drawn: drawnScene, massive: massiveScene)
            let states = try context.makeBuffer(length: room * 16)
            let motions = try context.makeBuffer(length: room * 16)
            var uploaded = 0
            var failure: Error?
            let (massive, tracers) = ParticleSystem.streamingLightTracers(
                drawn: drawnScene, massive: massiveScene
            ) { chunk in
                guard failure == nil else { return }
                do {
                    try states.upload(chunk.states, at: uploaded * 16)
                    try motions.upload(chunk.motions, at: uploaded * 16)
                    uploaded += chunk.count
                } catch {
                    failure = error
                }
            }
            if let failure { throw failure }

            let renderer = try CUDARenderer(
                context: context, particles: massive, settings: settings,
                largeSplatCapacity: largeSplatCapacity, laceTexels: laceTexels)
            let visible = renderer.drawnCount
            let builder = try CUDATreeBuilder(
                context: context, count: massive.count, nodeCapacity: massive.count)
            var grown = 0
            repeat {
                if try builder.overflowed {
                    try builder.grow()
                    grown += 1
                }
                try builder.buildCells(positions: renderer.positions)
            } while try builder.overflowed && grown < 20
            let ratio = Float(tracers + visible) / Float(max(visible, 1))
            let lengths = try context.makeBuffer(length: massive.count * 4)
            try builder.buildSmoothing(into: lengths, drawn: visible, ratio: ratio)
            try builder.buildSpacing(drawn: visible, ratio: ratio)
            try renderer.setSmoothing(lengths)
            renderer.setTracers(
                CUDARenderer.Tracers(
                    states: states, motions: motions, count: tracers, cells: builder.spacing,
                    treeFrame: builder.frame, depth: builder.maximumDepth))
            renderer.setDiskFrames(
                DiskFrame.make(
                    scene: massiveScene, centers: massiveScene.galaxies.map(\.position), time: 0,
                    strength: 1))
            self.renderer = renderer
            scene = massiveScene
            self.drawn = tracers + visible
            self.tracers = tracers
            seconds = Date().timeIntervalSince(started)
        }

        /// The two kinds of shot #283 times: the whole encounter, where a splat covers a few
        /// pixels, and a disk close up, where some cover hundreds.
        public var shots: [(name: String, camera: Camera)] {
            let centre = scene.galaxies.first?.position ?? .zero
            return [
                ("wide", Camera.framing(radius: 80)),
                ("close", Camera.framing(radius: 6, center: centre, elevation: 0.9)),
            ]
        }
    }

    static func settings(width: Int, height: Int, web: Float) -> RenderSettings {
        var settings = RenderSettings(
            width: width, height: height, supersample: 2, brightness: 0.15, dustStrength: 0.3,
            starCount: 1_500)
        settings.dustWeb = web
        settings.glint = RenderLook.styleGlint
        return settings
    }

    private static func percentile(_ sorted: [Float], _ share: Double) -> Float {
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(Int(Double(sorted.count) * share), sorted.count - 1)]
    }

    /// The faint light of a frame at `drawn` particles, where each carries 1e6 / drawn of the
    /// light, accumulated as Metal's half float targets do and in fixed point: how much light
    /// each keeps, and how far apart they are on the pixels that hold little.
    public static func faintLight(
        drawn: Int, width: Int = 3840, height: Int = 2160, laceTexels: Int = DustWeb.laceTexels
    ) throws -> [String] {
        let context = try CUDAContext()
        let stage = try Stage(
            context: context, drawn: drawn, settings: settings(width: width, height: height, web: 1),
            laceTexels: laceTexels)
        var lines = [
            "faint light: \(stage.drawn) drawn (\(stage.tracers) tracers), \(width) x \(height) x 2"
        ]
        for shot in stage.shots {
            stage.renderer.halfFloats = false
            try stage.renderer.render(camera: shot.camera)
            let fixed = try stage.renderer.target(.light)
            stage.renderer.halfFloats = true
            try stage.renderer.render(camera: shot.camera)
            let halves = try stage.renderer.target(.light)
            stage.renderer.halfFloats = false

            var sums = (fixed: 0.0, halves: 0.0)
            var largest: Float = 0
            // By how bright the fixed point says a pixel is, from the faintest decade up.
            let edges: [Float] = [0, 1e-6, 1e-5, 1e-4, 1e-3, 1e-2, 1e-1, 1, .infinity]
            var kept = [(fixed: Double, halves: Double, pixels: Int)](
                repeating: (0, 0, 0), count: edges.count - 1)
            var relative: [Float] = []
            for pixel in stride(from: 0, to: fixed.count, by: 4) {
                let a = fixed[pixel] + fixed[pixel + 1] + fixed[pixel + 2]
                let b = halves[pixel] + halves[pixel + 1] + halves[pixel + 2]
                sums.fixed += Double(a)
                sums.halves += Double(b)
                largest = max(largest, fixed[pixel], fixed[pixel + 1], fixed[pixel + 2])
                guard a > 0 else { continue }
                let decade = edges.indices.dropLast().last { a >= edges[$0] } ?? 0
                kept[decade].fixed += Double(a)
                kept[decade].halves += Double(b)
                kept[decade].pixels += 1
                relative.append(abs(b - a) / a)
            }
            relative.sort()
            lines.append(
                "  \(shot.name): light \(sums.fixed) in fixed point, \(sums.halves) in half floats"
                    + " (\(sums.halves / max(sums.fixed, 1e-30))), largest value \(largest)")
            lines.append(
                "  \(shot.name): relative difference a lit pixel: median \(percentile(relative, 0.5)),"
                    + " 90 % \(percentile(relative, 0.9)), 99 % \(percentile(relative, 0.99)),"
                    + " largest \(relative.last ?? 0)")
            for (index, decade) in kept.enumerated() where decade.pixels > 0 {
                lines.append(
                    "  \(shot.name): pixels from \(edges[index]) to \(edges[index + 1]): \(decade.pixels),"
                        + " half floats keep \(decade.halves / max(decade.fixed, 1e-30)) of their light")
            }
        }
        return lines
    }

    /// The time of the particle passes of a frame at `drawn` particles, wide and close, the
    /// first way and the second way for large splats, against the line Metal's follow at 4K on
    /// the M4 Max: 40 ms + 7.6 ns a particle (#239).
    public static func timings(
        drawn: Int, width: Int = 3840, height: Int = 2160, repeats: Int = 5,
        largeSplatPixels: Int = 256, laceTexels: Int = DustWeb.laceTexels
    ) throws -> [String] {
        let context = try CUDAContext()
        let stage = try Stage(
            context: context, drawn: drawn, settings: settings(width: width, height: height, web: 1),
            largeSplatCapacity: max(drawn / 8, 1_024), laceTexels: laceTexels)
        let metal = 40 + 7.6e-6 * Double(stage.drawn)
        var lines = [
            "timings: \(stage.drawn) drawn (\(stage.tracers) tracers), \(width) x \(height) x 2,"
                + " sampled and uploaded in \(stage.seconds) s; Metal's line gives \(metal) ms"
        ]
        for shot in stage.shots {
            for (way, pixels) in [("first way", 0), ("second way", largeSplatPixels)] {
                stage.renderer.largeSplatPixels = pixels
                // Once for the lace and the first touch of the targets, then the timed frames.
                try stage.renderer.render(camera: shot.camera)
                try context.synchronize()
                var times: [Double] = []
                for _ in 0..<max(repeats, 1) {
                    let started = Date()
                    try stage.renderer.render(camera: shot.camera)
                    try context.synchronize()
                    times.append(Date().timeIntervalSince(started) * 1000)
                }
                times.sort()
                let aside =
                    pixels > 0
                    ? ", \(stage.renderer.largeSplatCount) splats set aside in the last pass" : ""
                lines.append(
                    "  \(shot.name), \(way): median \(times[times.count / 2]) ms, fastest \(times[0]) ms"
                        + aside)
            }
        }
        stage.renderer.largeSplatPixels = 0
        return lines
    }
}
