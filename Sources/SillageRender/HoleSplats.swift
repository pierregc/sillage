import Foundation
import SillageCore

#if canImport(simd)
    import simd
#endif

/// What `holeStep` reads; mirrors `HoleStepParams` in `HoleShaders`.
public struct HoleStepParams: Sendable {
    var count: UInt32
    var timeStep: Float
    var swallow: Float
    var subStepAngle: Float
    var maximumSubSteps: UInt32
    var gridRadii: UInt32
    var gridAngles: UInt32
    var gridHeights: UInt32
    var logInner: Float
    var logScale: Float
    var heightCell: Float
    var stickiness: Float
    var crossing: Float
    var viscosity: Float
    var cooling: Float

    /// A step of `scene` over `count` tracers and the grid `gas`, for Metal and CUDA alike (#336).
    public init(scene: TidalDisruption, gas: GasGrid, count: Int) {
        let inner = log(scene.swallow)
        self.init(
            count: UInt32(count), timeStep: scene.timeStep, swallow: scene.swallow,
            subStepAngle: TidalDisruption.subStepAngle,
            maximumSubSteps: UInt32(TidalDisruption.maximumSubSteps),
            gridRadii: UInt32(gas.radii), gridAngles: UInt32(gas.angles),
            gridHeights: UInt32(gas.heights), logInner: inner,
            logScale: Float(gas.radii) / (log(gas.outer) - inner), heightCell: gas.heightCell,
            stickiness: scene.stickiness, crossing: scene.crossingSpeed,
            viscosity: scene.viscousOrbits > 0 ? 1 / scene.viscousOrbits : 0,
            cooling: scene.coolingTime)
    }

    init(
        count: UInt32, timeStep: Float, swallow: Float, subStepAngle: Float, maximumSubSteps: UInt32,
        gridRadii: UInt32, gridAngles: UInt32, gridHeights: UInt32, logInner: Float, logScale: Float,
        heightCell: Float, stickiness: Float, crossing: Float, viscosity: Float, cooling: Float
    ) {
        self.count = count
        self.timeStep = timeStep
        self.swallow = swallow
        self.subStepAngle = subStepAngle
        self.maximumSubSteps = maximumSubSteps
        self.gridRadii = gridRadii
        self.gridAngles = gridAngles
        self.gridHeights = gridHeights
        self.logInner = logInner
        self.logScale = logScale
        self.heightCell = heightCell
        self.stickiness = stickiness
        self.crossing = crossing
        self.viscosity = viscosity
        self.cooling = cooling
    }
}

/// The grid of the mean flow the gas is made of: cells in log r by angle by height over the
/// radius, as tall as wide. One layer is the spike's (#314), where a stream squeezed through the
/// plane counts as streams crossing.
public struct GasGrid: Sendable, Equatable, Codable {
    public var radii = 192
    public var angles = 384
    public var heights = 32
    /// How tall a cell is, over its distance from the axis.
    public var heightCell: Float = 1.0 / 64
    public var outer: Float = 200

    public init() {}

    public var cells: Int { radii * angles * heights }
    public var columns: Int { radii * angles }
}

/// A run of a tidal disruption on a GPU, Metal's `TidalRun` or CUDA's, as a take's replay steps it.
public protocol TidalStepping: AnyObject {
    var stepsTaken: Int { get }
    var frame: TidalFrame { get }
    func step(_ steps: Int)
    /// Goes on from a frame of a take of the same scene, `step` steps after the release.
    func resume(from frame: TidalFrame, step: Int)
}

extension HoleTakeFile.Loaded {
    /// Steps `run` on to `step`, from the frame kept before it when that is nearer or `step` lies
    /// behind; the frame there, as the run had it, or `held` when the run is there already.
    public func seek(_ step: Int, run: TidalStepping, held: TidalFrame) -> TidalFrame {
        var frame = held
        let index = frameIndex(before: step)
        let kept = header.steps[index]
        if step < run.stepsTaken || kept > run.stepsTaken {
            frame = self.frame(index)
            run.resume(from: frame, step: kept)
        }
        if step > run.stepsTaken {
            run.step(step - run.stepsTaken)
            frame = run.frame
        }
        return frame
    }

    /// The step of the run nearest `time`, within the take.
    public func step(at time: Double) -> Int {
        min(max(Int(((time - header.releaseTime) / header.timeStep).rounded()), 0), header.steps.last ?? 0)
    }
}

/// What `holeSplatVertex` reads; mirrors `HoleSplatUniforms` in `HoleShaders`.
public struct HoleSplatUniforms: Sendable {
    var viewProjection: simd_float4x4
    var camera: SIMD4<Float>
    var projectionScale: Float
    var particleSize: Float
    var minimumSize: Float
    var maximumSize: Float
    var brightness: Float
    var hottest: Float
    var image: UInt32
    var lensed: UInt32
    var radiusCount: UInt32
    var angleCount: UInt32
    var lensInner: Float
    var lensSpan: Float
    var beaming: Float
    var shadowAngle: Float
    var temperature: UInt32
    var crossingScale: Float
    var lightScale: Float
    var ambient: Float
    var innerEdge: Float
    var edgePeak: Float
    var supersample: Float
    var stars: UInt32 = 0
    var lensNear: Float = 0
    var lensFar: Float = 0
    var lensBlend: Float = 0
    var thinning: Float = 0

    /// The same uniforms for another of the images the lens makes.
    public func drawing(image: Int) -> HoleSplatUniforms {
        var uniforms = self
        uniforms.image = UInt32(image)
        return uniforms
    }
}

/// How a tidal disruption's frame is drawn (#314).
public struct HoleLook: Sendable {
    public enum Temperature: String, Sendable, CaseIterable {
        /// A thin disk's: T falls as r^-3/4 past the last stable orbit, whatever the gas does.
        case radius
        /// The run's: the heat the stream's crossings and the viscosity give each tracer.
        case crossing
    }

    /// Bent by the hole, or drawn straight with the shadow hiding what is behind it.
    public var lensed = true
    /// Images drawn: 1 the direct one, 2 with the one that passes behind the hole, 3 with the
    /// next, in the photon ring.
    public var images = 2
    /// The images that go round the hole are squeezed into the thin ring round the shadow, a
    /// hundredth as bright as the direct one, where drawing every tracer cost three times the
    /// direct image. Where the table makes an image fainter than this, it is drawn for that
    /// share of the tracers, each as many times brighter, so its splats lie no sparser than
    /// the direct image's and none is brighter than this share of a direct splat; 0 draws all.
    public var thinning: Float = 0.5
    public var temperature = Temperature.crossing
    /// Kelvin at the hottest: the thin disk's peak, or the run's brightest few per thousand.
    public var hottest: Float = 6500
    /// 1 for the Doppler shift and the redshift as they are, 0 for none.
    public var beaming: Float = 1
    public var exposure: Float = 1
    /// Light every tracer gives whatever its heat, against the mean of the heated ones, so
    /// that a cold stream still shows, dim and red.
    public var ambient: Float = 0.02
    /// A tracer's kernel, in Schwarzschild radii, between two sizes in output pixels.
    public var particleSize: Float = 0.05
    public var minimumSize: Float = 1.3
    public var maximumSize: Float = 24
    /// Field stars far behind the hole, which the lens bends as it bends the disk.
    public var stars = 8000
    public var starBrightness: Float = 1

    public init() {}

    /// The post stages' settings: Sillage's, softer, with no field stars and no spikes.
    public static func settings(width: Int, height: Int, supersample: Int = 2) -> RenderSettings {
        var settings = RenderSettings(
            width: width, height: height, supersample: supersample, starCount: 0,
            bloomThreshold: 0.6, bloomSoftKnee: 0.6, bloomIntensity: 0.35, bloomLevels: 6,
            stretch: 6, saturation: 1.6, whitePoint: 6, spikeArms: 0, spikeLength: 0,
            spikeIntensity: 0, skyLevel: 0.0006, noiseLevel: 0.0008, galaxyTint: 0)
        settings.columnSmoothing = 0
        return settings
    }
}

extension HoleLookFile {
    /// What the renderer draws with.
    public var renderLook: HoleLook {
        var look = HoleLook()
        look.lensed = lensed
        look.images = images
        look.temperature = temperature == .radius ? .radius : .crossing
        look.hottest = Float(hottest)
        look.beaming = Float(beaming)
        look.exposure = Float(exposure)
        look.ambient = Float(ambient)
        look.particleSize = Float(particleSize)
        look.thinning = Float(thinning)
        look.stars = stars
        look.starBrightness = Float(starBrightness)
        return look
    }

    /// The post stages at a size: `HoleLook.settings`, with the look's tone where it gives one.
    public func settings(width: Int, height: Int) -> RenderSettings {
        var settings = HoleLook.settings(width: width, height: height)
        if let stretch { settings.stretch = Float(stretch) }
        if let bloom { settings.bloomIntensity = Float(bloom) }
        if let whitePoint { settings.whitePoint = Float(whitePoint) }
        if let saturation { settings.saturation = Float(saturation) }
        return settings
    }
}

/// What a frame's light is normalised by: the tracers not yet swallowed, the mean light of each
/// temperature law over them, and the run's flux at which the brightest few per thousand reach
/// the hottest, measured on the frame's tracers on the CPU for both renderers (#336).
public struct HoleExposure: Sendable {
    /// Holds the exposure of the frame it was first set on, for a video that should not
    /// breathe with the light a frame happens to hold.
    public var fixed = false
    /// Share of the last frame's normalisation a new frame keeps, so that a run's video eases
    /// between the light of one moment and the next instead of jumping; 0 for none.
    public var easing: Float = 0
    public private(set) var alive: Float = 1
    public private(set) var meanLight: [HoleLook.Temperature: Float] = [:]
    public private(set) var crossingScale: Float = 1
    private var measured = false

    public init() {}

    public mutating func measure(_ frame: TidalFrame) {
        guard !(fixed && measured) else { return }
        measured = true
        var heats: [Float] = []
        var fluxes: [Float] = []
        var disk: Float = 0
        let stride = max(frame.count / 200_000, 1)
        for index in Swift.stride(from: 0, to: frame.count, by: stride) where frame.velocities[index].w >= 0 {
            let p = frame.positions[index]
            let heat = max(p.w, 0)
            heats.append(heat)
            fluxes.append(heat * frame.velocities[index].w)
            let shape = Self.diskShape(radius: simd_length(SIMD3<Float>(p.x, p.y, p.z)))
            disk += shape * shape * shape * shape
        }
        let count = Float(max(heats.count, 1))
        alive = count * Float(stride)
        fluxes.sort()
        let top = fluxes.isEmpty ? 1 : fluxes[min(Int(Float(fluxes.count) * 0.997), fluxes.count - 1)]
        let measured: [HoleLook.Temperature: Float] = [
            .crossing: max(heats.reduce(0, +) / count, 1e-30), .radius: max(disk / count, 1e-30),
        ]
        let scale = top > 0 ? 1 / top : 1
        let keep = meanLight.isEmpty ? 0 : easing
        func eased(_ old: Float, _ new: Float) -> Float { exp(log(old) * keep + log(new) * (1 - keep)) }
        for (law, value) in measured { meanLight[law] = eased(meanLight[law] ?? value, value) }
        crossingScale = eased(crossingScale, scale)
    }

    static let innerEdge = TidalDisruption.innermostStableOrbit
    /// The largest value of x^3/4 (1 - √x)^1/4, at x = 36/49.
    static let edgePeak: Float = {
        let x: Float = 36 / 49
        return pow(x, 0.75) * pow(1 - x.squareRoot(), 0.25)
    }()

    static func diskShape(radius: Float) -> Float {
        let x = innerEdge / max(radius, 1e-3)
        return x >= 1 ? 0 : pow(x, 0.75) * pow(1 - x.squareRoot(), 0.25) / edgePeak
    }
}

/// The draws of a frame of the close up, which both renderers make (#336): the tracers once per
/// image the lens table gives, then the field stars once per image, each with its uniforms.
public struct HoleSplats: Sendable {
    /// The tracers' uniforms, for image 0.
    public let tracers: HoleSplatUniforms
    /// The field stars', for image 0, or nil when none are drawn.
    public let stars: HoleSplatUniforms?
    /// Images drawn of each.
    public let images: Int

    /// `near` and `far` are the lens tables round the camera with the far one's share and the
    /// distance used, as `HoleLensSet.pair` gives them; `starCount` the field stars placed.
    public init(
        settings: RenderSettings, camera: Camera, look: HoleLook, exposure: HoleExposure, near: HoleLens,
        far: HoleLens, blend: Float, distance: Float, starCount: Int
    ) {
        let scale = Float(settings.supersample)
        let aspect = Float(settings.width) / Float(settings.height)
        tracers = HoleSplatUniforms(
            viewProjection: camera.viewProjection(aspectRatio: aspect),
            camera: SIMD4<Float>(camera.eye, distance),
            projectionScale: Float(settings.height) * scale / 2 / tan(camera.fieldOfView / 2),
            particleSize: look.particleSize, minimumSize: look.minimumSize * scale,
            maximumSize: look.maximumSize * scale,
            brightness: look.exposure * 1e5 / (exposure.alive * (1 + look.ambient)), hottest: look.hottest,
            image: 0, lensed: look.lensed ? 1 : 0, radiusCount: UInt32(near.radiusCount),
            angleCount: UInt32(near.angleCount), lensInner: near.minimumRadius,
            lensSpan: log(near.maximumRadius / near.minimumRadius), beaming: look.beaming,
            shadowAngle: HoleLens.shadowAngle(cameraDistance: distance),
            temperature: look.temperature == .radius ? 0 : 1,
            crossingScale: exposure.crossingScale,
            lightScale: 1 / (exposure.meanLight[look.temperature] ?? 1),
            ambient: look.ambient, innerEdge: HoleExposure.innerEdge,
            edgePeak: HoleExposure.edgePeak, supersample: scale, lensNear: near.cameraDistance,
            lensFar: far.cameraDistance, lensBlend: blend, thinning: max(look.thinning, 0))
        images = look.lensed ? min(max(look.images, 1), near.images) : 1
        if starCount > 0, look.starBrightness > 0 {
            var field = tracers
            field.stars = 1
            field.beaming = 0
            field.particleSize = 0
            field.brightness = look.starBrightness * look.exposure
            field.thinning = 0
            stars = field
        } else {
            stars = nil
        }
    }

    /// Field stars on a sphere `radius` from the hole: uniform over the sky, a few bright among
    /// many faint, from red dwarfs' colour to blue giants', the same every time. Their light in
    /// position w, their kelvin in colour w.
    public static func fieldStars(_ count: Int, radius: Float = 2000) -> (
        positions: [SIMD4<Float>], colours: [SIMD4<Float>]
    ) {
        var generator = SeededGenerator(seed: 314)
        var positions: [SIMD4<Float>] = []
        var colours: [SIMD4<Float>] = []
        for _ in 0..<count {
            let z = generator.uniform(in: -1...1)
            let angle = generator.uniform() * 2 * .pi
            let ring = (1 - z * z).squareRoot()
            let light = 0.0015 * pow(max(generator.uniform(), 1e-4), -1.5)
            let kelvin = 3000 + 9000 * pow(generator.uniform(), 2)
            positions.append(
                SIMD4<Float>(
                    ring * cos(angle) * radius, ring * sin(angle) * radius, z * radius, min(light, 1.5)))
            colours.append(SIMD4<Float>(0, 0, 0, kelvin))
        }
        return (positions, colours)
    }
}
