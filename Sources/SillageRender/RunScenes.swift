import Foundation
import SillageCore

/// A run's look and scenes, built from its command line as `sillage-render` has always built
/// them (#376): the take pass (`TakePassRun`) and the full pass (`FullPassRun`) read the same
/// options the same way, on either engine.
public struct RunScenes {
    public enum Failure: Error, CustomStringConvertible {
        case badCentre
        case unknownCamera(String)
        case unknownPreset(String)
        case unknownSolver(String)

        public var description: String {
            switch self {
            case .badCentre: "--center is x,y,z in kiloparsecs"
            case .unknownCamera(let mode): "unknown camera: \(mode)"
            case .unknownPreset(let name): "unknown preset: \(name)"
            case .unknownSolver(let name): "unknown solver: \(name)"
            }
        }
    }

    /// The scene file the run ran, as written beside its outputs.
    public var file: SceneFile
    /// The massive count's when the others are light tracers, the drawn count's otherwise.
    public var scene: SceneConfig
    /// The drawn count's, tracers included.
    public var drawn: SceneConfig
    /// The drawn count's as it was before the massive particles were split off, which a generated
    /// scene is judged on.
    public var planned: SceneConfig
    public var massive: Int?
    /// `barnes-hut`, `restricted` or `cpu`.
    public var backend: String
    /// The look, its flags applied, without the scene's colours: `look` gives them.
    public var look: LookFile
    /// The look with the colours the scene was drawn with, which replays it exactly.
    public var painted: LookFile
    /// The haste a generated scene was drawn with; nil for a scene read from a file.
    public var generatedHaste: Float?
    /// Steps, after `--span`.
    public var steps: Int
    public var presetName: String

    /// The look a command line asks for: its look file, each flag overriding its field.
    public static func look(_ arguments: [String]) throws -> LookFile {
        let options = RunOptions(arguments)
        var look =
            try options.argument("look").map {
                try LookFile.decoded(from: Data(contentsOf: URL(fileURLWithPath: $0)))
            } ?? .standard
        func flag(_ name: String, _ field: WritableKeyPath<LookFile, Float>) {
            if let value = options.argument(name).flatMap(Double.init) { look[keyPath: field] = Float(value) }
        }
        func flag(_ name: String, _ field: WritableKeyPath<LookFile, Float?>) {
            if let value = options.argument(name).flatMap(Double.init) { look[keyPath: field] = Float(value) }
        }
        func flag(_ name: String, _ field: WritableKeyPath<LookFile, Int>) {
            if let value = options.argument(name).flatMap(Double.init) { look[keyPath: field] = Int(value) }
        }
        flag("brightness", \.look.brightness)
        flag("dust", \.look.dustStrength)
        flag("star-size", \.look.starSize)
        flag("smoothing", \.look.smoothingScale)
        flag("min-kernel", \.look.minimumKernel)
        flag("max-kernel", \.look.maximumKernel)
        flag("bloom-threshold", \.look.bloomThreshold)
        flag("bloom-knee", \.look.bloomSoftKnee)
        flag("bloom", \.look.bloomIntensity)
        flag("stretch", \.look.stretch)
        flag("saturation", \.look.saturation)
        flag("white-point", \.look.whitePoint)
        flag("spikes", \.look.spikeArms)
        flag("spike-length", \.look.spikeLength)
        flag("spike-intensity", \.look.spikeIntensity)
        flag("sky", \.look.skyLevel)
        flag("noise", \.look.noiseLevel)
        flag("tint", \.look.galaxyTint)
        flag("fov", \.look.fieldOfView)
        flag("column", \.look.columnSmoothing)
        flag("glint", \.look.glint)
        flag("dust-web", \.look.dustWeb)
        flag("old-width", \.look.oldWidth)
        flag("bulge-width", \.look.bulgeWidth)
        flag("young-width", \.look.youngWidth)
        flag("knot-width", \.look.knotWidth)
        flag("stars", \.starCount)
        if arguments.contains("--plain") { look.plain = true }
        flag("supersample", \.supersample)
        flag("bloom-levels", \.bloomLevels)
        flag("arms", \.armStrength)
        flag("zoom", \.camera.zoom)
        flag("percentile", \.camera.percentile)
        flag("radius", \.camera.radius)
        flag("elevation", \.camera.elevation)
        flag("elevation-end", \.camera.elevationEnd)
        flag("azimuth", \.camera.azimuth)
        if let orbit = options.argument("orbit").flatMap(Double.init) {
            look.camera.azimuthEnd = look.camera.azimuth + Float(orbit)
        }
        flag("azimuth-end", \.camera.azimuthEnd)
        if let aim = options.argument("center") {
            let parts = aim.split(separator: ",").compactMap { Float($0) }
            guard parts.count == 3 else { throw Failure.badCentre }
            look.camera.center = SIMD3(parts[0], parts[1], parts[2])
        }
        if arguments.contains("--director") {
            look.camera.mode = arguments.contains("--immersed") ? .immersed : .director
        }
        if let mode = options.argument("camera") {
            guard let parsed = LookFile.CameraPlan.Mode(rawValue: mode) else {
                throw Failure.unknownCamera(mode)
            }
            look.camera.mode = parsed
        }
        return look
    }

    /// Every scene runs from its scene file, so the file written beside the output replays
    /// exactly what ran. Read from disk, a scene keeps its own values unless a flag is given;
    /// without `--scene`, `--preset` draws one. `look` gives the colours.
    public init(_ arguments: [String], look: LookFile) throws {
        let options = RunOptions(arguments)
        self.look = look
        presetName = options.argument("preset") ?? "merger"
        let particles = Int(options.number("particles", 1_000_000))
        steps = Int(options.number("steps", 3_000))
        let frames = Int(options.number("frames", 1))
        let seed = options.argument("seed").flatMap(UInt64.init)
        let scenePath = options.argument("scene")
        var file: SceneFile
        var palette: [SIMD3<Float>] = []
        // A generated scene's pericentres are drawn for a default stretch of time and moved into
        // the clip once its step is known.
        var generatedHaste: Float?
        if let scenePath {
            file = try SceneFile.decoded(from: Data(contentsOf: URL(fileURLWithPath: scenePath)))
        } else {
            let preset: SceneConfig
            switch presetName {
            case "merger": preset = .merger(particleCount: particles)
            case "encounter": preset = .encounter(particleCount: particles)
            case "flyby": preset = .flyby(particleCount: particles)
            case "disk": preset = .isolatedDisk(particleCount: particles)
            // Drawn from the seed and nothing else, which is what a library of scenes wants: the
            // seed is the whole description, so a scene worth keeping can be rendered again from
            // one integer.
            case "contemplation":
                preset = .contemplation(
                    particleCount: particles, seed: seed ?? 1, haste: Float(options.number("haste", 0)),
                    galaxies: options.argument("galaxies").flatMap(Int.init),
                    lookSeed: options.argument("look-seed").flatMap(UInt64.init))
                generatedHaste = Float(options.number("haste", 0))
            // The scene at `--index` in the batch `--seed` draws, archetypes mixed in at
            // `--archetypes` and pairs at `--pair-share`, `off` for a batch drawn before the share
            // (#176). The seed is the batch's here, and the scene's own follows from it and the
            // index.
            case "free":
                preset = BatchDraw(
                    batchSeed: seed ?? 1,
                    archetypeShare: Float(
                        options.number("archetypes", Double(BatchDraw.defaultArchetypeShare))),
                    pairShare: options.argument("pair-share") == "off"
                        ? nil : Float(options.number("pair-share", Double(BatchDraw.defaultPairShare))),
                    spacing: Float(options.number("spacing", Double(FreeDraw.defaultSpacing))),
                    haste: Float(options.number("haste", 0))
                ).scene(at: Int(options.number("index", 0)), particleCount: particles)
                generatedHaste = Float(options.number("haste", 0))
            // An archetype alone: its scene number `--index` in batch `--seed`, the same one the
            // batch draws when that archetype comes round for that time.
            default:
                guard let archetype = Archetype(rawValue: presetName) else {
                    throw Failure.unknownPreset(presetName)
                }
                preset = archetype.scene(
                    batchSeed: seed ?? 1, occurrence: Int(options.number("index", 0)),
                    particleCount: particles, haste: Float(options.number("haste", 0)))
                generatedHaste = Float(options.number("haste", 0))
            }
            file = SceneFile(preset)
            palette = preset.galaxies.map(\.color)
            file.openingAngle = 0.9
        }
        // A scene described before the calm disk (#167) replays as it was written; `--calm` moves
        // every galaxy onto it, and the scene file written beside the output records the change.
        if arguments.contains("--calm") {
            for index in file.galaxies.indices { file.galaxies[index].adoptCalmDisk() }
        }
        let batchSeeded = presetName == "free" || Archetype(rawValue: presetName) != nil
        if let seed, scenePath != nil || !batchSeeded { file.seed = seed }
        let placedFor = (file.solver, file.galaxies.map(\.haloParticleRatio))
        backend =
            options.argument("solver")
            ?? (scenePath == nil || file.solver == .restricted ? "restricted" : "barnes-hut")
        // The presets are self-gravitating by default, so the flag has to set the solver both ways.
        switch backend {
        case "barnes-hut":
            file.solver = .barnesHut
            if let ratio = options.argument("halo").flatMap(Float.init) ?? (scenePath == nil ? 1.5 : nil) {
                for index in file.galaxies.indices where file.galaxies[index].kind != .blackHole {
                    file.galaxies[index].haloParticleRatio = ratio
                }
            }
        case "restricted", "cpu":
            file.solver = .restricted
        default:
            throw Failure.unknownSolver(backend)
        }
        // Softening and step follow from the counts and the solver unless overridden below. Only
        // an explicit flag overrides the scale, because a generated scene picks its own.
        if let scale = options.argument("dt-scale").flatMap(Float.init) { file.timeStepScale = scale }
        if let dissipation = options.argument("dissipation").flatMap(Float.init) {
            for index in file.galaxies.indices { file.galaxies[index].dissipationTime = dissipation }
        }
        if let dt = options.argument("dt").flatMap(Float.init) { file.timeStep = dt }
        if let theta = options.argument("theta").flatMap(Float.init) { file.openingAngle = theta }
        if let value = options.argument("softening").flatMap(Float.init) { file.softening = value }
        for (index, entry) in look.palette.enumerated() {
            if index < palette.count { palette[index] = entry.colour } else { palette.append(entry.colour) }
        }
        var scene = file.scene(particleCount: particles, palette: palette)
        // `--span Myr` runs as many steps as cover it at the step this scene has, a whole number a
        // frame.
        if let span = options.argument("span").flatMap(Double.init) {
            steps = SceneFolder.Clip.steps(
                spanMyr: span, stepMyr: Double(scene.timeStep) * Physics.megayearsPerTimeUnit, frames: frames)
        }
        // Encounters are placed for a solver and a halo; a flag that changes either places them
        // again.
        if !scene.encounters.isEmpty,
            generatedHaste != nil || placedFor.0 != file.solver
                || placedFor.1 != file.galaxies.map(\.haloParticleRatio)
        {
            if let generatedHaste {
                scene.retimeEncounters(
                    from: SceneConfig.contemplationWindow(haste: generatedHaste),
                    to: scene.encounterWindow(settleSteps: Int(options.number("settle", 0)), steps: steps))
            }
            scene.placeEncountersGivingWay()
            let kept = file
            file = SceneFile(scene)
            file.softening = kept.softening
            file.timeStep = kept.timeStep
        }
        // The colours the scene was drawn with, so the look file written beside it replays it
        // exactly.
        var painted = look
        painted.palette = scene.galaxies.enumerated().map { index, galaxy in
            index < look.palette.count ? look.palette[index] : GalaxyColours(galaxy.color)
        }
        self.painted = painted
        // `--massive M` (#187): the scene is drawn at `--particles`, and only about M of the
        // visible particles carry the mass, with dark matter drawn for M (#211). The softening
        // and the step are the massive count's; the others are light tracers in their field.
        massive = SceneFolder.massive(in: arguments).map { min($0, particles) }
        planned = scene
        drawn = scene
        if let massive {
            scene = file.scene(particleCount: massive, palette: palette)
            // A disk drawn for its response answers at the massive particles' softening (#181).
            drawn.solveToomreQ(softening: scene.softening)
        }
        self.file = file
        self.scene = scene
        self.generatedHaste = generatedHaste
    }

    /// The lines a run starts with: the draw a generated scene came from, and its encounters.
    public var drawLines: [String] {
        var lines: [String] = []
        if let draw = drawn.draw {
            lines.append(
                "draw       \(draw.generator), batch \(draw.batchSeed) scene \(draw.index) (point \(draw.point)): "
                    + draw.families.map(\.rawValue).joined(separator: ", "))
        }
        for encounter in drawn.encounters {
            // How fast the pair would be far apart, or for a bound one, the speed its binding is
            // worth.
            let mass =
                drawn.galaxies[encounter.primary].potential.mass
                + drawn.galaxies[encounter.secondary].potential.mass
            let speed =
                (abs(encounter.eccentricity - 1) * mass / encounter.pericentre).squareRoot()
                * Float(Physics.kilometersPerSecondPerVelocityUnit)
            lines.append(
                String(
                    format:
                        "encounter  %d-%d, pericentre %.1f kpc at %.0f Myr, e %.2f (%@, %@ %.0f km/s), mass ratio %.2f",
                    encounter.primary, encounter.secondary, encounter.pericentre, encounter.pericentreTime,
                    encounter.eccentricity, encounter.orbit.rawValue,
                    encounter.eccentricity < 1 ? "binding" : "far out", speed, encounter.massRatio))
        }
        return lines
    }
}

/// A command line's options, read as every run reads them: `--name value`, the first wins.
public struct RunOptions: Sendable {
    public let arguments: [String]

    public init(_ arguments: [String]) { self.arguments = arguments }

    public func argument(_ name: String) -> String? {
        guard let index = arguments.firstIndex(of: "--\(name)"), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    public func number(_ name: String, _ fallback: Double) -> Double {
        argument(name).flatMap(Double.init) ?? fallback
    }

    public func contains(_ flag: String) -> Bool { arguments.contains(flag) }
}
