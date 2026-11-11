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

// MARK: - Against Metal's targets

/// The CUDA renderer against the targets Metal left (#276): the folder `sillage-render export
/// --dump-targets` fills on the Mac holds, for chosen frames of a take and a few looks, the
/// light and the dust before any post-processing with the buffers and uniforms they were drawn
/// from, byte for byte. The same frames are drawn here from those very bytes and compared.
extension CUDARenderChecks {
    public enum Failure: Error, CustomStringConvertible {
        case folder(String)

        public var description: String {
            switch self {
            case .folder(let message): message
            }
        }
    }

    /// How far two targets are apart, over the pixels where either holds something.
    public struct Difference {
        public var lit = 0
        /// The sum of mine over the sum of theirs.
        public var total = 1.0
        public var median: Float = 0
        public var ninety: Float = 0
        public var ninetyNine: Float = 0
        public var largest: Float = 0
        /// The relative difference a pixel, rows from the top, zero where neither holds anything.
        public var map: [Float] = []
        /// Lit pixels and their median relative difference, by the decade of their value.
        public var decades: [(from: Float, pixels: Int, median: Float, ninetyNine: Float)] = []

        var summary: String {
            "\(lit) pixels, total \(total), relative difference: median \(median), 90 % \(ninety),"
                + " 99 % \(ninetyNine), largest \(largest)"
        }
    }

    /// One target of the Mac drawn here.
    public struct Comparison {
        public var look: String
        public var frame: String
        public var shot: String
        public var width: Int
        public var height: Int
        /// The light in fixed point against Metal's, then accumulated in half floats as Metal
        /// blends them, one thread in Metal's order.
        public var light = Difference()
        public var halfLight = Difference()
        public var coverage = Difference()
        public var dust: Difference?
        public var halfDust: Difference?
        public var lines: [String] = []
        public var metalLight: [Float] = []
        public var cudaLight: [Float] = []
    }

    static func float(half bits: UInt16) -> Float {
        let sign = UInt32(bits & 0x8000) << 16
        let exponent = UInt32(bits >> 10) & 0x1F
        let mantissa = UInt32(bits & 0x3FF)
        if exponent == 0 {
            let small = Float(mantissa) * 5.9604645e-8
            return sign != 0 ? -small : small
        }
        if exponent == 31 { return Float(bitPattern: sign | 0x7F80_0000 | (mantissa << 13)) }
        return Float(bitPattern: sign | ((exponent + 112) << 23) | (mantissa << 13))
    }

    private static func data(_ entry: RenderTargetManifest.Entry, in folder: URL) throws -> Data {
        let data = try Data(contentsOf: folder.appendingPathComponent(entry.file))
        guard data.count == entry.count * entry.stride else {
            throw Failure.folder(
                "\(entry.file): \(data.count) bytes, not \(entry.count) of \(entry.stride)")
        }
        return data
    }

    private static func values<T>(
        _ entry: RenderTargetManifest.Entry, in folder: URL, as type: T.Type
    ) throws -> [T] {
        let data = try data(entry, in: folder)
        guard entry.stride == MemoryLayout<T>.stride else {
            throw Failure.folder(
                "\(entry.file): \(entry.stride) bytes a value, not \(MemoryLayout<T>.stride)")
        }
        return data.withUnsafeBytes { Array($0.bindMemory(to: T.self)) }
    }

    /// A half float target as floats.
    private static func halves(
        _ entry: RenderTargetManifest.Entry, in folder: URL
    ) throws -> [Float] {
        let data = try data(entry, in: folder)
        return data.withUnsafeBytes { $0.bindMemory(to: UInt16.self).map { float(half: $0) } }
    }

    /// The relative difference of two targets a pixel, `|mine - theirs| / max(mine, theirs)` of
    /// the sum of `channels`, over the pixels where that maximum passes `floor`.
    static func difference(
        _ mine: [Float], _ theirs: [Float], channels: Range<Int>, of stride: Int = 4,
        floor: Float = 0
    ) -> Difference {
        var result = Difference()
        let pixels = min(mine.count, theirs.count) / stride
        result.map = [Float](repeating: 0, count: pixels)
        var relative: [(value: Float, difference: Float)] = []
        var sums = (mine: 0.0, theirs: 0.0)
        for pixel in 0..<pixels {
            var a: Float = 0
            var b: Float = 0
            for channel in channels {
                a += mine[pixel * stride + channel]
                b += theirs[pixel * stride + channel]
            }
            sums.mine += Double(a)
            sums.theirs += Double(b)
            let larger = max(a, b)
            guard larger > floor else { continue }
            let difference = abs(a - b) / larger
            result.map[pixel] = difference
            relative.append((b, difference))
        }
        result.lit = relative.count
        result.total = sums.theirs > 0 ? sums.mine / sums.theirs : (sums.mine > 0 ? .infinity : 1)
        func percentiles(_ values: [Float]) -> (Float, Float, Float, Float) {
            let sorted = values.sorted()
            return (
                percentile(sorted, 0.5), percentile(sorted, 0.9), percentile(sorted, 0.99),
                sorted.last ?? 0
            )
        }
        (result.median, result.ninety, result.ninetyNine, result.largest) = percentiles(
            relative.map(\.difference))
        // By what Metal holds there: nothing, then a decade at a time.
        let edges: [Float] = [
            -.infinity, 1e-7, 1e-6, 1e-5, 1e-4, 1e-3, 1e-2, 1e-1, 1, 10, 100, 1_000, .infinity,
        ]
        for index in edges.indices.dropLast() {
            let inside = relative.filter { $0.value > edges[index] && $0.value <= edges[index + 1] }
            guard !inside.isEmpty else { continue }
            let (median, _, ninetyNine, _) = percentiles(inside.map(\.difference))
            result.decades.append((edges[index], inside.count, median, ninetyNine))
        }
        return result
    }

    /// Draws every target the manifest of `folder` lists, or those of `looks`, from the bytes
    /// Metal drew them from, and compares. `maps` takes the relative differences of the light
    /// and the two lights, as raw floats with a JSON index, for the pictures.
    public static func compare(
        folder: URL, looks: Set<String>? = nil, maps: URL? = nil,
        threads: Int = ProcessInfo.processInfo.activeProcessorCount,
        laceTexels: Int = DustWeb.laceTexels
    ) throws -> [Comparison] {
        guard let manifest = RenderTargetManifest.read(from: folder),
            manifest.format == "sillage-render-targets", manifest.version == 1
        else { throw Failure.folder("\(folder.path): no manifest of sillage-render-targets 1") }
        let context = try CUDAContext()
        var comparisons: [Comparison] = []
        var renderers: [String: CUDARenderer] = [:]
        var index: [[String: String]] = []
        if let maps {
            try FileManager.default.createDirectory(at: maps, withIntermediateDirectories: true)
        }

        for target in manifest.targets where looks?.contains(target.look) ?? true {
            guard let frame = manifest.frames.first(where: { $0.name == target.frame }) else {
                throw Failure.folder("no frame \(target.frame) for \(target.look)")
            }
            func entry(_ name: String) throws -> RenderTargetManifest.Entry {
                guard let entry = target.files[name] ?? frame.files[name] ?? manifest.particles[name]
                else { throw Failure.folder("\(target.look) \(target.frame): no \(name)") }
                return entry
            }
            let scale = target.supersample
            var settings = RenderSettings(
                width: manifest.width, height: manifest.height, supersample: scale,
                starCount: target.starCount, plain: target.plain)
            settings.dustWeb = target.dustWeb
            settings.columnSmoothing = target.columnSmoothing
            settings.holeShadow = target.holeShadow

            // A renderer a look: its lace is baked once. The attributes are Metal's own bytes.
            let renderer: CUDARenderer
            if let made = renderers[target.look] {
                renderer = made
            } else {
                var attributes = ParticleAttributes(ParticleSystem())
                attributes.count = target.drawn
                attributes.drawnCount = target.drawn
                attributes.component = try values(entry("component"), in: folder, as: UInt32.self)
                attributes.galaxy = try values(entry("galaxy"), in: folder, as: UInt32.self)
                func floats(_ name: String, _ fallback: Float) throws -> [Float] {
                    target.plain
                        ? [Float](repeating: fallback, count: target.drawn)
                        : try values(entry(name), in: folder, as: Float.self)
                }
                attributes.population = try floats("population", 0.5)
                attributes.formation = try floats("formation", ParticleSystem.ancient)
                attributes.luminosity = try floats("luminosity", 1)
                attributes.rampKeys = try floats("rampKeys", 1.7)
                attributes.traits =
                    target.plain
                    ? [SIMD2<Float>](repeating: SIMD2(1, 1), count: target.drawn)
                    : try values(entry("traits"), in: folder, as: SIMD2<Float>.self)
                attributes.galaxySlots = target.galaxySlots
                attributes.luminosityNormalisation = target.luminosityNormalisation
                renderer = try CUDARenderer(
                    context: context, attributes: attributes, settings: settings,
                    laceTexels: laceTexels)
                if !target.plain {
                    try renderer.setStellar(values(entry("stellar"), in: folder, as: SIMD2<Float>.self))
                }
                renderers[target.look] = renderer
            }

            try renderer.upload(
                positions: values(entry("positions"), in: folder, as: SIMD3<Float>.self))
            renderer.setDiskFrames(try values(entry("disk-frames"), in: folder, as: DiskFrame.self))
            if !target.plain {
                let lengths = try context.makeBuffer(
                    values(entry("smoothing"), in: folder, as: Float.self))
                try renderer.setSmoothing(lengths)
                renderer.setRamps(try values(entry("ramps"), in: folder, as: GalaxyRamp.self))
                if target.starCount > 0 {
                    try renderer.setStarfield(
                        values(entry("starfield"), in: folder, as: BackgroundStar.self))
                }
            }

            // The plan's passes from what the frame draws, its uniforms Metal's own bytes.
            let camera = Camera(
                eye: SIMD3(target.camera.eye[0], target.camera.eye[1], target.camera.eye[2]),
                target: SIMD3(target.camera.target[0], target.camera.target[1], target.camera.target[2]),
                up: SIMD3(target.camera.up[0], target.camera.up[1], target.camera.up[2]),
                fieldOfView: target.camera.fieldOfView, near: target.camera.near,
                far: target.camera.far)
            let webbed = target.files["web-uniforms"] != nil
            var plan = FramePlan(
                settings: settings, camera: camera, time: target.time, drawnCount: target.drawn,
                tracerCount: 0, luminosityNormalisation: target.luminosityNormalisation,
                mapped: target.mapped, laceScale: webbed ? 1 / max(target.laceMean ?? 1, 1e-6) : nil)
            let uniforms = try data(entry("splat-uniforms"), in: folder)
            plan.splat = uniforms.withUnsafeBytes { $0.loadUnaligned(as: SplatUniforms.self) }
            plan.splat.pass = 0
            if webbed {
                plan.web = try data(entry("web-uniforms"), in: folder).withUnsafeBytes {
                    $0.loadUnaligned(as: WebUniforms.self)
                }
            }

            renderer.halfFloats = false
            try renderer.draw(plan, threads: threads)
            try renderer.finish()
            let light = try renderer.target(.light)
            let dust = target.plain ? nil : try renderer.target(.dust)
            let column = target.columnSmoothing > 0 ? try renderer.target(.column) : nil
            let carrier = webbed ? try renderer.target(.carrier) : nil
            let tags = webbed ? try renderer.target(.tags) : nil
            // As Metal blends: half floats, one thread, the particles in their order.
            renderer.halfFloats = true
            try renderer.draw(plan, threads: 1)
            try renderer.finish()
            let halfLight = try renderer.target(.light)
            let halfDust = target.plain ? nil : try renderer.target(.dust)
            renderer.halfFloats = false

            let metalLight = try halves(entry("light"), in: folder)
            let (width, height) = (manifest.width * scale, manifest.height * scale)
            var comparison = Comparison(
                look: target.look, frame: target.frame, shot: target.shot ?? "", width: width,
                height: height)
            comparison.metalLight = metalLight
            comparison.cudaLight = light
            comparison.light = difference(light, metalLight, channels: 0..<3)
            comparison.halfLight = difference(halfLight, metalLight, channels: 0..<3)
            comparison.coverage = difference(light, metalLight, channels: 3..<4)
            let name = "\(target.look) \(target.frame)"
            comparison.lines.append(
                "\(name) (\(target.shot ?? "no shot"), \(width) x \(height), \(target.drawn) drawn,"
                    + " largest light Metal \(metalLight.max() ?? 0), CUDA \(light.max() ?? 0))")
            comparison.lines.append("  light, fixed point: \(comparison.light.summary)")
            comparison.lines.append("  light, half floats: \(comparison.halfLight.summary)")
            comparison.lines.append("  coverage: \(comparison.coverage.summary)")
            for decade in comparison.light.decades {
                comparison.lines.append(
                    "  light where Metal holds over \(decade.from): \(decade.pixels) pixels,"
                        + " median \(decade.median), 99 % \(decade.ninetyNine)")
            }
            if let dust, let halfDust, let listed = target.files["dust"] {
                let metalDust = try halves(listed, in: folder)
                let fixed = difference(dust, metalDust, channels: 0..<4)
                let half = difference(halfDust, metalDust, channels: 0..<4)
                comparison.dust = fixed
                comparison.halfDust = half
                comparison.lines.append(
                    "  dust, fixed point (largest Metal \(metalDust.max() ?? 0)): \(fixed.summary)")
                comparison.lines.append("  dust, half floats: \(half.summary)")
            }
            if let column, let listed = target.files["column"] {
                let metal = try values(listed, in: folder, as: Float.self)
                let same = zip(column, metal).filter { $0 == $1 }.count
                let (mine, theirs) = (column.reduce(0, +), metal.reduce(0, +))
                comparison.lines.append(
                    "  column: \(same) of \(metal.count) cells the same count, \(mine) counted here,"
                        + " \(theirs) on Metal")
            }
            if let carrier, let listed = target.files["carrier"] {
                let metal = try halves(listed, in: folder)
                comparison.lines.append(
                    "  carrier: \(difference(carrier, metal, channels: 0..<4).summary)")
            }
            if let tags, let listed = target.files["tags"] {
                let metal = [UInt8](try data(listed, in: folder))
                let same = zip(tags, metal).filter { ($0 * 255).rounded() == Float($1) }.count
                comparison.lines.append("  tags: \(same) of \(metal.count) values the same")
            }
            if webbed, let lace = manifest.lace, let crop = lace.files["level0-crop"],
                let side = crop.width
            {
                let metal = try halves(crop, in: folder)
                let whole = try renderer.lace(side: laceTexels)
                var mine: [Float] = []
                for row in 0..<min(side, laceTexels) {
                    mine += whole[(row * laceTexels)..<(row * laceTexels + min(side, laceTexels))]
                }
                let apart = difference(mine, metal, channels: 0..<1, of: 1)
                comparison.lines.append(
                    "  lace, first level: \(apart.summary); mean \(1 / (try renderer.bakeLace())) here,"
                        + " \(lace.mean) on Metal")
            }

            if let maps {
                let stem = "\(target.look)-\(target.frame)"
                func write(_ values: [Float], _ suffix: String) throws {
                    try values.withUnsafeBytes { Data($0) }
                        .write(to: maps.appendingPathComponent("\(stem)-\(suffix).f32"))
                }
                try write(comparison.light.map, "light-difference")
                try write(comparison.halfLight.map, "half-light-difference")
                try write(metalLight, "metal-light")
                try write(light, "cuda-light")
                index.append([
                    "look": target.look, "frame": target.frame, "shot": target.shot ?? "",
                    "width": String(width), "height": String(height), "stem": stem,
                ])
            }
            comparisons.append(comparison)
        }
        if let maps {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(index).write(to: maps.appendingPathComponent("maps.json"))
        }
        return comparisons
    }
}

// MARK: - From the take

/// The same frames drawn from the take alone, as a full pass on Linux will draw them (#278):
/// the positions decoded here, the attributes, the smoothing lengths, the camera and the
/// uniforms all made by the portable Swift and the CUDA tree, where `compare` takes Metal's own
/// bytes for each. Says how far each input is from Metal's, then how far the picture is.
extension CUDARenderChecks {
    public struct TakeComparison {
        public var look: String
        public var frame: String
        public var light = Difference()
        public var halfLight = Difference()
        public var lines: [String] = []
    }

    /// How many values of two buffers differ in their bits, and by how much at most, relative
    /// to the larger.
    private static func apart(_ mine: [Float], _ theirs: [Float]) -> String {
        guard mine.count == theirs.count else { return "\(mine.count) values against \(theirs.count)" }
        var differing = 0
        var far = 0
        var largest: Float = 0
        var absolute: Float = 0
        for (a, b) in zip(mine, theirs) where a.bitPattern != b.bitPattern {
            differing += 1
            let scale = max(abs(a), abs(b))
            let relative = scale > 0 ? abs(a - b) / scale : 0
            largest = max(largest, relative)
            absolute = max(absolute, abs(a - b))
            if relative > 1e-5 { far += 1 }
        }
        return differing == 0
            ? "the same bits (\(mine.count) values)"
            : "\(differing) of \(mine.count) values differ, \(far) by more than 1e-5 of their value;"
                + " the largest difference \(absolute), or \(largest) of the value"
    }

    private static func floats<T>(_ values: [T]) -> [Float] {
        values.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    public static func compareFromTake(
        folder: URL, looks: Set<String>? = nil,
        threads: Int = ProcessInfo.processInfo.activeProcessorCount,
        laceTexels: Int = DustWeb.laceTexels
    ) throws -> (inputs: [String], frames: [TakeComparison]) {
        guard let manifest = RenderTargetManifest.read(from: folder) else {
            throw Failure.folder("\(folder.path): no manifest of sillage-render-targets 1")
        }
        let take = try RecordingFile.read(from: folder.appendingPathComponent(manifest.take.file))
        let context = try CUDAContext()
        var inputs: [String] = []

        // The attributes, from the take's particles.
        let attributes = ParticleAttributes(take.particles)
        let drawn = attributes.drawnCount
        func listed(_ name: String) throws -> [Float] {
            guard let entry = manifest.particles[name] else { throw Failure.folder("no \(name)") }
            return floats(try [UInt8](data(entry, in: folder)))
        }
        inputs.append("attributes of \(drawn) drawn particles, made here against Metal's:")
        for (name, mine) in [
            ("population", attributes.population), ("formation", attributes.formation),
            ("luminosity", attributes.luminosity), ("rampKeys", attributes.rampKeys),
            ("component", floats(attributes.component)), ("galaxy", floats(attributes.galaxy)),
            ("traits", floats(attributes.traits)),
        ] {
            let width = name == "traits" ? 2 : 1
            inputs.append("  \(name): \(apart(Array(mine.prefix(drawn * width)), try listed(name)))")
        }
        inputs.append(
            "  stellar table: \(apart(floats(StellarPopulation.table), try listed("stellar")))")

        // The positions and the smoothing lengths of each frame.
        var positions: [String: [SIMD3<Float>]] = [:]
        var smoothing: [String: CUDABuffer] = [:]
        let builder = try CUDATreeBuilder(
            context: context, count: take.recording.particleCount, leafCapacity: 24,
            nodeCapacity: take.recording.particleCount / 4 + 1024)
        let held = try context.makeBuffer(length: take.recording.particleCount * 16)
        for frame in manifest.frames {
            guard let blend = take.recording.blend(atCaptured: frame.captured),
                let files = Optional(frame.files), let dumped = files["positions"]
            else { throw Failure.folder("no frame \(frame.name) in the take") }
            let decoded = take.recording.positions(at: blend)
            positions[frame.name] = decoded
            inputs.append(
                "frame \(frame.name): positions decoded here: "
                    + apart(
                        floats(Array(decoded.prefix(drawn))),
                        floats(try [UInt8](data(dumped, in: folder)))))
            try held.upload(decoded)
            var grown = 0
            repeat {
                if try builder.overflowed {
                    try builder.grow()
                    grown += 1
                }
                try builder.buildCells(positions: held)
            } while try builder.overflowed && grown < 20
            let lengths = try context.makeBuffer(length: take.recording.particleCount * 4)
            try builder.buildSmoothing(into: lengths, drawn: drawn)
            smoothing[frame.name] = lengths
            if let entry = files["smoothing"] {
                let mine = try lengths.download(Float.self, count: drawn)
                inputs.append(
                    "frame \(frame.name): smoothing lengths of the CUDA tree: "
                        + apart(mine, floats(try [UInt8](data(entry, in: folder)))))
            }
        }

        var frames: [TakeComparison] = []
        var renderers: [String: (renderer: CUDARenderer, look: LookFile, replay: ShotReplay)] = [:]
        for target in manifest.targets where looks?.contains(target.look) ?? true {
            let made: (renderer: CUDARenderer, look: LookFile, replay: ShotReplay)
            if let kept = renderers[target.look] {
                made = kept
            } else {
                let look = try LookFile.decoded(
                    from: Data(contentsOf: folder.appendingPathComponent(target.lookFile)))
                let renderer = try CUDARenderer(
                    context: context, particles: take.particles,
                    settings: look.renderSettings(width: manifest.width, height: manifest.height),
                    laceTexels: laceTexels)
                let replay = TakeFraming.replay(
                    look: look, framing: take, capturedRate: manifest.take.capturedRate,
                    width: manifest.width, height: manifest.height)
                made = (renderer, look, replay)
                renderers[target.look] = made
            }
            let renderer = made.renderer
            guard let decoded = positions[target.frame], let lengths = smoothing[target.frame],
                let shot = TakeFraming.prepare(
                    renderer, look: made.look, replay: made.replay, framing: take,
                    at: target.captured)
            else { throw Failure.folder("no frame \(target.frame) in the take") }
            try renderer.upload(positions: decoded)
            try renderer.setSmoothing(lengths)
            let plan = try renderer.plan(camera: shot.camera)

            var comparison = TakeComparison(look: target.look, frame: target.frame)
            if let entry = target.files["splat-uniforms"] {
                var mine = plan.uniforms(for: target.plain ? .plain : .stars)
                let words = withUnsafeBytes(of: &mine) { Array($0.bindMemory(to: Float.self)) }
                let theirs = floats(try [UInt8](data(entry, in: folder)))
                comparison.lines.append(
                    "\(target.look) \(target.frame): uniforms made here: "
                        + apart(Array(words.prefix(42)), Array(theirs.prefix(42))))
            }

            renderer.halfFloats = false
            try renderer.draw(plan, threads: threads)
            try renderer.finish()
            let light = try renderer.target(.light)
            renderer.halfFloats = true
            try renderer.draw(plan, threads: 1)
            try renderer.finish()
            let halfLight = try renderer.target(.light)
            renderer.halfFloats = false
            guard let entry = target.files["light"] else { continue }
            let metal = try halves(entry, in: folder)
            comparison.light = difference(light, metal, channels: 0..<3)
            comparison.halfLight = difference(halfLight, metal, channels: 0..<3)
            comparison.lines.append("  light, fixed point: \(comparison.light.summary)")
            comparison.lines.append("  light, half floats: \(comparison.halfLight.summary)")
            frames.append(comparison)
        }
        return (inputs, frames)
    }
}
