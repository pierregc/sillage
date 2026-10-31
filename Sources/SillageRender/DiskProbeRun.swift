import CoreGraphics
import CoreVideo
import Foundation
import Metal
import SillageCore
import simd

extension DiskProbe {
    /// What a probe run is asked for. The scene is a `scene.json` or a scene folder; the whole
    /// scene is sampled at `particles` and the galaxy's own particles are kept, star for star,
    /// set at rest at the origin, with the softening and time step the whole scene runs with
    /// at that count, so the probe measures the disk the scene shows.
    public struct Options: Sendable {
        public var scene: String
        public var galaxy: Int
        /// The scene's visible particle count; the galaxy takes its share. Absent, the
        /// folder's clip count, or 200 000 for a bare scene file.
        public var particles: Int?
        public var durationMyr: Double = 1000
        /// Asked-for cadence; the one run is a whole number of steps.
        public var frameMyr: Double = 4
        public var seed: UInt64?
        public var clumpiness: Float?
        public var toomreQ: Float?
        public var armStrength: Float?
        public var armCount: Int?
        public var armIrregularity: Float?
        public var diskMassFraction: Float?
        public var dissipationTime: Float?
        public var timeStepScale: Float?
        /// Prototype knobs of the spike branches, handed to the sampler before it draws.
        public var armStreaming: Float?
        public var youngAttachment: Float?
        /// Where the files go. Absent, `probe/g<index>` in the scene folder, or under `out/`.
        public var output: String?
        /// Size of each pane of the clip: the disk's own frame on the left, the frame the app
        /// shows on the right.
        public var width = 720
        public var height = 720
        /// Paint the density wave over the particles, as the app does. Off, the clip shows
        /// the particles as the solver left them, which is what the probe is for.
        public var painted = false
        public var clip = true
        public var lagMyr: Double = 50
        /// Instants, in Myr, a still is written at, from the same frames as the clip.
        public var stillsMyr: [Double] = []

        public init(scene: String, galaxy: Int) {
            self.scene = scene
            self.galaxy = galaxy
        }
    }

    public enum ProbeError: Error, CustomStringConvertible {
        case noSuchGalaxy(Int, Int)
        case notADisk(String)
        case noParticles(String)

        public var description: String {
            switch self {
            case .noSuchGalaxy(let asked, let count):
                "galaxy \(asked) asked for, the scene has \(count)"
            case .notADisk(let name): "\(name) is not a disk, nothing to probe"
            case .noParticles(let name): "\(name) got no particles at this count"
            }
        }
    }

    /// What the galaxy's own equilibrium says before anything moves, so a run's numbers can
    /// be read against what the disk should prefer.
    public struct Facts: Codable, Sendable {
        /// Toomre's swing-amplification parameter for two arms, kappa^2 R / (2 pi G Sigma m),
        /// at one, two and three scale lengths; amplification is strong between about 1 and
        /// 3, and the disk prefers the arm count that puts it near 2.
        public var x2 = [Double](repeating: 0, count: 3)
        public var preferredArmsAt2h = 0.0
        /// The rate the renderer turns the painted pattern at, in radians per megayear, with
        /// where its corotation and inner Lindblad resonance fall, in scale lengths.
        public var paintedPatternSpeed = 0.0
        public var paintedCorotation = Double.nan
        public var paintedInnerLindblad = Double.nan
        public var rotationPeriodAt2hMyr = 0.0
        public var epicyclicPeriodAt2hMyr = 0.0
        public var circularSpeedAt2hKms = 0.0

        public init() {}
    }

    /// The readings that say how the run went, taken over the whole run and over its last
    /// 500 Myr, written into `probe.json` so a sweep reads one number per run.
    public struct Summary: Codable, Sendable {
        public var medianStartKpc = 0.0
        public var medianEndKpc = 0.0
        /// Largest departure of the median radius from its start, as a fraction, within the
        /// first 300 Myr, and when it peaked: the figure `breathing-core.md` quotes.
        public var firstExcursion = 0.0
        public var firstExcursionMyr = 0.0
        /// Peak to trough of the median radius over the first 300 Myr, over its start.
        public var breathing = 0.0
        /// From when the median radius stays within 2 % of its final mean; nan if it never does.
        public var settledMyr = Double.nan
        public var sigmaRatioStart = 0.0
        public var sigmaRatio300 = 0.0
        public var sigmaRatioEnd = 0.0
        public var amplitude2Peak = 0.0
        public var amplitude2PeakMyr = 0.0
        public var amplitude2Late = 0.0
        public var amplitude1Late = 0.0
        public var lumpinessStart = 0.0
        public var lumpiness300 = 0.0
        public var lumpinessLate = 0.0
        public var polarLumpinessLate = 0.0
        public var youngLumpinessStart = 0.0
        public var youngLumpinessLate = 0.0
        /// Knots lit in the first 300 Myr, and per 100 Myr over the late stretch.
        public var formedFirst300 = 0
        public var formedLatePer100Myr = 0.0
        public var coherencePatternLate = Double.nan
        public var coherenceMaterialLate = Double.nan
        public var coherenceStaticLate = Double.nan
        public var patternSpeedLate = Double.nan
        public var patternSpreadLate = Double.nan
        public var referenceRate = 0.0
        public var corotationLate = Double.nan
        public var axisTiltMaxDeg = 0.0
        /// Root mean square displacement from one frame to the next, in kpc, of the nucleus
        /// and of the centre the solver reports.
        public var nucleusJitterKpc = 0.0
        public var solverCentreJitterKpc = 0.0
        public var centreOffsetLateKpc = 0.0
        public var outerOffsetLate = 0.0
        public var thicknessStartKpc = 0.0
        public var thicknessEndKpc = 0.0

        public init() {}
    }

    /// What ran and what it came to.
    public struct Report: Codable, Sendable {
        public var scene: String
        public var galaxy: Int
        public var name: String
        public var sceneParticles: Int
        public var galaxyParticles: Int
        public var simulatedParticles: Int
        public var seed: UInt64
        public var overrides: [String: Double]
        public var patternMode: Int
        public var durationMyr: Double
        public var frameMyr: Double
        public var frames: Int
        public var timeStepMyr: Double
        public var timeStepScale: Double
        public var softening: Double
        public var steps: Int
        public var seconds: Double
        public var millisecondsPerStep: Double
        public var clip: String?
        public var facts: Facts
        public var summary: Summary
    }

    /// Runs the probe and writes `probe.csv`, `probe.json`, `probe.scene.json`, the clip and
    /// the stills into the output folder. `log` gets one line a frame.
    public static func run(_ options: Options, log: (String) -> Void = { print($0) }) throws -> Report {
        let started = Date()
        let source = try loadScene(options.scene)
        var file = source.file
        if let scale = options.timeStepScale { file.timeStepScale = scale }
        if let seed = options.seed { file.seed = seed }
        let sceneParticles = options.particles ?? source.particles
        var full = file.scene(particleCount: sceneParticles)
        guard full.galaxies.indices.contains(options.galaxy) else {
            throw ProbeError.noSuchGalaxy(options.galaxy, full.galaxies.count)
        }
        guard full.galaxies[options.galaxy].kind.isRotating else {
            throw ProbeError.notADisk(full.galaxies[options.galaxy].name)
        }
        var overrides: [String: Double] = [:]
        func override<T: BinaryFloatingPoint>(
            _ value: T?, _ name: String, _ path: WritableKeyPath<GalaxyConfig, Float>
        ) {
            guard let value else { return }
            full.galaxies[options.galaxy][keyPath: path] = Float(value)
            overrides[name] = Double(value)
        }
        override(options.clumpiness, "clumpiness", \.clumpiness)
        override(options.toomreQ, "toomreQ", \.toomreQ)
        override(options.armStrength, "armStrength", \.armStrength)
        override(options.armIrregularity, "armIrregularity", \.armIrregularity)
        override(options.diskMassFraction, "diskMassFraction", \.diskMassFraction)
        override(options.dissipationTime, "dissipationTime", \.dissipationTime)
        if let count = options.armCount {
            full.galaxies[options.galaxy].armCount = count
            overrides["armCount"] = Double(count)
        }
        if let value = options.armStreaming {
            DiskSampler.armStreaming = value
            overrides["armStreaming"] = Double(value)
        }
        if let value = options.youngAttachment {
            DiskSampler.youngAttachment = value
            overrides["youngAttachment"] = Double(value)
        }
        // The whole scene is sampled and the galaxy's particles kept, so the probe's disk is
        // the scene's disk star for star, pattern seed included; then it is set at rest at
        // the origin and the solver sees one galaxy.
        var galaxy = full.galaxies[options.galaxy]
        let seeded = extract(galaxy: options.galaxy, from: RestrictedSolver.sampleParticles(for: full))
        guard seeded.count > 0 else { throw ProbeError.noParticles(galaxy.name) }
        galaxy.position = .zero
        galaxy.velocity = .zero
        var alone = SceneConfig(
            name: "\(file.name) \(galaxy.name)", galaxies: [galaxy], solver: .barnesHut,
            seed: full.seed, centerSoftening: full.centerSoftening, openingAngle: full.openingAngle)
        alone.timeStepScale = full.timeStepScale
        // The whole scene's, not what one galaxy alone would derive: the probe measures the
        // disk as the scene runs it.
        alone.softening = full.softening
        alone.timeStep = full.timeStep

        let myr = Physics.megayearsPerTimeUnit
        let stepMyr = Double(alone.timeStep) * myr
        let stepsPerFrame = max(Int((options.frameMyr / stepMyr).rounded()), 1)
        let frameMyr = Double(stepsPerFrame) * stepMyr
        let frames = max(Int((options.durationMyr / frameMyr).rounded()), 1)
        let patternMode = galaxy.kind == .spiral && (2...6).contains(galaxy.armCount) ? galaxy.armCount : 2

        let output = URL(
            fileURLWithPath: options.output ?? source.defaultOutput(galaxy: options.galaxy),
            isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var probeFile = SceneFile(alone)
        probeFile.softening = alone.softening
        probeFile.timeStep = alone.timeStep
        try probeFile.encoded().write(to: output.appendingPathComponent("probe.scene.json"))

        let solver = try MetalBarnesHutSolver(scene: alone, particles: seeded)
        let drawn = seeded.visibleCount > 0 ? seeded.visibleCount : seeded.count
        let equilibrium = DiskEquilibrium(config: galaxy, selfGravitating: true)
        let facts = facts(of: galaxy, equilibrium: equilibrium)
        log(
            String(
                format: "probe      %@ galaxy %d (%@), %d of %d visible, %d simulated, step %.4f Myr, "
                    + "%d steps a frame, %d frames of %.2f Myr",
                options.scene, options.galaxy, galaxy.name, drawn, sceneParticles, seeded.count,
                stepMyr, stepsPerFrame, frames, frameMyr))
        log(
            String(
                format: "facts      X_2 %.2f / %.2f / %.2f at 1, 2, 3 h (prefers %.1f arms at 2 h), "
                    + "painted pattern %.4f rad/Myr: corotation %.2f h, inner Lindblad %.2f h; "
                    + "v_c(2h) %.0f km/s, rotation %.0f Myr, epicycle %.0f Myr",
                facts.x2[0], facts.x2[1], facts.x2[2], facts.preferredArmsAt2h,
                facts.paintedPatternSpeed, facts.paintedCorotation, facts.paintedInnerLindblad,
                facts.circularSpeedAt2hKms, facts.rotationPeriodAt2hMyr, facts.epicyclicPeriodAt2hMyr))

        var look = LookFile.standard
        look.starCount = 0
        if !options.painted { look.armStrength = 0 }
        look.palette = [GalaxyColours(galaxy.color)]
        var picture: (renderer: Renderer, smoothing: SmoothingField)?
        var writer: VideoWriter?
        let clipURL = output.appendingPathComponent("probe.mov")
        if options.clip || !options.stillsMyr.isEmpty {
            let settings = look.renderSettings(width: options.width, height: options.height)
            let renderer = try Renderer(
                particles: seeded, settings: settings, externalPositions: solver.positions,
                externalFormation: solver.formation)
            let smoothing = try SmoothingField(device: renderer.device, particleCount: drawn)
            renderer.setSmoothing(smoothing.buffer)
            renderer.setGalaxyColours(look.palette)
            renderer.apply(look.look)
            picture = (renderer, smoothing)
            if options.clip {
                writer = try VideoWriter(
                    width: options.width * 2, height: options.height, framesPerSecond: 30, to: clipURL)
            }
        }
        let strength = options.painted ? LookFile.diskStrength(look.armStrength, look.look) : 0
        let stillFrames = Set(options.stillsMyr.map { Int(($0 / frameMyr).rounded()) })

        let csvURL = output.appendingPathComponent("probe.csv")
        FileManager.default.createFile(atPath: csvURL.path, contents: nil)
        let csv = try FileHandle(forWritingTo: csvURL)
        try csv.write(contentsOf: Data((Measurement.csvHeader + "\n").utf8))

        var frame = Frame.natal(galaxy)
        var tracker = Tracker(lagMyr: options.lagMyr, patternMode: patternMode, equilibrium: equilibrium)
        var readings: [Measurement] = []
        let component = seeded.component
        var stepSeconds = 0.0
        var previousTime = solver.time
        for index in 0...frames {
            var stepMs = 0.0
            if index > 0 {
                let stepStart = Date()
                solver.step(count: stepsPerFrame)
                stepMs = Date().timeIntervalSince(stepStart) * 1000
                stepSeconds += stepMs / 1000
            }
            let timeMyr = Double(solver.time) * myr
            let measureStart = Date()
            let positions = UnsafeBufferPointer(
                start: solver.positions.contents().bindMemory(to: SIMD3<Float>.self, capacity: drawn),
                count: drawn)
            let velocities = UnsafeBufferPointer(
                start: solver.velocities.contents().bindMemory(to: SIMD3<Float>.self, capacity: drawn),
                count: drawn)
            let solverCentre = solver.centers.first ?? .zero
            let (measured, map) = component.withUnsafeBufferPointer { components in
                let particles = Particles(
                    positions: positions, velocities: velocities,
                    component: UnsafeBufferPointer(rebasing: components[0..<drawn]))
                frame = DiskProbe.frame(of: particles, galaxy: galaxy, previous: frame)
                return measure(
                    particles, frame: frame, galaxy: galaxy, equilibrium: equilibrium,
                    solverCentre: solverCentre, timeMyr: timeMyr, patternMode: patternMode)
            }
            var reading = measured
            reading.frame = index
            reading.stepMilliseconds = stepMs / Double(stepsPerFrame)
            if index > 0 {
                let born = solver.formation.contents().bindMemory(to: Float.self, capacity: drawn)
                var formed = 0
                for particle in 0..<drawn
                where born[particle] > previousTime && born[particle] <= solver.time {
                    formed += 1
                }
                reading.formed = formed
            }
            previousTime = solver.time
            tracker.fold(&reading, map: map)
            reading.measureMilliseconds = Date().timeIntervalSince(measureStart) * 1000
            readings.append(reading)
            try csv.write(contentsOf: Data((reading.csvLine + "\n").utf8))

            let wantsStill = stillFrames.contains(index)
            if let picture, writer != nil || wantsStill {
                picture.smoothing.update(from: solver)
                picture.renderer.time = solver.time
                picture.renderer.setDiskFrames(
                    paintedFrames(
                        scene: full, galaxy: options.galaxy, centre: solverCentre, time: solver.time,
                        strength: strength, disk: solver.diskFrames.first))
                // Left, the disk's own frame; right, what the app frames: the solver's centre
                // seen along the natal axis.
                let own = camera(frame: frame, galaxy: galaxy, fieldOfView: look.look.fieldOfView)
                var app = Frame.natal(galaxy)
                app.centre = solverCentre
                let framed = camera(frame: app, galaxy: galaxy, fieldOfView: look.look.fieldOfView)
                let left = picture.renderer.render(camera: own)
                let right = picture.renderer.render(camera: framed)
                let stillURL = output.appendingPathComponent(
                    String(format: "still-%04d.png", Int(timeMyr.rounded())))
                if let writer {
                    try writer.append(filling: { pixels in
                        compose(
                            left: left, right: right, width: options.width, height: options.height,
                            into: pixels)
                    })
                }
                if wantsStill {
                    let joined = joined(
                        left: left, right: right, width: options.width, height: options.height)
                    try PNGWriter.write(
                        PNGWriter.image(joined, width: options.width * 2, height: options.height),
                        to: stillURL)
                }
            }
            log(
                String(
                    format: "frame %04d  t=%6.1f Myr  r50 %.2f  a2 %.3f  a1 %.3f  s/vc %.3f  lump %.3f  "
                        + "coh %.2f/%.2f  tilt %.2f  sim %.2f ms/step  measure %.1f ms",
                    index, timeMyr, reading.median, reading.amplitude2Mid, reading.amplitude1Mid,
                    reading.sigmaRatioMid, reading.lumpiness, reading.coherencePattern,
                    reading.coherenceMaterial, reading.axisTilt, reading.stepMilliseconds,
                    reading.measureMilliseconds))
        }
        try writer?.finish()
        try csv.close()

        let steps = frames * stepsPerFrame
        let report = Report(
            scene: options.scene, galaxy: options.galaxy, name: galaxy.name,
            sceneParticles: sceneParticles, galaxyParticles: drawn, simulatedParticles: seeded.count,
            seed: full.seed, overrides: overrides, patternMode: patternMode,
            durationMyr: Double(frames) * frameMyr, frameMyr: frameMyr, frames: frames + 1,
            timeStepMyr: stepMyr, timeStepScale: Double(alone.timeStepScale),
            softening: Double(alone.softening), steps: steps,
            seconds: Date().timeIntervalSince(started),
            millisecondsPerStep: steps > 0 ? stepSeconds * 1000 / Double(steps) : 0,
            clip: writer == nil ? nil : clipURL.path, facts: facts, summary: summarize(readings))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        try encoder.encode(report).write(to: output.appendingPathComponent("probe.json"))
        return report
    }

    struct Source {
        var file: SceneFile
        var particles: Int
        var folder: URL?
        var path: String

        func defaultOutput(galaxy: Int) -> String {
            if let folder {
                return folder.appendingPathComponent("probe/g\(galaxy)", isDirectory: true).path
            }
            let stem = URL(fileURLWithPath: path).lastPathComponent.split(separator: ".").first
            return "out/probe/\(stem.map(String.init) ?? "scene")-g\(galaxy)"
        }
    }

    /// A scene folder gives its `scene.json` and the particle count its clip ran at; a file
    /// gives itself and the explore default.
    static func loadScene(_ path: String) throws -> Source {
        var isDirectory: ObjCBool = false
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            let folder = SceneFolder(url)
            let file = try SceneFile.decoded(from: Data(contentsOf: folder.scene))
            let particles = (try? folder.storedClip().particles) ?? 200_000
            return Source(file: file, particles: particles, folder: url, path: path)
        }
        let file = try SceneFile.decoded(from: Data(contentsOf: url))
        return Source(file: file, particles: 200_000, folder: nil, path: path)
    }

    /// The particles of one galaxy of a sampled scene, brought to rest at the origin and
    /// renumbered as galaxy 0, visible ones first.
    static func extract(galaxy index: Int, from sampled: ParticleSystem) -> ParticleSystem {
        var kept = ParticleSystem()
        var position = SIMD3<Double>.zero
        var velocity = SIMD3<Double>.zero
        var mass = 0.0
        // At rest about its own centre of mass, dark matter included, so the halo does not
        // start with a drift the disk has not got.
        for particle in 0..<sampled.count where sampled.galaxyIndex[particle] == UInt32(index) {
            let m = Double(max(sampled.mass[particle], 1e-20))
            position += SIMD3<Double>(sampled.positions[particle]) * m
            velocity += SIMD3<Double>(sampled.velocities[particle]) * m
            mass += m
        }
        guard mass > 0 else { return kept }
        let centre = SIMD3<Float>(position / mass)
        let drift = SIMD3<Float>(velocity / mass)
        for particle in 0..<sampled.count where sampled.galaxyIndex[particle] == UInt32(index) {
            kept.append(
                position: sampled.positions[particle] - centre,
                velocity: sampled.velocities[particle] - drift, galaxy: 0,
                radius: sampled.birthRadius[particle], population: sampled.population[particle],
                luminosity: sampled.luminosity[particle], formation: sampled.formation[particle],
                component: ParticleComponent(rawValue: sampled.component[particle]) ?? .star,
                mass: sampled.mass[particle], kernelScale: sampled.kernelScale[particle])
        }
        kept.partitionVisibleFirst()
        return kept
    }

    /// The painted wave for the one galaxy, seeded as the scene seeds it: `DiskFrame.make`
    /// takes a galaxy's pattern seed from its index in the scene, so the frame is built on the
    /// whole scene and this galaxy's picked out.
    static func paintedFrames(
        scene: SceneConfig, galaxy index: Int, centre: SIMD3<Float>, time: Float, strength: Float,
        disk: DiskState?
    ) -> [DiskFrame] {
        var centres = scene.galaxies.map(\.position)
        centres[index] = centre
        var disks = DiskState.natal(scene)
        if let disk { disks[index] = disk }
        let frames = DiskFrame.make(
            scene: scene, centers: centres, time: time, strength: strength, disks: disks)
        return [frames[index]]
    }

    /// Face on, along the frame's axis, the whole disk in the picture, the frame's own
    /// in-plane axis up: the camera moves only as the frame does. Looking down the axis with
    /// `v` up puts `u` to the right, so the disk turns counterclockwise on screen whatever
    /// its spin.
    static func camera(frame: Frame, galaxy: GalaxyConfig, fieldOfView: Float) -> Camera {
        let radius = max(galaxy.diskScaleLength * galaxy.diskTruncation, 0.5)
        let distance = radius / tan(fieldOfView / 2) * 1.05
        return Camera(
            eye: frame.centre + frame.axis * distance, target: frame.centre, up: frame.v,
            fieldOfView: fieldOfView)
    }

    /// Two rendered panes side by side, as the BGRA frame the encoder takes.
    static func compose(
        left: [UInt8], right: [UInt8], width: Int, height: Int, into pixels: CVPixelBuffer
    ) {
        CVPixelBufferLockBaseAddress(pixels, [])
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return }
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        let target = base.assumingMemoryBound(to: UInt8.self)
        let row = width * 4
        for y in 0..<height {
            for (pane, source) in [left, right].enumerated() where source.count >= (y + 1) * row {
                for x in 0..<width {
                    let from = y * row + x * 4
                    let to = y * stride + (pane * width + x) * 4
                    target[to] = source[from + 2]
                    target[to + 1] = source[from + 1]
                    target[to + 2] = source[from]
                    target[to + 3] = 255
                }
            }
        }
    }

    /// The same two panes as one RGBA image, for a still.
    static func joined(left: [UInt8], right: [UInt8], width: Int, height: Int) -> [UInt8] {
        let row = width * 4
        var out = [UInt8](repeating: 0, count: row * 2 * height)
        for y in 0..<height {
            for (pane, source) in [left, right].enumerated() where source.count >= (y + 1) * row {
                let from = y * row
                let to = y * row * 2 + pane * row
                out.replaceSubrange(to..<(to + row), with: source[from..<(from + row)])
            }
        }
        return out
    }

    /// The swing-amplification figures and the painted pattern's resonances, from the
    /// galaxy's own equilibrium curve, before anything moves.
    static func facts(of galaxy: GalaxyConfig, equilibrium: DiskEquilibrium) -> Facts {
        var facts = Facts()
        let h = max(galaxy.diskScaleLength, 1e-3)
        let myr = Physics.megayearsPerTimeUnit
        func omega(_ radius: Float) -> Double {
            Double(equilibrium.circularSpeed(atRadius: radius) / radius) / myr
        }
        func kappa(_ radius: Float) -> Double {
            Double(equilibrium.epicyclicFrequency(atRadius: radius)) / myr
        }
        for (slot, scaled) in [Float(1), 2, 3].enumerated() {
            let radius = scaled * h
            let k = Double(equilibrium.epicyclicFrequency(atRadius: radius))
            let sigma = Double(equilibrium.surfaceDensity(atRadius: radius))
            facts.x2[slot] =
                k * k * Double(radius) / (2 * .pi * Double(Physics.gravitationalConstant) * sigma * 2)
        }
        facts.preferredArmsAt2h = facts.x2[1] * 2 / 2
        let two = 2 * h
        facts.circularSpeedAt2hKms =
            Double(equilibrium.circularSpeed(atRadius: two)) * Physics.kilometersPerSecondPerVelocityUnit
        facts.rotationPeriodAt2hMyr = 2 * .pi / omega(two)
        facts.epicyclicPeriodAt2hMyr = 2 * .pi / kappa(two)
        // The renderer's pattern speed, as DiskFrame.make sets it: half the analytic circular
        // frequency at two scale lengths.
        let reference = max(two, 0.5)
        facts.paintedPatternSpeed =
            Double(galaxy.potential.circularSpeed(atRadius: reference) / reference) * 0.5 / myr
        facts.paintedCorotation = corotation(
            patternSpeed: facts.paintedPatternSpeed, equilibrium: equilibrium)
        // The inner Lindblad resonance, where Omega - kappa / 2 meets the pattern speed, read
        // from the inside out on a grid.
        var previous: Double?
        for step in 1...240 {
            let scaled = Double(step) * 0.05
            let radius = Float(scaled) * h
            let value = omega(radius) - kappa(radius) / 2 - facts.paintedPatternSpeed
            if let previous, previous > 0, value <= 0 {
                facts.paintedInnerLindblad = scaled - 0.025
                break
            }
            previous = value
        }
        return facts
    }

    static func summarize(_ readings: [Measurement]) -> Summary {
        var summary = Summary()
        guard let first = readings.first, let last = readings.last else { return summary }
        let lateFrom = max(last.timeMyr - 500, (first.timeMyr + last.timeMyr) / 2)
        let late = readings.filter { $0.timeMyr >= lateFrom }
        func mean(_ values: [Double]) -> Double {
            let kept = values.filter { !$0.isNaN }
            return kept.isEmpty ? .nan : kept.reduce(0, +) / Double(kept.count)
        }
        func at(_ myr: Double) -> Measurement {
            readings.min { abs($0.timeMyr - myr) < abs($1.timeMyr - myr) } ?? last
        }
        summary.medianStartKpc = first.median
        summary.medianEndKpc = last.median
        if first.median > 0 {
            let early = readings.filter { $0.timeMyr <= 300 }
            for reading in early {
                let excursion = abs(reading.median / first.median - 1)
                if excursion > summary.firstExcursion {
                    summary.firstExcursion = excursion
                    summary.firstExcursionMyr = reading.timeMyr
                }
            }
            if let high = early.map(\.median).max(), let low = early.map(\.median).min() {
                summary.breathing = (high - low) / first.median
            }
        }
        let finalMedian = mean(readings.filter { $0.timeMyr >= last.timeMyr - 200 }.map(\.median))
        if finalMedian > 0 {
            var settled = Double.nan
            for reading in readings.reversed() {
                if abs(reading.median - finalMedian) / finalMedian > 0.02 { break }
                settled = reading.timeMyr
            }
            summary.settledMyr = settled
        }
        summary.sigmaRatioStart = first.sigmaRatioMid
        summary.sigmaRatio300 = at(300).sigmaRatioMid
        summary.sigmaRatioEnd = last.sigmaRatioMid
        if let peak = readings.max(by: { $0.amplitude2Mid < $1.amplitude2Mid }) {
            summary.amplitude2Peak = peak.amplitude2Mid
            summary.amplitude2PeakMyr = peak.timeMyr
        }
        summary.amplitude2Late = mean(late.map(\.amplitude2Mid))
        summary.amplitude1Late = mean(late.map(\.amplitude1Mid))
        summary.lumpinessStart = first.lumpiness
        summary.lumpiness300 = at(300).lumpiness
        summary.lumpinessLate = mean(late.map(\.lumpiness))
        summary.polarLumpinessLate = mean(late.map(\.polarLumpiness))
        summary.youngLumpinessStart = first.youngLumpiness
        summary.youngLumpinessLate = mean(late.map(\.youngLumpiness))
        summary.formedFirst300 = readings.filter { $0.timeMyr <= 300 }.reduce(0) { $0 + $1.formed }
        let lateSpan = (late.last?.timeMyr ?? 0) - (late.first?.timeMyr ?? 0)
        if lateSpan > 0 {
            let lit = late.dropFirst().reduce(0) { $0 + $1.formed }
            summary.formedLatePer100Myr = Double(lit) / lateSpan * 100
        }
        summary.coherencePatternLate = mean(late.map(\.coherencePattern))
        summary.coherenceMaterialLate = mean(late.map(\.coherenceMaterial))
        summary.coherenceStaticLate = mean(late.map(\.coherenceStatic))
        summary.patternSpeedLate = mean(late.map(\.patternSpeed))
        summary.patternSpreadLate = mean(late.map(\.patternSpread))
        summary.referenceRate = last.referenceRate
        summary.corotationLate = mean(late.map(\.corotation))
        summary.axisTiltMaxDeg = readings.map(\.axisTilt).max() ?? 0
        var nucleus = 0.0
        var solverCentre = 0.0
        for (before, after) in zip(readings, readings.dropFirst()) {
            nucleus += Double(simd_length_squared(after.centre - before.centre))
            solverCentre += Double(simd_length_squared(after.solverCentre - before.solverCentre))
        }
        let pairs = Double(max(readings.count - 1, 1))
        summary.nucleusJitterKpc = (nucleus / pairs).squareRoot()
        summary.solverCentreJitterKpc = (solverCentre / pairs).squareRoot()
        summary.centreOffsetLateKpc = mean(late.map(\.centreOffset))
        summary.outerOffsetLate = mean(late.map(\.outerOffset))
        summary.thicknessStartKpc = first.zRms
        summary.thicknessEndKpc = last.zRms
        return summary
    }
}
