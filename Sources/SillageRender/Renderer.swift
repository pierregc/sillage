import Foundation
import Metal
import QuartzCore
import SillageCore
import simd

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
    var skyRed: Float = 0.36
    var skyGreen: Float = 0.42
    var skyBlue: Float = 0.60
}

struct SpikeParams {
    var arms: UInt32
    var baseAngle: Float
    var length: Float
    var falloff: Float
    var samples: UInt32
    var shortArms: UInt32 = 0
    var shortBaseAngle: Float = 0
    var shortScale: Float = 0
}

public enum RenderError: Error, CustomStringConvertible {
    case noDevice
    case shaderCompilation(String)
    case pipelineCreation(String)
    case textureAllocation
    case unsupported(String)

    public var description: String {
        switch self {
        case .noDevice: "No Metal device available"
        case .shaderCompilation(let message): "Shader compilation failed: \(message)"
        case .pipelineCreation(let message): "Pipeline creation failed: \(message)"
        case .textureAllocation: "Could not allocate a render texture"
        case .unsupported(let message): "Not supported: \(message)"
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
    private let dustPipeline: MTLRenderPipelineState
    private let splatPipeline: MTLRenderPipelineState
    private let starfieldPipeline: MTLRenderPipelineState
    private let plainPipeline: MTLRenderPipelineState
    private let plainCompositePipeline: MTLComputePipelineState
    private let resolvePipeline: MTLComputePipelineState
    private let brightPassPipeline: MTLComputePipelineState
    private let downsamplePipeline: MTLComputePipelineState
    private let upsamplePipeline: MTLComputePipelineState
    private let compositePipeline: MTLComputePipelineState
    private let spikePipeline: MTLComputePipelineState
    private let compactPipeline: MTLComputePipelineState
    private let countPipeline: MTLRenderPipelineState
    private let library: MTLLibrary
    /// What a frame with the dust web draws with, built the first time one is drawn.
    private var webPass: DustWeb.Pass?
    private var webUnavailable = false

    private let accumulation: MTLTexture
    private let dustAccumulation: MTLTexture
    /// Emitting particles per cell of `columnCell` accumulation pixels, for the projected
    /// kernel.
    private let columnDensity: MTLTexture
    static let columnCell = FramePlan.columnCell
    private let resolved: MTLTexture
    private let bloomDown: [MTLTexture]
    private let bloomUp: [MTLTexture]
    private let spikeTexture: MTLTexture
    /// Source and result of sharp spikes, at a quarter of the output size: their source is
    /// no finer than that, and gathering at half size cost a millisecond a frame on Webb.
    private let sharpSource: MTLTexture
    private let sharpSpikes: MTLTexture
    static let spikeVisible: Float = 0.0001
    /// Webb's horizontal strut spikes, as a fraction of the long ones.
    static let webbShortArm: Float = 0.4
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
    /// Each particle's birth radius in its galaxy's scale lengths, where the colour ramps
    /// look it up (#119).
    private let rampKeyBuffer: MTLBuffer
    /// One `GalaxyRamp` per galaxy; none of them mapped until a look gives ramps.
    private let rampBuffer: MTLBuffer
    private let galaxySlots: Int
    private var mapped = false
    private var galaxyColours: [GalaxyColours] = []
    private let luminosityBuffer: MTLBuffer
    private let componentBuffer: MTLBuffer
    private let galaxyBuffer: MTLBuffer
    private var frameBuffer: MTLBuffer?
    private var smoothingBuffer: MTLBuffer?
    private var frameCount = 1
    private let starBuffer: MTLBuffer?
    private let particleCount: Int
    private let drawnCount: Int
    /// Where the massive particles start in `positionBuffer`, behind the light tracers.
    private let positionOffset: Int
    /// Light tracers drawn beside the massive particles, from the solver's own buffers (#238).
    private var tracers: TracerDrawing?
    private var tracerPipelines: TracerPipelines?
    /// A spacing for tracers drawn before there is a tree to read one off.
    private var tracerFallback: MTLBuffer?
    /// Each galaxy's scale length, in which a tracer's composition and ramp key are read.
    private let tracerScales: [Float]
    private var tracerCount: Int { tracers?.tracerCount ?? 0 }

    private struct TracerPipelines {
        let dust: MTLRenderPipelineState
        let splat: MTLRenderPipelineState
        let plain: MTLRenderPipelineState
        let count: MTLRenderPipelineState
    }
    /// One over the mean light per unit mass across this scene at t = 0.
    ///
    /// The exposure divides by the *number* of particles that reach a pixel, so a law that
    /// makes some of them twenty times brighter than others would move the whole frame unless
    /// its mean is held at one. Taken once, from the ages the scene was sampled with; the
    /// drift as a run ages its stars is a part in a thousand over any run worth watching, and
    /// recomputing it per frame would make the exposure breathe. Set from another set of
    /// particles when a run is drawn as a take of it would be (#239).
    public var luminosityNormalisation: Float

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

    /// `sharing` reads the particles of another renderer from its own buffers, `particles`
    /// left empty: see `init(sharing:settings:)`.
    public init(
        device: MTLDevice? = nil,
        particles: ParticleSystem,
        settings: RenderSettings,
        externalPositions: MTLBuffer? = nil,
        externalFormation: MTLBuffer? = nil,
        externalPositionOffset: Int = 0,
        sharing other: Renderer? = nil
    ) throws {
        guard let device = other?.device ?? device ?? MTLCreateSystemDefaultDevice() else {
            throw RenderError.noDevice
        }
        self.device = device
        self.settings = settings
        self.positionOffset =
            other?.positionOffset ?? (externalPositions == nil ? 0 : externalPositionOffset)
        // Only what is drawn. Dark matter is discarded in the vertex shader anyway, so the
        // draw call stops before it: at three million stars with live halos that is four and a
        // half million vertices a frame that existed only to be thrown away.
        let attributes = ParticleAttributes(particles)
        self.drawnCount = other?.drawnCount ?? attributes.drawnCount
        self.particleCount = other?.particleCount ?? particles.count
        self.luminosityNormalisation =
            other?.luminosityNormalisation ?? attributes.luminosityNormalisation

        let library: MTLLibrary
        do {
            library = try ShaderCache.library(Shaders.source, on: device)
        } catch {
            throw RenderError.shaderCompilation("\(error)")
        }
        self.library = library

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

        func additive(
            _ vertexFunction: String, _ fragmentFunction: String, writing target: Int,
            attachments: Int = 2, format: MTLPixelFormat = .rgba16Float
        ) throws -> MTLRenderPipelineState {
            try Renderer.additive(
                vertexFunction, fragmentFunction, writing: target, attachments: attachments,
                format: format, library: library, device: device)
        }
        dustPipeline = try additive("splatVertex", "dustFragment", writing: 1)
        splatPipeline = try additive("splatVertex", "splatFragment", writing: 0)
        starfieldPipeline = try additive("starfieldVertex", "starfieldFragment", writing: 0)
        plainPipeline = try additive(
            "plainVertex", "plainFragment", writing: 0, attachments: 1)
        plainCompositePipeline = try compute("plainComposite")
        countPipeline = try additive(
            "countVertex", "countFragment", writing: 0, attachments: 1, format: .r32Float)

        resolvePipeline = try compute("resolve")
        brightPassPipeline = try compute("brightPass")
        downsamplePipeline = try compute("downsample")
        upsamplePipeline = try compute("upsampleAdd")
        compositePipeline = try compute("composite")
        spikePipeline = try compute("diffractionSpikes")
        compactPipeline = try compute("compactLight")

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
            settings.plain ? 1 : settings.width * scale, settings.plain ? 1 : settings.height * scale,
            .rgba16Float, [.renderTarget, .shaderRead])
        resolved = try texture(
            settings.width, settings.height, .rgba16Float, [.shaderRead, .shaderWrite])
        columnDensity = try texture(
            settings.plain ? 1 : settings.width * scale / Self.columnCell,
            settings.plain ? 1 : settings.height * scale / Self.columnCell,
            .r32Float, [.renderTarget, .shaderRead])

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
        sharpSource = try texture(
            max(settings.width / 4, 1), max(settings.height / 4, 1), .rgba16Float,
            [.shaderRead, .shaderWrite])
        sharpSpikes = try texture(
            max(settings.width / 4, 1), max(settings.height / 4, 1), .rgba16Float,
            [.shaderRead, .shaderWrite])
        output = try texture(
            settings.width, settings.height, .rgba8Unorm, [.shaderRead, .shaderWrite], shared: true)

        let stride = MemoryLayout<SIMD3<Float>>.stride
        // Every array of `attributes` holds `count` values: makeBuffer(bytes:length:) copies
        // `length` bytes from the pointer it is given, so a one-element stand-in would have it
        // read off the end of the array.
        let count = attributes.count
        tracerScales = other?.tracerScales ?? attributes.tracerScales
        guard
            let positionBuffer = other?.positionBuffer ?? externalPositions
                ?? device.makeBuffer(length: count * stride, options: .storageModeShared),
            let populationBuffer = other?.populationBuffer
                ?? device.makeBuffer(
                    bytes: attributes.population,
                    length: count * 4, options: .storageModeShared),
            let formationBuffer = other?.formationBuffer ?? externalFormation
                ?? device.makeBuffer(
                    bytes: attributes.formation,
                    length: count * 4, options: .storageModeShared),
            let luminosityBuffer = other?.luminosityBuffer
                ?? device.makeBuffer(
                    bytes: attributes.luminosity,
                    length: count * 4, options: .storageModeShared),
            let componentBuffer = other?.componentBuffer
                ?? device.makeBuffer(
                    bytes: attributes.component,
                    length: count * 4, options: .storageModeShared),
            let traitBuffer = other?.traitBuffer
                ?? device.makeBuffer(
                    bytes: attributes.traits,
                    length: count * MemoryLayout<SIMD2<Float>>.stride,
                    options: .storageModeShared),
            let rampKeyBuffer = other?.rampKeyBuffer
                ?? device.makeBuffer(
                    bytes: attributes.rampKeys,
                    length: count * 4,
                    options: .storageModeShared),
            let stellarBuffer = other?.stellarBuffer
                ?? device.makeBuffer(
                    bytes: StellarPopulation.table,
                    length: StellarPopulation.samples * MemoryLayout<SIMD2<Float>>.stride,
                    options: .storageModeShared),
            let galaxyBuffer = other?.galaxyBuffer
                ?? device.makeBuffer(
                    bytes: attributes.galaxy,
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
        self.rampKeyBuffer = rampKeyBuffer
        galaxySlots = other?.galaxySlots ?? attributes.galaxySlots
        guard
            let rampBuffer = device.makeBuffer(
                bytes: [GalaxyRamp](repeating: .none, count: galaxySlots),
                length: galaxySlots * MemoryLayout<GalaxyRamp>.stride,
                options: .storageModeShared)
        else { throw RenderError.textureAllocation }
        self.rampBuffer = rampBuffer
        self.starBuffer = Renderer.makeStarfield(device: device, count: settings.starCount)
        if externalPositions == nil, other == nil {
            upload(positions: particles.positions)
        }
        if let source = other?.tracers { try setTracers(source) }
    }

    /// A renderer of its own size and look over the particles `other` draws: the buffers that
    /// hold a value a particle are `other`'s, so a run drawn in several formats pays for them
    /// once (#239). Its colours, arms and smoothing are set on it as on any other.
    public convenience init(sharing other: Renderer, settings: RenderSettings) throws {
        try self.init(particles: ParticleSystem(), settings: settings, sharing: other)
    }

    /// One over the mean light per unit mass of particles formed at `formation`, read on about
    /// fifty thousand of them.
    public static func luminosityNormalisation(formation: [Float]) -> Float {
        ParticleAttributes.luminosityNormalisation(formation: formation)
    }

    /// The field stars `BackgroundStar.field` draws, in a buffer.
    private static func makeStarfield(device: MTLDevice, count: Int) -> MTLBuffer? {
        let stars = BackgroundStar.field(count: count)
        guard !stars.isEmpty else { return nil }
        return device.makeBuffer(
            bytes: stars, length: stars.count * MemoryLayout<BackgroundStar>.stride,
            options: .storageModeShared)
    }

    /// Binds the per-particle smoothing lengths. Without them every particle covers the same
    /// fixed number of pixels and the image resolves the sampling rather than the galaxy.
    public func setSmoothing(_ buffer: MTLBuffer?) { smoothingBuffer = buffer }

    /// Moves the grain on as `count` frames drawn would, for a run that resumes (#240).
    public func skipFrames(_ count: Int) {
        guard !settings.plain else { return }
        for _ in 0..<max(count, 0) { frameSeed = frameSeed.truncatingRemainder(dividingBy: 4096) + 7.13 }
    }

    /// Draws the light tracers `source` holds beside the massive particles (#238), each with
    /// the kernel the massive tree around it gives; nil draws none.
    public func setTracers(_ source: TracerDrawing?) throws {
        tracers = source
        guard source != nil, tracerPipelines == nil else { return }
        func additive(
            _ vertexFunction: String, _ fragmentFunction: String, writing target: Int,
            attachments: Int = 2, format: MTLPixelFormat = .rgba16Float
        ) throws -> MTLRenderPipelineState {
            try Renderer.additive(
                vertexFunction, fragmentFunction, writing: target, attachments: attachments,
                format: format, library: library, device: device)
        }
        tracerPipelines = TracerPipelines(
            dust: try additive("splatTracerVertex", "dustFragment", writing: 1),
            splat: try additive("splatTracerVertex", "splatFragment", writing: 0),
            plain: try additive("plainTracerVertex", "plainFragment", writing: 0, attachments: 1),
            count: try additive(
                "countTracerVertex", "countFragment", writing: 0, attachments: 1, format: .r32Float))
        var fallback = SIMD4<UInt32>(Float(0.05).bitPattern, 0, 0, 0)
        tracerFallback = device.makeBuffer(bytes: &fallback, length: 16, options: .storageModeShared)
    }

    private static func additive(
        _ vertexFunction: String, _ fragmentFunction: String, writing target: Int,
        attachments: Int, format: MTLPixelFormat, library: MTLLibrary, device: MTLDevice
    ) throws -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: vertexFunction)
        descriptor.fragmentFunction = library.makeFunction(name: fragmentFunction)
        for (index, format) in [format, format].prefix(attachments).enumerated() {
            guard let attachment = descriptor.colorAttachments[index] else { continue }
            attachment.pixelFormat = format
            attachment.writeMask = index == target ? .all : []
            attachment.isBlendingEnabled = index == target
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
            throw RenderError.pipelineCreation("\(fragmentFunction): \(error)")
        }
    }

    /// The tracers' buffers, at indices no massive draw binds, so one encoder serves both.
    private func bindTracers(_ encoder: MTLRenderCommandEncoder, _ source: TracerDrawing) {
        encoder.setVertexBuffer(source.positions, offset: 0, index: 18)
        encoder.setVertexBuffer(source.velocities, offset: 0, index: 19)
        var scales = tracerScales
        encoder.setVertexBytes(&scales, length: scales.count * 4, index: 17)
        let spacing = source.tracerSpacing
        var depth = UInt32(spacing?.depth ?? 0)
        encoder.setVertexBuffer(spacing?.cells ?? tracerFallback, offset: 0, index: 14)
        encoder.setVertexBuffer(spacing?.frame ?? tracerFallback, offset: 0, index: 15)
        encoder.setVertexBytes(&depth, length: 4, index: 16)
    }

    /// `particles`, counted over `[massive drawn | tracers]`, split into the two draws' ranges.
    private func split(_ particles: Range<Int>) -> (massive: Range<Int>, tracers: Range<Int>) {
        let massive = particles.clamped(to: 0..<drawnCount)
        let light = particles.clamped(to: drawnCount..<(drawnCount + tracerCount))
        return (massive, (light.lowerBound - drawnCount)..<(light.upperBound - drawnCount))
    }

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

    /// Each galaxy's colours from a look file's palette; a galaxy with no ramp, or past the
    /// palette's end, keeps the one-colour shading.
    public func setGalaxyColours(_ palette: [GalaxyColours]) {
        guard palette != galaxyColours else { return }
        galaxyColours = palette
        let ramps = GalaxyRamp.ramps(for: palette, slots: galaxySlots)
        mapped = GalaxyRamp.mapped(ramps)
        ramps.withUnsafeBytes { source in
            rampBuffer.contents().copyMemory(from: source.baseAddress!, byteCount: source.count)
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
        settings.apply(look)
        armPersistence = look.armPersistence
    }

    /// Encodes the whole frame. Pass a drawable texture to present, or nil to render offscreen.
    public func encode(camera: Camera, into buffer: MTLCommandBuffer, present: MTLTexture? = nil) {
        encodeSplat(camera: camera, into: buffer)
        encodePost(into: buffer, present: present)
    }

    private func encodePlainPost(into buffer: MTLCommandBuffer, present: MTLTexture?) {
        guard let compute = buffer.makeComputeCommandEncoder() else { return }
        var factor = UInt32(settings.supersample)
        var visible = min(max(fade, 0), 1)
        let target = present ?? output
        dispatch(compute, plainCompositePipeline, into: target) { encoder in
            encoder.setTexture(accumulation, index: 0)
            encoder.setTexture(target, index: 2)
            encoder.setBytes(&factor, length: 4, index: 0)
            encoder.setBytes(&visible, length: 4, index: 1)
        }
        compute.endEncoding()
    }

    /// The particle passes of a frame, as its plan lists them (`FramePlan`, which the CUDA
    /// renderer executes too). `particles` and `stages` draw part of the splat into what
    /// earlier parts left, for `render(camera:slice:)`; the first part clears and draws the
    /// star field.
    private func encodeSplat(
        camera: Camera, into buffer: MTLCommandBuffer, particles: Range<Int>? = nil,
        stages: ClosedRange<UInt32> = 0...1, first: Bool = true
    ) {
        // Its own pipelines, so a look without the web draws what it always drew.
        let web = FramePlan.drawsWeb(settings, stages: stages) ? webResources() : nil
        let plan = FramePlan(
            settings: settings, camera: camera, time: time, drawnCount: drawnCount,
            tracerCount: tracerCount, luminosityNormalisation: luminosityNormalisation,
            mapped: mapped, laceScale: web?.scale, stages: stages, first: first)
        let parts = split(particles ?? 0..<(drawnCount + tracerCount))
        let traced =
            tracerCount > 0
            ? tracers.flatMap { source in tracerPipelines.map { (source: source, pipelines: $0) } }
            : nil
        let uniformsLength = MemoryLayout<SplatUniforms>.stride
        let webLength = MemoryLayout<WebUniforms>.stride

        func descriptor(_ targets: [MTLTexture], load: MTLLoadAction = .clear)
            -> MTLRenderPassDescriptor
        {
            let pass = MTLRenderPassDescriptor()
            for (index, target) in targets.enumerated() {
                pass.colorAttachments[index].texture = target
                pass.colorAttachments[index].loadAction = load
                pass.colorAttachments[index].clearColor = MTLClearColor(
                    red: 0, green: 0, blue: 0, alpha: 0)
                pass.colorAttachments[index].storeAction = .store
            }
            return pass
        }

        // The light and the dust: one encoder for every pass that draws into them, opened by
        // the first of them.
        var frame: MTLRenderCommandEncoder?
        func frameEncoder() -> MTLRenderCommandEncoder? {
            if frame == nil {
                frame = buffer.makeRenderCommandEncoder(
                    descriptor: descriptor(
                        [accumulation, dustAccumulation], load: plan.clears ? .clear : .load))
            }
            return frame
        }

        func bindParticles(_ encoder: MTLRenderCommandEncoder) {
            encoder.setVertexBuffer(positionBuffer, offset: positionOffset, index: 0)
            encoder.setVertexBuffer(populationBuffer, offset: 0, index: 1)
            encoder.setVertexBuffer(formationBuffer, offset: 0, index: 8)
            encoder.setVertexBuffer(luminosityBuffer, offset: 0, index: 2)
            encoder.setVertexBuffer(componentBuffer, offset: 0, index: 3)
            encoder.setVertexBuffer(galaxyBuffer, offset: 0, index: 5)
            encoder.setVertexBuffer(frameBuffer, offset: 0, index: 6)
            encoder.setVertexBuffer(smoothingBuffer, offset: 0, index: 7)
            encoder.setVertexBuffer(stellarBuffer, offset: 0, index: 9)
            encoder.setVertexBuffer(traitBuffer, offset: 0, index: 10)
            encoder.setVertexBuffer(rampKeyBuffer, offset: 0, index: 11)
            encoder.setVertexBuffer(rampBuffer, offset: 0, index: 12)
            encoder.setVertexTexture(columnDensity, index: 0)
            if let traced { bindTracers(encoder, traced.source) }
        }

        // The part's massive particles, then its light tracers. Each draw throws away the
        // particles belonging to another pass in the vertex stage, before any fragment work,
        // so the cost of a second pass over the buffer is a vertex shader and nothing else.
        // Compacting each draw's particles into its own index list was measured in #35: the
        // vertex stage did not shrink and the frame got slower.
        func drawParts(
            _ encoder: MTLRenderCommandEncoder, massive: MTLRenderPipelineState,
            tracers: MTLRenderPipelineState?
        ) {
            if !parts.massive.isEmpty {
                encoder.setRenderPipelineState(massive)
                encoder.drawPrimitives(
                    type: .point, vertexStart: parts.massive.lowerBound,
                    vertexCount: parts.massive.count)
            }
            if let tracers, !parts.tracers.isEmpty {
                encoder.setRenderPipelineState(tracers)
                encoder.drawPrimitives(
                    type: .point, vertexStart: parts.tracers.lowerBound,
                    vertexCount: parts.tracers.count)
            }
        }

        for pass in plan.passes {
            var uniforms = plan.uniforms(for: pass)
            switch pass {
            case .column:
                guard
                    let encoder = buffer.makeRenderCommandEncoder(
                        descriptor: descriptor([columnDensity]))
                else { continue }
                encoder.setRenderPipelineState(countPipeline)
                encoder.setVertexBuffer(positionBuffer, offset: positionOffset, index: 0)
                encoder.setVertexBuffer(componentBuffer, offset: 0, index: 3)
                encoder.setVertexBytes(&uniforms, length: uniformsLength, index: 4)
                encoder.setVertexBuffer(formationBuffer, offset: 0, index: 8)
                encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: drawnCount)
                if let traced {
                    encoder.setRenderPipelineState(traced.pipelines.count)
                    bindTracers(encoder, traced.source)
                    encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: tracerCount)
                }
                encoder.endEncoding()

            case .webCarrier:
                guard let web, var webUniforms = plan.web,
                    let encoder = buffer.makeRenderCommandEncoder(
                        descriptor: descriptor([web.carrier, web.tags]))
                else { continue }
                encoder.setVertexBuffer(positionBuffer, offset: positionOffset, index: 0)
                encoder.setVertexBuffer(formationBuffer, offset: 0, index: 8)
                encoder.setVertexBuffer(luminosityBuffer, offset: 0, index: 2)
                encoder.setVertexBuffer(componentBuffer, offset: 0, index: 3)
                encoder.setVertexBuffer(galaxyBuffer, offset: 0, index: 5)
                encoder.setVertexBuffer(frameBuffer, offset: 0, index: 6)
                encoder.setVertexBuffer(smoothingBuffer, offset: 0, index: 7)
                encoder.setVertexBuffer(traitBuffer, offset: 0, index: 10)
                encoder.setVertexBytes(&uniforms, length: uniformsLength, index: 4)
                encoder.setVertexBytes(&webUniforms, length: webLength, index: 13)
                if let traced { bindTracers(encoder, traced.source) }
                drawParts(
                    encoder, massive: web.carrierPipeline,
                    tracers: traced == nil ? nil : web.tracerCarrier)
                encoder.endEncoding()

            case .starfield:
                guard let starBuffer, let encoder = frameEncoder() else { continue }
                encoder.setRenderPipelineState(starfieldPipeline)
                encoder.setVertexBytes(&uniforms, length: uniformsLength, index: 4)
                encoder.setVertexBuffer(starBuffer, offset: 0, index: 0)
                encoder.drawPrimitives(
                    type: .point, vertexStart: 0, vertexCount: settings.starCount)

            case .dust:
                guard let encoder = frameEncoder() else { continue }
                bindParticles(encoder)
                encoder.setVertexBytes(&uniforms, length: uniformsLength, index: 4)
                drawParts(encoder, massive: dustPipeline, tracers: traced?.pipelines.dust)

            case .paintedDust:
                guard let web, var webUniforms = plan.web, let encoder = frameEncoder()
                else { continue }
                bindParticles(encoder)
                encoder.setVertexBytes(&uniforms, length: uniformsLength, index: 4)
                encoder.setVertexBytes(&webUniforms, length: webLength, index: 13)
                drawParts(
                    encoder, massive: web.painted, tracers: traced == nil ? nil : web.tracerPainted)

            case .webResolve:
                guard let web, var webUniforms = plan.web, let encoder = frameEncoder()
                else { continue }
                encoder.setRenderPipelineState(web.resolve)
                encoder.setFragmentBuffer(frameBuffer, offset: 0, index: 0)
                encoder.setFragmentBytes(&webUniforms, length: webLength, index: 1)
                encoder.setFragmentTexture(web.lace, index: 0)
                encoder.setFragmentTexture(web.carrier, index: 1)
                encoder.setFragmentTexture(web.tags, index: 2)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

            case .stars:
                guard let encoder = frameEncoder() else { continue }
                bindParticles(encoder)
                encoder.setVertexBytes(&uniforms, length: uniformsLength, index: 4)
                drawParts(encoder, massive: splatPipeline, tracers: traced?.pipelines.splat)

            case .plain:
                guard
                    let encoder = buffer.makeRenderCommandEncoder(
                        descriptor: descriptor([accumulation]))
                else { continue }
                encoder.setRenderPipelineState(plainPipeline)
                encoder.setVertexBytes(&uniforms, length: uniformsLength, index: 4)
                encoder.setVertexBuffer(positionBuffer, offset: positionOffset, index: 0)
                encoder.setVertexBuffer(componentBuffer, offset: 0, index: 3)
                encoder.setVertexBuffer(galaxyBuffer, offset: 0, index: 5)
                encoder.setVertexBuffer(frameBuffer, offset: 0, index: 6)
                encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: drawnCount)
                if let traced {
                    encoder.setRenderPipelineState(traced.pipelines.plain)
                    bindTracers(encoder, traced.source)
                    encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: tracerCount)
                }
                encoder.endEncoding()
            }
        }
        frame?.endEncoding()
    }

    /// Nil when the web could not be built, and the dust is then drawn as it always was.
    private func webResources() -> DustWeb.Pass? {
        if webPass == nil, !webUnavailable {
            do {
                webPass = try DustWeb.Pass(
                    library: library, device: device,
                    width: settings.width * settings.supersample,
                    height: settings.height * settings.supersample)
            } catch {
                webUnavailable = true
            }
        }
        return webPass
    }

    private func encodePost(into buffer: MTLCommandBuffer, present: MTLTexture?) {
        if settings.plain { return encodePlainPost(into: buffer, present: present) }
        guard let compute = buffer.makeComputeCommandEncoder() else { return }

        var factor = UInt32(settings.supersample)
        dispatch(compute, resolvePipeline, into: resolved) { encoder in
            encoder.setTexture(accumulation, index: 0)
            encoder.setTexture(resolved, index: 2)
            encoder.setBytes(&factor, length: 4, index: 0)
        }

        let bloomOn = settings.bloomIntensity > 0
        let spikesOn = settings.spikeArms > 0 && settings.spikeIntensity >= Self.spikeVisible
        var bloom = BloomParams(
            threshold: settings.bloomThreshold, softKnee: settings.bloomSoftKnee)
        // A sharp spike source is the light one bloom level down, a little wider than a pixel so
        // taps two pixels apart do not bead, less the broad light two levels further down.
        let broadLevel = min(3, bloomDown.count - 1)
        let sharpSpikes = spikesOn && settings.spikeSharpness > 0 && broadLevel > 1
        if let first = bloomDown.first, bloomOn || spikesOn {
            dispatch(compute, brightPassPipeline, into: first) { encoder in
                encoder.setTexture(resolved, index: 0)
                encoder.setTexture(first, index: 1)
                encoder.setBytes(&bloom, length: MemoryLayout<BloomParams>.stride, index: 0)
            }
            for level in 1..<bloomDown.count where bloomOn || (sharpSpikes && level <= broadLevel) {
                dispatch(compute, downsamplePipeline, into: bloomDown[level]) { encoder in
                    encoder.setTexture(bloomDown[level - 1], index: 0)
                    encoder.setTexture(bloomDown[level], index: 1)
                }
            }
        }

        var bloomResult = bloomOn ? bloomDown.last : nil
        if bloomOn, bloomDown.count > 1 {
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
        // A sharp source is a pixel or two wide at quarter size, so the taps have to be that
        // close or a spike comes out as a string of beads. Lengths are in half-size pixels.
        if sharpSpikes {
            spike.length = settings.spikeLength / 2
            spike.samples = UInt32(min(max(28, settings.spikeLength / 2.5), 96))
        }
        if settings.spikePattern == .webb {
            spike.baseAngle = .pi / 2
            spike.shortArms = 2
            spike.shortScale = Self.webbShortArm
        }
        var spikeSource = bloomDown.first ?? resolved
        let spikeResult = sharpSpikes ? self.sharpSpikes : spikeTexture
        if sharpSpikes {
            var amount = min(max(settings.spikeSharpness, 0), 1)
            let point = bloomDown[1]
            dispatch(compute, compactPipeline, into: sharpSource) { encoder in
                encoder.setTexture(point, index: 0)
                encoder.setTexture(bloomDown[broadLevel], index: 1)
                encoder.setTexture(sharpSource, index: 2)
                encoder.setBytes(&amount, length: 4, index: 0)
            }
            spikeSource = sharpSource
        }
        if spikesOn {
            dispatch(compute, spikePipeline, into: spikeResult) { encoder in
                encoder.setTexture(spikeSource, index: 0)
                encoder.setTexture(spikeResult, index: 1)
                encoder.setBytes(&spike, length: MemoryLayout<SpikeParams>.stride, index: 0)
            }
        }

        frameSeed = frameSeed.truncatingRemainder(dividingBy: 4096) + 7.13
        var composite = CompositeParams(
            bloomIntensity: bloomResult == nil ? 0 : settings.bloomIntensity,
            stretch: settings.stretch,
            saturation: settings.saturation,
            spikeIntensity: spikesOn ? settings.spikeIntensity : 0,
            skyLevel: settings.skyLevel,
            noiseLevel: settings.noiseLevel,
            seed: frameSeed,
            whitePoint: settings.whitePoint,
            fade: min(max(fade, 0), 1),
            skyRed: settings.skyColour.x,
            skyGreen: settings.skyColour.y,
            skyBlue: settings.skyColour.z)
        let target = present ?? output
        dispatch(compute, compositePipeline, into: target) { encoder in
            encoder.setTexture(resolved, index: 0)
            encoder.setTexture(bloomResult ?? resolved, index: 1)
            encoder.setTexture(target, index: 2)
            encoder.setTexture(spikesOn ? spikeResult : resolved, index: 3)
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
        let (clock, pacer) = (gpuClock, pacer)
        buffer.addCompletedHandler { finished in
            clock.milliseconds = (finished.gpuEndTime - finished.gpuStartTime) * 1000
            pacer?.frameFinished(gpuSeconds: finished.gpuEndTime - finished.gpuStartTime)
        }
        buffer.present(drawable)
        buffer.commit()
    }

    /// Told when each presented frame finishes, so background work can fit between frames.
    public var pacer: CanvasPacer?

    /// Submits the splat pass alone while set, so `lastSplatTime` is its own span on the GPU
    /// clock and not a share of the frame's.
    public var timesSplatPass = false
    public private(set) var lastSplatTime: Double = 0

    /// Renders offscreen and reads the result back as 8-bit RGBA.
    public func render(camera: Camera) -> [UInt8] {
        guard let buffer = queue.makeCommandBuffer() else { return [] }
        if timesSplatPass, let splat = queue.makeCommandBuffer() {
            encodeSplat(camera: camera, into: splat)
            splat.commit()
            splat.waitUntilCompleted()
            lastSplatTime = splat.gpuEndTime - splat.gpuStartTime
            encodePost(into: buffer, present: nil)
        } else {
            encode(camera: camera, into: buffer)
        }
        buffer.commit()
        buffer.waitUntilCompleted()
        lastGPUTime = buffer.gpuEndTime - buffer.gpuStartTime
        return readBack()
    }

    /// As `render`, with the splat cut into command buffers of `slice` particles at most, each
    /// waited for before the next and each first handed to `pacer` with what the one before
    /// took, so the canvas's frames can go between them (#114). Additive, in the same order, so
    /// the same picture.
    public func render(camera: Camera, slice: Int, pacer: CanvasPacer? = nil) -> [UInt8] {
        let total = drawnCount + tracerCount
        guard !settings.plain, slice > 0, total > slice else {
            pacer?.waitForGap(lastGPUTime)
            return render(camera: camera)
        }
        var first = true
        var took = 0.0
        func run(_ encode: (MTLCommandBuffer) -> Void) -> Bool {
            guard let buffer = queue.makeCommandBuffer() else { return false }
            encode(buffer)
            pacer?.waitForGap(took)
            buffer.commit()
            buffer.waitUntilCompleted()
            took = buffer.gpuEndTime - buffer.gpuStartTime
            return true
        }
        for stage in UInt32(0)...1 {
            for start in Swift.stride(from: 0, to: total, by: slice) {
                let range = start..<min(start + slice, total)
                guard
                    run({
                        encodeSplat(
                            camera: camera, into: $0, particles: range, stages: stage...stage,
                            first: first)
                    })
                else { return [] }
                first = false
            }
        }
        guard run({ encodePost(into: $0, present: nil) }) else { return [] }
        lastGPUTime = took
        return readBack()
    }

    private func readBack() -> [UInt8] {
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
