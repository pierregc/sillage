import Foundation

/// A scene described by its physics alone, as it is kept on disk. Nothing about how it looks
/// is in it, and the particle count is supplied when it is read, so the same file runs at a
/// hundred thousand particles or at five million.
///
/// Softening and time step follow from the particle count, so they are stored only when they
/// were set by hand; absent, they are derived again at whatever count the scene is read at.
public struct SceneFile: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    public var name: String
    public var seed: UInt64
    public var solver: SolverKind
    public var timeStepScale: Float
    public var openingAngle: Float
    public var centerSoftening: Float
    public var softening: Float?
    public var timeStep: Float?
    public var galaxies: [Galaxy]
    /// How the galaxies were placed, when they were placed from encounters. The positions and
    /// velocities below are what that gave and what a replay runs from.
    public var encounters: [Encounter]?
    /// How the scene was drawn, when a generator drew it.
    public var draw: SceneDraw?

    public struct Galaxy: Codable, Sendable, Equatable {
        public var name: String
        /// Fraction of the visible particles this galaxy is given. The shares sum to one.
        public var particleShare: Double
        public var kind: GalaxyKind
        public var potential: GalaxyPotential
        public var diskScaleLength: Float
        public var diskTruncation: Float
        public var diskThickness: Float
        public var velocityDispersion: Float
        public var armCount: Int
        public var armStrength: Float
        public var armPitch: Float
        public var armIrregularity: Float
        public var dustFraction: Float
        public var starFormingFraction: Float
        public var bulgeExtent: Float
        public var bulgeFraction: Float
        public var bulgeFlattening: Float
        public var clumpiness: Float
        public var outskirtFraction: Float
        public var diskMassFraction: Float
        public var toomreQ: Float
        public var haloParticleRatio: Float
        public var haloExtent: Float
        public var dissipationTime: Float
        public var position: SIMD3<Float>
        public var velocity: SIMD3<Float>
        public var inclination: Float
        public var positionAngle: Float
        public var spin: Spin

        public init(_ galaxy: GalaxyConfig, share: Double) {
            name = galaxy.name
            particleShare = share
            kind = galaxy.kind
            potential = galaxy.potential
            diskScaleLength = galaxy.diskScaleLength
            diskTruncation = galaxy.diskTruncation
            diskThickness = galaxy.diskThickness
            velocityDispersion = galaxy.velocityDispersion
            armCount = galaxy.armCount
            armStrength = galaxy.armStrength
            armPitch = galaxy.armPitch
            armIrregularity = galaxy.armIrregularity
            dustFraction = galaxy.dustFraction
            starFormingFraction = galaxy.starFormingFraction
            bulgeExtent = galaxy.bulgeExtent
            bulgeFraction = galaxy.bulgeFraction
            bulgeFlattening = galaxy.bulgeFlattening
            clumpiness = galaxy.clumpiness
            outskirtFraction = galaxy.outskirtFraction
            diskMassFraction = galaxy.diskMassFraction
            toomreQ = galaxy.toomreQ
            haloParticleRatio = galaxy.haloParticleRatio
            haloExtent = galaxy.haloExtent
            dissipationTime = galaxy.dissipationTime
            position = galaxy.position
            velocity = galaxy.velocity
            inclination = galaxy.inclination
            positionAngle = galaxy.positionAngle
            spin = galaxy.spin
        }

        func config(particleCount: Int, color: SIMD3<Float>?) -> GalaxyConfig {
            var galaxy = GalaxyConfig(
                name: name,
                particleCount: particleCount,
                kind: kind,
                potential: potential,
                diskScaleLength: diskScaleLength,
                diskTruncation: diskTruncation,
                diskThickness: diskThickness,
                velocityDispersion: velocityDispersion,
                armCount: armCount,
                armStrength: armStrength,
                armPitch: armPitch,
                dustFraction: dustFraction,
                starFormingFraction: starFormingFraction,
                bulgeExtent: bulgeExtent,
                bulgeFraction: bulgeFraction,
                bulgeFlattening: bulgeFlattening,
                clumpiness: clumpiness,
                outskirtFraction: outskirtFraction,
                armIrregularity: armIrregularity,
                diskMassFraction: diskMassFraction,
                toomreQ: toomreQ,
                haloParticleRatio: haloParticleRatio,
                haloExtent: haloExtent,
                dissipationTime: dissipationTime,
                position: position,
                velocity: velocity,
                inclination: inclination,
                positionAngle: positionAngle,
                spin: spin)
            if let color { galaxy.color = color }
            return galaxy
        }
    }

    public enum ReadError: Error, CustomStringConvertible {
        case unsupportedVersion(Int)
        case noGalaxies
        case sharesDoNotSumToOne(Double)

        public var description: String {
            switch self {
            case .unsupportedVersion(let version):
                "scene file version \(version), this build reads \(SceneFile.currentVersion)"
            case .noGalaxies: "scene file has no galaxies"
            case .sharesDoNotSumToOne(let sum): "particle shares sum to \(sum), not 1"
            }
        }
    }

    /// The physics of a scene. Its softening and time step are taken as derived; set
    /// `softening` or `timeStep` afterwards to keep a value chosen by hand.
    public init(_ scene: SceneConfig) {
        let total = Double(max(scene.totalParticleCount, 1))
        version = Self.currentVersion
        name = scene.name
        seed = scene.seed
        solver = scene.solver
        timeStepScale = scene.timeStepScale
        openingAngle = scene.openingAngle
        centerSoftening = scene.centerSoftening
        galaxies = scene.galaxies.map { Galaxy($0, share: Double($0.particleCount) / total) }
        encounters = scene.encounters.isEmpty ? nil : scene.encounters
        draw = scene.draw
    }

    /// The scene at a given number of visible particles. Read back at the count it was written
    /// from, every galaxy gets exactly the particles it had. Colours are not part of the file;
    /// `palette` supplies them by galaxy, and any galaxy past its end keeps the default.
    public func scene(particleCount: Int, palette: [SIMD3<Float>] = []) -> SceneConfig {
        var counts = galaxies.map { Int(($0.particleShare * Double(particleCount)).rounded()) }
        if !counts.isEmpty {
            counts[0] = max(particleCount - counts.dropFirst().reduce(0, +), 0)
        }
        var scene = SceneConfig(
            name: name,
            galaxies: galaxies.indices.map { index in
                galaxies[index].config(
                    particleCount: counts[index],
                    color: palette.indices.contains(index) ? palette[index] : nil)
            },
            solver: solver,
            seed: seed,
            centerSoftening: centerSoftening,
            openingAngle: openingAngle)
        scene.timeStepScale = timeStepScale
        scene.encounters = encounters ?? []
        scene.draw = draw
        scene.retune()
        if let timeStep { scene.timeStep = timeStep }
        if let softening { scene.softening = softening }
        return scene
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func decoded(from data: Data) throws -> SceneFile {
        let file = try JSONDecoder().decode(SceneFile.self, from: data)
        guard file.version == currentVersion else {
            throw ReadError.unsupportedVersion(file.version)
        }
        guard !file.galaxies.isEmpty else { throw ReadError.noGalaxies }
        let sum = file.galaxies.reduce(0) { $0 + $1.particleShare }
        guard abs(sum - 1) < 1e-3, file.galaxies.allSatisfy({ $0.particleShare >= 0 }) else {
            throw ReadError.sharesDoNotSumToOne(sum)
        }
        return file
    }
}
