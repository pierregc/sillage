import Foundation
import Metal
import QuartzCore
import SillageCore
import simd

struct SplatUniforms {
    var viewProjection: simd_float4x4
    /// Simulated time of this frame and how to read it in megayears, so a knot's colour and
    /// brightness can be worked out from its own age rather than painted from a pattern.
    var time: Float
    var megayearsPerUnit: Float
    var ionisedMyr: Float
    var populationYoungMyr: Float
    var populationSpan: Float
    var populationLast: Float
    var luminosityNormalisation: Float
    var brightness: Float
    var dustStrength: Float
    var starSize: Float
    var projectionScale: Float
    var smoothingScale: Float
    var referenceArea: Float
    var minimumSize: Float
    var maximumSize: Float
    var galaxyTint: Float
    var slabNear: Float
    var slabScale: Float
    var pass: UInt32
}

struct BackgroundStar {
    var direction: SIMD4<Float>
    var color: SIMD4<Float>
}

struct BloomParams {
    var threshold: Float
    var softKnee: Float
    var pad0: Float = 0
    var pad1: Float = 0
}

struct CompositeParams {
    var bloomIntensity: Float
    var stretch: Float
    var saturation: Float
    var spikeIntensity: Float
    var skyLevel: Float
    var noiseLevel: Float
    var seed: Float
    var whitePoint: Float
    var fade: Float = 1
}

struct SpikeParams {
    var arms: UInt32
    var baseAngle: Float
    var length: Float
    var falloff: Float
    var samples: UInt32
    var pad0: Float = 0
    var pad1: Float = 0
    var pad2: Float = 0
}

public struct RenderSettings: Sendable {
    public var width: Int
    public var height: Int
    /// Renders at this multiple of the output resolution, then box-filters down.
    public var supersample: Int
    /// Emission per particle, expressed per million particles. Normalising by count keeps a
    /// scene looking the same whether it runs at 500 000 particles or at 20 million.
    public var brightness: Float
    /// Optical depth per dust particle, expressed per million particles so a scene keeps the
    /// same column density whichever count it runs at.
    public var dustStrength: Float
    /// Number of foreground field stars.
    public var starCount: Int
    /// Point size of the field stars before their magnitude scaling.
    public var starSize: Float
    /// How many local interparticle spacings a particle's kernel spans. This is the whole of
    /// the softness control: it scales the stored length in the shader, so it costs nothing to
    /// change and never rebuilds the tree.
    public var smoothingScale: Float
    /// Smallest and largest kernel a particle may cover, in output pixels.
    public var minimumKernel: Float
    public var maximumKernel: Float
    public var bloomThreshold: Float
    public var bloomSoftKnee: Float
    public var bloomIntensity: Float
    public var bloomLevels: Int
    /// Strength of the logarithmic stretch applied before tone mapping. 0 disables it.
    public var stretch: Float
    /// 1 leaves colour untouched, above 1 pushes the two disks further apart in hue.
    public var saturation: Float
    /// How far above the disk's own level a core has to be before it reads as white. Raise it
    /// and a bright nucleus keeps falling off instead of flattening into a disc.
    public var whitePoint: Float
    /// Diffraction arms: 6 for a segmented mirror, 4 for a Cassegrain spider, 0 for none.
    public var spikeArms: Int
    public var spikeLength: Float
    public var spikeIntensity: Float
    /// Sky background and detector noise, both in linear signal units before tone mapping.
    public var skyLevel: Float
    public var noiseLevel: Float
    /// How far the per-galaxy tint pulls the stars away from the colour their population
    /// implies. Zero is the physical answer; a little of it is what keeps stars torn out of
    /// one disk recognisable inside the other.
    public var galaxyTint: Float

    public init(
        width: Int = 1920,
        height: Int = 1080,
        supersample: Int = 2,
        brightness: Float = 0.15,
        dustStrength: Float = 0.055,
        starCount: Int = 46000,
        starSize: Float = 1.15,
        smoothingScale: Float = 1.9,
        minimumKernel: Float = 1.1,
        maximumKernel: Float = 64,
        bloomThreshold: Float = 0.55,
        bloomSoftKnee: Float = 0.6,
        bloomIntensity: Float = 0.22,
        bloomLevels: Int = 6,
        stretch: Float = 18,
        saturation: Float = 2.8,
        whitePoint: Float = 4.5,
        spikeArms: Int = 6,
        spikeLength: Float = 72,
        spikeIntensity: Float = 0.38,
        skyLevel: Float = 0.0018,
        noiseLevel: Float = 0.0016,
        galaxyTint: Float = 0.35
    ) {
        self.width = width
        self.height = height
        self.supersample = max(1, min(supersample, 4))
        self.brightness = brightness
        self.dustStrength = dustStrength
        self.starCount = starCount
        self.starSize = starSize
        self.smoothingScale = smoothingScale
        self.minimumKernel = minimumKernel
        self.maximumKernel = maximumKernel
        self.bloomThreshold = bloomThreshold
        self.bloomSoftKnee = bloomSoftKnee
        self.bloomIntensity = bloomIntensity
        self.bloomLevels = bloomLevels
        self.stretch = stretch
        self.saturation = saturation
        self.whitePoint = whitePoint
        self.spikeArms = spikeArms
        self.spikeLength = spikeLength
        self.spikeIntensity = spikeIntensity
        self.skyLevel = skyLevel
        self.noiseLevel = noiseLevel
        self.galaxyTint = galaxyTint
    }
}

public enum RenderError: Error, CustomStringConvertible {
    case noDevice
    case shaderCompilation(String)
    case pipelineCreation(String)
    case textureAllocation

    public var description: String {
        switch self {
        case .noDevice: "No Metal device available"
        case .shaderCompilation(let message): "Shader compilation failed: \(message)"
        case .pipelineCreation(let message): "Pipeline creation failed: \(message)"
        case .textureAllocation: "Could not allocate a render texture"
        }
    }
}

/// Accumulates particles additively into a supersampled HDR target, builds a Kawase
/// dual-filter bloom pyramid from it, then tone maps the sum to 8-bit sRGB.
public final class Renderer {
    public let device: MTLDevice
    public private(set) var settings: RenderSettings
    public private(set) var lastGPUTime: Double = 0
    private var frameSeed: Float = 1

    private let queue: MTLCommandQueue
    private let splatPipeline: MTLRenderPipelineState
    private let starfieldPipeline: MTLRenderPipelineState
    private let resolvePipeline: MTLComputePipelineState
    private let brightPassPipeline: MTLComputePipelineState
    private let downsamplePipeline: MTLComputePipelineState
    private let upsamplePipeline: MTLComputePipelineState
    private let compositePipeline: MTLComputePipelineState
    private let spikePipeline: MTLComputePipelineState

    private let accumulation: MTLTexture
    private let dustAccumulation: MTLTexture
    private let resolved: MTLTexture
    private let bloomDown: [MTLTexture]
    private let bloomUp: [MTLTexture]
    private let spikeTexture: MTLTexture
    public let output: MTLTexture

    private let positionBuffer: MTLBuffer
    private let populationBuffer: MTLBuffer
    private let formationBuffer: MTLBuffer
    /// Colour temperature and light per unit mass against age, computed once by
    /// `StellarPopulation` and read by every star in every frame.
    private let stellarBuffer: MTLBuffer
    /// Two things a particle carries that never change: how much cooler its composition makes
    /// it read, and how wide its kernel is drawn. Packed together because both are one float
    /// per particle written once, and a second buffer of twenty megabytes for one of them is
    /// not worth the tidiness.
    ///
    /// The composition is taken from `birthRadius` and not from where the particle stands now:
    /// a star flung out of a nucleus by an encounter keeps the composition of the nucleus.
    private let traitBuffer: MTLBuffer
    private let luminosityBuffer: MTLBuffer
    private let componentBuffer: MTLBuffer
    private let galaxyBuffer: MTLBuffer
    private var frameBuffer: MTLBuffer?
    private var smoothingBuffer: MTLBuffer?
    private var frameCount = 1
    private let starBuffer: MTLBuffer?
    private let particleCount: Int
    private let drawnCount: Int
    /// One over the mean light per unit mass across this scene at t = 0.
    ///
    /// The exposure divides by the *number* of particles that reach a pixel, so a law that
    /// makes some of them twenty times brighter than others would move the whole frame unless
    /// its mean is held at one. Taken once, from the ages the scene was sampled with; the
    /// drift as a run ages its stars is a part in a thousand over any run worth watching, and
    /// recomputing it per frame would make the exposure breathe.
    private let luminosityNormalisation: Float

    /// Framing at which the brightness and dust settings are calibrated, in kpc per pixel.
    static let referenceKpcPerPixel: Float = 0.0436

    /// The buffer holding particle positions, so a GPU solver can write into it directly.
    public var positions: MTLBuffer { positionBuffer }

    /// `externalPositions` lets a GPU solver own the position buffer, so particle state
    /// never crosses the bus between the integrator and the rasteriser.
    /// Strength multiplier on the density wave, 0 to disable it.
    public var armPersistence: Float = 1
    /// Master fade, 1 for the picture and 0 for black. Contemplation crossfades scenes
    /// through it; nothing else uses it.
    public var fade: Float = 1
    /// Simulated time of the frame being drawn, in code units. A knot's colour and brightness
    /// are read off its age, so the renderer has to know when now is.
    public var time: Float = 0

    public init(
        device: MTLDevice? = nil,
        particles: ParticleSystem,
        settings: RenderSettings,
        externalPositions: MTLBuffer? = nil,
        externalFormation: MTLBuffer? = nil
    ) throws {
        guard let device = device ?? MTLCreateSystemDefaultDevice() else {
            throw RenderError.noDevice
        }
        self.device = device
        self.settings = settings
        // Only what is drawn. Dark matter is discarded in the vertex shader anyway, so the
        // draw call stops before it: at three million stars with live halos that is four and a
        // half million vertices a frame that existed only to be thrown away.
        self.drawnCount = particles.visibleCount > 0 ? particles.visibleCount : particles.count
        self.particleCount = particles.count
        var totalLight: Float = 0
        var lit = 0
        let step = max(particles.formation.count / 50_000, 1)
        for index in stride(from: 0, to: particles.formation.count, by: step) {
            let born = particles.formation[index]
            guard born > -1e8, born < 1e8 else { continue }
            totalLight +=
                StellarPopulation.sampled(
                    ageMyr: -born * Float(Physics.megayearsPerTimeUnit)
                ).lightPerMass
            lit += 1
        }
        self.luminosityNormalisation = lit > 0 ? Float(lit) / max(totalLight, 1e-6) : 1

        let library: MTLLibrary
        do {
            library = try ShaderCache.library(Shaders.source, on: device)
        } catch {
            throw RenderError.shaderCompilation("\(error)")
        }

        func compute(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else {
                throw RenderError.pipelineCreation("missing kernel \(name)")
            }
            do {
                return try device.makeComputePipelineState(function: function)
            } catch {
                throw RenderError.pipelineCreation("\(name): \(error)")
            }
        }

        func additive(_ vertexFunction: String) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: vertexFunction)
            descriptor.fragmentFunction = library.makeFunction(name: "splatFragment")
            for (index, format) in [MTLPixelFormat.rgba16Float, .rgba16Float].enumerated() {
                guard let attachment = descriptor.colorAttachments[index] else { continue }
                attachment.pixelFormat = format
                attachment.isBlendingEnabled = true
                attachment.rgbBlendOperation = .add
                attachment.alphaBlendOperation = .add
                attachment.sourceRGBBlendFactor = .one
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationRGBBlendFactor = .one
                attachment.destinationAlphaBlendFactor = .one
            }
            do {
                return try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                throw RenderError.pipelineCreation("\(vertexFunction): \(error)")
            }
        }
        splatPipeline = try additive("splatVertex")
        starfieldPipeline = try additive("starfieldVertex")

        resolvePipeline = try compute("resolve")
        brightPassPipeline = try compute("brightPass")
        downsamplePipeline = try compute("downsample")
        upsamplePipeline = try compute("upsampleAdd")
        compositePipeline = try compute("composite")
        spikePipeline = try compute("diffractionSpikes")

        guard let queue = device.makeCommandQueue() else { throw RenderError.noDevice }
        self.queue = queue

        func texture(
            _ width: Int, _ height: Int, _ format: MTLPixelFormat, _ usage: MTLTextureUsage,
            shared: Bool = false
        ) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: max(width, 1), height: max(height, 1), mipmapped: false)
            descriptor.usage = usage
            descriptor.storageMode = shared ? .shared : .private
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw RenderError.textureAllocation
            }
            return texture
        }

        let scale = settings.supersample
        accumulation = try texture(
            settings.width * scale, settings.height * scale, .rgba16Float,
            [.renderTarget, .shaderRead])
        // Four channels, and they are four slabs of view depth rather than four colours: a
        // grain of dust writes into the slab it stands in, and a star reads back the ones in
        // front of it. That is the whole of what makes a lane pass in front of a bright
        // region rather than grey the picture down evenly.
        dustAccumulation = try texture(
            settings.width * scale, settings.height * scale, .rgba16Float,
            [.renderTarget, .shaderRead])
        resolved = try texture(
            settings.width, settings.height, .rgba16Float, [.shaderRead, .shaderWrite])

        var down: [MTLTexture] = []
        var up: [MTLTexture] = []
        var levelWidth = settings.width / 2
        var levelHeight = settings.height / 2
        while down.count < settings.bloomLevels && levelWidth >= 8 && levelHeight >= 8 {
            down.append(
                try texture(levelWidth, levelHeight, .rgba16Float, [.shaderRead, .shaderWrite]))
            up.append(
                try texture(levelWidth, levelHeight, .rgba16Float, [.shaderRead, .shaderWrite]))
            levelWidth /= 2
            levelHeight /= 2
        }
        bloomDown = down
        bloomUp = up

        spikeTexture = try texture(
            max(settings.width / 2, 1), max(settings.height / 2, 1), .rgba16Float,
            [.shaderRead, .shaderWrite])
        output = try texture(
            settings.width, settings.height, .rgba8Unorm, [.shaderRead, .shaderWrite], shared: true)

        let stride = MemoryLayout<SIMD3<Float>>.stride
        let count = max(particles.count, 1)
        // makeBuffer(bytes:length:) copies `length` bytes from the pointer it is given, so a
        // one-element stand-in would have it read off the end of the array. Fill the whole
        // length instead.
        func attribute<T>(_ values: [T], _ fallback: T) -> [T] {
            values.count == count ? values : [T](repeating: fallback, count: count)
        }
        guard
            let positionBuffer = externalPositions
                ?? device.makeBuffer(length: count * stride, options: .storageModeShared),
            let populationBuffer = device.makeBuffer(
                bytes: attribute(particles.population, Float(0.5)),
                length: count * 4, options: .storageModeShared),
            let formationBuffer = externalFormation
                ?? device.makeBuffer(
                    bytes: attribute(particles.formation, ParticleSystem.ancient),
                    length: count * 4, options: .storageModeShared),
            let luminosityBuffer = device.makeBuffer(
                bytes: attribute(particles.luminosity, Float(1)),
                length: count * 4, options: .storageModeShared),
            let componentBuffer = device.makeBuffer(
                bytes: attribute(particles.component, UInt32(0)),
                length: count * 4, options: .storageModeShared),
            let traitBuffer = device.makeBuffer(
                bytes: Renderer.traits(of: particles),
                length: count * MemoryLayout<SIMD2<Float>>.stride,
                options: .storageModeShared),
            let stellarBuffer = device.makeBuffer(
                bytes: StellarPopulation.table,
                length: StellarPopulation.samples * MemoryLayout<SIMD2<Float>>.stride,
                options: .storageModeShared),
            let galaxyBuffer = device.makeBuffer(
                bytes: attribute(particles.galaxyIndex, UInt32(0)),
                length: count * 4, options: .storageModeShared)
        else {
            throw RenderError.textureAllocation
        }
        self.galaxyBuffer = galaxyBuffer
        self.positionBuffer = positionBuffer
        self.populationBuffer = populationBuffer
        self.formationBuffer = formationBuffer
        self.luminosityBuffer = luminosityBuffer
        self.componentBuffer = componentBuffer
        self.stellarBuffer = stellarBuffer
        self.traitBuffer = traitBuffer
        self.starBuffer = Renderer.makeStarfield(device: device, count: settings.starCount)
        if externalPositions == nil {
            upload(positions: particles.positions)
        }
    }

    /// Field stars, placed far enough out that orbiting the galaxy does not parallax them.
    ///
    /// Colours are drawn as temperatures and converted by the same Planckian law the galaxy's
    /// own stars use, rather than picked out of three buckets by hand. The temperature
    /// distribution is the sky's: the overwhelming majority of stars are cool dwarfs, and the
    /// hot blue ones are rare and — because they are enormously more luminous — the ones that
    /// end up bright. Drawing brightness and colour together instead of independently is what
    /// makes a field read as a sky rather than as confetti.
    private static func makeStarfield(device: MTLDevice, count: Int) -> MTLBuffer? {
        guard count > 0 else { return nil }
        var generator = SeededGenerator(seed: 0x5111_1A6E)
        var stars: [BackgroundStar] = []
        stars.reserveCapacity(count)
        let shell: Float = 6_000

        for _ in 0..<count {
            let direction = DiskSampler.randomDirection(&generator)
            // Steeply weighted to the cool end, which is what a magnitude-limited field is.
            let heat = pow(generator.uniform(), 2.6)
            let kelvin = 3_000 * pow(28_000 / 3_000, heat)
            let colour = Blackbody.linearSRGB(kelvin: kelvin)
            // Hot stars are the bright ones, because they are enormously more luminous; the
            // exponent bends with temperature rather than a term being added, so that raising
            // the count adds faint stars and not bright ones. Added instead of bent, at ten
            // thousand stars, and the frame came out a wall of diffraction spikes with the
            // galaxy lost behind it.
            let magnitude = pow(generator.uniform(), 6.5 - 2.2 * heat)
            // And a spike belongs to the few that earn one. Every star having one is what
            // makes a field read as a graphic rather than as a sky.
            let spike = DiskSampler.smoothstep(0.80, 0.97, magnitude)
            stars.append(
                BackgroundStar(
                    direction: SIMD4<Float>(
                        direction.x * shell, direction.y * shell, direction.z * shell, magnitude),
                    color: SIMD4<Float>(colour.x, colour.y, colour.z, spike)))
        }
        return device.makeBuffer(
            bytes: stars, length: stars.count * MemoryLayout<BackgroundStar>.stride,
            options: .storageModeShared)
    }

    /// Binds the per-particle smoothing lengths. Without them every particle covers the same
    /// fixed number of pixels and the image resolves the sampling rather than the galaxy.
    public func setSmoothing(_ buffer: MTLBuffer?) { smoothingBuffer = buffer }

    /// Updates the spiral pattern for each galaxy. Called once per frame with the current
    /// galaxy centres and elapsed time, so the arms turn as a density wave.
    public func setDiskFrames(_ frames: [DiskFrame]) {
        guard !frames.isEmpty else { return }
        let length = frames.count * MemoryLayout<DiskFrame>.stride
        if frameBuffer == nil || frameCount != frames.count {
            frameBuffer = device.makeBuffer(length: length, options: .storageModeShared)
            frameCount = frames.count
        }
        frames.withUnsafeBytes { source in
            frameBuffer?.contents().copyMemory(from: source.baseAddress!, byteCount: source.count)
        }
    }

    /// Unified memory means this is a plain memcpy into a buffer the GPU already sees.
    public func upload(positions: [SIMD3<Float>]) {
        guard !positions.isEmpty else { return }
        positions.withUnsafeBytes { source in
            positionBuffer.contents().copyMemory(from: source.baseAddress!, byteCount: source.count)
        }
    }

    /// Everything a frame may change on its own, in one go. Resolution, supersampling, bloom
    /// levels and the starfield are deliberately absent: those own textures and buffers, and
    /// changing them means a new renderer.
    public func apply(_ look: RenderLook) {
        settings.brightness = look.brightness
        settings.dustStrength = look.dustStrength
        settings.smoothingScale = look.smoothingScale
        settings.minimumKernel = look.minimumKernel
        settings.maximumKernel = look.maximumKernel
        settings.bloomThreshold = look.bloomThreshold
        settings.bloomSoftKnee = look.bloomSoftKnee
        settings.bloomIntensity = look.bloomIntensity
        settings.stretch = look.stretch
        settings.saturation = look.saturation
        settings.whitePoint = look.whitePoint
        settings.spikeArms = look.spikeArms
        settings.spikeLength = look.spikeLength
        settings.spikeIntensity = look.spikeIntensity
        settings.skyLevel = look.skyLevel
        settings.noiseLevel = look.noiseLevel
        settings.galaxyTint = look.galaxyTint
        settings.starSize = look.starSize
        armPersistence = look.armPersistence
    }

    /// Encodes the whole frame. Pass a drawable texture to present, or nil to render offscreen.
    /// The colour-temperature multiplier each particle carries for its composition, one per
    /// particle, in the order the buffers are uploaded.
    ///
    /// Stored as the multiplier rather than as the abundance so that the slope relating the
    /// two lives in exactly one place, in `StellarPopulation`, instead of being written once
    /// here and once in the shader where it could drift.
    ///
    /// The scale length is measured off the sample rather than passed in: the renderer is not
    /// given the scene, and for an exponential disk the median radius is 1.678 scale lengths,
    /// which is a sturdier way to ask the question than trusting a configuration field to
    /// still describe the particles by the time they arrive here.
    private static func traits(of particles: ParticleSystem) -> [SIMD2<Float>] {
        let count = particles.count
        let scales =
            particles.kernelScale.count == count
            ? particles.kernelScale : [Float](repeating: 1, count: count)
        guard particles.birthRadius.count == count else {
            return (0..<max(count, 1)).map { SIMD2<Float>(1, $0 < scales.count ? scales[$0] : 1) }
        }
        var byGalaxy: [UInt32: [Float]] = [:]
        for index in 0..<count
        where particles.component[index] == ParticleComponent.star.rawValue {
            byGalaxy[particles.galaxyIndex[index], default: []].append(particles.birthRadius[index])
        }
        var scaleLength: [UInt32: Float] = [:]
        for (galaxy, radii) in byGalaxy where !radii.isEmpty {
            let sorted = radii.sorted()
            scaleLength[galaxy] = max(sorted[sorted.count / 2] / 1.678, 1e-3)
        }
        return (0..<count).map { index in
            guard let scale = scaleLength[particles.galaxyIndex[index]] else {
                return SIMD2<Float>(1, scales[index])
            }
            let warming = StellarPopulation.metallicityWarming(
                StellarPopulation.metallicity(
                    atScaleLengths: particles.birthRadius[index] / scale))
            return SIMD2<Float>(warming, scales[index])
        }
    }

    public func encode(camera: Camera, into buffer: MTLCommandBuffer, present: MTLTexture? = nil) {
        let scale = settings.supersample
        let aspect = Float(settings.width) / Float(settings.height)

        // Pixels per unit length at unit depth. The vertex shader divides a particle's
        // smoothing length by its view depth to get the kernel's size on screen.
        let projectionScale =
            Float(settings.height * scale) / (2 * tan(camera.fieldOfView / 2))
        // Conserving flux per particle already makes surface brightness independent of the
        // zoom, so no separate area correction is needed here.
        //
        // Over the particles that reach a pixel, not over every particle simulated. Dividing
        // by the whole count meant that turning live halos on dimmed a scene by the halo
        // ratio — two and a half at the default — because three particles in five are dark
        // matter that never lands on a pixel. Exposure per drawn particle is what keeps a
        // scene looking the same whether it runs at 500 000 stars or at twenty million,
        // which is the whole point of normalising by count at all.
        let perParticle = 1_000_000 / Float(max(drawnCount, 1))

        // The stack of depth slabs, centred on what the camera is pointed at and as deep as
        // the frame is wide. A disk seen at any angle at all spans several of them, which is
        // what lets its near side shadow its far side; seen exactly face-on it does not, and
        // it should not — a thin disk seen flat has no lane in front of anything.
        let distance = simd_length(camera.eye - camera.target)
        let halfExtent = distance * tan(camera.fieldOfView / 2)
        let slabNear = distance - halfExtent

        var splat = SplatUniforms(
            viewProjection: camera.viewProjection(aspectRatio: aspect),
            time: time,
            megayearsPerUnit: Float(Physics.megayearsPerTimeUnit),
            ionisedMyr: StarFormation.ionisedMyr,
            populationYoungMyr: Float(StellarPopulation.youngestMyr),
            populationSpan: log(Float(StellarPopulation.oldestMyr / StellarPopulation.youngestMyr)),
            populationLast: Float(StellarPopulation.samples - 1),
            luminosityNormalisation: luminosityNormalisation,
            brightness: settings.brightness * perParticle,
            dustStrength: settings.dustStrength * perParticle,
            starSize: settings.starSize * Float(scale),
            projectionScale: projectionScale,
            smoothingScale: settings.smoothingScale,
            referenceArea: 0.01,
            minimumSize: settings.minimumKernel * Float(scale),
            maximumSize: settings.maximumKernel * Float(scale),
            galaxyTint: settings.galaxyTint,
            slabNear: slabNear,
            slabScale: 1 / max(2 * halfExtent, 1e-3),
            pass: 0)

        let pass = MTLRenderPassDescriptor()
        for (index, target) in [accumulation, dustAccumulation].enumerated() {
            pass.colorAttachments[index].texture = target
            pass.colorAttachments[index].loadAction = .clear
            pass.colorAttachments[index].clearColor = MTLClearColor(
                red: 0, green: 0, blue: 0, alpha: 0)
            pass.colorAttachments[index].storeAction = .store
        }

        if let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) {
            encoder.setVertexBytes(&splat, length: MemoryLayout<SplatUniforms>.stride, index: 4)

            if let starBuffer {
                encoder.setRenderPipelineState(starfieldPipeline)
                encoder.setVertexBuffer(starBuffer, offset: 0, index: 0)
                encoder.drawPrimitives(
                    type: .point, vertexStart: 0, vertexCount: settings.starCount)
            }

            encoder.setRenderPipelineState(splatPipeline)
            encoder.setVertexBuffer(positionBuffer, offset: 0, index: 0)
            encoder.setVertexBuffer(populationBuffer, offset: 0, index: 1)
            encoder.setVertexBuffer(formationBuffer, offset: 0, index: 8)
            encoder.setVertexBuffer(luminosityBuffer, offset: 0, index: 2)
            encoder.setVertexBuffer(componentBuffer, offset: 0, index: 3)
            encoder.setVertexBuffer(galaxyBuffer, offset: 0, index: 5)
            encoder.setVertexBuffer(frameBuffer, offset: 0, index: 6)
            encoder.setVertexBuffer(smoothingBuffer, offset: 0, index: 7)
            encoder.setVertexBuffer(stellarBuffer, offset: 0, index: 9)
            encoder.setVertexBuffer(traitBuffer, offset: 0, index: 10)
            // Twice over the same buffer: the dust first, so that its opacity is standing in
            // the attachment when the stars are drawn and read it back. Each draw throws away
            // the particles belonging to the other one in the vertex stage, before any
            // fragment work, so the cost of the second pass is a vertex shader over the whole
            // buffer and nothing else.
            for stage in UInt32(0)...1 {
                splat.pass = stage
                encoder.setVertexBytes(
                    &splat, length: MemoryLayout<SplatUniforms>.stride, index: 4)
                encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: drawnCount)
            }
            encoder.endEncoding()
        }

        guard let compute = buffer.makeComputeCommandEncoder() else { return }

        var factor = UInt32(scale)
        dispatch(compute, resolvePipeline, into: resolved) { encoder in
            encoder.setTexture(accumulation, index: 0)
            encoder.setTexture(resolved, index: 2)
            encoder.setBytes(&factor, length: 4, index: 0)
        }

        var bloom = BloomParams(
            threshold: settings.bloomThreshold, softKnee: settings.bloomSoftKnee)
        if let first = bloomDown.first {
            dispatch(compute, brightPassPipeline, into: first) { encoder in
                encoder.setTexture(resolved, index: 0)
                encoder.setTexture(first, index: 1)
                encoder.setBytes(&bloom, length: MemoryLayout<BloomParams>.stride, index: 0)
            }
            for level in 1..<bloomDown.count {
                dispatch(compute, downsamplePipeline, into: bloomDown[level]) { encoder in
                    encoder.setTexture(bloomDown[level - 1], index: 0)
                    encoder.setTexture(bloomDown[level], index: 1)
                }
            }
        }

        var bloomResult = bloomDown.last
        if bloomDown.count > 1 {
            for level in stride(from: bloomDown.count - 1, to: 0, by: -1) {
                let destination = bloomUp[level - 1]
                let source = bloomResult!
                dispatch(compute, upsamplePipeline, into: destination) { encoder in
                    encoder.setTexture(source, index: 0)
                    encoder.setTexture(bloomDown[level - 1], index: 1)
                    encoder.setTexture(destination, index: 2)
                }
                bloomResult = destination
            }
        }

        // Spikes are gathered from the bright pass, so they pick up stars and galaxy cores
        // rather than the whole frame.
        var spike = SpikeParams(
            arms: UInt32(max(settings.spikeArms, 0)),
            baseAngle: 0.32,
            length: settings.spikeLength,
            falloff: 4.2,
            samples: 28)
        let spikeSource = bloomDown.first ?? resolved
        dispatch(compute, spikePipeline, into: spikeTexture) { encoder in
            encoder.setTexture(spikeSource, index: 0)
            encoder.setTexture(spikeTexture, index: 1)
            encoder.setBytes(&spike, length: MemoryLayout<SpikeParams>.stride, index: 0)
        }

        frameSeed = frameSeed.truncatingRemainder(dividingBy: 4096) + 7.13
        var composite = CompositeParams(
            bloomIntensity: bloomResult == nil ? 0 : settings.bloomIntensity,
            stretch: settings.stretch,
            saturation: settings.saturation,
            spikeIntensity: settings.spikeArms > 0 ? settings.spikeIntensity : 0,
            skyLevel: settings.skyLevel,
            noiseLevel: settings.noiseLevel,
            seed: frameSeed,
            whitePoint: settings.whitePoint,
            fade: min(max(fade, 0), 1))
        let target = present ?? output
        dispatch(compute, compositePipeline, into: target) { encoder in
            encoder.setTexture(resolved, index: 0)
            encoder.setTexture(bloomResult ?? resolved, index: 1)
            encoder.setTexture(target, index: 2)
            encoder.setTexture(spikeTexture, index: 3)
            encoder.setBytes(&composite, length: MemoryLayout<CompositeParams>.stride, index: 0)
        }
        compute.endEncoding()
    }

    private func dispatch(
        _ encoder: MTLComputeCommandEncoder,
        _ pipeline: MTLComputePipelineState,
        into texture: MTLTexture,
        configure: (MTLComputeCommandEncoder) -> Void
    ) {
        encoder.setComputePipelineState(pipeline)
        configure(encoder)
        let side = 16
        encoder.dispatchThreadgroups(
            MTLSize(
                width: (texture.width + side - 1) / side,
                height: (texture.height + side - 1) / side,
                depth: 1),
            threadsPerThreadgroup: MTLSize(width: side, height: side, depth: 1))
    }

    /// Renders straight into a view's drawable.
    /// Wall time the GPU spent on the last presented frame. The CPU side of `present` is
    /// encoding only — it commits and returns — so timing around the call measures nothing
    /// that matters. This is the number that decides whether a frame makes its vsync.
    /// How long the GPU spent on the last frame, from the command buffer's own clock.
    ///
    /// Held in a box rather than in the renderer, so the completion handler can write it
    /// without capturing `self`. It runs on whatever thread Metal finishes on, and it used to
    /// hop to the main actor to do the write — which captures a non-Sendable renderer into a
    /// main-actor closure from a task-isolated one, and is a data race the newer compiler on
    /// CI rejects outright while the one on this machine says nothing.
    public var lastGPUMilliseconds: Double { gpuClock.milliseconds }

    private let gpuClock = FrameClock()

    final class FrameClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0.0
        var milliseconds: Double {
            get {
                lock.lock()
                defer { lock.unlock() }
                return value
            }
            set {
                lock.lock()
                value = newValue
                lock.unlock()
            }
        }
    }

    public func present(camera: Camera, drawable: CAMetalDrawable) {
        guard let buffer = queue.makeCommandBuffer() else { return }
        encode(camera: camera, into: buffer, present: drawable.texture)
        let clock = gpuClock
        buffer.addCompletedHandler { finished in
            clock.milliseconds = (finished.gpuEndTime - finished.gpuStartTime) * 1000
        }
        buffer.present(drawable)
        buffer.commit()
    }

    /// Renders offscreen and reads the result back as 8-bit RGBA.
    public func render(camera: Camera) -> [UInt8] {
        guard let buffer = queue.makeCommandBuffer() else { return [] }
        encode(camera: camera, into: buffer)
        buffer.commit()
        buffer.waitUntilCompleted()
        lastGPUTime = buffer.gpuEndTime - buffer.gpuStartTime

        var pixels = [UInt8](repeating: 0, count: settings.width * settings.height * 4)
        pixels.withUnsafeMutableBytes { destination in
            output.getBytes(
                destination.baseAddress!,
                bytesPerRow: settings.width * 4,
                from: MTLRegionMake2D(0, 0, settings.width, settings.height),
                mipmapLevel: 0)
        }
        return pixels
    }

    public var gpuName: String { device.name }
}
